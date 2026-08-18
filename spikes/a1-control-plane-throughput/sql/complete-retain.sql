-- Completer, retention variant: mark claimed work COMPLETE instead of
-- deleting it.
--
-- Requires sql/schema-retention.sql to have been applied, which widens the
-- state CHECK to admit 2 and adds completed_at.
--
-- pgbench script. Variables:
--   :complete_batch  rows retired per transaction
--
-- This is the more expensive of the two arms: the row survives, so its
-- dead prior version still has to be vacuumed, and the table only ever
-- grows. Run it against sql/complete.sql to price retention.

BEGIN;

WITH picked AS (
    SELECT id
    FROM jobs
    WHERE state = 1
    ORDER BY claimed_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT :complete_batch
)
UPDATE jobs AS j
SET
    state        = 2,
    completed_at = clock_timestamp()
FROM picked
WHERE j.id = picked.id;

COMMIT;
