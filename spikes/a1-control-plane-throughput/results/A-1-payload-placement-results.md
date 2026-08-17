# A-1 — Payload Placement: Is Claim Cost Independent of Payload Size?

**Project:** Gentzen
**Epic:** A-1 — Spike: control-plane throughput ceiling #1
**Date:** 2026-08-17
**Status:** Complete for the claim path and for ingest. Completion/deletion lifecycle still outstanding.

## Purpose

Gentzen's third core principle says orchestration state is not payload data: large documents belong outside the engine and should be referenced rather than stored. This document tests that principle instead of assuming it.

Two questions:

1. Does claim throughput and p99 stay flat as payload size grows, when the control-plane row holds only a hash?
2. What does it actually cost to do the other thing — put the document in the job row?

The second question matters because the answer is not obviously "it is catastrophic." PostgreSQL has TOAST, which already implements *store a reference, keep the row small* internally. A fair test has to find out where that saves you and where it does not.

---

## Headline Result

**The claim path is flat across a 1,000× payload range.** Draining an identical 22,000-job burst with payloads of 1 KB, 16 KB, 256 KB and 1 MB:

```text
1 KB     137.9 ms
16 KB    143.0 ms
256 KB   156.1 ms
1 MB     153.1 ms
```

The whole range is 137.9–156.1 ms — a 13% spread across a 1,000× change in payload size. For comparison, five repetitions of this *same single configuration* in the burst matrix ranged 136.8–150.6 ms, so almost all of the variation here is ordinary run-to-run noise.

Not quite all of it, though, and the residue is worth naming rather than glossing over. There is a mild upward drift with payload size, but it is **not monotonic**: 256 KB (156.1 ms) came out slower than 1 MB (153.1 ms). Since the control-plane row is byte-identical in all four cases, payload size cannot be the mechanism. The likeliest cause is the test setup rather than the design — the blob store shares an NVMe device with `PGDATA`, and the larger fixtures (5.4 GB, then 22 GB) displace page cache and were written later in the sequence. A deployment with a separate object store removes this confound entirely.

**Storing the document in the job row instead costs, in the worst case, 4,000× the ingest time and 8,000× the ingest WAL** — 435 s and 46.5 GB to admit one burst, versus 0.1 s and 5.8 MB.

---

## Method

Both arms drain the same 22,000-job burst at the recommended 8 claimers × batch 50, 3 repetitions each (1 repetition for the 1 MB inline arm, for reasons given below).

**Reference arm** — the Gentzen design. `sql/schema.sql` unchanged: the job row carries a 32-byte `payload_hash`. The documents are **actually materialized** in an external blob store on the filesystem (`.state/blobs/<size>/`), because "PostgreSQL is fast when the data does not exist" is not a finding. At 1 MB that is a real 22 GB of files on the same NVMe device as `PGDATA`.

**Inline arm** — the design Gentzen rejects. `sql/schema-inline.sql` is identical except for one added column, `payload jsonb NOT NULL`, holding the document. Same indexes, same claim query, same driver.

Payload bodies are base64-encoded random bytes, not repetitive filler, so TOAST compression cannot quietly shrink a large-payload test into a small-payload test. Real JSON compresses better than this, so the inline arm's storage numbers are a worst case. The random body is generated once per seed and reused across rows with a per-row prefix; PostgreSQL does not deduplicate TOAST values across rows and compresses each value independently, so this costs nothing in fidelity.

Every repetition was verified for exactly-once claiming. Across **22 repetitions**: `exactly_once_violations = 0`, all bursts claimed 22,000 jobs, zero failed transactions.

---

## Claim-Path Results

