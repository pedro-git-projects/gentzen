# A-1 — Control-Plane Throughput Spike: Initial Results

**Project:** Gentzen  
**Epic:** A-1 — Spike: control-plane throughput ceiling #1  
**Date:** 2026-08-16  
**Status:** Initial diagnostic results; acceptance matrix not yet complete

## Purpose

This spike tests whether PostgreSQL can serve as Gentzen's durable control-plane job queue using a small-row `FOR UPDATE SKIP LOCKED` claim pattern.

The benchmark deliberately stores only a 32-byte payload hash in the job row. Payload bytes are not part of the control-plane table.

The current workload is a **recycle-churn torture test**:

```text
READY -> CLAIMED -> READY -> CLAIMED -> ...
```

The same fixed pool of rows is repeatedly claimed and recycled. This is intentionally harsher than the expected production lifecycle and is useful for exposing MVCC, index, WAL, checkpoint, and autovacuum behavior.

This document records the initial hard data. It is **not yet the A-1 acceptance result**.

---

## Test Host

| Item | Value |
|---|---|
| OS | Arch Linux x86_64 |
| Kernel | Linux 7.1.8-arch1-3 |
| CPU | AMD Ryzen 5 7600X, 6 cores / 12 threads |
| RAM | ~30.5 GiB |
| Benchmark filesystem | ext4 on `/mnt/entropy` |
| Storage device | `/dev/nvme0n1` |
| PostgreSQL | 18.4 |
| Load generator | `pgbench` 18.4 |
| Deployment topology | PostgreSQL and pgbench on the same host |
| Connection | Local Unix-domain socket |
| Job pool | 1,000,000 rows |
| Payload reference | 32-byte SHA-256 hash |

Because PostgreSQL and pgbench share the same host, these numbers are a **developer-machine baseline**, not a final production hardware result.

---

## Queue Schema Characteristics

The benchmark job row is deliberately small and contains a payload hash rather than payload bytes.

Two partial indexes are involved in the state transition:

- `jobs_ready_idx` for `state = 0`
- `jobs_claimed_idx` for `state = 1`

The claim path uses `FOR UPDATE SKIP LOCKED`.

`EXPLAIN ANALYZE` confirmed that PostgreSQL uses `jobs_ready_idx` to find claimable work and the primary-key index to update the selected row.

Because changing `state` changes partial-index membership, the recycle workload generates **non-HOT updates**. All sustained runs observed:

```text
n_tup_hot_upd = 0
```

---

# 1. Smoke-Test Results

These 60-second runs validated correctness, batching behavior, and basic concurrency scaling before deeper diagnostics.

| Claimers | Batch | Jobs/sec | Avg tx latency | p99 latency | Batch fill | Failures |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 2,118.04 | 0.471 ms | 0.701 ms | 100% | 0 |
| 8 | 1 | 10,415.45 | 0.766 ms | 1.357 ms | 100% | 0 |
| 8 | 10 | 32,901.48 | 2.428 ms | 7.907 ms | 100% | 0 |
| 8 | 50 | 61,107.00 | 6.541 ms | 13.942 ms | 100% | 0 |

### Immediate observations

Moving from 1 to 8 claimers with batch size 1 increased throughput by approximately **4.9x**.

Batching increased jobs/sec substantially:

```text
8 x batch 1   ~10.4k jobs/sec
8 x batch 10  ~32.9k jobs/sec
8 x batch 50  ~61.1k jobs/sec
```

The cost was higher transaction latency, especially at the tail.

All runs maintained:

```text
batch_fill_pct = 100%
failed_transactions = 0
```

Therefore the observed degradation was not caused by an empty queue or failed claim transactions.

---

# 2. Instrumented 8×50 Baseline — `max_wal_size = 1 GB`

A fully instrumented 60-second `8 claimers × batch 50` run was used as the default PostgreSQL configuration baseline.

**Result directory:**

```text
results/20260816T213920Z-c8-b50
```

## Throughput and latency

