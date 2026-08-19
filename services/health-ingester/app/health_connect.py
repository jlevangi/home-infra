"""Small, dependency-free validator for Health Connect protocol v1."""

from __future__ import annotations

import hmac
import json
import math
import os
from datetime import datetime, timezone
from typing import Any

from . import hc_types

MAX_RECORDS = 500
MAX_BYTES = 2 * 1024 * 1024
TYPES = hc_types.TYPES
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


def _iso(value: str) -> str:
    """Return one stable, timezone-aware representation for archive columns."""
    return _time(value).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _epoch_millis(value: str) -> int:
    return int(_time(value).timestamp() * 1000)


def expand_health_connect_record(record: dict) -> list[dict]:
    """Map one validated protocol record to archive observation rows.

    Each record type declares its shape in hc_types; the shape decides how many
    rows a record produces and how their external_id is derived. Sleep stages
    use the stage start epoch-millis so re-collection of a revised record is
    idempotent; sample series use the sample epoch-millis; single-value records
    use the bare record key.
    """
    raw = json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    record_type, key, payload = record["recordType"], record["key"], record["payload"]
    common = {
        "start_time": _iso(record["startTime"]),
        "end_time": _iso(record["endTime"]),
        "source_name": f"Health Connect Direct / {record['originPackage']}",
        "device_name": (record.get("device") or {}).get("model"),
        "raw_payload_json": raw,
        "original_type": hc_types.original_type_for(record_type),
    }

    if record_type == "sleep":
        return [{**common, "metric_type": "sleep_segment",
                 "start_time": _iso(stage["startTime"]), "end_time": _iso(stage["endTime"]),
                 "value_numeric": None, "value_text": stage["stage"], "unit": None,
                 "external_id": f"{key}:stage:{_epoch_millis(stage['startTime'])}"}
                for stage in payload.get("stages", [])]

    if record_type in hc_types.SAMPLE_SERIES:
        field, metric_type, unit = hc_types.SAMPLE_SERIES[record_type]
        return [{**common, "metric_type": metric_type,
                 "start_time": _iso(sample["time"]), "end_time": _iso(sample["time"]),
                 "value_numeric": sample[field], "value_text": None, "unit": unit,
                 "external_id": f"{key}:sample:{_epoch_millis(sample['time'])}"}
                for sample in payload["samples"]]

    if record_type in hc_types.MULTI:
        return [{**common, "metric_type": metric_type, "value_numeric": payload[field],
                 "value_text": None, "unit": unit, "external_id": f"{key}:{field}"}
                for field, metric_type, unit in hc_types.MULTI[record_type]
                if payload.get(field) is not None]

    if record_type == "exercise_session":
        # Duration in minutes, matching the existing exercise_session rows.
        minutes = (_time(record["endTime"]) - _time(record["startTime"])).total_seconds() / 60
        return [{**common, "metric_type": "exercise_session", "value_numeric": minutes,
                 "value_text": payload.get("title"), "unit": "min", "external_id": key}]

    if record_type in hc_types.CODED:
        field, metric_type = hc_types.CODED[record_type]
        return [{**common, "metric_type": metric_type, "value_numeric": payload.get(field),
                 "value_text": None, "unit": None, "external_id": key}]

    if record_type in hc_types.TEXT_NOTES:
        return [{**common, "metric_type": hc_types.TEXT_NOTES[record_type],
                 "value_numeric": None, "value_text": payload.get("notes"),
                 "unit": None, "external_id": key}]

    field, metric_type, unit = hc_types.SCALARS[record_type]
    return [{**common, "metric_type": metric_type, "value_numeric": payload[field],
             "value_text": None, "unit": unit, "external_id": key}]


