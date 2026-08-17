\pset pager off

-- Where the bytes actually live: main heap, TOAST, or neither.
--
-- Everything here is derived from catalog sizes rather than from reading the
-- payload column, because touching the column would detoast it and both
-- distort the numbers and take a very long time at large payload sizes.
SELECT
    pg_size_pretty(pg_relation_size('jobs'))            AS heap,
    pg_size_pretty(pg_indexes_size('jobs'))             AS indexes,
    pg_size_pretty(
        COALESCE(pg_total_relation_size(reltoastrelid), 0)
    )                                                   AS toast,
    pg_size_pretty(pg_total_relation_size('jobs'))      AS total,
    pg_relation_size('jobs')                            AS heap_bytes,
    COALESCE(pg_total_relation_size(reltoastrelid), 0)  AS toast_bytes,
    pg_total_relation_size('jobs')                      AS total_bytes
FROM pg_class
WHERE oid = 'jobs'::regclass;

-- Heap density. This is what actually decides the claim path's work: how many
-- job rows fit on an 8 kB page, and therefore how many pages a claim must
-- traverse to gather a batch.
SELECT
    relpages,
    reltuples,
    CASE
        WHEN relpages > 0
        THEN round((reltuples / relpages)::numeric, 1)
        ELSE 0
    END                                                 AS tuples_per_page,
    CASE
        WHEN reltuples > 0
        THEN round((pg_relation_size('jobs') / reltuples)::numeric)
        ELSE 0
    END                                                 AS heap_bytes_per_job
FROM pg_class
WHERE oid = 'jobs'::regclass;
