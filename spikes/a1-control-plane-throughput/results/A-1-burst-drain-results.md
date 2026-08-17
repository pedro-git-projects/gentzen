# A-1 :: One-Shot Burst Drain: 22,000 Jobs

**Project:** Gentzen
**Epic:** A-1 :: Spike: control-plane throughput ceiling #1
**Date:** 2026-08-17
**Status:** Burst-drain matrix complete. Lifecycle and payload-independence tests still outstanding.

## Purpose

The recycle-churn results (`A-1-recycle-churn-results.md`) answered a defensive question: *can PostgreSQL survive pathological state flipping?* It can.

This document answers the question that actually decides A-1:

> How quickly and reliably can Gentzen drain a real burst of 22,000 jobs, claiming each one exactly once?

The system being replaced receives bursts of roughly 22,000 jobs at once and currently takes **tens of minutes** to clear them, sometimes failing from backpressure.

Targets set for this spike:

| Goal | Drain time | Implied rate |
|---|---:|---:|
| Good | ≤ 5 s | ~4,400 jobs/s |
| Stretch | ≤ 1 s | ~22,000 jobs/s |
| A-1 headroom requirement | - | 3× the accepted target |

---

## Headline Result

At the best tested configuration | **8 claimers × batch 50** | a 22,000-job burst drains in:

```text
139.9 ms   (median of 5 repetitions)
157,225 jobs/sec
```

That is approximately **36× the "good" target** and **7× the "stretch" target**, with every job claimed exactly once and zero failed transactions.

**Every tested configuration except `1 claimer × batch 1` beats the 5 s good target.** Six of the nine beat the 1 s stretch target.

---

## What Changed From the Recycle Benchmark

The recycle workload could not express this test, so a purpose-built driver was written.

### No recycling

The queue is seeded with exactly 22,000 READY jobs. Nothing puts work back. The run ends the moment the last job is claimed. There is no steady-state window to average over, the measured quantity is **wall-clock time to drain**.

### A new driver: `burst/`

`pgbench` was replaced for this test for two reasons:

1. **It cannot express "drain until empty."** It runs for a fixed duration or a fixed transaction count. Neither ends when the queue empties, and a fixed transaction count cannot drain the queue exactly, because `SKIP LOCKED` makes per-transaction yield variable.

2. **Its client ramp-up would dominate the measurement.** `pgbench` connects clients as it starts them. When the entire event under test lasts ~140 ms, staggered connection setup is a large fraction of the result.

`burst/a1burst` (Go, `pgx/v5`) instead:

- connects **and prepares** every claimer before the clock starts,
- releases all claimers simultaneously from a barrier,
- records every claim round trip with its exact row count,
- ends the run when the claimed counter reaches the burst size,
- reports drain time as the commit time of the claim that took the **last** job, not when the last goroutine noticed.

Connection setup is measured and reported separately (`connect_setup_ms`); it is excluded from drain time, because a real dispatcher runs with a warm pool.

### One difference in the claim statement

The claim SQL is otherwise identical to the recycle benchmark, but is issued as a single implicit transaction instead of being wrapped in explicit `BEGIN`/`COMMIT`, saving two round trips. A single statement is already atomic, so the semantics are unchanged. Burst numbers should therefore not be compared directly against the recycle-churn numbers.

### Correctness is verified, not assumed

After every repetition:

```sql
SELECT count(*) FROM jobs WHERE state <> 1 OR claim_count <> 1;
```

The run aborts if this is not zero. Across **47 repetitions** covering all configurations:

```text
exactly_once_violations = 0     (47/47)
claimed = 22000                 (47/47)
failed transactions = 0
```

---

## Test Host and Configuration

Same host as the recycle benchmark: AMD Ryzen 5 7600X (6 cores / 12 threads), ~30.5 GiB RAM, PostgreSQL 18.4 on ext4/NVMe, local Unix-domain socket.

Durability was fully enabled, these are honest durable-commit numbers, not a `fsync=off` result:

```text
fsync              = on
synchronous_commit = on
full_page_writes   = on
wal_level          = replica
max_wal_size       = 8GB      (carried over from the recycle A/B)
shared_buffers     = 128MB    (default, untuned)
```

Note that `shared_buffers` is still at the 128 MB default. A 22,000-row job table is ~3.5 MB, so it is comfortably resident regardless.

---

## The Matrix

Median of 5 repetitions per cell. Each repetition re-seeds a fresh 22,000-job burst.

