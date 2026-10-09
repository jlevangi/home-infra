"""Postgres access for the health ingester.

The write path intentionally mirrors the n8n workflow's transaction: the same
tables, the same ON CONFLICT keys, and the same 'health_sync' source_system, so
this service can take over ingestion without re-inserting existing rows.
"""

from __future__ import annotations

import json
import os
import hashlib
from datetime import datetime, timezone
import psycopg
from psycopg.rows import dict_row
from . import hc_types
from .health_connect import expand_health_connect_record

SOURCE_SYSTEM = "health_sync"
HEALTH_CONNECT_SOURCE_SYSTEM = "health_connect_direct"

_SOURCE_SQL = """INSERT INTO health_sources
  (source_system, source_name, source_type, device_name, external_source_id, metadata_json)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (source_system, source_name, external_source_id)
DO UPDATE SET source_type = EXCLUDED.source_type, device_name = EXCLUDED.device_name
RETURNING id"""
_OBSERVATION_SQL = """INSERT INTO health_observations_raw
  (source_id, metric_type, original_type, start_time, end_time, value_numeric,
   value_text, unit, source_name, device_name, external_id, raw_payload_json)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (source_id, original_type, external_id) DO NOTHING
RETURNING id"""
_COLLECTOR_RUN_INSERT_SQL = """INSERT INTO collector_sync_runs
  (request_id, received_at, collector_id, submitted_count, accepted_count,
   duplicate_count, rejected_count, oldest_observation_at,
   newest_observation_at, origin_counts, record_type_counts, status)
VALUES (%s, %s, %s, %s, 0, 0, 0, %s, %s, %s::jsonb, %s::jsonb, 'received')"""
_COLLECTOR_RUN_UPDATE_SQL = """UPDATE collector_sync_runs
SET accepted_count = %s, duplicate_count = %s, rejected_count = %s,
    status = %s
WHERE request_id = %s"""
_COLLECTOR_RUN_RETENTION_SQL = """WITH expired AS (
    SELECT request_id FROM collector_sync_runs
    WHERE received_at < now() - interval '90 days'
    ORDER BY received_at
    LIMIT 1000
)
DELETE FROM collector_sync_runs
WHERE request_id IN (SELECT request_id FROM expired)"""
_RECORD_KEY_SQL = "external_id >= %s AND external_id < %s"


def _record_key_params(source_id: int, original_type: str, key: str) -> tuple:
    return source_id, original_type, key, key + ";", key




def _record_collector_run(cur, metadata: dict) -> None:
    cur.execute(_COLLECTOR_RUN_RETENTION_SQL)
    cur.execute(_COLLECTOR_RUN_INSERT_SQL, (
        metadata["request_id"], metadata["received_at"], metadata["collector_id"],
        metadata["submitted_count"], metadata["oldest_observation_at"],
        metadata["newest_observation_at"], json.dumps(metadata["origin_counts"]),
        json.dumps(metadata["record_type_counts"]),
    ))


def record_collector_run(metadata: dict) -> None:
    """Durably record receipt before opening the observation transaction."""
    with connect() as conn, conn.cursor() as cur:
        _record_collector_run(cur, metadata)
        conn.commit()


def finish_collector_run(
    metadata: dict, accepted: list, duplicates: list, rejected: list, status: str
) -> None:
    if status not in {"completed", "partial", "validation_rejected", "failed"}:
        raise ValueError("invalid collector run status")
    with connect() as conn, conn.cursor() as cur:
        cur.execute(_COLLECTOR_RUN_UPDATE_SQL, (
            len(accepted), len(duplicates), len(rejected), status, metadata["request_id"],
        ))
        conn.commit()


def mark_collector_run_failed(metadata: dict) -> None:
    finish_collector_run(metadata, [], [], [], "failed")


