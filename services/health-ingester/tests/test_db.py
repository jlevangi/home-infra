import json

from app import db
from app.health_connect import expand_health_connect_record


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
        "device": {"manufacturer": "Samsung", "model": "SM-S928U", "type": "phone"},
        "startTime": START,
        "endTime": END,
        "collectedAt": "2026-08-10T12:00:00Z",
        "payload": payload,
    }


def test_freshness_query_uses_index_driven_latest_lookups_and_completion_time():
    sql = " ".join(db._FRESHNESS_SQL.split()).lower()
    assert "select distinct source.id as source_id" in sql
    assert "cross join lateral" in sql
    assert "where observation.source_id = metrics.source_id" in sql
    assert "source.source_system = 'health_connect_direct'" in sql
    assert "order by text_to_timestamptz_immutable(observation.start_time) desc" in sql
    assert "order by text_to_timestamptz_immutable(observation.end_time) desc" in sql
    assert "metrics.metric_type <> 'sleep_segment'" in sql
    assert "metrics.metric_type = 'sleep_segment'" in sql
    assert "group by source.source_system, observation.metric_type" not in sql


def test_expands_android_records_to_archive_rows():
    heart = expand_health_connect_record(record())
    sleep = expand_health_connect_record(record("sleep", "sleep-1"))
    steps = expand_health_connect_record(record("steps", "steps-1"))

    assert [(row["metric_type"], row["original_type"], row["unit"]) for row in heart] == [
        ("heart_rate", "health_connect_direct_heart_rate", "count/min"),
        ("heart_rate", "health_connect_direct_heart_rate", "count/min"),
    ]
    assert heart[0]["external_id"] == "k1:sample:1786356000000"
    assert heart[0]["start_time"] == heart[0]["end_time"] == START
    assert sleep[0]["external_id"] == "sleep-1:stage:1786356000000"
    assert sleep[0]["value_text"] == "deep"
    assert steps[0]["external_id"] == "steps-1"
    assert steps[0]["value_numeric"] == 12
    for row in heart + sleep + steps:
        assert row["source_name"] == "Health Connect Direct / com.example.health"
        assert row["device_name"] == "SM-S928U"
        assert json.loads(row["raw_payload_json"])["key"] in {"k1", "sleep-1", "steps-1"}
        assert " " not in row["raw_payload_json"]


def test_sql_contract_is_parameterized_and_idempotent():
    assert "%s" in db._SOURCE_SQL and "%s" in db._OBSERVATION_SQL
    assert "health_connect_direct" == db.HEALTH_CONNECT_SOURCE_SYSTEM
    assert "ON CONFLICT (source_id, original_type, external_id) DO NOTHING" in db._OBSERVATION_SQL
    assert "android_health_connect" not in db._OBSERVATION_SQL


class FakeCursor:
    def __init__(self, fail_external=None):
        self.sources = {}
        self.observations = set()
        self.last = None
        self.fail_external = fail_external
        self.executions = []
        self.deleted_sessions = []
        self.revisions = {}
        self.current = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, sql, params=None):
        self.executions.append((sql, params))
        stripped = sql.strip()
        if stripped.startswith("SELECT content_hash, provider_modified_at"):
            self.last = self.current.get((params[0], params[1]))
        elif stripped.startswith("SELECT count(*) AS revisions"):
            seen = [k for k in self.revisions if k[:3] == (params[0], params[1], params[2])]
            self.last = {"revisions": len(seen), "latest": max((self.revisions[k][4] for k in seen if self.revisions[k][4]), default=None)}
        elif stripped.startswith("INSERT INTO health_connect_record_revisions"):
            self.revisions[(params[0], params[1], params[2], params[4])] = params
            self.last = None
        elif stripped.startswith("INSERT INTO health_connect_record_current"):
            self.current[(params[0], params[1])] = {"content_hash": params[3], "provider_modified_at": params[4], "source_id": params[2]}
            self.last = None
        elif stripped.startswith("SELECT id FROM health_sources"):
            self.last = {"id": 1}
        elif stripped.startswith("UPDATE health_connect_record_current"):
            self.current[(params[1], params[2])]["provider_modified_at"] = params[0]
            self.last = None
        elif stripped.startswith("INSERT INTO health_sources"):
            key = (params[0], params[1], params[4])
            self.sources.setdefault(key, len(self.sources) + 1)
            self.last = {"id": self.sources[key]}
        elif stripped.startswith("DELETE FROM health_observations_raw"):
            self.deleted_sessions.append(sql)
            self.last = None
        elif stripped.startswith("DELETE FROM"):
            self.deleted_sessions.append(sql)
            self.last = None
        elif stripped.startswith("INSERT INTO health_observations_raw"):
            external_id = params[10]
            if external_id == self.fail_external:
                raise RuntimeError("secret SQL detail")
            key = (params[0], params[2], external_id)
            if key in self.observations:
                self.last = None
            else:
                self.observations.add(key)
                self.last = {"id": len(self.observations)}
        elif stripped.startswith("SELECT count(*) AS better_existing"):
            self.last = {"better_existing": 0}
        elif stripped.startswith("SELECT count(*) AS stage_count"):
            self.last = {"stage_count": 0}
        else:
            self.last = None

    def fetchone(self):
        return self.last
    def fetchall(self):
        return []


