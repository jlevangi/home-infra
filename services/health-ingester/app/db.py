"""Postgres access for the health ingester.

The write path intentionally mirrors the n8n workflow's transaction: the same
tables, the same ON CONFLICT keys, and the same 'health_sync' source_system, so
this service can take over ingestion without re-inserting existing rows.
"""

from __future__ import annotations

import json
import os

import psycopg
from psycopg.rows import dict_row

SOURCE_SYSTEM = "health_sync"

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

_FRESHNESS_SQL = """
WITH RECURSIVE metric_types(metric_type) AS (
  (
    SELECT metric_type
    FROM health_observations_raw
    WHERE metric_type IS NOT NULL
    ORDER BY metric_type
    LIMIT 1
  )
  UNION ALL
  SELECT (
    SELECT candidate.metric_type
    FROM health_observations_raw candidate
    WHERE candidate.metric_type > metric_types.metric_type
    ORDER BY candidate.metric_type
    LIMIT 1
  )
  FROM metric_types
  WHERE metric_type IS NOT NULL
), known_metrics AS (
  SELECT metric_type
  FROM metric_types
  WHERE metric_type IS NOT NULL
)
SELECT known_metrics.metric_type,
       EXTRACT(EPOCH FROM latest.observed_at) AS last_seen
FROM known_metrics
CROSS JOIN LATERAL (
  SELECT text_to_timestamptz_immutable(observation.start_time) AS observed_at
  FROM health_observations_raw observation
  WHERE observation.metric_type = known_metrics.metric_type
  ORDER BY text_to_timestamptz_immutable(observation.start_time) DESC
  LIMIT 1
) latest
ORDER BY known_metrics.metric_type
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


def ingest_health_connect(records: list[dict]) -> dict:
    """Persistence hook implemented by the next task; route tests replace it."""
    raise NotImplementedError("Health Connect persistence belongs to Task 5")


def metric_freshness() -> dict[str, float]:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(_FRESHNESS_SQL)
        return {
            row["metric_type"]: float(row["last_seen"])
            for row in cur.fetchall()
            if row["last_seen"] is not None
        }
