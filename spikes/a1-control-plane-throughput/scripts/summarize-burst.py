#!/usr/bin/env python3
"""Aggregate the repetitions of one burst-drain configuration.

Each rep-N directory holds a key=value burst-summary.txt from the driver plus a
deltas.txt of server-side counters. A single 22k burst is short enough that one
sample is mostly noise, so the interesting numbers are the median and the
spread across repetitions.
"""

import statistics
import sys
from pathlib import Path


def read_kv(path):
    values = {}

    if not path.exists():
        return values

    for line in path.read_text().splitlines():
        if "=" not in line:
            continue

        key, _, value = line.partition("=")

        try:
            values[key] = float(value)
        except ValueError:
            values[key] = value

    return values


def summarize(label, samples, unit="", precision=3):
    if not samples:
        return

    lo = min(samples)
    hi = max(samples)
    median = statistics.median(samples)

    print(
        f"{label:<28} median={median:>12.{precision}f}{unit}"
        f"  min={lo:>12.{precision}f}{unit}"
        f"  max={hi:>12.{precision}f}{unit}"
    )


def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <result-dir>")
        raise SystemExit(1)

    root = Path(sys.argv[1])

    reps = sorted(
        root.glob("rep-*"),
        key=lambda p: int(p.name.split("-")[1]),
    )

    runs = []

    for rep in reps:
        summary = read_kv(rep / "burst-summary.txt")

        if not summary:
            continue

        summary.update(read_kv(rep / "deltas.txt"))
        runs.append(summary)

    if not runs:
        print("No repetitions found.")
        raise SystemExit(1)

    first = runs[0]

    print("=== burst drain summary ===")
    print(f"claimers={int(first['claimers'])}")
    print(f"batch={int(first['batch'])}")
    print(f"burst_jobs={int(first['burst_jobs'])}")
    print(f"reps={len(runs)}")
    print()

    def column(key):
        return [run[key] for run in runs if key in run]

    summarize("drain_ms", column("drain_ms"), " ms")
    summarize("jobs_per_second", column("jobs_per_second"), "", 0)
    summarize("p50_ms", column("p50_ms"), " ms")
    summarize("p95_ms", column("p95_ms"), " ms")
    summarize("p99_ms", column("p99_ms"), " ms")
    summarize("max_ms", column("max_ms"), " ms")
    summarize("mean_claim_latency_ms", column("mean_claim_latency_ms"), " ms")
    summarize("batch_fill_pct", column("batch_fill_pct"), " %", 2)
    summarize("transactions", column("transactions"), "", 0)
    summarize("empty_transactions", column("empty_transactions"), "", 0)
    summarize("connect_setup_ms", column("connect_setup_ms"), " ms")

    wal = column("wal_bytes_delta")

    if wal:
        summarize("wal_mb", [b / 1048576 for b in wal], " MB", 1)
        summarize(
            "wal_bytes_per_job",
            [b / first["burst_jobs"] for b in wal],
            " B",
            0,
        )

    summarize(
        "requested_checkpoints",
        column("requested_checkpoints_delta"),
        "",
        0,
    )

    print()
    print("per-rep drain_ms: " + ", ".join(f"{run['drain_ms']:.3f}" for run in runs))


if __name__ == "__main__":
    main()
