#!/usr/bin/env python3

import math
import sys
from pathlib import Path


def percentile(values, p):
    if not values:
        return float("nan")

    index = max(0, math.ceil(len(values) * p) - 1)
    return values[index]


if len(sys.argv) < 2:
    print(f"usage: {sys.argv[0]} <pgbench-log> [...]")
    raise SystemExit(1)


latencies_us = []

for pattern in sys.argv[1:]:
    for path in Path(".").glob(pattern):
        with path.open() as f:
            for line in f:
                fields = line.split()

                if len(fields) < 3:
                    continue

                try:
                    latency_us = int(fields[2])
                except ValueError:
                    # Handles failed/skipped transactions.
                    continue

                latencies_us.append(latency_us)


if not latencies_us:
    print("No latency samples found.")
    raise SystemExit(1)


latencies_us.sort()

print(f"samples={len(latencies_us)}")
print(f"p50_ms={percentile(latencies_us, 0.50) / 1000:.3f}")
print(f"p95_ms={percentile(latencies_us, 0.95) / 1000:.3f}")
print(f"p99_ms={percentile(latencies_us, 0.99) / 1000:.3f}")
print(f"max_ms={latencies_us[-1] / 1000:.3f}")
