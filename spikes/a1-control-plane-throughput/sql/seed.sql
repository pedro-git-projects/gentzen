\set ON_ERROR_STOP on

TRUNCATE jobs RESTART IDENTITY;

SELECT pg_stat_reset_single_table_counters('jobs'::regclass);

INSERT INTO jobs (
    state,
    available_at,
    payload_hash
)
SELECT
    0,
    clock_timestamp(),
    sha256(int8send(g::bigint))
FROM generate_series(1, :pool_size) AS g;

VACUUM (ANALYZE) jobs;

CHECKPOINT;
