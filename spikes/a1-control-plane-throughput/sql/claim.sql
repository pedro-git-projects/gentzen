BEGIN;

WITH picked AS (
    SELECT id
    FROM jobs
    WHERE state = 0
      AND available_at <= clock_timestamp()
    ORDER BY available_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT :batch
)
UPDATE jobs AS j
SET
    state       = 1,
    claimed_by  = :client_id,
    claimed_at  = clock_timestamp(),
    claim_count = claim_count + 1
FROM picked
WHERE j.id = picked.id;

COMMIT;