class FakeConnection:
    def __init__(self, cursor):
        self._cursor = cursor
        self.commits = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def cursor(self):
        return self._cursor

    def commit(self):
        self.commits += 1


def batch_metadata():
    return {
        "request_id": "00000000-0000-0000-0000-000000000001",
        "received_at": "2026-08-10T12:00:00Z",
        "collector_id": "collector-1",
        "submitted_count": 1,
        "oldest_observation_at": None,
        "newest_observation_at": None,
        "origin_counts": {"com.example.health": 1},
        "record_type_counts": {"steps": 1},
    }


def test_batch_receipt_is_written_and_finalized_on_separate_transactions(monkeypatch):
    cursor = FakeCursor()
    connections = [FakeConnection(cursor), FakeConnection(cursor)]
    monkeypatch.setattr(db, "connect", lambda: connections.pop(0))

    db.record_collector_run(batch_metadata())
    db.finish_collector_run(batch_metadata(), ["accepted"], ["duplicate"], [{"key": "bad"}], "partial")

    assert connections == []
    assert cursor.executions[0][0] == db._COLLECTOR_RUN_RETENTION_SQL
    assert "INSERT INTO collector_sync_runs" in cursor.executions[1][0]
    assert "status = %s" in cursor.executions[-1][0]


def test_batch_receipt_failure_can_be_marked_failed_after_ingestion_error(monkeypatch):
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    db.record_collector_run(batch_metadata())
    db.mark_collector_run_failed(batch_metadata())

    assert connection.commits == 2
    assert cursor.executions[-1][1] == (0, 0, 0, "failed", batch_metadata()["request_id"])


def test_ingestion_accepts_then_classifies_replay_as_duplicate(monkeypatch):
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    first = db.ingest_health_connect("collector-1", [record("steps", "steps-1")])
    second = db.ingest_health_connect("collector-1", [record("steps", "steps-1")])

    assert first == {"accepted": ["steps-1"], "duplicates": [], "rejected": []}
    assert second == {"accepted": [], "duplicates": ["steps-1"], "rejected": []}
    source_params = next(params for sql, params in cursor.executions if sql.startswith("INSERT INTO health_sources"))
    assert source_params[:3] == ("health_connect_direct", "Health Connect Direct / com.example.health", "android_health_connect")


def test_collector_identity_scopes_direct_source(monkeypatch):
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    first = db.ingest_health_connect("collector-1", [record("steps", "same-key")])
    second = db.ingest_health_connect("collector-2", [record("steps", "same-key")])

    assert first == {"accepted": ["same-key"], "duplicates": [], "rejected": []}
    assert second == {"accepted": ["same-key"], "duplicates": [], "rejected": []}
    assert len(cursor.sources) == 2


def test_storage_failure_rolls_back_record_and_keeps_peer(monkeypatch):
    cursor = FakeCursor(fail_external="bad")
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    result = db.ingest_health_connect("collector-1", [record("steps", "bad"), record("steps", "good")])

    assert result == {
        "accepted": ["good"],
        "duplicates": [],
        "rejected": [{"key": "bad", "code": "storage_error", "message": "storage error"}],
    }
    sql = [statement for statement, _ in cursor.executions]
    assert any(statement.startswith("ROLLBACK TO SAVEPOINT") for statement in sql)
    assert "secret SQL detail" not in json.dumps(result)
    assert connection.commits == 1


