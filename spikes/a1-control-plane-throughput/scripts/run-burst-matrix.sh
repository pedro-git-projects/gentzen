#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Burst-drain acceptance matrix: claimers x batch.
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JOBS="${JOBS:-22000}"
REPS="${REPS:-5}"

CLAIMERS_LIST="${CLAIMERS_LIST:-1 8 32}"
BATCH_LIST="${BATCH_LIST:-1 10 50}"

for claimers in $CLAIMERS_LIST; do
    for batch in $BATCH_LIST; do
        "$ROOT/scripts/run-burst.sh" "$claimers" "$batch" "$JOBS" "$REPS"
        echo
    done
done

echo "=== matrix complete ==="
