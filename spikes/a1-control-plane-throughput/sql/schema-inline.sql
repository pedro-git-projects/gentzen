\set ON_ERROR_STOP on

-- The anti-pattern arm of the payload-placement test.
--
-- Identical to sql/schema.sql in every respect except one: the payload
-- document is stored in the control-plane row instead of being referenced by
-- hash. This is the design Gentzen rejects, kept here so the cost of rejecting
-- it can be measured rather than asserted.

CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DROP TABLE IF EXISTS jobs;

CREATE TABLE jobs (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    state           smallint NOT NULL DEFAULT 0
                    CHECK (state IN (0, 1)),

    available_at    timestamptz NOT NULL DEFAULT clock_timestamp(),

    payload_hash    bytea NOT NULL
                    CHECK (octet_length(payload_hash) = 32),

    -- The difference. The orchestration row now carries the document.
    payload         jsonb NOT NULL,

    claimed_by      integer,
    claimed_at      timestamptz,

    claim_count     bigint NOT NULL DEFAULT 0
);

CREATE INDEX jobs_ready_idx
    ON jobs (available_at, id)
    WHERE state = 0;

CREATE INDEX jobs_claimed_idx
    ON jobs (claimed_at, id)
    WHERE state = 1;