def test_sleep_supersession_triggers_dedup_delete(monkeypatch):
    """When a sleep record arrives, existing overlapping sessions on the same
    wake_date are deleted before inserting the new (refined) session."""
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    result = db.ingest_health_connect("collector-1", [record("sleep", "sleep-new")])

    assert result == {"accepted": ["sleep-new"], "duplicates": [], "rejected": []}
    # The dedup DELETE must have fired before the INSERT
    delete_idx = next(i for i, (sql, _) in enumerate(cursor.executions)
                      if sql.strip().startswith("DELETE FROM health_observations_raw"))
    insert_idx = next(i for i, (sql, _) in enumerate(cursor.executions)
                      if sql.strip().startswith("INSERT INTO health_observations_raw"))
    assert delete_idx < insert_idx
    assert len(cursor.deleted_sessions) == 1


def test_non_sleep_records_skip_dedup(monkeypatch):
    """Non-sleep records must not trigger the dedup DELETE."""
    cursor = FakeCursor()
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    db.ingest_health_connect("collector-1", [record("steps", "steps-1")])
    assert len(cursor.deleted_sessions) == 0


def test_stale_sleep_resend_skipped_when_better_exists(monkeypatch):
    """When an existing overlapping session has >= stage count, the incoming
    stale re-send is classified as duplicate, not accepted, and no DELETE fires."""
    cursor = FakeCursor()
    # Override: report 1 better existing session
    cursor._better_existing = 1

    class StaleFakeCursor(FakeCursor):
        def execute(self, sql, params=None):
            stripped = sql.strip()
            if stripped.startswith("SELECT count(*) AS better_existing"):
                self.executions.append((sql, params))
                self.last = {"better_existing": 1}
                return
            super().execute(sql, params)

    cursor = StaleFakeCursor()
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    result = db.ingest_health_connect("collector-1", [record("sleep", "sleep-old")])
    assert result == {"accepted": [], "duplicates": ["sleep-old"], "rejected": []}
    assert len(cursor.deleted_sessions) == 0

class SameSessionFakeCursor(FakeCursor):
    """Reports a stored stage count for the incoming session key."""

    def __init__(self, stored_stage_count):
        super().__init__()
        self.stored_stage_count = stored_stage_count
        self.stale_prunes = []

    def execute(self, sql, params=None):
        stripped = sql.strip()
        if stripped.startswith("SELECT count(*) AS stage_count"):
            self.executions.append((sql, params))
            self.last = {"stage_count": self.stored_stage_count}
            return
        if "external_id <> ALL" in stripped:
            self.stale_prunes.append(params)
        super().execute(sql, params)


def test_recollected_sleep_session_prunes_stage_rows_it_no_longer_contains(monkeypatch):
    """A re-collection of the same session must clear stage rows the new stage
    list no longer contains — ON CONFLICT DO NOTHING cannot remove them."""
    cursor = SameSessionFakeCursor(stored_stage_count=1)
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    db.ingest_health_connect("collector-1", [record("sleep", "sleep-1")])

    assert len(cursor.stale_prunes) == 1
    source_id, prefix, keep = cursor.stale_prunes[0]
    assert prefix == "sleep-1:stage:%"
    assert keep == ["sleep-1:stage:1786356000000"]


def test_stale_same_session_replay_does_not_truncate_refined_session(monkeypatch):
    """A replay carrying fewer stages than are already stored for the session
    must leave the stored stages alone."""
    cursor = SameSessionFakeCursor(stored_stage_count=9)
    connection = FakeConnection(cursor)
    monkeypatch.setattr(db, "connect", lambda: connection)

    db.ingest_health_connect("collector-1", [record("sleep", "sleep-1")])

    assert cursor.stale_prunes == []


def test_sleep_overlap_regex_matches_samsung_and_health_connect():
    import re
    pattern = r"^(health_connect:[^:]+|samsung_health):sleep:[^:]+:stage:[0-9]+$"
    assert re.search(pattern, "health_connect:com.google.android.apps.fitness:sleep:43b16f80:stage:1789441740000")
    assert re.search(pattern, "samsung_health:sleep:000001a0-d1e9-9373-ea04-d056fb981b6f:stage:1790258850000")
    assert not re.search(pattern, "health_sync:sleep:12345")
    assert not re.search(pattern, "samsung_health:heart_rate:12345")
    assert "samsung_health" in db._SLEEP_OVERLAP_CHECK_SQL
    assert "samsung_health" in db._SLEEP_DEDUP_SQL


