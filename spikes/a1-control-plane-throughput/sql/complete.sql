-- Completer: retire claimed work by deleting it.
--
-- pgbench script. Variables:
--   :complete_batch  rows retired per transaction
--
-- SKIP LOCKED is used here for the same reason as in claim.sql: several
-- completers must be able to run without ever queueing behind each other.
-- Rows currently being claimed are simply skipped and picked up next pass.
--
-- Use sql/complete-retain.sql instead if finished jobs must be kept.

BEGIN;

WITH picked AS (
    SELECT id
    FROM jobs
    WHERE state = 1
    ORDER BY claimed_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT :complete_batch
)
DELETE FROM jobs AS j
USING picked
WHERE j.id = picked.id;

COMMIT;
