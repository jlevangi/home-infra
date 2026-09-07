"""HTTP entrypoint for the health ingester.

n8n keeps its Google Drive credential and does the listing/downloading; this
service owns parsing and persistence. The two-phase protocol (filter, then
ingest) exists so n8n only downloads files that are actually new -- the Drive
folders hold thousands of historical exports.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from datetime import datetime, timezone
from uuid import uuid4

from flask import Flask, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from waitress import serve

from . import db, parsers
from .health_connect import (
    collector_batch_metadata,
    TYPES,
    require_collector_token,
    validate_batch,
    validate_envelope,
)

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("health-ingester")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 * 1024

FILES_TOTAL = Counter(
    "health_ingester_files_total", "Files processed", ["format", "outcome"]
)
OBSERVATIONS_TOTAL = Counter(
    "health_ingester_observations_inserted_total", "Observations inserted", ["format"]
)
LAST_OBSERVATION = Gauge(
    "health_archive_last_observation_timestamp_seconds",
    "Unix timestamp of the most recent observation per source system and metric type",
    ["source_system", "metric_type"],
)
COLLECTOR_RECORDS = Counter(
    "health_collector_records_total", "Collector records", ["record_type", "origin", "outcome"]
)
COLLECTOR_AUTH_FAILURES = Counter(
    "health_collector_auth_failures_total", "Collector authentication failures"
)
COLLECTOR_UNKNOWN_TYPES = Counter(
    "health_collector_unknown_record_type_total",
    "Records whose recordType this service does not recognise",
    ["record_type"],
)
COLLECTOR_BATCHES = Counter(
    "health_collector_batches_total", "Collector HTTP batches", ["outcome"]
)
COLLECTOR_BATCH_RECORDS = Counter(
    "health_collector_batch_records_total", "Records submitted by collector batches", ["outcome"]
)
COLLECTOR_BATCH_RECEIPT_LAG = Gauge(
    "health_collector_batch_receipt_lag_seconds",
    "Seconds between newest observation and HTTP receipt, by collector outcome",
    ["outcome"],
)


@app.post("/api/v1/health-connect/records:batch")
def health_connect_batch():
    request_id = str(uuid4())
    received_at = datetime.now(timezone.utc)
    if not require_collector_token(request):
        COLLECTOR_AUTH_FAILURES.inc()
        COLLECTOR_BATCHES.labels(outcome="unauthorized").inc()
        log.info("collector batch rejected request_id=%s outcome=unauthorized", request_id)
        return jsonify(error="unauthorized"), 401
    if not request.is_json:
        COLLECTOR_BATCHES.labels(outcome="malformed").inc()
        log.info("collector batch rejected request_id=%s outcome=malformed", request_id)
        return jsonify(error="malformed JSON"), 400
    body = request.get_json(silent=True)
    if body is None:
        COLLECTOR_BATCHES.labels(outcome="malformed").inc()
        log.info("collector batch rejected request_id=%s outcome=malformed", request_id)
        return jsonify(error="malformed JSON"), 400
    if error := validate_envelope(body):
        COLLECTOR_BATCHES.labels(outcome="invalid").inc()
        log.info("collector batch rejected request_id=%s outcome=invalid", request_id)
        return jsonify(error=error), 400
    metadata = collector_batch_metadata(body, request_id, received_at)
    valid, rejected = validate_batch(body)
    COLLECTOR_BATCHES.labels(outcome="received").inc()
    COLLECTOR_BATCH_RECORDS.labels(outcome="submitted").inc(metadata["submitted_count"])
    if metadata["newest_observation_at"]:
        COLLECTOR_BATCH_RECEIPT_LAG.labels(outcome="received").set(
            max(0, (received_at - metadata["newest_observation_at"]).total_seconds())
        )
    try:
        db.record_collector_run(metadata)
        result = db.ingest_health_connect(metadata, valid)
    except Exception:
        COLLECTOR_BATCHES.labels(outcome="storage_error").inc()
        try:
            db.mark_collector_run_failed(metadata)
        except Exception:
            log.exception("collector batch failure could not be recorded request_id=%s", request_id)
        log.exception("collector batch storage failed request_id=%s", request_id)
        return jsonify(error="storage unavailable"), 503
    accepted, duplicates = result.get("accepted", []), result.get("duplicates", [])
    rejected.extend(result.get("rejected", []))
    outcome = "validation_rejected" if not valid else ("partial" if rejected else "completed")
    try:
        db.finish_collector_run(metadata, accepted, duplicates, rejected, outcome)
    except Exception:
        COLLECTOR_BATCHES.labels(outcome="storage_error").inc()
        try:
            db.mark_collector_run_failed(metadata)
        except Exception:
            log.exception("collector batch failure could not be finalized request_id=%s", request_id)
        log.exception("collector batch finalization failed request_id=%s", request_id)
        return jsonify(error="storage unavailable"), 503
    COLLECTOR_BATCHES.labels(outcome=outcome).inc()
    submitted = {
        r.get("key"): r for r in body.get("records", []) if isinstance(r, dict)
    }
    for record in valid:
        record_outcome = "accepted" if record["key"] in accepted else (
            "duplicate" if record["key"] in duplicates else None
        )
        if record_outcome:
            COLLECTOR_RECORDS.labels(
                record_type=record["recordType"],
                origin=record.get("originPackage", "unknown"),
                outcome=record_outcome,
            ).inc()

    # Rejections are reported by key only, so recover each one's type from the
    # request. Labelling every rejection "unknown" is what hid the collector
    # sending 39 record types at a service that accepted 3.
    for rejection in rejected:
        source = submitted.get(rejection.get("key")) or {}
        record_type = source.get("recordType")
        if not isinstance(record_type, str) or record_type not in TYPES:
            record_type = "unknown"
        origin = source.get("originPackage", "unknown")
        if not isinstance(origin, str) or not origin:
            origin = "unknown"
        COLLECTOR_RECORDS.labels(record_type=record_type, origin=origin, outcome="rejected").inc()
        if rejection.get("code") == "transient_unknown_record_type":
            COLLECTOR_UNKNOWN_TYPES.labels(record_type=record_type).inc()
    COLLECTOR_BATCH_RECORDS.labels(outcome="accepted").inc(len(accepted))
    COLLECTOR_BATCH_RECORDS.labels(outcome="duplicate").inc(len(duplicates))
    COLLECTOR_BATCH_RECORDS.labels(outcome="rejected").inc(len(rejected))
    log.info(
        "collector batch %s",
        json.dumps({
            "request_id": request_id,
            "collector_id": metadata["collector_id"],
            "submitted": metadata["submitted_count"],
            "accepted": len(accepted),
            "duplicate": len(duplicates),
            "rejected": len(rejected),
            "oldest_observation_at": metadata["oldest_observation_at"].isoformat() if metadata["oldest_observation_at"] else None,
            "newest_observation_at": metadata["newest_observation_at"].isoformat() if metadata["newest_observation_at"] else None,
            "origin_counts": metadata["origin_counts"],
            "record_type_counts": metadata["record_type_counts"],
        }, sort_keys=True, separators=(",", ":")),
    )
    return jsonify(accepted=accepted, duplicates=duplicates, rejected=rejected)


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
        if prior is None or (prior[0] == 0 and not prior[1]):
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

    # Legacy ingestion recorded unsupported files as processed with zero rows.
    # Mark files that this service has deliberately handled so the filter can
    # retry legacy zero-yield rows once without retrying known-empty files
    # forever.
    handled_empty = "handled-empty:health-ingester-v2" if not observations else None
    result = db.ingest(meta, observations, error_text=handled_empty)
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
        for (source_system, metric_type), last_seen in db.metric_freshness().items():
            LAST_OBSERVATION.labels(source_system=source_system, metric_type=metric_type).set(last_seen)
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
