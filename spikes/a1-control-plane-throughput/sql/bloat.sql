\pset pager off

SELECT
    clock_timestamp() AS measured_at,
    pg_size_pretty(pg_table_size('jobs')) AS table_size,
    pg_size_pretty(pg_indexes_size('jobs')) AS indexes_size,
    pg_size_pretty(pg_total_relation_size('jobs')) AS total_size;

SELECT *
FROM pgstattuple('jobs');

SELECT
    'jobs_ready_idx' AS index_name,
    *
FROM pgstatindex('jobs_ready_idx');

SELECT
    'jobs_claimed_idx' AS index_name,
    *
FROM pgstatindex('jobs_claimed_idx');

SELECT
    n_live_tup,
    n_dead_tup,
    n_tup_ins,
    n_tup_upd,
    n_tup_hot_upd,
    n_tup_del,
    autovacuum_count,
    last_autovacuum,
    autoanalyze_count,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE relname = 'jobs';