_INGEST_SQL = """
WITH payload AS (
  SELECT * FROM jsonb_to_recordset(%(payload)s::jsonb) AS x(
    metric_type text, original_type text, start_time text, end_time text,
    value_numeric double precision, value_text text, unit text,
    source_name text, external_id text, raw_payload_json text
  )
), source_rows AS (
  SELECT DISTINCT source_name FROM payload
), sources AS (
  INSERT INTO health_sources
    (source_system, source_name, source_type, device_name, external_source_id, metadata_json)
  SELECT %(source_system)s, source_name, 'health_sync_google_drive_export', NULL, source_name, '{}'
  FROM source_rows
  ON CONFLICT (source_system, source_name, external_source_id)
  DO UPDATE SET source_type = EXCLUDED.source_type
  RETURNING id, source_name
), inserted AS (
  INSERT INTO health_observations_raw
    (source_id, metric_type, original_type, start_time, end_time,
     value_numeric, value_text, unit, source_name, device_name,
     external_id, raw_payload_json)
  SELECT s.id, p.metric_type, p.original_type, p.start_time, p.end_time,
         p.value_numeric, p.value_text, p.unit, p.source_name, NULL,
         p.external_id, p.raw_payload_json
  FROM payload p JOIN sources s USING (source_name)
  ON CONFLICT (source_id, original_type, external_id) DO NOTHING
  RETURNING id
), ledger AS (
  INSERT INTO health_ingested_files
    (source_system, external_file_id, version_key, file_name, folder_id,
     folder_name, modified_time, md5_checksum, status,
     observation_count, inserted_count, processed_at, error_text)
  VALUES (%(source_system)s, %(file_id)s, %(version_key)s, %(file_name)s,
          %(folder_id)s, %(folder_name)s,
          NULLIF(%(modified_time)s, '')::timestamptz, NULLIF(%(md5)s, ''),
          %(status)s,
          jsonb_array_length(%(payload)s::jsonb),
          (SELECT count(*) FROM inserted), now(), %(error_text)s)
  ON CONFLICT (source_system, external_file_id, version_key)
  DO UPDATE SET status = EXCLUDED.status,
                observation_count = EXCLUDED.observation_count,
                inserted_count = EXCLUDED.inserted_count,
                processed_at = now(),
                error_text = EXCLUDED.error_text
  RETURNING observation_count, inserted_count
)
SELECT observation_count, inserted_count FROM ledger
"""

_SLEEP_OVERLAP_CHECK_SQL = """
SELECT count(*) AS better_existing
FROM (
  SELECT substring(external_id from '^(.*):stage:[0-9]+$') AS session_key,
         count(*) AS stage_count
  FROM health_observations_raw
  WHERE source_id = %s
    AND metric_type = 'sleep_segment'
    AND external_id ~ '^(health_connect:[^:]+|samsung_health):sleep:[^:]+:stage:[0-9]+$'
    AND external_id NOT LIKE %s
  GROUP BY 1
  HAVING min(text_to_timestamptz_immutable(start_time)) < %s::timestamptz
     AND max(text_to_timestamptz_immutable(end_time)) > %s::timestamptz
     AND (date(max(text_to_timestamptz_immutable(end_time))) AT TIME ZONE 'America/New_York')::date
         = (date(%s::timestamptz) AT TIME ZONE 'America/New_York')::date
) AS existing
WHERE stage_count >= %s
"""

_SLEEP_DEDUP_SQL = """
DELETE FROM health_observations_raw r
USING (
  SELECT
    substring(external_id from '^(.*):stage:[0-9]+$') AS session_key
  FROM health_observations_raw
  WHERE source_id = %s
    AND metric_type = 'sleep_segment'
    AND external_id ~ '^(health_connect:[^:]+|samsung_health):sleep:[^:]+:stage:[0-9]+$'
    AND external_id NOT LIKE %s
  GROUP BY 1
  HAVING min(text_to_timestamptz_immutable(start_time)) < %s::timestamptz
     AND max(text_to_timestamptz_immutable(end_time)) > %s::timestamptz
     AND (date(max(text_to_timestamptz_immutable(end_time))) AT TIME ZONE 'America/New_York')::date
         = (date(%s::timestamptz) AT TIME ZONE 'America/New_York')::date
     AND count(*) < %s
) AS superseded
WHERE r.source_id = %s
  AND r.metric_type = 'sleep_segment'
  AND substring(r.external_id from '^(.*):stage:[0-9]+$') = superseded.session_key
"""

_SLEEP_SESSION_STAGE_COUNT_SQL = """
SELECT count(*) AS stage_count
FROM health_observations_raw
WHERE source_id = %s
  AND metric_type = 'sleep_segment'
  AND external_id LIKE %s
"""