| Metric | Result |
|---|---:|
| Duration | 60.031 s |
| Transactions | 66,243 |
| Claimed jobs | 3,312,150 |
| Jobs/sec, whole-run average | **55,173.92** |
| Batch fill | **100.00%** |
| Failed transactions | **0** |
| p50 | 6.554 ms |
| p95 | 13.012 ms |
| p99 | **15.770 ms** |
| Max sampled latency | 59.593 ms |

### Throughput by 10-second window

Because batch size is 50, pgbench TPS multiplied by 50 gives jobs/sec:

| Window | TPS | Approx. jobs/sec |
|---|---:|---:|
| 0–10 s | 2,463.9 | 123,195 |
| 10–20 s | 1,294.8 | 64,740 |
| 20–30 s | 904.5 | 45,225 |
| 30–40 s | 752.2 | 37,610 |
| 40–50 s | 682.5 | 34,125 |
| 50–60 s | 525.6 | **26,280** |

The fresh-table rate therefore fell from approximately **123k jobs/sec to 26k jobs/sec** within one minute.

---

## WAL and checkpoint activity

### WAL delta

```text
wal_bytes before = 14,503,334,521
wal_bytes at stop = 17,952,221,752

delta = 3,448,887,231 bytes
```

That is approximately:

- **3.45 GB WAL in 60 seconds**
- **57.5 MB/s WAL**
- **~1,041 bytes WAL per claimed job**

### Checkpoint delta

```text
requested checkpoints: 30 -> 36   (+6)
completed checkpoints: 32 -> 37   (+5)
checkpoint write time: 915,871 ms -> 958,458 ms
```

Checkpoint write time increased by approximately **42.6 seconds during a 60-second run**.

The PostgreSQL log repeatedly reported WAL-driven checkpoints only seconds apart and emitted:

```text
checkpoints are occurring too frequently
HINT: Consider increasing the configuration parameter "max_wal_size".
```

---

## Physical relation growth

### Before load

| Metric | Value |
|---|---:|
| Heap | 97 MB |
| Indexes | 52 MB |
| Total | **148 MB** |
| Physical dead tuples | 0 |
| Free heap space | 0.83% |

### At workload stop

| Metric | Value |
|---|---:|
| Heap | 639 MB |
| Indexes | 295 MB |
| Total | **934 MB** |
| Free heap space | **78.74%** |
| `n_tup_upd` | 6,623,900 |
| HOT updates | **0** |

The logical dataset remained approximately one million jobs, but the physical relation expanded from **148 MB to 934 MB** under rapid state flipping.

A large fraction of the expanded heap was already reusable space rather than live job data.

---

# 3. A/B Diagnostic — `max_wal_size = 8 GB`

To isolate checkpoint pressure, one parameter was changed:

```conf
max_wal_size = 8GB
```

No other PostgreSQL tuning was intentionally changed for this A/B test.

**Result directory:**

```text
results/20260816T214712Z-c8-b50
```

## Result

| Metric | 1 GB baseline | 8 GB diagnostic | Change |
|---|---:|---:|---:|
| Avg jobs/sec | 55,173.92 | **70,867.64** | **+28.4%** |
| Claimed jobs | 3,312,150 | **4,252,900** | +28.4% |
| Avg tx latency | 7.245 ms | **5.640 ms** | -22.2% |
| p50 | 6.554 ms | **4.519 ms** | -31.1% |
| p95 | 13.012 ms | **11.202 ms** | -13.9% |
| p99 | 15.770 ms | 16.321 ms | +3.5% |
| Requested checkpoints during run | +6 | **0** | eliminated |

### WAL

```text
wal_bytes before = 18,676,338,482
wal_bytes at stop = 22,454,284,966

delta = 3,777,946,484 bytes
```

That equals approximately:

- **3.78 GB WAL in 60 seconds**
- **63.0 MB/s WAL**
- **~888 bytes WAL per claimed job**

Although total WAL increased because more jobs were processed, WAL generated per claimed job fell from approximately **1,041 B/job to 888 B/job**, about a **14.7% reduction**.

The number of full-page images also increased much less than in the 1 GB run.

### Interpretation of the A/B

