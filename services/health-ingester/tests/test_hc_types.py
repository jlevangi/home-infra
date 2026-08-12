"""Every protocol record type must validate and expand to at least one row.

v0.5.0 of the collector expanded from 3 record types to 39 while this service
still accepted 3. The other 36 were rejected and quarantined on the device.
These tests fail if that gap ever reopens.
"""

import json
import pathlib

import pytest

from app import hc_types
from app.health_connect import expand_health_connect_record, validate_batch

START = "2026-08-10T10:00:00Z"
END = "2026-08-10T11:00:00Z"

PROTOCOL = json.loads(
    (pathlib.Path(__file__).parent.parent / "app" / "protocol" / "record_types.json").read_text()
)


def payload_for(record_type: str) -> dict:
    """Build a minimal valid payload for any record type from the registry."""
    if record_type == "sleep":
        return {"stages": [{"stage": "deep", "startTime": START, "endTime": END}]}
    if record_type == "exercise_session":
        return {"title": "Evening ride", "exerciseType": 8}
    if record_type in hc_types.SAMPLE_SERIES:
        field, _, _ = hc_types.SAMPLE_SERIES[record_type]
        value = 80 if record_type == "heart_rate" else 1.5
        return {"samples": [{"time": START, field: value}]}
    if record_type in hc_types.MULTI:
        return {field: 1.5 for field, _, _ in hc_types.MULTI[record_type]}
    if record_type in hc_types.CODED:
        field, _ = hc_types.CODED[record_type]
        return {field: 1}
    if record_type in hc_types.TEXT_NOTES:
        return {"notes": "recorded"}
    field, _, _ = hc_types.SCALARS[record_type]
    return {field: 12 if field == "count" else 1.5}


def record(record_type: str, key: str | None = None) -> dict:
    return {
        "key": key or f"health_connect:com.example.health:{record_type}:uid-1",
        "keyVersion": 1,
        "recordType": record_type,
        "originPackage": "com.example.health",
        "startTime": START,
        "endTime": END,
        "collectedAt": "2026-08-10T12:00:00Z",
        "payload": payload_for(record_type),
    }


def test_registry_matches_the_collector_protocol():
    """Guards against the app and this service drifting apart again."""
    assert sorted(hc_types.TYPES) == PROTOCOL["recordTypes"]


@pytest.mark.parametrize("record_type", sorted(hc_types.TYPES))
def test_every_record_type_is_accepted(record_type):
    valid, rejected = validate_batch(
        {"schemaVersion": 1, "collectorId": "phone-1", "records": [record(record_type)]}
    )
    assert rejected == []
    assert len(valid) == 1


@pytest.mark.parametrize("record_type", sorted(hc_types.TYPES))
def test_every_record_type_expands_to_rows(record_type):
    rows = expand_health_connect_record(record(record_type))
    assert rows, f"{record_type} produced no observation rows"
    for row in rows:
        assert row["metric_type"]
        assert row["external_id"]
        assert row["original_type"].startswith("health_connect_direct_")
        assert row["value_numeric"] is not None or row["value_text"] is not None


def test_unknown_record_type_is_transient_so_the_device_retries():
    unknown = record("steps")
    unknown["recordType"] = "not_a_real_type"
    _, rejected = validate_batch(
        {"schemaVersion": 1, "collectorId": "phone-1", "records": [unknown]}
    )
    assert rejected[0]["code"] == "transient_unknown_record_type"


@pytest.mark.parametrize("record_type, metric_type", [
    ("total_calories_burned", "calories"),
    ("active_calories_burned", "active_energy"),
    ("body_fat", "body_fat_percentage"),
    ("exercise_session", "exercise_session"),
    ("floors_climbed", "flights_climbed"),
    ("vo2_max", "vo2max"),
    ("sleep", "sleep_segment"),
    ("blood_pressure", "blood_pressure_systolic"),
])
def test_metric_type_reuses_the_archive_vocabulary(record_type, metric_type):
    """Health Connect's own names differ from the names already in the archive
    (which spans apple_health back to 2017, google_fit, health_sync and an
    earlier health_connect import). Using a second name for the same
    measurement splits the series at the point the phone took over."""
    assert metric_type in {row["metric_type"] for row in expand_health_connect_record(record(record_type))}


def test_original_type_of_sleep_is_unchanged():
    """Part of the archive's (source_id, original_type, external_id) unique key."""
    rows = expand_health_connect_record(record("sleep"))
    assert rows[0]["original_type"] == "health_connect_direct_sleep_stage"


def test_blood_pressure_becomes_two_rows():
    rows = expand_health_connect_record(record("blood_pressure"))
    assert {row["metric_type"] for row in rows} == {
        "blood_pressure_systolic", "blood_pressure_diastolic"}
    assert len({row["external_id"] for row in rows}) == 2


def test_sample_series_fans_out_per_sample():
    multi = record("speed")
    multi["payload"]["samples"] = [
        {"time": START, "speedMetersPerSecond": 1.0},
        {"time": END, "speedMetersPerSecond": 2.0},
    ]
    rows = expand_health_connect_record(multi)
    assert len(rows) == 2
    assert len({row["external_id"] for row in rows}) == 2


def test_absent_optional_multi_fields_are_skipped():
    sparse = record("nutrition")
    sparse["payload"] = {"energyKcal": 500.0}
    rows = expand_health_connect_record(sparse)
    assert [row["metric_type"] for row in rows] == ["dietary_energy"]


def test_a_batch_of_all_record_types_reaches_storage(monkeypatch):
    """Full path: validate -> expand -> insert, for all 39 types at once."""
    from app import db
    from tests.test_db import FakeConnection, FakeCursor

    cursor = FakeCursor()
    monkeypatch.setattr(db, "connect", lambda: FakeConnection(cursor))

    types = sorted(hc_types.TYPES)
    batch = {
        "schemaVersion": 1,
        "collectorId": "phone-1",
        "records": [record(t, key=f"key-{t}") for t in types],
    }
    valid, rejected = validate_batch(batch)
    assert rejected == []
    assert len(valid) == len(types)

    result = db.ingest_health_connect("phone-1", valid)
    assert result["rejected"] == []
    assert sorted(result["accepted"]) == sorted(f"key-{t}" for t in types)
    # Every row carries a metric_type, and none collide on the dedup key.
    inserted = [params for sql, params in cursor.executions
                if sql.startswith("INSERT INTO health_observations_raw")]
    assert len(inserted) == len(cursor.observations)
