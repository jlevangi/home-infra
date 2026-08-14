#!/usr/bin/env python3
"""
OpenAI-compatible /v1/models enrichment proxy.

WHY THIS EXISTS
---------------
LibreChat can derive each model's context window automatically, with no model names
configured on its side. processModelData() runs for ANY custom endpoint - it is
not OpenRouter-specific. But it is gated behind a zod schema requiring every
model object to carry all three of:

    id: string
    pricing: { prompt: string, completion: string }
    context_length: number

Nothing in this stack emits all three:
  * llama-swap sends only id/object/created/owned_by.
  * 9router sends `context_length` (from a static capability table that never
    matches a local alias, so it reports a generic default) and never sends
    `pricing` at all - 0 occurrences in its /v1/models route.

zod fails the WHOLE array if one element is short a field, so LibreChat silently
discarded the list and fell back to a guessed window - the "28K" in the UI.

This proxy sits in front of an OpenAI-compatible server and fixes up GET
/v1/models. Everything else is proxied through untouched, streaming included.

TWO DEPLOYMENTS, ONE SCRIPT
---------------------------
1. On the llama-swap host (--config):
       reads --ctx-size straight out of llama-swap's config.yaml
       => authoritative context for local models, and the source of truth for (2)

2. In front of 9router (--context-source):
       proxies 9router so RTK and combos still apply, then corrects the context
       of local models using the values published by (1)

CONTEXT PRECEDENCE
------------------
    1. authoritative value (--config / --context-source)   <- always wins
    2. whatever the upstream already reported              <- cloud models
    3. --default-ctx                                       <- last resort

Step 2 matters: upstream context for cloud models must never be clobbered by our
default. Step 3 only ever applies to things nobody can describe - notably
9router combos, which carry no context_length at all.
"""

import argparse
import http.client
import json
import os
import re
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Hop-by-hop headers must not be forwarded (RFC 7230 6.1).
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}

CTX_RE = re.compile(r"--ctx-size[\s=]+(\d+)")


class ContextResolver:
    """Authoritative model -> context map, from a llama-swap config and/or peers."""

    def __init__(self, config_path=None, sources=(), ttl=60):
        self.config_path = config_path
        self.sources = list(sources)
        self.ttl = ttl
        self._lock = threading.Lock()
        self._cfg_mtime = None
        self._cfg = {}
        self._remote = {}
        self._remote_at = 0.0

    # --- llama-swap config.yaml -> {model: ctx} --------------------------
    def _load_config(self):
        import yaml  # only needed in this mode; cluster deploy has no PyYAML

        with open(self.config_path, "r", encoding="utf-8") as fh:
            cfg = yaml.safe_load(fh) or {}

        found = {}
        for name, spec in (cfg.get("models") or {}).items():
            match = CTX_RE.search((spec or {}).get("cmd", ""))
            if not match:
                continue
            ctx = int(match.group(1))
            found[name] = ctx
            for alias in (spec or {}).get("aliases") or []:
                found[alias] = ctx
        return found

    def _refresh_config(self):
        if not self.config_path:
            return
        try:
            mtime = os.path.getmtime(self.config_path)
        except OSError:
            return
        if mtime == self._cfg_mtime:
            return
        try:
            self._cfg = self._load_config()
            self._cfg_mtime = mtime
            log(f"loaded {len(self._cfg)} model contexts from {self.config_path}")
        except Exception as exc:  # noqa: BLE001 - keep serving on a bad config
            log(f"WARNING: could not parse {self.config_path}: {exc}")

    # --- peer /v1/models that already reports context_length -------------
    def _refresh_remote(self):
        if not self.sources or (time.time() - self._remote_at) < self.ttl:
            return
        merged = {}
        for url in self.sources:
            try:
                with urllib.request.urlopen(url, timeout=10) as resp:
                    payload = json.load(resp)
                for model in payload.get("data", []):
                    mid, ctx = model.get("id"), model.get("context_length")
                    if isinstance(mid, str) and isinstance(ctx, int):
                        merged[mid] = ctx
            except Exception as exc:  # noqa: BLE001 - a peer being down is not fatal
                log(f"WARNING: context source {url} unavailable: {exc}")
        # Only replace on success; a transient outage keeps the last good map.
        if merged:
            self._remote = merged
            self._remote_at = time.time()
            log(f"refreshed {len(merged)} model contexts from peers")
        elif self.sources:
            self._remote_at = time.time()  # back off rather than hammer

    def lookup(self, model_id):
        """Authoritative context for model_id, or None."""
        with self._lock:
            self._refresh_config()
            self._refresh_remote()
            for table in (self._cfg, self._remote):
                if model_id in table:
                    return table[model_id]
                # 9router exposes models as "<prefix>/<model>"; match the tail.
                if "/" in model_id:
                    tail = model_id.rsplit("/", 1)[1]
                    if tail in table:
                        return table[tail]
        return None


