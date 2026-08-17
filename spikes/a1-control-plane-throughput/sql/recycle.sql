BEGIN;

WITH picked AS (
    SELECT id
    FROM jobs
    WHERE state = 1
    ORDER BY claimed_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT :recycle_batch
)
UPDATE jobs AS j
SET
    state        = 0,
    available_at = clock_timestamp(),
    claimed_by   = NULL,
    claimed_at   = NULL
FROM picked
WHERE j.id = picked.id;

COMMIT;

\sleep 1 ms
