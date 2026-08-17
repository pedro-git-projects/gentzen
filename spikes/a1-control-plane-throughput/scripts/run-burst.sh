#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# One-shot burst drain.
#
# Seeds an exact number of READY jobs, releases N pre-connected claimers
# simultaneously, and measures how long the burst takes to drain.
#
# There is no recycler. Every job must be claimed exactly once.
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PGHOST="$ROOT/.state/socket"
export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-gentzen_a1}"
export PGUSER="${PGUSER:-$USER}"

CLAIMERS="${1:?clients required}"
BATCH="${2:?batch required}"
JOBS="${3:-22000}"
REPS="${4:-5}"

DRIVER="$ROOT/burst/a1burst"

if [[ ! -x "$DRIVER" ]]; then
    echo "ERROR: burst driver not built: $DRIVER" >&2
    echo "Build it with: (cd $ROOT/burst && go build -o a1burst .)" >&2
    exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="$ROOT/results/${TIMESTAMP}-burst-c${CLAIMERS}-b${BATCH}"

mkdir -p "$RESULT"

echo "=== Gentzen A-1 burst drain ==="
echo "claimers:   $CLAIMERS"
echo "batch:      $BATCH"
echo "burst:      $JOBS jobs"
echo "reps:       $REPS"
echo "results:    $RESULT"
echo


###############################################################################
# Environment
###############################################################################

{
    echo "date=$(date --iso-8601=seconds)"
    echo "workload=one-shot-burst"
    echo "claimers=$CLAIMERS"
    echo "batch=$BATCH"
    echo "burst_jobs=$JOBS"
    echo "reps=$REPS"
    echo

    postgres --version
    uname -a

    echo
    lscpu

    echo
    free -h

    echo
    findmnt -T "$ROOT/.state/pgdata"

} > "$RESULT/environment.txt"

psql --no-psqlrc -c 'SHOW ALL;' > "$RESULT/postgresql-config.txt"


###############################################################################
# Repetitions
#
# A 22k burst drains fast enough that a single sample is mostly noise, so each
# configuration is repeated on a freshly seeded queue.
###############################################################################

for ((rep = 1; rep <= REPS; rep++)); do
    REP_DIR="$RESULT/rep-$rep"

    mkdir -p "$REP_DIR"

    echo "--- rep $rep/$REPS ---"

    # Fresh burst. Seeds exactly JOBS rows, all READY, then vacuums and
    # checkpoints so the run does not start behind pre-existing maintenance.
    psql \
        --no-psqlrc \
        -v pool_size="$JOBS" \
        -f "$ROOT/sql/seed.sql" \
        > "$REP_DIR/seed.txt"

    psql --no-psqlrc -f "$ROOT/sql/system-stats.sql" > "$REP_DIR/system-before.txt"
    psql --no-psqlrc -f "$ROOT/sql/bloat.sql" > "$REP_DIR/bloat-before.txt"

    # Scalar snapshots, so WAL and checkpoint deltas are trivial to diff.
    WAL_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
    CKPT_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"
    SIZE_BEFORE="$(psql --no-psqlrc -tA -c "SELECT pg_total_relation_size('jobs');")"

    "$DRIVER" \
        -claimers "$CLAIMERS" \
        -batch "$BATCH" \
        -jobs "$JOBS" \
        -out "$REP_DIR" \
        | tee "$REP_DIR/driver.txt"

    psql --no-psqlrc -f "$ROOT/sql/system-stats.sql" > "$REP_DIR/system-after.txt"
    psql --no-psqlrc -f "$ROOT/sql/bloat.sql" > "$REP_DIR/bloat-after.txt"

    WAL_AFTER="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
    CKPT_AFTER="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"
    SIZE_AFTER="$(psql --no-psqlrc -tA -c "SELECT pg_total_relation_size('jobs');")"

    {
        echo "wal_bytes_delta=$((WAL_AFTER - WAL_BEFORE))"
        echo "requested_checkpoints_delta=$((CKPT_AFTER - CKPT_BEFORE))"
        echo "total_relation_bytes_before=$SIZE_BEFORE"
        echo "total_relation_bytes_after=$SIZE_AFTER"
    } > "$REP_DIR/deltas.txt"

    ###########################################################################
    # Exactly-once verification
    #
    # The burst is only valid if every seeded job ended CLAIMED with exactly
    # one claim recorded against it.
    ###########################################################################

    psql --no-psqlrc -f "$ROOT/sql/verify-burst.sql" > "$REP_DIR/verify.txt"

    VIOLATIONS="$(
        psql \
            --no-psqlrc \
            --tuples-only \
            --no-align \
            -c "
SELECT count(*)
FROM jobs
WHERE state <> 1
   OR claim_count <> 1;
"
    )"

    echo "exactly_once_violations=$VIOLATIONS" | tee "$REP_DIR/exactly-once.txt"

    if [[ "$VIOLATIONS" != "0" ]]; then
        echo "ERROR: burst did not claim every job exactly once (rep $rep)" >&2
        exit 1
    fi

    echo
done


###############################################################################
# Aggregate across repetitions
###############################################################################

"$ROOT/scripts/summarize-burst.py" "$RESULT" | tee "$RESULT/summary.txt"

echo
echo "Run complete: $RESULT"