def test_collector_correction_replaces_projection_and_preserves_each_revision(monkeypatch):
    cursor = FakeCursor()
    monkeypatch.setattr(db, "connect", lambda: FakeConnection(cursor))
    original = record("heart_rate", "same-key")
    corrected = record("heart_rate", "same-key")
    corrected["payload"]["samples"][0]["beatsPerMinute"] = 99
    replayed = record("heart_rate", "same-key")

    first = db.ingest_health_connect(batch_metadata(), [original])
    second = db.ingest_health_connect(batch_metadata(), [corrected])
    third = db.ingest_health_connect(batch_metadata(), [replayed])

    assert first["accepted"] == ["same-key"]
    assert second["accepted"] == ["same-key"]
    assert third["duplicates"] == ["same-key"]
    assert len(cursor.revisions) == 2


def test_provider_timestamp_rejects_stale_replay_and_accepts_aba_newer(monkeypatch):
    cursor = FakeCursor()
    monkeypatch.setattr(db, "connect", lambda: FakeConnection(cursor))
    a = record("steps", "steps-revised")
    a["lastModifiedTime"] = "2026-08-10T12:00:00Z"
    b = record("steps", "steps-revised")
    b["payload"]["count"] = 99
    b["lastModifiedTime"] = "2026-08-10T12:01:00Z"
    stale_a = {**a, "lastModifiedTime": "2026-08-10T12:00:00Z"}
    newer_a = {**a, "lastModifiedTime": "2026-08-10T12:02:00Z"}

    results = [db.ingest_health_connect(batch_metadata(), [item]) for item in (a, b, stale_a, newer_a)]

    assert results[0]["accepted"] == ["steps-revised"]
    assert results[1]["accepted"] == ["steps-revised"]
    assert results[2]["duplicates"] == ["steps-revised"]
    assert results[3]["accepted"] == ["steps-revised"]
    assert len(cursor.revisions) == 3


def test_empty_corrected_record_is_stored_as_revision(monkeypatch):
    cursor = FakeCursor()
    monkeypatch.setattr(db, "connect", lambda: FakeConnection(cursor))
    first = record("heart_rate", "empty-correction")
    empty = record("heart_rate", "empty-correction")
    empty["payload"]["samples"] = []

    db.ingest_health_connect(batch_metadata(), [first])
    result = db.ingest_health_connect(batch_metadata(), [empty])

    assert result["accepted"] == ["empty-correction"]
    assert len(cursor.revisions) == 2



def test_postgres_revision_smoke_when_database_configured():
    import os
    import psycopg
    import pytest

    if not os.environ.get("HEALTH_INGESTER_SMOKE_DSN"):
        pytest.skip("set HEALTH_INGESTER_SMOKE_DSN to a disposable migrated PostgreSQL database")
    dsn = os.environ["HEALTH_INGESTER_SMOKE_DSN"]
    _cleanup_smoke(dsn)
    monkeypatch = __import__("pytest").MonkeyPatch()
    monkeypatch.setattr(db, "connect", lambda: psycopg.connect(dsn, row_factory=__import__("psycopg.rows", fromlist=["dict_row"]).dict_row))
    try:
        a = record("steps", "smoke-key")
        a["lastModifiedTime"] = "2026-08-10T12:00:00Z"
        b = record("steps", "smoke-key")
        b["payload"]["count"] = 27
        b["lastModifiedTime"] = "2026-08-10T12:01:00Z"
        assert db.ingest_health_connect({"collector_id": "smoke-collector"}, [a])["accepted"] == ["smoke-key"]
        assert db.ingest_health_connect({"collector_id": "smoke-collector"}, [b])["accepted"] == ["smoke-key"]
        replay = {**a, "collectedAt": "2026-08-10T13:00:00Z"}
        assert db.ingest_health_connect({"collector_id": "smoke-collector"}, [replay])["duplicates"] == ["smoke-key"]
        fresh = record("steps", "smoke-key")
        fresh["payload"]["count"] = 55
        fresh["lastModifiedTime"] = "2026-08-10T12:03:00Z"
        assert db.ingest_health_connect({"collector_id": "smoke-collector"}, [fresh])["accepted"] == ["smoke-key"]
        with psycopg.connect(dsn) as conn, conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM health_connect_record_revisions WHERE collector_identity = %s AND record_key = %s", ('["smoke-collector","com.example.health"]', "smoke-key"))
            assert cur.fetchone()[0] == 3
            cur.execute("SELECT canonical_record->'collectedAt' FROM health_connect_record_revisions WHERE collector_identity = %s AND record_key = %s ORDER BY revision_id", ('["smoke-collector","com.example.health"]', "smoke-key"))
            assert [row[0] for row in cur.fetchall()] == ["2026-08-10T12:00:00Z", "2026-08-10T12:00:00Z", "2026-08-10T12:00:00Z"]
            cur.execute("SELECT provider_modified_at FROM health_connect_record_current WHERE collector_identity = %s AND record_key = %s", ('["smoke-collector","com.example.health"]', "smoke-key"))
            assert cur.fetchone()[0].isoformat() == "2026-08-10T12:03:00+00:00"
            cur.execute("SELECT value_numeric FROM health_observations_raw o JOIN health_sources s ON s.id = o.source_id WHERE s.external_source_id = %s AND o.external_id = %s", ('["smoke-collector","com.example.health"]', "smoke-key"))
            assert cur.fetchone()[0] == 55
    finally:
        monkeypatch.undo()
        _cleanup_smoke(dsn)

