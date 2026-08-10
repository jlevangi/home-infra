"""Small, dependency-free validator for Health Connect protocol v1."""

from __future__ import annotations

import hmac
import json
from datetime import datetime
from typing import Any

MAX_RECORDS = 500
MAX_BYTES = 2 * 1024 * 1024
TYPES = {"heart_rate", "sleep", "steps"}
STAGES = {"awake", "sleeping", "out_of_bed", "light", "deep", "rem", "unknown"}


def _time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("invalid_timestamp") from exc
    if parsed.tzinfo is None:
        raise ValueError("invalid_timestamp")
    return parsed


def _reject(record: Any, code: str, message: str) -> dict:
    return {"key": record.get("key") if isinstance(record, dict) else None, "code": code, "message": message}


def _validate(record: Any) -> None:
    if not isinstance(record, dict):
        raise ValueError("invalid_record")
    required = {"key", "keyVersion", "type", "originPackage", "startTime", "endTime", "collectedAt", "payload"}
    if not required <= record.keys():
        raise ValueError("missing_field")
    if not isinstance(record["key"], str) or not isinstance(record["keyVersion"], int):
        raise ValueError("invalid_identity")
    if record["type"] not in TYPES:
        raise ValueError("unknown_record_type")
    start, end = _time(record["startTime"]), _time(record["endTime"])
    _time(record["collectedAt"])
    if end < start:
        raise ValueError("end_before_start")
    payload = record["payload"]
    if not isinstance(payload, dict):
        raise ValueError("invalid_payload")
    if record["type"] == "heart_rate":
        samples = payload.get("samples")
        if not isinstance(samples, list):
            raise ValueError("invalid_samples")
        for sample in samples:
            if not isinstance(sample, dict) or not 1 <= sample.get("bpm", 0) <= 300:
                raise ValueError("invalid_bpm")
            sample_time = _time(sample.get("time"))
            if not start <= sample_time <= end:
                raise ValueError("sample_outside_record")
    elif record["type"] == "steps":
        if not isinstance(payload.get("count"), (int, float)) or isinstance(payload["count"], bool) or payload["count"] < 0:
            raise ValueError("invalid_steps")
    else:
        stages = payload.get("stages", [])
        if not isinstance(stages, list):
            raise ValueError("invalid_stages")
        intervals = []
        for stage in stages:
            if not isinstance(stage, dict) or stage.get("stage") not in STAGES:
                raise ValueError("invalid_stage")
            stage_start, stage_end = _time(stage.get("startTime")), _time(stage.get("endTime"))
            if stage_end < stage_start or stage_start < start or stage_end > end:
                raise ValueError("stage_outside_session")
            intervals.append((stage_start, stage_end))
        if any(current[0] < previous[1] for previous, current in zip(sorted(intervals), sorted(intervals)[1:])):
            raise ValueError("overlapping_stages")


def validate_batch(body: object) -> tuple[list[dict], list[dict]]:
    if not isinstance(body, dict):
        return [], [{"key": None, "code": "invalid_batch", "message": "batch must be an object"}]
    if body.get("schemaVersion", 1) != 1:
        return [], [{"key": None, "code": "unsupported_schema", "message": "schemaVersion must be 1"}]
    records = body.get("records")
    if not isinstance(records, list):
        return [], [{"key": None, "code": "invalid_batch", "message": "records must be an array"}]
    if not records:
        return [], [{"key": None, "code": "empty_batch", "message": "records must not be empty"}]
    if len(records) > MAX_RECORDS:
        return [], [{"key": None, "code": "too_many_records", "message": "at most 500 records"}]
    valid, rejected, keys = [], [], set()
    for record in records:
        try:
            if len(json.dumps(record, separators=(",", ":"), ensure_ascii=False).encode()) > MAX_BYTES:
                raise ValueError("oversized_record")
            _validate(record)
            if record["key"] in keys:
                raise ValueError("duplicate_key")
            keys.add(record["key"])
            valid.append(record)
        except (ValueError, TypeError, OverflowError) as exc:
            code = str(exc) or "invalid_record"
            rejected.append(_reject(record, code, code.replace("_", " ")))
    return valid, rejected


def require_collector_token(request) -> bool:
    expected = __import__("os").environ.get("HEALTH_COLLECTOR_TOKEN")
    supplied = request.headers.get("Authorization", "")
    return bool(expected) and supplied.startswith("Bearer ") and hmac.compare_digest(supplied[7:], expected)
