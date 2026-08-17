# A-1 — Spike: Control-Plane Throughput Ceiling

Can PostgreSQL be Gentzen's durable control-plane job queue?

The design under test is a small job row claimed with `FOR UPDATE SKIP LOCKED`, where the row carries a **32-byte payload hash** rather than the payload itself. Large JSON documents are expected to live outside PostgreSQL entirely, so that orchestration cost stays independent of payload size.

The workload that has to be survived: bursts of roughly **22,000 jobs at once**. The system being replaced takes tens of minutes to clear such a burst and sometimes fails from backpressure.

## Results

| Document | Question it answers |
|---|---|
| [`results/A-1-recycle-churn-results.md`](results/A-1-recycle-churn-results.md) | Can PostgreSQL survive pathological `READY -> CLAIMED -> READY` recycling? |
| [`results/A-1-burst-drain-results.md`](results/A-1-burst-drain-results.md) | How fast does a real 22,000-job burst drain, claimed exactly once? |
| [`results/A-1-payload-placement-results.md`](results/A-1-payload-placement-results.md) | Does claim cost stay independent of payload size? |

## Layout

```text
sql/        schema, seed, claim, recycle, and measurement queries
scripts/    run harnesses and summarizers
burst/      Go burst-drain driver (pgx), used by the burst and payload tests
results/    one directory per run, plus the written-up result documents
.state/     local PostgreSQL cluster, socket, and external blob store (gitignored)
```

## Two workloads, two drivers

**Recycle churn** (`scripts/run-one.sh`, driven by `pgbench`) repeatedly flips a fixed pool of rows between READY and CLAIMED. It is deliberately harsher than production and exists to expose MVCC, WAL, checkpoint and autovacuum behavior.

**Burst drain** (`scripts/run-burst.sh`, driven by `burst/a1burst`) seeds an exact burst, releases pre-connected claimers from a barrier, and measures wall-clock time until the last job is claimed. `pgbench` cannot express this: it runs for a fixed duration or transaction count, neither of which ends when the queue empties, and its staggered client startup would dominate an event lasting ~140 ms.

## Running it

```bash
# One-time
./scripts/pg-local.sh init
./scripts/pg-local.sh start
psql -f sql/schema.sql
(cd burst && go build -o a1burst .)

# Recycle churn: claimers, batch, seconds
./scripts/run-one.sh 8 50 60

# Burst drain: claimers, batch, burst size, repetitions
./scripts/run-burst.sh 8 50 22000 5
./scripts/run-burst-matrix.sh

# Payload placement: arm, payload bytes, burst size, repetitions
./scripts/run-payload.sh reference 262144 22000 3
./scripts/run-payload-matrix.sh
```

Connection settings come from `scripts/env.sh`; the cluster listens on a Unix socket under `.state/`.

Every run writes a directory under `results/` containing raw per-transaction records, WAL and checkpoint deltas, relation sizes, PostgreSQL configuration, and host environment, so any published number can be recomputed from the raw data.

## Status

Both headline questions are answered, and both answers are positive.

- A 22,000-job burst drains in **139.9 ms** (~157k jobs/s), every job claimed exactly once. A burst **ten times** that size still drains in 1.35 s, so the 3× headroom requirement is met by direct measurement rather than extrapolation.
- Claim cost is **flat across a 1,000× payload range**, and inlining documents into the job row instead costs up to 4,000× the ingest time and 8,000× the ingest WAL.

Still outstanding before a GO/NO-GO:

- production job lifecycle (`INSERT -> READY -> CLAIM -> COMPLETE/DELETE`), including completion and deletion cost,
- sustained and overlapping bursts rather than one burst against an idle system,
- execution on agreed target hardware, over a network rather than a local socket.

### Disk fixtures

The external blob stores under `.state/blobs/` are left in place so payload runs can be repeated without regenerating them. They total roughly **28 GB**, dominated by the 1 MB fixture. Delete `.state/blobs/` to reclaim it; `run-payload.sh` rebuilds whatever it needs.
