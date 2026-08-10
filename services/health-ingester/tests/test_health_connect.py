from copy import deepcopy

import pytest

from app.health_connect import validate_batch, validate_envelope

START = "2026-08-10T10:00:00Z"
END = "2026-08-10T11:00:00Z"


def record(record_type="heart_rate", key="k1"):
    payload = {
        "samples": [{"time": START, "beatsPerMinute": 80}]
    } if record_type == "heart_rate" else (
        {"count": 12} if record_type == "steps" else {
            "stages": [{"stage": "deep", "startTime": START, "endTime": END}]
        }
    )
    return {
        "key": key,
        "keyVersion": 1,
        "recordType": record_type,
        "originPackage": "com.example.health",
        "startTime": START,
        "endTime": END,
        "collectedAt": "2026-08-10T12:00:00Z",
        "payload": payload,
    }


def envelope(records):
    return {"schemaVersion": 1, "collectorId": "phone-1", "records": records}


@pytest.mark.parametrize("record_type", ["heart_rate", "sleep", "steps"])
def test_android_record_schema_is_accepted(record_type):
    valid, rejected = validate_batch(envelope([record(record_type)]))
    assert len(valid) == 1
    assert valid[0]["recordType"] == record_type
    assert rejected == []


def test_old_type_and_bpm_fields_are_rejected():
    old = record()
    old["type"] = old.pop("recordType")
    old["payload"]["bpm"] = old["payload"]["samples"][0].pop("beatsPerMinute")
    valid, rejected = validate_batch(envelope([old]))
    assert valid == []
    assert rejected[0]["code"] == "missing_field"


@pytest.mark.parametrize("count", [1.5, True, -1])
def test_steps_count_must_be_nonnegative_integer(count):
    invalid = record("steps")
    invalid["payload"]["count"] = count
    valid, rejected = validate_batch(envelope([invalid]))
    assert valid == []
    assert rejected[0]["code"] == "invalid_steps"


@pytest.mark.parametrize("mutation", [
    lambda r: r["payload"]["samples"][0].update(beatsPerMinute=80.5),
    lambda r: r["payload"]["samples"][0].update(beatsPerMinute=True),
    lambda r: r["payload"]["samples"][0].update(beatsPerMinute=301),
])
def test_heart_rate_beats_per_minute_is_integer_in_range(mutation):
    invalid = record()
    mutation(invalid)
    valid, rejected = validate_batch(envelope([invalid]))
    assert valid == []
    assert rejected[0]["code"] == "invalid_bpm"


def test_duplicate_and_temporal_records_are_rejected_per_record():
    invalid_time = record("steps", "k2")
    invalid_time["endTime"] = "bad"
    valid, rejected = validate_batch(envelope([record(), record(), invalid_time]))
    assert [r["key"] for r in valid] == ["k1"]
    assert {r["code"] for r in rejected} == {"duplicate_key", "invalid_timestamp"}


@pytest.mark.parametrize("body", [
    None,
    {"schemaVersion": 2, "collectorId": "phone-1", "records": [record()]},
    {"schemaVersion": 1, "collectorId": "phone-1", "records": []},
    {"schemaVersion": 1, "collectorId": "phone-1"},
    {"schemaVersion": 1, "collectorId": "", "records": [record()]},
    {"schemaVersion": 1, "collectorId": "   ", "records": [record()]},
    {"schemaVersion": 1, "records": [record()]},
    {"schemaVersion": 1, "collectorId": "phone-1", "records": "nope"},
])
def test_invalid_envelopes_have_errors(body):
    assert validate_envelope(body) is not None


def test_valid_and_invalid_records_are_mixed():
    invalid = deepcopy(record("steps", "bad"))
    invalid["payload"]["count"] = 1.25
    valid, rejected = validate_batch(envelope([record(), invalid, record("sleep", "sleep-1")]))
    assert [r["key"] for r in valid] == ["k1", "sleep-1"]
    assert [r["key"] for r in rejected] == ["bad"]


def test_malformed_record_rejection_has_android_string_key():
    valid, rejected = validate_batch(envelope([None]))
    assert valid == []
    assert rejected == [{"key": "", "code": "invalid_record", "message": "invalid record"}]


def test_batch_limits():
    assert validate_batch({"schemaVersion": 1, "collectorId": "p", "records": [record()] * 501})[1][0]["code"] == "too_many_records"


def test_sleep_stages_must_be_contained_and_nonoverlapping():
    invalid = record("sleep")
    invalid["payload"]["stages"] = [
        {"stage": "deep", "startTime": "2026-08-10T10:00:00Z", "endTime": "2026-08-10T10:30:00Z"},
        {"stage": "bad", "startTime": "2026-08-10T10:20:00Z", "endTime": "2026-08-10T10:40:00Z"},
    ]
    assert validate_batch(envelope([invalid]))[1][0]["code"] == "invalid_stage"


def test_datetime_is_timezone_aware():
    assert validate_batch(envelope([record()]))[0]
