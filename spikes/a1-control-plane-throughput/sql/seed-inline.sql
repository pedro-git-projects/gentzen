\set ON_ERROR_STOP on

-- Seeds a burst whose payload documents live inside the control-plane row.
--
-- The payload body is base64-encoded random bytes rather than repetitive
-- filler, so that TOAST compression cannot silently shrink the payload and
-- turn a large-payload test into a small-payload test. Real JSON compresses
-- better than this, so treat these as worst-case storage numbers.
--
-- pgcrypto's gen_random_bytes() is capped at 1024 bytes per call, so the body
-- is assembled from 1 kB chunks and then truncated to exactly :payload_bytes
-- characters. base64 output is ASCII, so characters and bytes are the same
-- thing here.
--
-- The random body is generated once and reused across rows, with a per-row
-- prefix so no two payloads are identical. PostgreSQL does not deduplicate
-- TOAST values across rows and compresses each value independently, so this
-- costs nothing in fidelity and saves generating tens of gigabytes of random
-- data per seed.

TRUNCATE jobs RESTART IDENTITY;

SELECT pg_stat_reset_single_table_counters('jobs'::regclass);

WITH body AS (
    SELECT left(
        (
            SELECT string_agg(encode(gen_random_bytes(1024), 'base64'), '')
            FROM generate_series(1, (:payload_bytes / 1024) + 1)
        ),
        :payload_bytes
    ) AS bytes
)
INSERT INTO jobs (
    state,
    available_at,
    payload_hash,
    payload
)
SELECT
    0,
    clock_timestamp(),
    sha256(int8send(g::bigint)),
    jsonb_build_object(
        'job', g,
        'body', overlay(body.bytes PLACING md5(g::text) FROM 1)
    )
FROM generate_series(1, :pool_size) AS g, body;

VACUUM (ANALYZE) jobs;

CHECKPOINT;