| Payload | Arm | Drain | Jobs/sec | p50 | p99 | Batch fill | WAL |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 KB | reference | 137.9 ms | 159,574 | 2.42 ms | **4.23 ms** | 99.55% | 12.2 MB |
| 1 KB | inline | **163.7 ms** | 134,404 | 2.91 ms | **9.30 ms** | 99.32% | **57.1 MB** |
| 16 KB | reference | 143.0 ms | 153,803 | 2.52 ms | 4.94 ms | 99.55% | 12.2 MB |
| 16 KB | inline | 143.8 ms | 153,021 | 2.57 ms | 4.60 ms | 99.55% | 12.9 MB |
| 256 KB | reference | 156.1 ms | 140,928 | 2.58 ms | 5.11 ms | 99.32% | 12.2 MB |
| 256 KB | inline | 150.8 ms | 145,936 | 2.61 ms | 5.25 ms | 99.55% | 12.9 MB |
| 1 MB | reference | 153.1 ms | 143,664 | 2.62 ms | 4.55 ms | 99.32% | 12.2 MB |
| 1 MB | inline | 142.1 ms | 154,774 | 2.51 ms | 4.78 ms | 99.55% | 12.8 MB |

Medians of 3 repetitions (1 for 1 MB inline). Individual reference-arm repetitions spanned 135.2–156.8 ms across all four payload sizes.

### The reference arm is flat, as designed

Payload size has no effect on the claim path, because the claim path never sees the payload. This is a structural property, not a tuning result: the jobs table is byte-for-byte identical whether the referenced document is 1 KB or 1 MB.

### The inline arm hurts in exactly one place — and it is the small-payload case

This is the counter-intuitive result. Inline payloads are only expensive when they are **small**:

| Payload | Heap size | Tuples per page | TOAST |
|---:|---:|---:|---:|
| reference, any size | 4.4 MB | **80.9** | — |
| inline, 1 KB | **53.2 MB** | **7.0** | 0 |
| inline, 16 KB | 5.1 MB | 69.8 | 358.9 MB |
| inline, 256 KB | 5.1 MB | 69.8 | 5.7 GB |
| inline, 1 MB | 5.1 MB | 69.8 | 22.9 GB |

PostgreSQL moves a value out of the heap once the tuple exceeds roughly 2 kB. A 1 KB payload stays **under** that threshold, so it lives in the main heap, and the consequences land directly on the claim:

- heap density collapses from 80.9 to **7.0 tuples per page**, so a batch of 50 jobs must touch ~12× more pages;
- the claim is a non-HOT update, so each claim copies the entire 1 KB payload into the new tuple version — **57.1 MB of WAL** versus 12.2 MB, a 4.7× amplification for doing exactly the same orchestration work;
- p99 degrades from 4.23 ms to **9.30 ms**, and drain time from 137.9 ms to 163.7 ms.

Above the threshold, TOAST stores the document out of line and the heap tuple keeps only an 18-byte pointer. An `UPDATE` that does not modify the payload column reuses that pointer without rewriting the TOAST chunks, so the claim path returns to reference performance.

**PostgreSQL is, in effect, implementing Gentzen's design on your behalf once the payload is big enough.** That is worth stating plainly rather than overselling the result: for large documents, the inline arm is not slow *at claim time*.

The catch is that it only defends the claim path, and the claim path is not where the cost lands.

---

## Where Inline Payloads Actually Cost You

Ingest is not a hot path in the same sense, but it is where a 22,000-job burst arrives. These are the numbers for admitting one burst:

| Payload | Arm | Ingest time | Ingest WAL | Resulting relation |
|---:|---|---:|---:|---:|
| 1 KB | reference | 0.1 s | 5.7 MB | 6.8 MB |
| 1 KB | inline | 0.2 s | 28.2 MB | 55.6 MB |
| 16 KB | reference | 0.1 s | 5.8 MB | 6.8 MB |
| 16 KB | inline | 2.1 s | 378.4 MB | 366.4 MB |
| 256 KB | reference | 0.1 s | 5.8 MB | 6.8 MB |
| 256 KB | inline | **38.1 s** | **11.6 GB** | 5.7 GB |
| 1 MB | reference | **0.1 s** | **5.8 MB** | **6.8 MB** |
| 1 MB | inline | **435.4 s** | **46.5 GB** | **22.9 GB** |

Admitting a single 22,000-job burst of 1 MB documents into the control-plane table takes **7 minutes 15 seconds** and writes **46.5 GB of WAL** — roughly 2.1× the payload volume, because the TOAST inserts are themselves WAL-logged on top of full-page writes. The same burst with references costs **0.1 s and 5.8 MB**.