Increasing `max_wal_size` removed WAL-triggered checkpoint pressure during the 60-second benchmark and improved average throughput by roughly **28%**.

However, throughput still declined materially over the minute.

Therefore:

> Frequent checkpoints were a significant contributor to degradation, but they were not the root cause of the recycle-churn slowdown.

---

# 4. Five-Minute Steady-State Test — 8×50, `max_wal_size = 8 GB`

A five-minute run was performed to determine whether throughput and physical relation size continue degrading or reach an equilibrium.

Command:

```bash
SAMPLE_RATE=0.05 ./scripts/run-one.sh 8 50 300
```

**Result directory:**

```text
results/20260816T220056Z-c8-b50
```

## Whole-run result

| Metric | Result |
|---|---:|
| Duration | 300.017 s |
| Transactions | 312,013 |
| Claimed jobs | **15,600,650** |
| Whole-run avg jobs/sec | **51,999.29** |
| Batch fill | **100.00%** |
| Failed transactions | **0** |
| p50 | 6.107 ms |
| p95 | 13.127 ms |
| p99 | **49.481 ms** |
| Max sampled latency | 72.781 ms |
| Sample rate | 5% |

## Approximate throughput by minute

Derived from the 10-second pgbench progress windows:

| Minute | Approx. jobs/sec |
|---:|---:|
| 1 | **73,512** |
| 2 | **42,808** |
| 3 | **48,046** |
| 4 | **47,540** |
| 5 | **48,099** |

After the initial transient, throughput did **not** continue collapsing toward zero.

The recycle workload settled around approximately:

```text
~48k jobs/sec
```

on this machine/configuration.

The tradeoff is significant tail latency: sampled p99 reached approximately **49.5 ms**.

---

# 5. Five-Minute Storage Behavior

## Relation size over time

The runtime sampler showed the heap growing rapidly and then reaching a high-water mark:

```text
start     heap ~101 MB
~15 s     heap ~415 MB
~30 s     heap ~533 MB
~45 s     heap ~657 MB
~60 s     heap ~802 MB
~75 s     heap ~808 MB
...
~300 s    heap ~808 MB
```

The heap remained essentially flat around **808 MB** for most of the run.

The indexes continued growing initially but later stayed around roughly **330 MB**.

This is evidence of a **high-water working set**, rather than obviously unbounded heap growth over this five-minute window.

## At workload stop

| Metric | Result |
|---|---:|
| Heap | **770 MB** |
| Indexes | **319 MB** |
| Total relation size | **1,090 MB** |
| Physical dead tuples | 1,201,755 |
| Dead tuple percent | 15.03% |
| Free heap space | 68.03% |
| Cumulative updates | **31,201,300** |
| HOT updates | **0** |
| Completed autovacuums during run | 4 |

An autovacuum was still active when the workload stopped.

After that active vacuum completed:

| Metric | Result |
|---|---:|
| Heap | 770 MB |
| Indexes | 319 MB |
| Total | **1,090 MB** |
| Estimated dead tuples | 285,940 |
| Free heap space | 68.7% |
| Autovacuum count | 5 |

Ordinary vacuum reclaimed space for internal reuse but did not shrink the relation back to its original 148 MB footprint.

---

# 6. Five-Minute WAL and Checkpoints

## WAL

```text
wal_bytes before = 22,771,886,841
wal_bytes at stop = 36,276,286,606

delta = 13,504,399,765 bytes
```

Approximately:

- **13.50 GB WAL over five minutes**
- **45.0 MB/s average WAL**
- **~866 bytes WAL per claimed job**

## Checkpoints

During the five-minute measured interval:

```text
requested checkpoints: 39 -> 42   (+3)
completed checkpoints: 42 -> 44   (+2)
```

The logs showed long background checkpoints, including approximately 101-second and 109-second checkpoint durations, while autovacuum ran periodically.

The system therefore reached a steady-state pattern involving:

- sustained claim/recycle traffic,
- continuous non-HOT index churn,
- periodic autovacuum,
- long background checkpoints,
- periodic latency spikes.

---

# 7. Findings So Far

## Confirmed

