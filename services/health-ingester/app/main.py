"""HTTP entrypoint for the health ingester.

n8n keeps its Google Drive credential and does the listing/downloading; this
service owns parsing and persistence. The two-phase protocol (filter, then
ingest) exists so n8n only downloads files that are actually new -- the Drive
folders hold thousands of historical exports.
"""

from __future__ import annotations

import base64
import logging
import os

from flask import Flask, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from waitress import serve

from . import db, parsers

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("health-ingester")

app = Flask(__name__)

FILES_TOTAL = Counter(
    "health_ingester_files_total", "Files processed", ["format", "outcome"]
)
OBSERVATIONS_TOTAL = Counter(
    "health_ingester_observations_inserted_total", "Observations inserted", ["format"]
)
LAST_OBSERVATION = Gauge(
    "health_archive_last_observation_timestamp_seconds",
    "Unix timestamp of the most recent observation per metric type",
    ["metric_type"],
)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.post("/files/filter")
def filter_files():
    """Return the subset of candidate files that still need ingesting.

    A file is needed when it has never been processed, or when a previous run
    processed it but extracted nothing -- that is the signature of the format
    gaps this service was built to close, and those files must be retried.
    """
    body = request.get_json(force=True, silent=True) or {}
    candidates = body.get("files") or []
    index = db.processed_index()

    needed = []
    for item in candidates:
        file_id = item.get("file_id") or item.get("id")
        version_key = str(item.get("version_key") or item.get("version") or "")
        if not file_id:
            continue
        prior = index.get((file_id, version_key))
        if prior is None or prior == 0:
            needed.append({"file_id": file_id, "version_key": version_key})

    log.info("filter: %d candidates -> %d needed", len(candidates), len(needed))
    return jsonify(needed=needed, needed_count=len(needed))


@app.post("/ingest")
def ingest():
    body = request.get_json(force=True, silent=True) or {}
    meta = {
        "file_id": body.get("file_id") or body.get("id"),
        "version_key": str(body.get("version_key") or body.get("version") or ""),
        "file_name": body.get("file_name") or body.get("name") or "",
        "folder_id": body.get("folder_id"),
        "folder_name": body.get("folder_name"),
        "modified_time": body.get("modified_time"),
        "md5_checksum": body.get("md5_checksum"),
    }
    if not meta["file_id"]:
        return jsonify(error="file_id is required"), 400

    encoded = body.get("content_base64")
    if encoded is None:
        return jsonify(error="content_base64 is required"), 400
    try:
        content = base64.b64decode(encoded)
    except Exception:
        return jsonify(error="content_base64 is not valid base64"), 400

    try:
        observations, fmt = parsers.parse(content, meta)
    except Exception as exc:
        # Record the failure in the ledger so a bad file is visible rather than
        # silently absent, then surface it to the caller.
        log.exception("parse failed for %s", meta["file_name"])
        db.ingest(meta, [], status="failed", error_text=str(exc)[:500])
        FILES_TOTAL.labels(format="unknown", outcome="failed").inc()
        return jsonify(error="parse failed", detail=str(exc)[:500]), 422

    result = db.ingest(meta, observations)
    FILES_TOTAL.labels(format=fmt, outcome="processed").inc()
    OBSERVATIONS_TOTAL.labels(format=fmt).inc(result["inserted_count"])
    log.info(
        "ingested %s [%s] observations=%d inserted=%d",
        meta["file_name"], fmt, result["observation_count"], result["inserted_count"],
    )
    return jsonify(format=fmt, **result)


@app.get("/metrics")
def metrics():
    try:
        for metric_type, last_seen in db.metric_freshness().items():
            LAST_OBSERVATION.labels(metric_type=metric_type).set(last_seen)
    except Exception:
        # Never fail the scrape on a transient database issue; the counters
        # above are still worth exporting.
        log.exception("freshness refresh failed")
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


def run() -> None:
    port = int(os.environ.get("PORT", "8080"))
    log.info("health-ingester listening on :%d", port)
    serve(app, host="0.0.0.0", port=port, threads=4)


if __name__ == "__main__":
    run()
