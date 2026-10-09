BEGIN;

-- Preserve every collector-delivered canonical record and its expanded children.
-- health_observations_raw remains the current projection used by existing readers.
CREATE TABLE health_connect_record_revisions (
    collector_identity text NOT NULL,
    record_key text NOT NULL,
    revision_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    content_hash text NOT NULL,
    provider_modified_at timestamptz,
    latest_provider_modified_at timestamptz,
    received_at timestamptz NOT NULL DEFAULT now(),
    canonical_record jsonb NOT NULL,
    observation_rows jsonb NOT NULL,
    became_current boolean NOT NULL
);

CREATE INDEX health_connect_record_revisions_lookup_idx
    ON health_connect_record_revisions (collector_identity, record_key, received_at DESC);

CREATE TABLE health_connect_record_current (
    collector_identity text NOT NULL,
    record_key text NOT NULL,
    source_id integer NOT NULL REFERENCES health_sources(id),
    content_hash text NOT NULL,
    provider_modified_at timestamptz,
    PRIMARY KEY (collector_identity, record_key)
);

CREATE INDEX health_connect_record_current_source_idx
    ON health_connect_record_current (source_id, record_key);

COMMIT;