def test_revision_smoke_delete_preserves_adjacent_record_key_when_database_configured():
    import os
    import psycopg
    import pytest

    if not os.environ.get("HEALTH_INGESTER_SMOKE_DSN"):
        pytest.skip("set HEALTH_INGESTER_SMOKE_DSN to a disposable migrated PostgreSQL database")
    dsn = os.environ["HEALTH_INGESTER_SMOKE_DSN"]
    identity = '["smoke-collector","com.example.health"]'
    key = "smoke-boundary"
    _cleanup_smoke(dsn, identity, key)
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(db, "connect", lambda: psycopg.connect(dsn, row_factory=__import__("psycopg.rows", fromlist=["dict_row"]).dict_row))
    try:
        original = record("steps", key)
        original["lastModifiedTime"] = "2026-08-10T12:00:00Z"
        assert db.ingest_health_connect({"collector_id": "smoke-collector"}, [original])["accepted"] == [key]
        with psycopg.connect(dsn) as conn, conn.cursor() as cur:
            cur.execute("INSERT INTO health_observations_raw (source_id, metric_type, original_type, start_time, end_time, value_numeric, value_text, unit, source_name, device_name, external_id, raw_payload_json) SELECT source_id, metric_type, original_type, start_time, end_time, value_numeric, value_text, unit, source_name, device_name, external_id || ';adjacent', jsonb_set(raw_payload_json::jsonb, '{key}', to_jsonb(%s::text)) FROM health_observations_raw WHERE external_id = %s", (key + ";adjacent", key))
            conn.commit()
        corrected = record("steps", key)
        corrected["payload"]["count"] = 99
        corrected["lastModifiedTime"] = "2026-08-10T12:01:00Z"
        assert db.ingest_health_connect({"collector_id": "smoke-collector"}, [corrected])["accepted"] == [key]
        with psycopg.connect(dsn) as conn, conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM health_observations_raw WHERE external_id = %s", (key + ";adjacent",))
            assert cur.fetchone()[0] == 1
            cur.execute("SELECT count(*) FROM health_observations_raw WHERE external_id = %s", (key,))
            assert cur.fetchone()[0] == 1
    finally:
        monkeypatch.undo()
        _cleanup_smoke(dsn, identity, key)


def _cleanup_smoke(dsn: str, identity: str = '["smoke-collector","com.example.health"]', key: str = "smoke-key") -> None:
    import psycopg
    with psycopg.connect(dsn) as conn, conn.cursor() as cur:
        for table in ("health_connect_record_current", "health_connect_record_revisions"):
            cur.execute(f"DELETE FROM {table} WHERE collector_identity = %s", (identity,))
        cur.execute("DELETE FROM health_observations_raw WHERE external_id = %s OR external_id = %s", (key, key + ";adjacent"))
        cur.execute("DELETE FROM health_sources WHERE source_system = %s AND external_source_id = %s", (db.HEALTH_CONNECT_SOURCE_SYSTEM, identity))
        conn.commit()
