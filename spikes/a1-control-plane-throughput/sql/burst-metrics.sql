\pset pager off

-- Server-side truth for a one-shot burst drain.
--
-- Everything here is derived from the jobs table itself, not from the
-- benchmark driver, so the numbers survive any doubt about pgbench's
-- own accounting.
--
-- Requires:  -v expected=<burst size>  -v batch=<claim batch>


-- 1. Correctness.
--
-- The burst is only valid if every seeded job ended CLAIMED with exactly
-- one claim recorded against it. claim_count is incremented by the claim
-- statement itself, so a value of 2 is direct evidence of a double claim
-- and a value of 0 is direct evidence of a lost job.
SELECT
    count(*)                                    AS jobs_total,
    count(*) FILTER (WHERE state = 1)           AS claimed,
    count(*) FILTER (WHERE state = 0)           AS still_ready,
    count(*) FILTER (WHERE claim_count = 1)     AS claimed_exactly_once,
    count(*) FILTER (WHERE claim_count = 0)     AS never_claimed,
    count(*) FILTER (WHERE claim_count > 1)     AS claimed_more_than_once,
    count(*) FILTER (WHERE claimed_by IS NULL)  AS unattributed,
    count(DISTINCT claimed_by)                  AS distinct_claimers
FROM jobs;


-- 2. Drain window and throughput.
--
-- claimed_at is clock_timestamp() evaluated per row inside the claiming
-- UPDATE, so min() is the instant the first job was claimed and max() is
-- the instant the last one was. That window is the burst drain, measured
-- by the server, with no client-side clock and no pgbench start-up in it.
SELECT
    min(claimed_at)                                                 AS first_claim,
    max(claimed_at)                                                 AS last_claim,
    round(
        extract(epoch FROM max(claimed_at) - min(claimed_at))::numeric * 1000,
        3
    )                                                               AS drain_ms,
    round(
        count(*) / nullif(
            extract(epoch FROM max(claimed_at) - min(claimed_at))::numeric,
            0
        ),
        1
    )                                                               AS jobs_per_second
FROM jobs
WHERE state = 1;


-- 3. Claimer ramp skew.
--
-- pgbench does not release its clients from a barrier: each one starts
-- claiming as soon as its own connection is ready. This measures how much
-- of the drain window elapsed before the last claimer joined in, which is
-- exactly the bias pgbench introduces on a burst this short. If ramp_ms is
-- a large fraction of drain_ms, the drain number is start-up limited and
-- should not be read as a PostgreSQL ceiling.
WITH firsts AS (
    SELECT
        claimed_by,
        min(claimed_at) AS first_claim
    FROM jobs
    WHERE state = 1
    GROUP BY claimed_by
)
SELECT
    count(*)                                                        AS claimers_observed,
    round(
        extract(epoch FROM max(first_claim) - min(first_claim))::numeric * 1000,
        3
    )                                                               AS ramp_ms
FROM firsts;


-- 4. Batch fill.
--
-- Every row updated by one claim transaction carries that transaction's
-- xid in its xmin, so grouping on xmin recovers the exact per-transaction
-- batch size after the fact, at zero cost during the run. Only productive
-- transactions appear here; a claim that found an empty queue updated no
-- rows and therefore left no trace.
WITH batches AS (
    SELECT
        xmin,
        count(*) AS fill
    FROM jobs
    WHERE state = 1
    GROUP BY xmin
)
SELECT
    count(*)                                                        AS productive_transactions,
    sum(fill)                                                       AS rows_claimed,
    min(fill)                                                       AS min_fill,
    percentile_disc(0.50) WITHIN GROUP (ORDER BY fill)              AS p50_fill,
    percentile_disc(0.95) WITHIN GROUP (ORDER BY fill)              AS p95_fill,
    max(fill)                                                       AS max_fill,
    round(avg(fill), 2)                                             AS mean_fill,
    round(avg(fill) * 100.0 / :batch, 2)                            AS mean_fill_pct_of_batch
FROM batches;


-- 5. Distribution across claimers.
SELECT
    claimed_by,
    count(*) AS jobs
FROM jobs
WHERE state = 1
GROUP BY claimed_by
ORDER BY claimed_by;
