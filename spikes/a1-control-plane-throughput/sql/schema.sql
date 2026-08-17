\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgstattuple;

DROP TABLE IF EXISTS jobs;

CREATE TABLE jobs (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- 0 = activatable
    -- 1 = activated
    state           smallint NOT NULL DEFAULT 0
                    CHECK (state IN (0, 1)),

    available_at    timestamptz NOT NULL DEFAULT clock_timestamp(),

    -- This is deliberately the payload reference, NOT the payload.
    payload_hash    bytea NOT NULL
                    CHECK (octet_length(payload_hash) = 32),

    claimed_by      integer,
    claimed_at      timestamptz,

    -- Benchmark instrumentation.
    -- Lets us count the exact number of jobs claimed.
    claim_count     bigint NOT NULL DEFAULT 0
);

-- Hot path: find work that can be activated.
CREATE INDEX jobs_ready_idx
    ON jobs (available_at, id)
    WHERE state = 0;

-- Needed by our synthetic recycler.
-- A real engine will probably need something similar for lease expiry.
CREATE INDEX jobs_claimed_idx
    ON jobs (claimed_at, id)
    WHERE state = 1;
