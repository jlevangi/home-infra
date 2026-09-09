#!/usr/bin/env python3
"""Start and inspect local OpenHands Agent Canvas conversations."""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE_URL = os.environ.get("OPENHANDS_API_URL", "http://127.0.0.1:18000")
ENV_FILE = Path.home() / ".config" / "openhands.env"


def api_key() -> str:
    for line in ENV_FILE.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and key == "LOCAL_BACKEND_API_KEY":
            return value
    raise RuntimeError(f"LOCAL_BACKEND_API_KEY missing from {ENV_FILE}")


def request(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        BASE_URL + path,
        data=data,
        method=method,
        headers={"X-Session-API-Key": api_key(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"OpenHands API {exc.code}: {exc.read().decode()}") from exc


def active_profile_id() -> str:
    return request("GET", "/api/agent-profiles")["active_agent_profile_id"]


def conversation(conversation_id: str):
    query = urllib.parse.urlencode({"ids": conversation_id})
    result = request("GET", f"/api/conversations?{query}")[0]
    if result is None:
        raise RuntimeError(f"conversation not found: {conversation_id}")
    return result


def start(args):
    workspace = Path(args.workspace).expanduser().resolve()
    if not workspace.is_dir():
        raise RuntimeError(f"workspace is not a directory: {workspace}")
    payload = {
        "workspace": {"working_dir": str(workspace), "kind": "LocalWorkspace"},
        "worktree": not args.direct,
        "initial_message": {
            "role": "user",
            "content": [{"type": "text", "text": args.prompt}],
            "run": True,
        },
        "max_iterations": args.max_iterations,
        "agent_profile_id": active_profile_id(),
        "tags": {"orchestrator": "hermes"},
    }
    result = request("POST", "/api/conversations", payload)
    print(result["id"])


def status(args):
    item = conversation(args.conversation_id)
    print(json.dumps({
        "id": item["id"],
        "title": item.get("title"),
        "status": item["execution_status"],
        "workspace": item["workspace"],
        "iterations": item.get("stats", {}).get("iteration_count"),
    }, indent=2))


def events(args):
    query = urllib.parse.urlencode({"limit": args.limit})
    print(json.dumps(request("GET", f"/api/conversations/{args.conversation_id}/events?{query}"), indent=2))


def final(args):
    print(json.dumps(request("GET", f"/api/conversations/{args.conversation_id}/agent_final_response"), indent=2))


def wait(args):
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        item = conversation(args.conversation_id)
        if item["execution_status"] not in {"running", "starting"}:
            print(item["execution_status"])
            return
        time.sleep(2)
    raise RuntimeError(f"timed out after {args.timeout}s")


def interrupt(args):
    print(json.dumps(request("POST", f"/api/conversations/{args.conversation_id}/interrupt"), indent=2))


def parser():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(required=True)
    s = sub.add_parser("start")
    s.add_argument("workspace")
    s.add_argument("prompt")
    s.add_argument("--max-iterations", type=int, default=50)
    s.add_argument("--direct", action="store_true", help="work in the checked-out repository instead of a temporary worktree")
    s.set_defaults(func=start)
    for name, func in (("status", status), ("final", final), ("interrupt", interrupt)):
        s = sub.add_parser(name)
        s.add_argument("conversation_id")
        s.set_defaults(func=func)
    s = sub.add_parser("events")
    s.add_argument("conversation_id")
    s.add_argument("--limit", type=int, default=20)
    s.set_defaults(func=events)
    s = sub.add_parser("wait")
    s.add_argument("conversation_id")
    s.add_argument("--timeout", type=int, default=600)
    s.set_defaults(func=wait)
    return p


def main():
    args = parser().parse_args()
    try:
        args.func(args)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
