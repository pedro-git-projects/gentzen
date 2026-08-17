#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Payload-placement matrix.
#
# Both arms are run over a 1 KB -> 256 KB payload range, then the reference arm
# alone is pushed to 1 MB. The inline arm gets a single 1 MB repetition, purely
# to capture its ingest cost: seeding 22,000 x 1 MB documents into the
# control-plane table is itself the finding, and repeating it three times would
# only cost 66 GB of WAL to say the same thing.
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JOBS="${JOBS:-22000}"
REPS="${REPS:-3}"

for size in 1024 16384 262144; do
    "$ROOT/scripts/run-payload.sh" reference "$size" "$JOBS" "$REPS"
    echo

    "$ROOT/scripts/run-payload.sh" inline "$size" "$JOBS" "$REPS"
    echo
done

"$ROOT/scripts/run-payload.sh" reference 1048576 "$JOBS" "$REPS"
echo

"$ROOT/scripts/run-payload.sh" inline 1048576 "$JOBS" 1
echo

echo "=== payload matrix complete ==="
