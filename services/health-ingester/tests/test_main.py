import pytest


START = "2026-08-10T10:00:00Z"
END = "2026-08-10T11:00:00Z"


def record(record_type="heart_rate", key="k1"):
    payload = {"samples": [
        {"time": START, "beatsPerMinute": 80},
        {"time": "2026-08-10T10:01:00Z", "beatsPerMinute": 81},
    ]}
    if record_type == "sleep":
        payload = {"stages": [{"startTime": START, "endTime": END, "stage": "deep"}]}
    elif record_type == "steps":
        payload = {"count": 12}
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


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("HEALTH_COLLECTOR_TOKEN", "route-secret")
    from app.main import app
    return app.test_client()


def auth():
    return {"Authorization": "Bearer route-secret"}


def test_route_requires_bearer(client):
    assert client.post("/api/v1/health-connect/records:batch").status_code == 401
    assert client.post(
        "/api/v1/health-connect/records:batch",
        headers={"Authorization": "Bearer wrong-secret"},
    ).status_code == 401


@pytest.mark.parametrize("body", [
    None,
    [],
    {"schemaVersion": 2, "collectorId": "phone-1", "records": [record()]},
    {"schemaVersion": 1, "collectorId": "phone-1", "records": []},
    {"schemaVersion": 1, "collectorId": "phone-1"},
    {"schemaVersion": 1, "collectorId": "", "records": [record()]},
    {"schemaVersion": 1, "collectorId": 7, "records": [record()]},
    {"schemaVersion": 1, "records": [record()]},
    {"schemaVersion": 1, "collectorId": "phone-1", "records": "bad"},
    {"schemaVersion": 1, "collectorId": "phone-1", "records": [record()] * 501},
])
def test_invalid_envelope_is_400_without_db_call(client, monkeypatch, body):
    calls = []
    monkeypatch.setattr("app.db.ingest_health_connect", lambda collector_id, records: calls.append(records))
    response = client.post(
        "/api/v1/health-connect/records:batch", json=body, headers=auth()
    )
    assert response.status_code == 400
    assert calls == []


def test_malformed_json_is_400_without_db_call(client, monkeypatch):
    calls = []
    monkeypatch.setattr("app.db.ingest_health_connect", lambda collector_id, records: calls.append(records))
    response = client.post(
        "/api/v1/health-connect/records:batch",
        data="{",
        content_type="application/json",
        headers=auth(),
    )
    assert response.status_code == 400
    assert calls == []


def test_android_contract_mixed_batch_is_200_and_response_is_compatible(client, monkeypatch):
    invalid = record("steps", "bad")
    invalid["payload"]["count"] = 1.5
    submitted = [record(), record("sleep", "sleep-1"), record("steps", "steps-1"), invalid]
    calls = []

    def ingest(collector_id, records):
        calls.append(records)
        return {"accepted": ["k1", "sleep-1"], "duplicates": ["steps-1"]}

    monkeypatch.setattr("app.db.ingest_health_connect", ingest)
    response = client.post(
        "/api/v1/health-connect/records:batch",
        json=envelope(submitted),
        headers=auth(),
    )
    assert response.status_code == 200
    assert [item["key"] for item in calls[0]] == ["k1", "sleep-1", "steps-1"]
    assert response.json == {
        "accepted": ["k1", "sleep-1"],
        "duplicates": ["steps-1"],
        "rejected": [{"key": "bad", "code": "invalid_steps", "message": "invalid steps"}],
    }


def test_storage_rejection_is_merged_into_response(client, monkeypatch):
    monkeypatch.setattr("app.db.ingest_health_connect", lambda collector_id, records: {
        "accepted": [],
        "duplicates": [],
        "rejected": [{"key": "k1", "code": "storage_error", "message": "storage error"}],
    })
    response = client.post(
        "/api/v1/health-connect/records:batch",
        json=envelope([record()]),
        headers=auth(),
    )
    assert response.status_code == 200
    assert response.json == {
        "accepted": [],
        "duplicates": [],
        "rejected": [{"key": "k1", "code": "storage_error", "message": "storage error"}],
    }


def test_legacy_routes_remain_unauthenticated(client, monkeypatch):
    monkeypatch.setattr("app.db.processed_index", lambda: {})
    assert client.get("/healthz").status_code == 200
    assert client.get("/metrics").status_code == 200
    assert client.post("/files/filter", json={"files": []}).status_code == 200
