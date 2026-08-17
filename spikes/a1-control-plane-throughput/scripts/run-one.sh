#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PGHOST="$ROOT/.state/socket"
export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-gentzen_a1}"
export PGUSER="${PGUSER:-$USER}"

CLIENTS="${1:?clients required}"
BATCH="${2:?batch required}"
DURATION="${3:-60}"

POOL_SIZE="${POOL_SIZE:-1000000}"
RECYCLERS="${RECYCLERS:-4}"
RECYCLE_BATCH="${RECYCLE_BATCH:-1000}"

# For smoke tests, 1.0 is fine.
# For sustained 30-minute runs, use something like 0.01.
SAMPLE_RATE="${SAMPLE_RATE:-1.0}"

CPU_COUNT="$(nproc)"

DEFAULT_THREADS="$CLIENTS"

if (( DEFAULT_THREADS > CPU_COUNT )); then
    DEFAULT_THREADS="$CPU_COUNT"
fi

THREADS="${THREADS:-$DEFAULT_THREADS}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="$ROOT/results/${TIMESTAMP}-c${CLIENTS}-b${BATCH}"

mkdir -p "$RESULT"

RECYCLER_PID=""
STATS_PID=""


cleanup() {
    if [[ -n "${RECYCLER_PID:-}" ]]; then
        kill "$RECYCLER_PID" 2>/dev/null || true
        wait "$RECYCLER_PID" 2>/dev/null || true
    fi

    if [[ -n "${STATS_PID:-}" ]]; then
        kill "$STATS_PID" 2>/dev/null || true
        wait "$STATS_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM


echo "=== Gentzen A-1 ==="
echo "clients:          $CLIENTS"
echo "batch:            $BATCH"
echo "duration:         $DURATION s"
echo "pool:             $POOL_SIZE"
echo "recyclers:        $RECYCLERS"
echo "recycle batch:    $RECYCLE_BATCH"
echo "pgbench threads:  $THREADS"
echo "sample rate:      $SAMPLE_RATE"
echo "results:          $RESULT"
echo


###############################################################################
# Environment
###############################################################################

{
    echo "date=$(date --iso-8601=seconds)"
    echo "clients=$CLIENTS"
    echo "batch=$BATCH"
    echo "duration_seconds=$DURATION"
    echo "pool_size=$POOL_SIZE"
    echo "recyclers=$RECYCLERS"
    echo "recycle_batch=$RECYCLE_BATCH"
    echo "pgbench_threads=$THREADS"
    echo "sample_rate=$SAMPLE_RATE"
    echo

    postgres --version
    pgbench --version
    uname -a

    echo
    lscpu

    echo
    free -h

    echo
    lsblk -o NAME,MODEL,SIZE,ROTA,TRAN,FSTYPE,MOUNTPOINTS

    echo
    findmnt -T "$ROOT/.state/pgdata"

} > "$RESULT/environment.txt"


###############################################################################
# Clean fixture
###############################################################################

echo "Seeding..."

psql \
    --no-psqlrc \
    -v pool_size="$POOL_SIZE" \
    -f "$ROOT/sql/seed.sql" \
    > "$RESULT/seed.txt"


###############################################################################
# PostgreSQL configuration
###############################################################################

psql \
    --no-psqlrc \
    -c 'SHOW ALL;' \
    > "$RESULT/postgresql-config.txt"


###############################################################################
# Baseline measurements
###############################################################################

psql \
    --no-psqlrc \
    -f "$ROOT/sql/bloat.sql" \
    > "$RESULT/bloat-before.txt"

psql \
    --no-psqlrc \
    -f "$ROOT/sql/system-stats.sql" \
    > "$RESULT/system-before.txt"


###############################################################################
# Background runtime stats collector
###############################################################################

"$ROOT/scripts/collect-stats.sh" \
    "$RESULT/runtime-stats.csv" \
    15 &

STATS_PID=$!


###############################################################################
# Recycler
###############################################################################

pgbench \
    --no-vacuum \
    --client="$RECYCLERS" \
    --jobs="$RECYCLERS" \
    --time="$((DURATION + 30))" \
    --protocol=prepared \
    --define="recycle_batch=$RECYCLE_BATCH" \
    --file="$ROOT/sql/recycle.sql" \
    "$PGDATABASE" \
    > "$RESULT/recycler.txt" \
    2>&1 &

RECYCLER_PID=$!

sleep 0.1

if ! kill -0 "$RECYCLER_PID" 2>/dev/null; then
    echo "ERROR: recycler exited during startup" >&2
    cat "$RESULT/recycler.txt" >&2
    exit 1
fi


###############################################################################
# Benchmark
###############################################################################

LOG_PREFIX="$RESULT/pgbench-latency"

START_NS="$(date +%s%N)"

pgbench \
    --no-vacuum \
    --client="$CLIENTS" \
    --jobs="$THREADS" \
    --time="$DURATION" \
    --progress=10 \
    --progress-timestamp \
    --report-per-command \
    --protocol=prepared \
    --define="batch=$BATCH" \
    --file="$ROOT/sql/claim.sql" \
    --log \
    --sampling-rate="$SAMPLE_RATE" \
    --log-prefix="$LOG_PREFIX" \
    "$PGDATABASE" \
    2>&1 | tee "$RESULT/pgbench.txt"

END_NS="$(date +%s%N)"

ELAPSED_NS=$((END_NS - START_NS))

ELAPSED_SECONDS="$(
    awk \
        -v ns="$ELAPSED_NS" \
        'BEGIN { printf "%.6f", ns / 1000000000 }'
)"


###############################################################################
# Stop synthetic workload
###############################################################################

# The main benchmark has stopped. The recycler should still be alive.
# If it exited unexpectedly, the run is invalid because queue supply may
# have been compromised.

