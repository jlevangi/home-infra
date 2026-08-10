from datetime import datetime, timezone

from app.health_connect import validate_batch


def record(record_type="heart_rate", key="k1"):
    payload = {"samples": [{"time": "2026-08-10T10:00:00Z", "bpm": 80}]} if record_type == "heart_rate" else (
        {"count": 12} if record_type == "steps" else {"stages": []}
    )
    return {
        "key": key, "keyVersion": 1, "type": record_type,
        "originPackage": "com.example.health", "startTime": "2026-08-10T10:00:00Z",
        "endTime": "2026-08-10T11:00:00Z", "collectedAt": "2026-08-10T12:00:00Z",
        "payload": payload,
    }


def test_valid_record_types_are_canonical():
    valid, rejected = validate_batch({"schemaVersion": 1, "collectorId": "phone", "records": [
        record("heart_rate"), record("sleep", "k2"), record("steps", "k3")
    ]})
    assert [r["type"] for r in valid] == ["heart_rate", "sleep", "steps"]
    assert rejected == []


def test_invalid_records_are_isolated_and_duplicates_rejected():
    valid, rejected = validate_batch({"schemaVersion": 1, "collectorId": "phone", "records": [
        record(), record(key="k1"), {**record("steps", "k3"), "endTime": "bad"}
    ]})
    assert [r["key"] for r in valid] == ["k1"]
    assert {r["code"] for r in rejected} == {"duplicate_key", "invalid_timestamp"}


def test_batch_shape_and_limits():
    assert validate_batch({"schemaVersion": 2, "collectorId": "p", "records": []})[1][0]["code"] == "unsupported_schema"
    assert validate_batch({"schemaVersion": 1, "collectorId": "p", "records": []})[1][0]["code"] == "empty_batch"
    assert validate_batch({"schemaVersion": 1, "collectorId": "p", "records": [record()] * 501})[1][0]["code"] == "too_many_records"


def test_temporal_and_typed_constraints():
    bad = record("steps")
    bad["payload"]["count"] = -1
    bad["endTime"] = "2026-08-10T09:00:00Z"
    assert len(validate_batch({"schemaVersion": 1, "collectorId": "p", "records": [bad]})[1]) == 1
    bad = record("sleep")
    bad["payload"]["stages"] = [{"stage": "deep", "startTime": "2026-08-10T09:30:00Z", "endTime": "2026-08-10T10:30:00Z"}, {"stage": "bad", "startTime": "2026-08-10T10:20:00Z", "endTime": "2026-08-10T10:40:00Z"}]
    assert validate_batch({"schemaVersion": 1, "collectorId": "p", "records": [bad]})[1]

def test_bpm_must_be_1_to_300_and_types_are_known():
    bad = record()
    bad["payload"]["samples"][0]["bpm"] = 301
    unknown = record("other", "other")
    assert validate_batch({"schemaVersion": 1, "collectorId": "p", "records": [bad, unknown]})[1]
    assert len(validate_batch({"schemaVersion": 1, "collectorId": "p", "records": [bad, unknown]})[0]) == 0


def test_bearer_auth_and_route_contract(monkeypatch):
    monkeypatch.setenv("HEALTH_COLLECTOR_TOKEN", "secret-token")
    from app.main import app
    monkeypatch.setattr("app.db.ingest_health_connect", lambda records: {"accepted": [r["key"] for r in records], "duplicate": []})
    client = app.test_client()
    body = {"schemaVersion": 1, "collectorId": "phone", "records": [record()]}
    assert client.post("/api/v1/health-connect/records:batch", json=body).status_code == 401
    response = client.post("/api/v1/health-connect/records:batch", json=body, headers={"Authorization": "Bearer secret-token"})
    assert response.status_code == 200
    assert response.json["accepted"] == ["k1"]
    assert client.post("/api/v1/health-connect/records:batch", data="{", headers={"Authorization": "Bearer secret-token", "Content-Type": "application/json"}).status_code == 400
    assert client.get("/healthz").status_code == 200
    assert client.get("/metrics").status_code == 200


def test_auth_comparison_rejects_wrong_token_without_reflection(monkeypatch):
    monkeypatch.setenv("HEALTH_COLLECTOR_TOKEN", "secret-token")
    from app.main import app
    response = app.test_client().post("/api/v1/health-connect/records:batch", headers={"Authorization": "Bearer wrong-secret"})
    assert response.status_code == 401
    assert b"wrong-secret" not in response.data


def test_legacy_routes_remain_unauthenticated(monkeypatch):
    monkeypatch.delenv("HEALTH_COLLECTOR_TOKEN", raising=False)
    from app.main import app
    monkeypatch.setattr("app.db.processed_index", lambda: {})
    assert app.test_client().post("/files/filter", json={"files": []}).status_code == 200
    assert app.test_client().get("/healthz").status_code == 200
    assert app.test_client().get("/metrics").status_code == 200

def test_datetime_is_timezone_aware():
    assert datetime.fromisoformat("2026-08-10T00:00:00+00:00").tzinfo == timezone.utc