| Claimers | Batch | Drain | Jobs/sec | p50 | p95 | p99 | max | Batch fill |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 7,748.1 ms | 2,839 | 0.341 ms | 0.398 ms | 0.438 ms | 7.599 ms | 100.00% |
| 1 | 10 | 844.4 ms | 26,055 | 0.370 ms | 0.446 ms | 0.499 ms | 7.548 ms | 100.00% |
| 1 | 50 | 235.9 ms | 93,248 | 0.519 ms | 0.664 ms | 0.767 ms | 1.363 ms | 100.00% |
| 8 | 1 | 1,261.4 ms | 17,441 | 0.433 ms | 0.557 ms | 0.659 ms | 7.818 ms | 100.00% |
| 8 | 10 | 194.6 ms | 113,077 | 0.671 ms | 0.933 ms | 1.152 ms | 2.092 ms | 99.95% |
| **8** | **50** | **139.9 ms** | **157,225** | 2.535 ms | 3.792 ms | 4.395 ms | 5.163 ms | 99.32% |
| 32 | 1 | 806.1 ms | 27,291 | 0.974 ms | 2.528 ms | 3.744 ms | 8.843 ms | 100.00% |
| 32 | 10 | 479.5 ms | 45,880 | 4.800 ms | 20.338 ms | 32.942 ms | 56.510 ms | 99.77% |
| 32 | 50 | 290.0 ms | 75,868 | 12.708 ms | 61.201 ms | 103.668 ms | 155.127 ms | 98.00% |

Latency percentiles cover **productive** claims, transactions that returned at least one job. Empty transactions are reported separately, since a claim that returns nothing did no work and would flatter the percentiles.

Run-to-run variance was low. For the winning cell the five drain times were:

```text
136.784  150.622  142.321  139.927  137.738  ms
```

**Evidence directories:** `results/20260817T0139*-burst-*` through `results/20260817T0140*-burst-*`.

---

## Reading the Matrix

### 1. Batching is the dominant lever; concurrency is secondary

At a single claimer, batching alone moves the burst from failing the target to beating the stretch goal:

```text
1 x batch 1    7,748 ms     2,839 jobs/s
1 x batch 10     844 ms    26,055 jobs/s
1 x batch 50     236 ms    93,248 jobs/s
```

That is a **33× improvement from batching alone, on one connection.**

Concurrency does far less. Going from 1 to 8 claimers at batch 50, eight times the clients, improves drain time only from 236 ms to 140 ms, about **1.7×**. A single claimer with batch 50 already outperforms 32 claimers at batch 1 (806 ms) and 32 claimers at batch 10 (480 ms).

The practical consequence for Gentzen: **a dispatcher that claims in batches matters much more than a dispatcher that runs many workers.** A single well-batched claimer already clears a 22k burst in a quarter of a second.

### 2. Thirty-two claimers is past the useful limit on this machine

32 claimers is worse than 8 at *every* batch size, on both drain time and latency:

| Batch | 8 claimers | 32 claimers | Change |
|---:|---:|---:|---|
| 1 | 1,261 ms | 806 ms | better |
| 10 | 195 ms | 480 ms | **2.5× worse** |
| 50 | 140 ms | 290 ms | **2.1× worse** |

The p99 damage is more dramatic than the throughput damage: at 32×50, p99 goes from 4.4 ms to **103.7 ms**, a 24× regression, and batch fill degrades to 98%.

This is oversubscription. 32 backends on 12 hardware threads all contend for the head of the same `jobs_ready_idx`, ordered by `(available_at, id)`. Every claimer wants the same page. More claimers means more `SKIP LOCKED` collisions and more context switching for the same amount of work.

The pattern only inverts at batch 1, where each transaction is so short that extra clients mainly buy pipelining rather than contention.

### 3. Empty claims are an end-of-burst artifact, not a steady-state problem

At 32×50, 239 of 689 transactions returned zero rows — an alarming-looking number. Their timing explains them:

```text
225-250 ms:    1 empty claim
250-275 ms:    7 empty claims
275-300 ms:  231 empty claims
```

**97% of them occur in the final 25 ms of a 290 ms drain.** Once fewer jobs remain than the claimers collectively request (32 × 50 = 1,600), the claimers thrash against each other over the last rows. This is the tail of the burst, not the burst.

The design consequence is real but narrow: **a claimer that finds an empty queue must back off rather than spin.** The driver here deliberately spins with no backoff to expose the effect. Production code should not.

### 4. A periodic ~7.6 ms stall exists and is bounded

Several configurations show a `max` latency near 7.6 ms that never appears in p99. It is a recurring server-wide event, not a random outlier. At 1 claimer × batch 1, the slow transactions start at:

```text
868 ms, 1,868 ms, 3,868 ms, 4,868 ms, 6,868 ms
```

 exactly one second apart. At 8 claimers × batch 1, four separate claimers stall within 5 µs of each other at t = 1,013.86 ms, so all backends block simultaneously.

The cause has **not** been confirmed and should not be guessed at in a decision document. What matters operationally is the bound: it costs roughly one 7.6 ms hiccup per second, system-wide. At 22k-burst timescales it affects at most one transaction and never reaches p99. It would only become interesting in a sustained low-latency workload, and is worth a follow-up if Gentzen ever targets single-digit-millisecond p999.

---

## Headroom, Measured Rather Than Extrapolated

A-1 requires roughly 3× throughput headroom. Multiplying the 22k result by three would be a guess, so larger bursts were drained directly at the recommended 8×50 configuration (median of 3 repetitions).

