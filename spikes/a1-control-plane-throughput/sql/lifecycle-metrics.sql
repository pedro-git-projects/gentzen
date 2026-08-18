\pset pager off

-- Server-side accounting for a sustained producer/claimer/completer run.
--
-- Row counters come from pg_stat_user_tables, which seed.sql resets at the
-- start of the run, so these are whole-run totals rather than deltas.

-- 1. Where the queue ended up.
--
-- A control plane that kept up ends near the depth band it was held in.
-- A large CLAIMED backlog means completers could not keep up with
-- claimers; a large READY backlog means claimers could not keep up with
-- producers and the governor was the only thing holding the line.
SELECT
    count(*)                                AS rows_total,
    count(*) FILTER (WHERE state = 0)       AS ready,
    count(*) FILTER (WHERE state = 1)       AS claimed,
    count(*) FILTER (WHERE state = 2)       AS completed_retained
FROM jobs;


-- 2. Work done, by role.
--
-- n_tup_ins is the producer, n_tup_del is the completer in its deleting
-- form, n_tup_upd is the claimer plus, in the retention arm, the completer.
SELECT
    n_tup_ins                               AS rows_inserted,
    n_tup_upd                               AS rows_updated,
    n_tup_hot_upd                           AS rows_hot_updated,
    n_tup_del                               AS rows_deleted,
    round(n_tup_hot_upd * 100.0 / nullif(n_tup_upd, 0), 2)
                                            AS hot_update_pct,
    n_live_tup,
    n_dead_tup,
    autovacuum_count,
    last_autovacuum,
    autoanalyze_count
FROM pg_stat_user_tables
WHERE relname = 'jobs';


-- 3. Whether any job was ever claimed twice.
--
-- Only meaningful in the retention arm. When completers delete, the
-- evidence leaves with the row, and exactly-once has to be argued from the
-- burst test instead.
SELECT
    count(*) FILTER (WHERE claim_count > 1) AS claimed_more_than_once,
    max(claim_count)                        AS max_claim_count
FROM jobs;


-- 4. Age of the oldest work still in flight.
--
-- Rising residency is the first symptom of a control plane falling behind,
-- well before throughput visibly drops.
SELECT
    round(extract(epoch FROM clock_timestamp()
        - min(available_at) FILTER (WHERE state = 0))::numeric, 3)
                                            AS oldest_ready_seconds,
    round(extract(epoch FROM clock_timestamp()
        - min(claimed_at) FILTER (WHERE state = 1))::numeric, 3)
                                            AS oldest_claimed_seconds
FROM jobs;