if ! kill -0 "$RECYCLER_PID" 2>/dev/null; then
    echo "ERROR: recycler exited unexpectedly during benchmark" >&2
    echo "Recycler output:" >&2
    cat "$RESULT/recycler.txt" >&2
    exit 1
fi

kill "$RECYCLER_PID"

# A SIGTERM-induced non-zero exit is expected here.
wait "$RECYCLER_PID" 2>/dev/null || true

RECYCLER_PID=""


###############################################################################
# Stop lightweight runtime sampler
###############################################################################

kill "$STATS_PID" 2>/dev/null || true
wait "$STATS_PID" 2>/dev/null || true

STATS_PID=""


###############################################################################
# System state at workload stop
###############################################################################

psql \
    --no-psqlrc \
    -f "$ROOT/sql/system-stats.sql" \
    > "$RESULT/system-at-stop.txt"


###############################################################################
# Exact number of jobs claimed
###############################################################################

CLAIMS="$(
    psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        -c 'SELECT COALESCE(sum(claim_count), 0) FROM jobs;'
)"

TXNS="$(
    awk -F': ' \
        '/number of transactions actually processed:/ {
            print $2
        }' \
        "$RESULT/pgbench.txt"
)"

if [[ -z "$TXNS" ]]; then
    echo "ERROR: could not determine transaction count from pgbench output" >&2
    exit 1
fi

MAX_CLAIMS=$((TXNS * BATCH))

BATCH_FILL_PCT="$(
    awk \
        -v claims="$CLAIMS" \
        -v max="$MAX_CLAIMS" \
        'BEGIN {
            if (max == 0)
                printf "0.00"
            else
                printf "%.2f", (claims / max) * 100
        }'
)"

JOBS_PER_SECOND="$(
    awk \
        -v claims="$CLAIMS" \
        -v seconds="$ELAPSED_SECONDS" \
        'BEGIN {
            if (seconds == 0)
                printf "0.00"
            else
                printf "%.2f", claims / seconds
        }'
)"


###############################################################################
# Queue state sanity check
###############################################################################

psql \
    --no-psqlrc \
    -c '
SELECT
    state,
    count(*)
FROM jobs
GROUP BY state
ORDER BY state;
' > "$RESULT/final-job-states.txt"


###############################################################################
# Physical state immediately after workload stops
###############################################################################

psql \
    --no-psqlrc \
    -f "$ROOT/sql/bloat.sql" \
    > "$RESULT/bloat-at-stop.txt"


###############################################################################
# Capture any vacuum already active at workload stop
###############################################################################

psql \
    --no-psqlrc \
    -c "
SELECT
    pid,
    relid::regclass,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed,
    index_vacuum_count
FROM pg_stat_progress_vacuum
WHERE relid = 'jobs'::regclass;
" > "$RESULT/vacuum-at-stop.txt"


###############################################################################
# Wait for any currently-running vacuum on jobs to complete
###############################################################################

ACTIVE_VACUUM="$(
    psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        -c "
SELECT EXISTS (
    SELECT 1
    FROM pg_stat_progress_vacuum
    WHERE relid = 'jobs'::regclass
);
"
)"

if [[ "$ACTIVE_VACUUM" == "t" ]]; then
    echo "Waiting for active vacuum on jobs to finish..."

    while psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        -c "
SELECT EXISTS (
    SELECT 1
    FROM pg_stat_progress_vacuum
    WHERE relid = 'jobs'::regclass
);
" | grep -qx t
    do
        sleep 1
    done
fi


###############################################################################
# Physical/system state after currently-active maintenance drains
###############################################################################

psql \
    --no-psqlrc \
    -f "$ROOT/sql/bloat.sql" \
    > "$RESULT/bloat-after-maintenance.txt"

psql \
    --no-psqlrc \
    -f "$ROOT/sql/system-stats.sql" \
    > "$RESULT/system-after-maintenance.txt"


###############################################################################
# Latency percentiles
###############################################################################

(
    cd "$RESULT"

    "$ROOT/scripts/summarize-latency.py" \
        'pgbench-latency.*'
) > "$RESULT/latency.txt"


###############################################################################
# Summary
###############################################################################

{
    echo "clients=$CLIENTS"
    echo "batch=$BATCH"
    echo "recyclers=$RECYCLERS"
    echo "recycle_batch=$RECYCLE_BATCH"
    echo "pgbench_threads=$THREADS"
    echo "sample_rate=$SAMPLE_RATE"
    echo "duration_requested_seconds=$DURATION"
    echo "duration_measured_seconds=$ELAPSED_SECONDS"
    echo "transactions=$TXNS"
    echo "claims=$CLAIMS"
    echo "max_possible_claims=$MAX_CLAIMS"
    echo "batch_fill_pct=$BATCH_FILL_PCT"
    echo "jobs_per_second=$JOBS_PER_SECOND"
    echo

    cat "$RESULT/latency.txt"

} | tee "$RESULT/summary.txt"


###############################################################################
# Done
###############################################################################

echo
echo "Run complete."
echo
echo "Key outputs:"
echo "  $RESULT/summary.txt"
echo "  $RESULT/pgbench.txt"
echo "  $RESULT/runtime-stats.csv"
echo "  $RESULT/system-before.txt"
echo "  $RESULT/system-at-stop.txt"
echo "  $RESULT/system-after-maintenance.txt"
echo "  $RESULT/bloat-before.txt"
echo "  $RESULT/bloat-at-stop.txt"
echo "  $RESULT/bloat-after-maintenance.txt"
echo "  $RESULT/vacuum-at-stop.txt"
echo "  $RESULT/recycler.txt"