| Burst size | Multiple of production burst | Drain | Jobs/sec | p99 | Batch fill | WAL |
|---:|---:|---:|---:|---:|---:|---:|
| 22,000 | 1× | 139.9 ms | 157,225 | 4.40 ms | 99.32% | 12.2 MB |
| 220,000 | 10× | **1,348.1 ms** | 163,196 | 4.94 ms | 99.95% | 125.9 MB |
| 1,000,000 | 45× | **7,074.8 ms** | 141,347 | 9.41 ms | 99.99% | 593.3 MB |

Two things stand out.

**Throughput is flat, not degrading.** A 10× burst runs at *higher* jobs/sec than the 22k burst (163k vs 157k), because the fixed cost of starting and finishing a burst amortizes over more work. Even at 45× the production burst, throughput only falls to ~141k jobs/s, and batch fill *improves* to 99.99%, the end-of-burst thrash described below becomes a vanishing fraction of a longer drain.

**The 3× headroom requirement is met by a wide margin.** A burst **ten times** the production size still drains in 1.35 s, comfortably inside the 5 s good target and close to the 1 s stretch target. Checkpoint pressure remains absent (0 requested checkpoints) even for the 1M-job burst.

Variance grows with burst length, as longer runs start to overlap with background maintenance. The 220k repetitions were 1.343 s, 1.348 s and 2.235 s; the 1M repetitions were 6.75 s, 7.07 s and 7.87 s. The slow 220k outlier still beat the good target by 2.2×.

**Evidence directories:** `results/20260817T014345Z-burst-c8-b50` (220k) and `results/20260817T014352Z-burst-c8-b50` (1M).

---

## Cost of a Burst

A 22,000-job burst is physically cheap. Per repetition, at 8×50:

| Metric | Value |
|---|---:|
| WAL generated | ~12.2 MB |
| WAL per claimed job | ~582 B |
| Requested checkpoints | **0** |
| Table + indexes before | 3.50 MB |
| Table + indexes after | 7.14 MB |

The relation roughly doubles, which is expected: the claim is a non-HOT update, so every row briefly exists as both a dead and a live version until vacuum runs. Nothing here approaches the 1 GB working set the recycle torture test produced, because the burst performs 22,000 updates rather than 31 million.

WAL cost per job varies mildly with configuration, from ~510 B/job at 1×10 to ~739 B/job at 32×50, tracking how many full-page images the write pattern triggers. None of it is close to a constraint: the entire burst fits in ~12 MB of WAL and triggers no checkpoints at all.

---

## Verdict on the Burst Question

| Question | Answer |
|---|---|
| Does the 22k burst drain in ≤ 5 s (good)? | **Yes** — 140 ms, 36× margin |
| Does it drain in ≤ 1 s (stretch)? | **Yes** — 140 ms, 7× margin |
| Is every job claimed exactly once? | **Yes** — 47/47 repetitions, zero violations |
| Any failures or backpressure? | **None** — zero failed transactions |
| Is batch fill maintained? | **Yes** — ≥ 99.3% at the recommended configuration |

The burst that currently takes tens of minutes and sometimes fails drains in **under a fifth of a second**.

### Recommended starting configuration

```text
8 claimers x batch 50
```

8 claimers is the sweet spot on a 6-core host; the useful claimer count is bounded by cores, not by the queue. Batch size is the lever worth tuning first. If tail latency matters more than raw drain time, **8 × batch 10** gives 195 ms with a p99 of 1.15 ms, a 39% slower drain for a **3.8× better p99**.

---

## What This Still Does Not Prove

This test measures the claim path against a pre-seeded burst. It does not yet cover:

1. **The full lifecycle.** Jobs here are seeded by a bulk `INSERT` and left CLAIMED. Production is `INSERT → READY → CLAIM → COMPLETE/DELETE`. Burst *ingest* cost and completion/deletion cost are unmeasured.
2. ~~**Payload-size independence.**~~ Answered separately in [`A-1-payload-placement-results.md`](A-1-payload-placement-results.md): claim cost is flat across a 1,000× payload range, and the cost of inlining documents instead is quantified.
3. **Sustained arrival.** This is one burst against an idle system. Repeated bursts, or bursts arriving while a previous one is still draining, are untested.
4. **Target hardware.** PostgreSQL and the driver share one developer machine. Real deployments add network round trips, which will hurt small batches far more than large ones — another reason batching is the right lever.
5. **Backoff behavior.** The driver spins on an empty queue. Production claimers need real backoff, and its effect on drain time should be measured.

---

## Reproducing

```bash
# Build the driver
(cd burst && go build -o a1burst .)

# Single configuration: claimers, batch, burst size, repetitions
./scripts/run-burst.sh 8 50 22000 5

# Full matrix
./scripts/run-burst-matrix.sh
```

Each repetition writes raw per-transaction records to `rep-N/burst-transactions.csv`
(`worker, start_us, end_us, latency_us, rows, failed`, relative to the barrier release),
so every number above can be recomputed from the raw data.