The 1 MB inline arm was run once rather than three times deliberately: repeating it would have cost another 93 GB of WAL to demonstrate the same point.

### The external payloads are not free either, and that is accounted for

The reference arm's 0.1 s does not mean the bytes vanished. Materializing the blob store took:

| Payload | Blob store | Build time |
|---:|---:|---:|
| 1 KB | 87 MB | 11.6 s |
| 16 KB | 345 MB | 12.4 s |
| 256 KB | 5.4 GB | 28.9 s |
| 1 MB | 22 GB | 72.0 s |

Writing the same 22 GB took **72 s** to the filesystem versus **435 s** through PostgreSQL — about 6× faster even before considering that the blob build here is single-threaded and bottlenecked on `/dev/urandom`.

But the throughput ratio is the less important half. The structural differences are:

- payload writes are **independent transactions**, parallelizable across producers and retryable individually, rather than one enormous ingest transaction;
- a failed payload write does not roll back orchestration state;
- the engine's backup, restore and replication footprint stays at **6.8 MB** instead of 22.9 GB, which is principle 5 — recovery should be boring;
- WAL, checkpoint and autovacuum pressure stay proportional to *job count*, not to *payload volume*.

Note the deployment caveat: the blob store here shares an NVMe device with `PGDATA`. A real deployment would separate them, which can only improve the reference arm.

---

## Answering the Two Questions

**1. Does claim cost stay independent of payload size?**

Yes, and the independence is structural rather than incidental. Across a 1,000× payload range the drain time stays within measurement noise, because the row the claim touches does not change.

**2. What does inlining cost?**

| | Inline, small payloads (< ~2 kB) | Inline, large payloads (TOASTed) |
|---|---|---|
| Claim throughput | 18% slower | unaffected |
| Claim p99 | 2.2× worse | unaffected |
| Claim WAL | 4.7× | unaffected |
| Heap density | 7.0 vs 80.9 tuples/page | unaffected |
| Ingest time | ~2× | up to **4,000×** |
| Ingest WAL | 5× | up to **8,000×** |
| Engine footprint | 8× | up to **3,400×** |

The honest summary is that inlining fails in two different ways depending on size. Small payloads poison the claim path directly by destroying heap density. Large payloads leave the claim path alone — TOAST rescues it — but make ingest, storage, WAL, backup and restore scale with payload volume instead of job count.

There is no payload size at which putting the document in the job row is the better choice, but the *reason* changes as the payload grows.

---

## Evidence

```text
results/20260817T015753Z-payload-reference-1024B
results/20260817T020141Z-payload-inline-1024B
results/20260817T015807Z-payload-reference-16384B
results/20260817T020143Z-payload-inline-16384B
results/20260817T020150Z-payload-reference-262144B
results/20260817T020220Z-payload-inline-262144B
results/20260817T020407Z-payload-reference-1048576B
results/20260817T020520Z-payload-inline-1048576B
```

Each contains per-repetition raw transaction records, WAL and checkpoint deltas, heap/TOAST/index sizes, heap density, ingest timings, and exactly-once verification.

## Reproducing

```bash
# arm, payload bytes, burst size, repetitions
./scripts/run-payload.sh reference 1048576 22000 3
./scripts/run-payload.sh inline    1048576 22000 1

# Full matrix (warning: the 1 MB inline cell writes ~46 GB of WAL)
./scripts/run-payload-matrix.sh
```

## What This Does Not Cover

- **Completion and deletion.** Jobs are left CLAIMED. Deleting a completed job with a 1 MB inline payload also deletes its TOAST chunks, and the vacuum cost of that is unmeasured.
- **Reading the payload.** Workers here never fetch the document. The comparison is about orchestration cost, not end-to-end job cost.
- **Streaming.** Principle 4 says a huge document should not require huge RAM. The reference design makes streaming possible; this test does not demonstrate a streaming client.
- **A real object store.** The external store is a local filesystem, not S3. Network latency and failure modes are untested.
