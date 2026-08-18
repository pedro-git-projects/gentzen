\set ON_ERROR_STOP on

-- Optional schema widening for the retention arm of the lifecycle test.
-- Only needed by sql/complete-retain.sql.
--
-- 2 = completed

ALTER TABLE jobs
    DROP CONSTRAINT IF EXISTS jobs_state_check;

ALTER TABLE jobs
    ADD CONSTRAINT jobs_state_check CHECK (state IN (0, 1, 2));

ALTER TABLE jobs
    ADD COLUMN IF NOT EXISTS completed_at timestamptz;

-- Retention means completed rows accumulate, so the claimed-work index
-- must stay small. It is already partial on state = 1, which excludes
-- them; this index exists for whatever sweeps them out later.
CREATE INDEX IF NOT EXISTS jobs_completed_idx
    ON jobs (completed_at, id)
    WHERE state = 2;
