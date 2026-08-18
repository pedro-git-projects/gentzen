-- Producer: admit new work into the queue.
--
-- pgbench script. Variables:
--   :produce_batch   rows inserted per transaction
--   :client_id       supplied by pgbench
--
-- The row carries the payload *reference*, never the payload. Hash inputs
-- repeat across transactions; nothing in the schema requires them to be
-- unique, and generating unique ones would only measure sha256 throughput.

BEGIN;

INSERT INTO jobs (
    state,
    available_at,
    payload_hash
)
SELECT
    0,
    clock_timestamp(),
    sha256(int8send(g::bigint))
FROM generate_series(1, :produce_batch) AS g;

COMMIT;
