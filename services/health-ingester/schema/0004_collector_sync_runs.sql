BEGIN;

-- One bounded receipt summary per HTTP batch. Raw observation rows remain
-- unchanged; this table answers receipt timing, batch, and aggregate-count
-- questions without storing collector keys, tokens, metadata IDs, or payloads.
CREATE TABLE collector_sync_runs (
    request_id uuid PRIMARY KEY,
    received_at timestamptz NOT NULL,
    collector_id text NOT NULL,
    submitted_count integer NOT NULL CHECK (submitted_count >= 0),
    accepted_count integer NOT NULL DEFAULT 0 CHECK (accepted_count >= 0),
    duplicate_count integer NOT NULL DEFAULT 0 CHECK (duplicate_count >= 0),
    rejected_count integer NOT NULL DEFAULT 0 CHECK (rejected_count >= 0),
    oldest_observation_at timestamptz,
    newest_observation_at timestamptz,
    origin_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
    record_type_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL CHECK (status IN ('received', 'completed', 'partial', 'validation_rejected', 'failed'))
);

CREATE INDEX collector_sync_runs_received_at_idx ON collector_sync_runs (received_at DESC);
CREATE INDEX collector_sync_runs_collector_id_received_at_idx
    ON collector_sync_runs (collector_id, received_at DESC);

COMMIT;