_LOG_FH = None


def log(msg):
    """Safe under pythonw.exe, where sys.stdout is None and print() would raise."""
    line = f"[shim] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    if _LOG_FH is not None:
        try:
            _LOG_FH.write(line + "\n")
            _LOG_FH.flush()
        except Exception:  # noqa: BLE001 - logging must never take the server down
            pass
    try:
        if sys.stdout is not None:
            print(line, flush=True)
    except Exception:  # noqa: BLE001
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "models-enrichment-shim"

    def log_message(self, fmt, *args):
        pass  # we log the interesting things ourselves

    def do_GET(self):
        if self.path.split("?")[0].endswith("/v1/models") or self.path.split("?")[0] == "/models":
            self.handle_models()
        else:
            self.proxy()

    do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = lambda self: self.proxy()

    def _upstream(self, timeout):
        return http.client.HTTPConnection(self.server.upstream_host,
                                          self.server.upstream_port, timeout=timeout)

    def _fwd_headers(self):
        return {k: v for k, v in self.headers.items()
                if k.lower() not in HOP_BY_HOP and k.lower() != "host"}

    def handle_models(self):
        try:
            conn = self._upstream(30)
            conn.request("GET", self.path, headers=self._fwd_headers())
            resp = conn.getresponse()
            raw = resp.read()
            status = resp.status
            conn.close()
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR: upstream unreachable: {exc}")
            self.send_error(502, "upstream unreachable")
            return

        if status != 200:
            self.send_response(status)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return

        try:
            payload = json.loads(raw)
            enriched = defaulted = 0
            for model in payload.get("data", []):
                mid = model.get("id")
                if not mid:
                    continue
                model.setdefault("pricing", {"prompt": "0", "completion": "0"})

                authoritative = self.server.contexts.lookup(mid)
                if authoritative is not None:
                    model["context_length"] = authoritative
                    enriched += 1
                elif not isinstance(model.get("context_length"), int):
                    model["context_length"] = self.server.default_ctx
                    defaulted += 1
            body = json.dumps(payload).encode("utf-8")
            log(f"/v1/models: {len(payload.get('data', []))} models, "
                f"{enriched} authoritative, {defaulted} defaulted")
        except (ValueError, AttributeError) as exc:
            log(f"WARNING: passing models through unmodified: {exc}")
            body = raw

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        try:
            # No timeout: generation on a cold model can take minutes.
            conn = self._upstream(None)
            conn.request(self.command, self.path, body=body, headers=self._fwd_headers())
            resp = conn.getresponse()
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR: upstream unreachable: {exc}")
            self.send_error(502, "upstream unreachable")
            return

        self.send_response(resp.status)
        for key, value in resp.getheaders():
            if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        # Re-frame as connection-close so SSE streams without needing chunking.
        self.send_header("Connection", "close")
        self.end_headers()

        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()  # critical: SSE must not sit in a buffer
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
        self.close_connection = True


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9081)
    ap.add_argument("--upstream-host", default="127.0.0.1")
    ap.add_argument("--upstream-port", type=int, default=9080)
    ap.add_argument("--config", default=None,
                    help="llama-swap config.yaml to read --ctx-size from (needs PyYAML)")
    ap.add_argument("--context-source", action="append", default=[], metavar="URL",
                    help="OpenAI-compatible /v1/models URL that already reports "
                         "context_length; used as the authoritative map. Repeatable.")
    ap.add_argument("--source-ttl", type=int, default=60,
                    help="seconds to cache --context-source results (default 60)")
    ap.add_argument("--default-ctx", type=int, default=32768,
                    help="context for models nobody can describe, e.g. 9router combos "
                         "(default 32768 - same ballpark LibreChat guesses today, so "
                         "this is never a regression). Every model MUST carry a number "
                         "or LibreChat rejects the entire list.")
    ap.add_argument("--log-file", default=None,
                    help="append log lines here. Strongly recommended when launched via "
                         "pythonw.exe, which gives the process no stdout at all.")
    args = ap.parse_args()

    if args.log_file:
        global _LOG_FH
        try:
            _LOG_FH = open(args.log_file, "a", encoding="utf-8")
        except OSError as exc:
            print(f"[shim] WARNING: cannot open log file {args.log_file}: {exc}")

    server = ThreadingHTTPServer((args.listen, args.port), Handler)
    server.daemon_threads = True
    server.upstream_host = args.upstream_host
    server.upstream_port = args.upstream_port
    server.default_ctx = args.default_ctx
    server.contexts = ContextResolver(args.config, args.context_source, args.source_ttl)

    log(f"listening on {args.listen}:{args.port} -> {args.upstream_host}:{args.upstream_port}")
    if args.config:
        log(f"context source: {args.config}")
    for url in args.context_source:
        log(f"context source: {url}")
    log(f"default context for unknown models: {args.default_ctx}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")


if __name__ == "__main__":
    main()
