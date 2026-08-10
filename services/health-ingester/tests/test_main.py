import os


def test_health_connect_route_requires_bearer_and_preserves_legacy(monkeypatch):
    monkeypatch.setenv("HEALTH_COLLECTOR_TOKEN", "route-secret")
    from app.main import app
    monkeypatch.setattr("app.db.ingest_health_connect", lambda records: {"accepted": [], "duplicate": []})
    client = app.test_client()
    assert client.post("/api/v1/health-connect/records:batch").status_code == 401
    assert client.get("/healthz").status_code == 200
    assert client.get("/metrics").status_code == 200
    assert os.environ["HEALTH_COLLECTOR_TOKEN"] == "route-secret"