_SLEEP_STALE_STAGE_SQL = """
DELETE FROM health_observations_raw
WHERE source_id = %s
  AND metric_type = 'sleep_segment'
  AND external_id LIKE %s
  AND external_id <> ALL(%s)
"""

_FRESHNESS_SQL = """
WITH source_metrics AS (
    SELECT DISTINCT source.id AS source_id, source.source_system, observation.metric_type
    FROM health_sources source
    JOIN health_observations_raw observation ON observation.source_id = source.id
    WHERE source.source_system = 'health_connect_direct'
      AND observation.metric_type IS NOT NULL
), latest AS (
    SELECT metrics.source_system, metrics.metric_type,
           EXTRACT(EPOCH FROM text_to_timestamptz_immutable(latest.start_time)) AS last_seen
    FROM source_metrics metrics
    CROSS JOIN LATERAL (
        SELECT observation.start_time
        FROM health_observations_raw observation
        WHERE observation.source_id = metrics.source_id
          AND observation.metric_type = metrics.metric_type
          AND metrics.metric_type <> 'sleep_segment'
        ORDER BY text_to_timestamptz_immutable(observation.start_time) DESC
        LIMIT 1
    ) latest
    UNION ALL
    SELECT metrics.source_system, metrics.metric_type,
           EXTRACT(EPOCH FROM text_to_timestamptz_immutable(latest.end_time)) AS last_seen
    FROM source_metrics metrics
    CROSS JOIN LATERAL (
        SELECT observation.end_time
        FROM health_observations_raw observation
        WHERE observation.source_id = metrics.source_id
          AND observation.metric_type = metrics.metric_type
          AND metrics.metric_type = 'sleep_segment'
        ORDER BY text_to_timestamptz_immutable(observation.end_time) DESC
        LIMIT 1
    ) latest
), freshness AS (
    SELECT source_system, metric_type, max(last_seen) AS last_seen
    FROM latest
    GROUP BY source_system, metric_type
)
SELECT source_system, metric_type, last_seen
FROM freshness
ORDER BY source_system, metric_type
"""


def connect() -> psycopg.Connection:
    return psycopg.connect(
        host=os.environ.get("PGHOST", "health-postgres"),
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "health_archive"),
        user=os.environ.get("PGUSER", "health_archive"),
        password=os.environ["PGPASSWORD"],
        connect_timeout=10,
        row_factory=dict_row,
    )


