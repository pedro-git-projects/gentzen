\pset pager off

-- Every seeded job must end CLAIMED, exactly once.
SELECT
    count(*)                                        AS jobs,
    count(*) FILTER (WHERE state = 1)               AS claimed,
    count(*) FILTER (WHERE state = 0)               AS still_ready,
    count(*) FILTER (WHERE claim_count = 1)         AS claimed_once,
    count(*) FILTER (WHERE claim_count = 0)         AS never_claimed,
    count(*) FILTER (WHERE claim_count > 1)         AS claimed_more_than_once,
    count(DISTINCT claimed_by)                      AS distinct_claimers
FROM jobs;

-- How evenly the burst spread across claimers.
SELECT
    claimed_by,
    count(*) AS jobs
FROM jobs
GROUP BY claimed_by
ORDER BY claimed_by;