### 1. The claim mechanism remains correct under the tested load

Across the tested runs:

- no failed claim transactions were observed,
- batch fill remained 100%,
- `FOR UPDATE SKIP LOCKED` continued making progress under concurrency.

### 2. Batching materially increases throughput

At 8 claimers:

```text
batch 1   ~10.4k jobs/sec
batch 10  ~32.9k jobs/sec
batch 50  ~61.1k jobs/sec
```

Batching trades higher transaction/tail latency for higher throughput.

### 3. The recycle workload creates severe write amplification

The state transitions invalidate partial-index membership, resulting in:

```text
HOT updates = 0
```

The five-minute test generated:

```text
31.2 million UPDATEs
13.5 GB WAL
~1.09 GB physical table+index working set
```

for a logical pool of one million small job rows.

### 4. Default `max_wal_size = 1 GB` is too small for this torture workload

The default configuration caused repeated WAL-driven checkpoints only seconds apart.

Raising only `max_wal_size` to 8 GB:

- eliminated WAL-driven checkpoints in the 60-second A/B interval,
- improved average throughput by ~28%,
- reduced WAL bytes per claimed job by ~15%.

### 5. Checkpoint pressure is not the entire problem

Even after removing the 1 GB checkpoint storm, the recycle workload still suffered substantial warm-up degradation.

The remaining cost is associated with sustained MVCC, heap/index churn, autovacuum, and background write activity.

### 6. The five-minute recycle workload reaches a rough equilibrium

After the initial transient:

- throughput stabilized around **~48k jobs/sec**,
- heap size stabilized around **~808 MB**,
- index size roughly stabilized around **~330 MB**.

This is substantially better than unbounded degradation, but the equilibrium is operationally expensive and has poor p99 spikes.

---

# 8. What This Does Not Prove

This workload intentionally recycles the same fixed pool:

```text
READY -> CLAIMED -> READY
```

indefinitely.

That is not necessarily Gentzen's production lifecycle.

A more realistic control-plane workload should test something closer to:

```text
INSERT READY
    ->
CLAIM
    ->
COMPLETE / DELETE / RETAIN
```

The current recycle test should therefore be treated as a **pathological churn / torture test**, not as the final production throughput result.

The following A-1 acceptance work is still outstanding:

- full concurrency matrix: `1 / 8 / 32 / 128`,
- batch matrix: `1 / 10 / 50`,
- sustained 30-minute runs,
- production-like job lifecycle,
- payload-size-independence test,
- execution on agreed target hardware,
- explicit production throughput target,
- final 3×-headroom GO/NO-GO decision.

---

# 9. Current Interim Conclusion

The spike has **not killed the PostgreSQL `FOR UPDATE SKIP LOCKED` design**.

On the current developer machine, an intentionally adversarial permanent recycle workload:

- remains correct,
- maintains full batches,
- produces no failed claims,
- reaches a rough steady state around **~48k jobs/sec** at `8 × batch 50`,
- but produces substantial WAL, MVCC/index churn, background maintenance, relation expansion, and p99 latency spikes.

The most important result so far is not a single throughput number. It is:

> The SQL claim mechanism itself continues to function under sustained contention, but the physical lifecycle of frequently state-flipped rows is expensive enough that Gentzen's real job lifecycle must be benchmarked before the architecture can receive a GO decision.

---

# 10. Evidence / Result Directories

```text
# Smoke tests
results/20260816T211527Z-c1-b1
results/20260816T211754Z-c8-b1
results/20260816T212037Z-c8-b10
results/20260816T212158Z-c8-b50

# Fully instrumented default-config recycle baseline
results/20260816T213920Z-c8-b50

# max_wal_size=8GB diagnostic, 60 seconds
results/20260816T214712Z-c8-b50

# max_wal_size=8GB steady-state diagnostic, 300 seconds
results/20260816T220056Z-c8-b50
```

These directories contain the raw pgbench output, latency logs, runtime relation statistics, WAL/checkpointer snapshots, bloat snapshots, vacuum state, PostgreSQL configuration, and environment information used for the results above.