def _number(value: Any) -> float:
    """Accept any finite number. Ranges are deliberately not checked.

    Only heart rate and step count carry range checks, because those were
    written against known-bad data. Guessing plausible bounds for the other
    types would silently drop real measurements, which is the failure this
    service exists to avoid.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("invalid_value")
    if not math.isfinite(value):
        raise ValueError("invalid_value")
    return value


def _reject(record: Any, code: str, message: str) -> dict:
    key = record.get("key", "") if isinstance(record, dict) else ""
    return {"key": key if isinstance(key, str) else "", "code": code, "message": message}


def _validate(record: Any) -> None:
    if not isinstance(record, dict):
        raise ValueError("invalid_record")
    required = {"key", "keyVersion", "recordType", "originPackage", "startTime", "endTime", "collectedAt", "payload"}
    if not required <= record.keys():
        raise ValueError("missing_field")
    if not isinstance(record["key"], str) or not isinstance(record["keyVersion"], int) or isinstance(record["keyVersion"], bool):
        raise ValueError("invalid_identity")
    if record["recordType"] not in TYPES:
        # Deliberately a transient_ code. The collector quarantines permanently
        # rejected records with no way to release them, so a server that lags
        # the app's record types would destroy that data on the device. Marking
        # it transient makes the collector hold the records and retry instead.
        raise ValueError("transient_unknown_record_type")
    start, end = _time(record["startTime"]), _time(record["endTime"])
    _time(record["collectedAt"])
    if end < start:
        raise ValueError("end_before_start")
    payload = record["payload"]
    if not isinstance(payload, dict):
        raise ValueError("invalid_payload")
    record_type = record["recordType"]
    if record_type in hc_types.SAMPLE_SERIES:
        field, _, _ = hc_types.SAMPLE_SERIES[record_type]
        samples = payload.get("samples")
        if not isinstance(samples, list):
            raise ValueError("invalid_samples")
        for sample in samples:
            if not isinstance(sample, dict):
                raise ValueError("invalid_samples")
            if record_type == "heart_rate":
                bpm = sample.get("beatsPerMinute")
                if not isinstance(bpm, int) or isinstance(bpm, bool) or not 1 <= bpm <= 300:
                    raise ValueError("invalid_bpm")
            else:
                _number(sample.get(field))
            sample_time = _time(sample.get("time"))
            if not start <= sample_time <= end:
                raise ValueError("sample_outside_record")
    elif record_type == "steps":
        if not isinstance(payload.get("count"), int) or isinstance(payload["count"], bool) or payload["count"] < 0:
            raise ValueError("invalid_steps")
    elif record_type in hc_types.SCALARS:
        field, _, _ = hc_types.SCALARS[record_type]
        _number(payload.get(field))
    elif record_type in hc_types.MULTI:
        present = [field for field, _, _ in hc_types.MULTI[record_type]
                   if payload.get(field) is not None]
        if not present:
            raise ValueError("missing_field")
        for field in present:
            _number(payload[field])
    elif record_type == "exercise_session":
        exercise_type = payload.get("exerciseType")
        if not isinstance(exercise_type, int) or isinstance(exercise_type, bool):
            raise ValueError("invalid_value")
    elif record_type in hc_types.CODED:
        field, _ = hc_types.CODED[record_type]
        code = payload.get(field)
        if code is not None and (not isinstance(code, int) or isinstance(code, bool)):
            raise ValueError("invalid_value")
    elif record_type in hc_types.TEXT_NOTES:
        notes = payload.get("notes")
        if notes is not None and not isinstance(notes, str):
            raise ValueError("invalid_value")
    elif record_type == "sleep":
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
    else:
        # A type listed in hc_types.TYPES with no branch here. Treat it as not
        # yet supported rather than storing it unvalidated.
        raise ValueError("transient_unknown_record_type")


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


def validate_envelope(body: object) -> str | None:
    if not isinstance(body, dict):
        return "batch must be an object"
    if body.get("schemaVersion", 1) != 1:
        return "schemaVersion must be 1"
    collector_id = body.get("collectorId")
    if not isinstance(collector_id, str) or not collector_id.strip():
        return "collectorId must be a non-empty string"
    records = body.get("records")
    if not isinstance(records, list):
        return "records must be an array"
    if not records:
        return "records must not be empty"
    if len(records) > MAX_RECORDS:
        return "at most 500 records"
    return None


def require_collector_token(request) -> bool:
    expected = os.environ.get("HEALTH_COLLECTOR_TOKEN")
    supplied = request.headers.get("Authorization", "")
    return bool(expected) and supplied.startswith("Bearer ") and hmac.compare_digest(supplied[7:], expected)
