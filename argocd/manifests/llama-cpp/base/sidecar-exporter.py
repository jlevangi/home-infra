#!/usr/bin/env python3
# llama-swap metrics aggregator sidecar.
#
# Runs alongside llama-swap in the same Pod. Polls /running every
# POLL_INTERVAL seconds to know which model (if any) is loaded, then on
# each /metrics scrape from Prometheus:
#   1. Forwards llama-swap's own host metrics (llamaswap_*) verbatim.
#   2. For each loaded model, scrapes /upstream/<model>/metrics, adds a
#      stable model="<name>" label, and emits the lines.
#   3. Emits a synthetic llamacpp_active_model_info{model=...} gauge so
#      dashboards can show the active model without parsing labels.
#
# Inactive models are skipped because llama-swap's /upstream/<inactive>
# proxy hangs (does NOT auto-load), and we don't want every scrape to
# spawn a model load.

import http.server
import json
import re
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request

LLAMASWAP = "http://localhost:8080"
LISTEN_PORT = 9090
POLL_INTERVAL = 10
HTTP_TIMEOUT = 5

_metric_line = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(.+)$")

_running_lock = threading.Lock()
_running: list[str] = []


def _fetch(url: str, timeout: float = HTTP_TIMEOUT) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def _poll_loop() -> None:
    # /running returns {"running": [{"model": "...", "state": "ready", ...}, ...]}
    # when models are loaded, and {"running": []} when none are. The older
    # plain-string schema is also handled for forward/backward compatibility.
    global _running
    while True:
        try:
            data = json.loads(_fetch(f"{LLAMASWAP}/running"))
            new: list[str] = []
            for entry in data.get("running", []):
                if isinstance(entry, str):
                    new.append(entry)
                elif isinstance(entry, dict) and isinstance(entry.get("model"), str):
                    new.append(entry["model"])
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError):
            new = []
        with _running_lock:
            _running = new
        time.sleep(POLL_INTERVAL)


def _add_model_label(line: str, model: str) -> str:
    m = _metric_line.match(line)
    if not m:
        return line
    name, labels, value = m.groups()
    extra = f'model="{model}"'
    inner = (labels[1:-1] + "," if labels else "") + extra
    return f"{name}{{{inner}}} {value}"


def _aggregate() -> str:
    out: list[str] = []
    seen_meta: set[tuple[str, str]] = set()

    def emit_block(body: str, model: str | None) -> None:
        for line in body.splitlines():
            if not line:
                continue
            if line.startswith("# HELP ") or line.startswith("# TYPE "):
                parts = line.split(maxsplit=2)
                if len(parts) >= 3:
                    key = (parts[1], parts[0])
                    if key in seen_meta:
                        continue
                    seen_meta.add(key)
                out.append(line)
                continue
            if line.startswith("#"):
                continue
            out.append(_add_model_label(line, model) if model else line)

    try:
        emit_block(_fetch(f"{LLAMASWAP}/metrics"), model=None)
    except Exception as e:  # noqa: BLE001
        out.append(f"# llama-swap host metrics scrape failed: {e}")

    with _running_lock:
        models = list(_running)

    out.append("# HELP llamacpp_active_model_info 1 if the model is currently loaded by llama-swap")
    out.append("# TYPE llamacpp_active_model_info gauge")
    for model in models:
        out.append(f'llamacpp_active_model_info{{model="{model}"}} 1')

    for model in models:
        try:
            emit_block(_fetch(f"{LLAMASWAP}/upstream/{model}/metrics", timeout=10), model=model)
        except Exception as e:  # noqa: BLE001
            out.append(f"# upstream {model} metrics scrape failed: {e}")

    return "\n".join(out) + "\n"


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/metrics":
            body = _aggregate().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path in ("/healthz", "/"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args, **_kw) -> None:  # silence default access log
        pass


def main() -> int:
    threading.Thread(target=_poll_loop, daemon=True).start()
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", LISTEN_PORT), _Handler) as srv:
        srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
