# A-1 :: Spike: Control-Plane Throughput Ceiling

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
sql/        schema, seed, produce, claim, complete, and measurement queries
scripts/    run harnesses and summarizers
burst/      Go burst-drain driver (pgx), superseded by the pgbench harness
results/    one directory per run, plus the written-up result documents
.state/     local PostgreSQL cluster, socket, and external blob store (gitignored)
```

## Workloads

**Recycle churn** (`scripts/run-one.sh`) repeatedly flips a fixed pool of rows between READY and CLAIMED. It is deliberately harsher than production and exists to expose MVCC, WAL, checkpoint and autovacuum behavior.

**Burst drain** (`scripts/run-burst-pgbench.sh`) seeds an exact burst, turns N claimers loose on it, and measures the drain. Nothing recycles; every job must be claimed exactly once.

**Sustained lifecycle** (`scripts/run-lifecycle.sh`) runs producers, claimers and completers concurrently at a fixed admission rate, so a job costs an INSERT, an UPDATE and a DELETE rather than an UPDATE alone.

Everything above A-1 is PostgreSQL, `pgbench`, SQL and Bash. No engine code exists yet, and none is needed to answer these questions; the point of the spike is to establish the database ceiling that a future C dispatcher will be measured against.

### On pgbench and the burst

An earlier version of this spike used a Go driver (`burst/a1burst`) for the burst, on the reasoning that `pgbench` runs for a fixed duration or transaction count, neither of which ends when the queue empties, and that its staggered client start-up would dominate an event lasting ~140 ms.

Both objections turned out to be answerable without leaving `pgbench`:

- **Stopping at empty.** Claimers get a deliberately oversized transaction budget. Once the queue drains, the remaining claims find nothing and cost tens of microseconds; they are excluded from the reported numbers, and the harness rejects the run outright if the budget was too small to drain the burst.
- **Start-up stagger.** It is measured rather than assumed. `min(claimed_at)` per claimer gives the spread between the first and last claimer joining in, reported as `ramp_ms`. On a 22,000-job burst it is **0.18 ms against a 145 ms drain**, or about 0.1%.

The two drivers agree: 145 ms mean drain with `pgbench` against 139.9 ms with `a1burst`. The Go driver is kept for cross-checking but is no longer required.

One caveat the harness makes visible: the same burst drains in ~197 ms when
autovacuum from a previous workload is still draining, against ~145 ms on a
settled system, reproducibly, with correctness unaffected. A burst arriving
on the heels of other work is ~35% slower than one arriving into quiet. Run
the burst against a settled cluster before comparing numbers, and treat
"burst on top of existing load" as its own measurement rather than noise.

## Running it

```bash
# One-time
./scripts/pg-local.sh init
./scripts/pg-local.sh start
psql -f sql/schema.sql

# Recycle churn: claimers, batch, seconds
./scripts/run-one.sh 8 50 60

# Burst drain: claimers, batch, burst size, repetitions
./scripts/run-burst-pgbench.sh 8 50 22000 5

# Sustained lifecycle: claimers, batch, seconds
TARGET_RATE=40000 ./scripts/run-lifecycle.sh 8 50 120

# Admission-rate sweep: claimers, batch, seconds, rates
./scripts/run-lifecycle-sweep.sh 8 50 60 20000 40000 60000 80000

# Payload placement: arm, payload bytes, burst size, repetitions
./scripts/run-payload.sh reference 262144 22000 3
./scripts/run-payload-matrix.sh
```

The lifecycle harness takes `PRODUCERS`, `COMPLETERS`, `TARGET_RATE`, `DEPTH_LOW`/`DEPTH_HIGH` and `RETAIN` from the environment. `RETAIN=1` swaps the deleting completer for one that marks jobs COMPLETE and keeps them, after applying `sql/schema-retention.sql`.

Connection settings come from `scripts/env.sh`; the cluster listens on a Unix socket under `.state/`.

Every run writes a directory under `results/` containing raw per-transaction records, WAL and checkpoint deltas, relation sizes, PostgreSQL configuration, and host environment, so any published number can be recomputed from the raw data.

## Status

Both headline questions are answered, and both answers are positive.

- A 22,000-job burst drains in **139.9 ms** (~157k jobs/s), every job claimed exactly once. A burst **ten times** that size still drains in 1.35 s, so the 3× headroom requirement is met by direct measurement rather than extrapolation.
- Claim cost is **flat across a 1,000× payload range**, and inlining documents into the job row instead costs up to 4,000× the ingest time and 8,000× the ingest WAL.

The full lifecycle is now measured too, and it is the expensive one. With
producers, claimers and completers running together, 8 claimers sustain
**~40,000 jobs/second end to end** with the queue near empty and claim p99
at 3.4 ms; pushing admission past that plateaus throughput around
47-53k/s and the queue starts backing up. A job that costs one UPDATE in
the burst test costs an INSERT, an UPDATE and a DELETE here, and the
roughly 4x gap against the 152k/s claim-only figure is that difference.
These are single 30-second repetitions on a developer machine over a Unix
socket, with meaningful run-to-run variance; they size the problem, they
are not yet a published result.

Still outstanding before a GO/NO-GO:

- longer lifecycle runs with repetitions, and the retention arm priced against the deleting one,
- overlapping bursts arriving on top of a queue that is already loaded,
- execution on agreed target hardware, over a network rather than a local socket.

One finding worth carrying into the engine design: the claim UPDATE writes
`state` and `claimed_at`, both of which are indexed, so **no claim is ever a
HOT update** (`n_tup_hot_upd` is 0 across every lifecycle run). Every claim
writes index entries as well as a new row version. Whether the lease
timestamp needs to be indexed is a schema question worth revisiting before
production.

### Disk fixtures

The external blob stores under `.state/blobs/` are left in place so payload runs can be repeated without regenerating them. They total roughly **28 GB**, dominated by the 1 MB fixture. Delete `.state/blobs/` to reclaim it; `run-payload.sh` rebuilds whatever it needs.