def processed_index() -> dict[tuple[str, str], tuple[int, bool]]:
    """Map processed files to their row count and handled-empty marker."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT external_file_id, version_key, observation_count,"
            " error_text = 'handled-empty:health-ingester-v2' AS handled_empty"
            " FROM health_ingested_files"
            " WHERE source_system = %s AND status = 'processed'",
            (SOURCE_SYSTEM,),
        )
        return {
            (row["external_file_id"], row["version_key"]): (
                row["observation_count"], row["handled_empty"]
            )
            for row in cur.fetchall()
        }


def ingest(meta: dict, observations: list[dict], status: str = "processed",
           error_text: str | None = None) -> dict:
    params = {
        "payload": json.dumps(observations),
        "source_system": SOURCE_SYSTEM,
        "file_id": meta["file_id"],
        "version_key": meta["version_key"],
        "file_name": meta.get("file_name", ""),
        "folder_id": meta.get("folder_id"),
        "folder_name": meta.get("folder_name"),
        "modified_time": meta.get("modified_time") or "",
        "md5": meta.get("md5_checksum") or "",
        "status": status,
        "error_text": error_text,
    }
    with connect() as conn, conn.cursor() as cur:
        cur.execute(_INGEST_SQL, params)
        row = cur.fetchone() or {}
        conn.commit()
    return {
        "observation_count": row.get("observation_count", 0),
        "inserted_count": row.get("inserted_count", 0),
    }


def _collector_identity(collector_id: str, origin_package: str) -> str:
    return json.dumps([collector_id, origin_package], separators=(",", ":"))


def _canonical_collector_record(record: dict) -> tuple[str, str, datetime | None]:
    content = {key: value for key, value in record.items() if key not in {"collectedAt", "lastModifiedTime"}}
    encoded = json.dumps(content, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    modified = record.get("lastModifiedTime")
    provider_modified_at = datetime.fromisoformat(modified.replace("Z", "+00:00")) if modified else None
    return json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True), digest, provider_modified_at


def _ingest_collector_revision(cur, identity: str, record: dict, rows: list[dict]) -> tuple[str, int]:
    encoded, digest, modified = _canonical_collector_record(record)
    key = record["key"]
    cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (json.dumps([identity, key], separators=(",", ":")),))
    cur.execute(
        "SELECT content_hash, provider_modified_at, source_id FROM health_connect_record_current "
        "WHERE collector_identity = %s AND record_key = %s FOR UPDATE",
        (identity, key),
    )
    current = cur.fetchone()
    source_id = current["source_id"] if current else None
    source_name = f"Health Connect Direct / {record['originPackage']}"
    cur.execute(_SOURCE_SQL, (HEALTH_CONNECT_SOURCE_SYSTEM, source_name, "android_health_connect", (record.get("device") or {}).get("model"), identity, "{}"))
    source_row = cur.fetchone()
    source_id = source_row["id"] if isinstance(source_row, dict) else source_row[0]
    original_type = rows[0]["original_type"] if rows else hc_types.original_type_for(record["recordType"])
    if not current:
        cur.execute("SELECT * FROM health_observations_raw WHERE source_id = %s AND original_type = %s AND (" + _RECORD_KEY_SQL + ") AND raw_payload_json::jsonb ->> 'key' = %s", _record_key_params(source_id, original_type, key))
        baseline_rows = cur.fetchall()
        if baseline_rows:
            baseline_by_record = {}
            for child in baseline_rows:
                baseline_by_record.setdefault(child["raw_payload_json"], []).append(dict(child))
            for raw_record, children in baseline_by_record.items():
                legacy_record = json.loads(raw_record)
                _, legacy_hash, legacy_modified = _canonical_collector_record(legacy_record)
                cur.execute("INSERT INTO health_connect_record_revisions (collector_identity, record_key, content_hash, provider_modified_at, latest_provider_modified_at, canonical_record, observation_rows, became_current) VALUES (%s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, false)", (identity, key, legacy_hash, legacy_modified, legacy_modified, json.dumps(legacy_record), json.dumps(children)))
                current = {"content_hash": legacy_hash, "provider_modified_at": legacy_modified, "source_id": source_id}
            latest_baseline = max(baseline_by_record, key=lambda raw: _canonical_collector_record(json.loads(raw))[2] or datetime.min.replace(tzinfo=timezone.utc))
            baseline_record = json.loads(latest_baseline)
            _, baseline_hash, baseline_modified = _canonical_collector_record(baseline_record)
            cur.execute("INSERT INTO health_connect_record_current (collector_identity, record_key, source_id, content_hash, provider_modified_at) VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING", (identity, key, source_id, baseline_hash, baseline_modified))
            cur.execute("SELECT content_hash, provider_modified_at, source_id FROM health_connect_record_current WHERE collector_identity = %s AND record_key = %s FOR UPDATE", (identity, key))
            current = cur.fetchone()
            # Preserve mixed legacy children above, then normalize the current
            # projection to the most recently modified complete snapshot.
            baseline_projection = expand_health_connect_record(baseline_record)
            cur.execute("DELETE FROM health_observations_raw WHERE source_id = %s AND original_type = %s AND (" + _RECORD_KEY_SQL + ") AND raw_payload_json::jsonb ->> 'key' = %s", _record_key_params(source_id, original_type, key))
            for old_row in baseline_projection:
                cur.execute(_OBSERVATION_SQL, (source_id, old_row["metric_type"], old_row["original_type"], old_row["start_time"], old_row["end_time"], old_row["value_numeric"], old_row["value_text"], old_row["unit"], old_row["source_name"], old_row["device_name"], old_row["external_id"], old_row["raw_payload_json"]))
                cur.fetchone()
    if current and digest == current["content_hash"]:
        if modified and (current["provider_modified_at"] is None or modified > current["provider_modified_at"]):
            cur.execute("UPDATE health_connect_record_current SET provider_modified_at = %s WHERE collector_identity = %s AND record_key = %s", (modified, identity, key))
            cur.execute("UPDATE health_connect_record_revisions SET latest_provider_modified_at = GREATEST(COALESCE(latest_provider_modified_at, %s), %s) WHERE collector_identity = %s AND record_key = %s AND content_hash = %s", (modified, modified, identity, key, digest))
        return "duplicate", source_id


    cur.execute(
        "SELECT count(*) AS revisions, max(latest_provider_modified_at) AS latest FROM health_connect_record_revisions "
        "WHERE collector_identity = %s AND record_key = %s AND content_hash = %s",
        (identity, key, digest),
    )
    seen = cur.fetchone()
    if seen["revisions"]:
        if modified is None or (seen["latest"] is not None and modified <= seen["latest"]):
            return "duplicate", source_id

    stale = bool(current and modified and current["provider_modified_at"] and modified < current["provider_modified_at"])
    source_name = f"Health Connect Direct / {record['originPackage']}"
    cur.execute(_SOURCE_SQL, (HEALTH_CONNECT_SOURCE_SYSTEM, source_name, "android_health_connect", (record.get("device") or {}).get("model"), identity, "{}"))
    source_row = cur.fetchone()
    source_id = source_row["id"] if isinstance(source_row, dict) else source_row[0]
    cur.execute(
        "INSERT INTO health_connect_record_revisions "
        "(collector_identity, record_key, content_hash, provider_modified_at, latest_provider_modified_at, canonical_record, observation_rows, became_current) "
        "VALUES (%s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, %s)",
        (identity, key, digest, modified, modified, json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True), json.dumps(rows, ensure_ascii=False, separators=(",", ":")), not stale),
    )
    if stale:
        return "duplicate", source_id

    # Delete only rows for this logical record. Other records/imports may share the source.
    cur.execute(
        "DELETE FROM health_observations_raw WHERE source_id = %s AND original_type = %s AND (" + _RECORD_KEY_SQL + ") "
        "AND raw_payload_json::jsonb ->> 'key' = %s",
        _record_key_params(source_id, rows[0]["original_type"] if rows else hc_types.original_type_for(record["recordType"]), key),
    )
    cur.execute(
        "INSERT INTO health_connect_record_current (collector_identity, record_key, source_id, content_hash, provider_modified_at) "
        "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (collector_identity, record_key) DO UPDATE SET "
        "source_id = EXCLUDED.source_id, content_hash = EXCLUDED.content_hash, provider_modified_at = COALESCE(EXCLUDED.provider_modified_at, health_connect_record_current.provider_modified_at)",
        (identity, key, source_id, digest, modified),
    )
    inserted = 0
    for row in rows:
        cur.execute(_OBSERVATION_SQL, (source_id, row["metric_type"], row["original_type"], row["start_time"], row["end_time"], row["value_numeric"], row["value_text"], row["unit"], row["source_name"], row["device_name"], row["external_id"], row["raw_payload_json"]))
        if cur.fetchone() is not None:
            inserted += 1
    return "accepted", inserted

def ingest_health_connect(metadata: dict | str, records: list[dict]) -> dict:
    accepted, duplicates, rejected = [], [], []
    is_batch = isinstance(metadata, dict)
    if not is_batch:
        metadata = {
            "collector_id": metadata,
        }
    collector_id = metadata["collector_id"]
    with connect() as conn, conn.cursor() as cur:
        if is_batch:
            sources = sorted({_collector_identity(collector_id, r["originPackage"]) for r in records})
            for source_identity in sources:
                cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (source_identity,))
            locks = sorted({json.dumps([_collector_identity(collector_id, r["originPackage"]), r["key"]], separators=(",", ":")) for r in records})
            for lock_key in locks:
                cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (lock_key,))
        for record in records:
            savepoint = f"health_connect_record_{len(accepted) + len(duplicates) + len(rejected)}"
            try:
                cur.execute(f"SAVEPOINT {savepoint}")
                rows = expand_health_connect_record(record)
                identity = _collector_identity(collector_id, record["originPackage"])
                if is_batch:
                    outcome, _ = _ingest_collector_revision(cur, identity, record, rows)
                    (accepted if outcome == "accepted" else duplicates).append(record["key"])
                    cur.execute(f"RELEASE SAVEPOINT {savepoint}")
                    continue

                # Zepp supersession guard: when a sleep session arrives that
                # overlaps an existing session on the same wake_date, either:
                #  - incoming has MORE stages → delete the old (stale) session
                #  - incoming has FEWER stages → skip it (stale re-send)
                # Genuine naps (disjoint time ranges) are untouched.
                if record["recordType"] == "sleep" and rows:
                    identity = _collector_identity(collector_id, record["originPackage"])
                    cur.execute(
                        "SELECT id FROM health_sources"
                        " WHERE source_system = %s AND external_source_id = %s",
                        (HEALTH_CONNECT_SOURCE_SYSTEM, identity),
                    )
                    src = cur.fetchone()
                    if src:
                        source_id = src["id"] if isinstance(src, dict) else src[0]
                        new_start = rows[0]["start_time"]
                        new_end = rows[-1]["end_time"]
                        new_key = record["key"]
                        new_stage_count = len(rows)

                        # Check if a better or equal session already exists
                        cur.execute(_SLEEP_OVERLAP_CHECK_SQL, (
                            source_id, new_key + ":%",
                            new_end, new_start, new_end, new_stage_count,
                        ))
                        better = cur.fetchone()
                        better_count = better["better_existing"] if isinstance(better, dict) else (better[0] if better else 0)
                        if better_count and better_count > 0:
                            # Existing session is at least as good — skip this stale re-send
                            cur.execute(f"RELEASE SAVEPOINT {savepoint}")
                            duplicates.append(record["key"])
                            continue

                        # Incoming is better — delete the old overlapping sessions
                        cur.execute(_SLEEP_DEDUP_SQL, (
                            source_id, new_key + ":%",
                            new_end, new_start, new_end, new_stage_count, source_id,
                        ))

                        # Same-session reconciliation: a re-collection of this very
                        # session leaves behind any stage row the new stage list no
                        # longer contains (older positional keys, or a stage whose
                        # start moved), which ON CONFLICT DO NOTHING cannot clear.
                        # Only prune when the incoming list is at least as complete,
                        # so a stale replay can never truncate a refined session.
                        stage_prefix = new_key + ":stage:%"
                        cur.execute(_SLEEP_SESSION_STAGE_COUNT_SQL, (source_id, stage_prefix))
                        existing = cur.fetchone()
                        existing_count = existing["stage_count"] if isinstance(existing, dict) else (existing[0] if existing else 0)
                        if existing_count and new_stage_count >= existing_count:
                            cur.execute(_SLEEP_STALE_STAGE_SQL, (
                                source_id, stage_prefix, [row["external_id"] for row in rows],
                            ))

                inserted = 0
                source_ids = {}
                for row in rows:
                    identity = _collector_identity(collector_id, record["originPackage"])
                    source_key = (row["source_name"], identity)
                    if source_key not in source_ids:
                        cur.execute(_SOURCE_SQL, (
                            HEALTH_CONNECT_SOURCE_SYSTEM,
                            row["source_name"],
                            "android_health_connect",
                            row["device_name"],
                            identity,
                            "{}",
                        ))
                        source_row = cur.fetchone()
                        source_ids[source_key] = source_row["id"] if isinstance(source_row, dict) else source_row[0]
                    cur.execute(_OBSERVATION_SQL, (
                        source_ids[source_key],
                        row["metric_type"],
                        row["original_type"],
                        row["start_time"],
                        row["end_time"],
                        row["value_numeric"],
                        row["value_text"],
                        row["unit"],
                        row["source_name"],
                        row["device_name"],
                        row["external_id"],
                        row["raw_payload_json"],
                    ))
                    if cur.fetchone() is not None:
                        inserted += 1
                cur.execute(f"RELEASE SAVEPOINT {savepoint}")
                (accepted if inserted else duplicates).append(record["key"])
            except Exception:
                cur.execute(f"ROLLBACK TO SAVEPOINT {savepoint}")
                try:
                    cur.execute(f"RELEASE SAVEPOINT {savepoint}")
                except Exception:
                    pass
                rejected.append({"key": record.get("key", ""), "code": "storage_error", "message": "storage error"})
        conn.commit()
    return {"accepted": accepted, "duplicates": duplicates, "rejected": rejected}


def metric_freshness() -> dict[tuple[str, str], float]:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(_FRESHNESS_SQL)
        return {
            (row["source_system"], row["metric_type"]): float(row["last_seen"])
            for row in cur.fetchall()
            if row["last_seen"] is not None
        }