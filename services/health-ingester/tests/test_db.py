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

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, sql, params=None):
        self.executions.append((sql, params))
        if sql.startswith("INSERT INTO health_sources"):
            key = (params[0], params[1], params[4])
            self.sources.setdefault(key, len(self.sources) + 1)
            self.last = {"id": self.sources[key]}
        elif sql.startswith("INSERT INTO health_observations_raw"):
            external_id = params[10]
            if external_id == self.fail_external:
                raise RuntimeError("secret SQL detail")
            key = (params[0], params[2], external_id)
            if key in self.observations:
                self.last = None
            else:
                self.observations.add(key)
                self.last = {"id": len(self.observations)}
        else:
            self.last = None

    def fetchone(self):
        return self.last


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