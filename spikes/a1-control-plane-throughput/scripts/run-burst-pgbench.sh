#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Gentzen A-1 — 22,000-job burst drain, pgbench only.
#
#   1. Seed exactly JOBS READY rows.
#   2. Release CLAIMERS concurrent pgbench claimers against them.
#   3. No producer, no completer, no recycler. Nothing puts work back.
#   4. Stop once the queue is empty.
#   5. Report drain time, throughput, claim latency, batch fill, failures,
#      and prove every job was claimed exactly once.
#
# pgbench has no "run until the queue is empty" mode, so each claimer is
# given a deliberately oversized transaction budget instead. Once the queue
# drains, the remaining transactions find nothing, cost a few tens of
# microseconds each, and are excluded from the reported numbers. The run is
# rejected outright if the budget turned out to be too small.
#
# Timing is taken from the server, not from this script: claimed_at is
# clock_timestamp() evaluated inside the claiming UPDATE, so the drain
# window is min(claimed_at) .. max(claimed_at) and contains no client
# start-up, no connection setup, and no post-drain idle spinning.
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PGHOST="$ROOT/.state/socket"
export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-gentzen_a1}"
export PGUSER="${PGUSER:-$USER}"

CLAIMERS="${1:?claimers required}"
BATCH="${2:?batch required}"
JOBS="${3:-22000}"
REPS="${4:-5}"

# How many times over the theoretical minimum number of claim transactions
# each client is allowed to run. Covers the case where SKIP LOCKED hands
# one client most of the work and starves another.
OVERSHOOT="${OVERSHOOT:-4}"

CPU_COUNT="$(nproc)"
THREADS="${THREADS:-$CLAIMERS}"

if (( THREADS > CPU_COUNT )); then
    THREADS="$CPU_COUNT"
fi

# Minimum transactions per client to drain the burst if work were split
# perfectly and every batch came back full, then padded.
MIN_TXNS=$(( (JOBS + BATCH * CLAIMERS - 1) / (BATCH * CLAIMERS) ))
TXNS=$(( MIN_TXNS * OVERSHOOT + 16 ))

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="$ROOT/results/${TIMESTAMP}-pgburst-c${CLAIMERS}-b${BATCH}"

mkdir -p "$RESULT"

echo "=== Gentzen A-1 burst drain (pgbench) ==="
echo "claimers:            $CLAIMERS"
echo "batch:               $BATCH"
echo "burst:               $JOBS jobs"
echo "reps:                $REPS"
echo "pgbench threads:     $THREADS"
echo "txns per client:     $TXNS (minimum $MIN_TXNS, overshoot ${OVERSHOOT}x)"
echo "results:             $RESULT"
echo


###############################################################################
# Environment
###############################################################################

{
    echo "date=$(date --iso-8601=seconds)"
    echo "workload=one-shot-burst-pgbench"
    echo "driver=pgbench"
    echo "claimers=$CLAIMERS"
    echo "batch=$BATCH"
    echo "burst_jobs=$JOBS"
    echo "reps=$REPS"
    echo "pgbench_threads=$THREADS"
    echo "txns_per_client=$TXNS"
    echo "overshoot=$OVERSHOOT"
    echo

    postgres --version
    pgbench --version
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
# A 22k burst drains in the low hundreds of milliseconds, so a single
# sample is mostly noise. Each repetition runs against a freshly seeded,
# vacuumed and checkpointed queue.
###############################################################################

for ((rep = 1; rep <= REPS; rep++)); do
    REP_DIR="$RESULT/rep-$rep"

    mkdir -p "$REP_DIR"

    echo "--- rep $rep/$REPS ---"

    psql \
        --no-psqlrc \
        -v pool_size="$JOBS" \
        -f "$ROOT/sql/seed.sql" \
        > "$REP_DIR/seed.txt"

    SEEDED="$(psql --no-psqlrc -tA -c 'SELECT count(*) FROM jobs WHERE state = 0;')"

    if [[ "$SEEDED" != "$JOBS" ]]; then
        echo "ERROR: seeded $SEEDED READY jobs, expected $JOBS" >&2
        exit 1
    fi

    psql --no-psqlrc -f "$ROOT/sql/system-stats.sql" > "$REP_DIR/system-before.txt"
    psql --no-psqlrc -f "$ROOT/sql/bloat.sql"        > "$REP_DIR/bloat-before.txt"

    WAL_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
    CKPT_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"
    SIZE_BEFORE="$(psql --no-psqlrc -tA -c "SELECT pg_total_relation_size('jobs');")"

    ###########################################################################
    # The burst
    ###########################################################################

    START_NS="$(date +%s%N)"

    pgbench \
        --no-vacuum \
        --client="$CLAIMERS" \
        --jobs="$THREADS" \
        --transactions="$TXNS" \
        --protocol=prepared \
        --define="batch=$BATCH" \
        --file="$ROOT/sql/claim.sql" \
        --log \
        --log-prefix="$REP_DIR/pgbench-latency" \
        "$PGDATABASE" \
        > "$REP_DIR/pgbench.txt" 2>&1

    END_NS="$(date +%s%N)"

    WALL_SECONDS="$(
        awk -v ns="$((END_NS - START_NS))" \
            'BEGIN { printf "%.6f", ns / 1000000000 }'
    )"

    psql --no-psqlrc -f "$ROOT/sql/system-stats.sql" > "$REP_DIR/system-after.txt"
    psql --no-psqlrc -f "$ROOT/sql/bloat.sql"        > "$REP_DIR/bloat-after.txt"

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
    # Correctness gates
    #
    # Any one of these failing invalidates the repetition, and there is no
    # point averaging an invalid run into a headline number, so the harness
    # stops rather than carrying on.
    ###########################################################################

    psql \
        --no-psqlrc \
        -v expected="$JOBS" \
        -v batch="$BATCH" \
        -f "$ROOT/sql/burst-metrics.sql" \
        > "$REP_DIR/metrics.txt"

    STILL_READY="$(psql --no-psqlrc -tA -c 'SELECT count(*) FROM jobs WHERE state = 0;')"

    if [[ "$STILL_READY" != "0" ]]; then
        echo "ERROR: burst did not drain: $STILL_READY jobs still READY (rep $rep)" >&2
        echo "       raise OVERSHOOT (currently $OVERSHOOT) and re-run" >&2
        exit 1
    fi

    VIOLATIONS="$(
        psql --no-psqlrc -tA -c \
            'SELECT count(*) FROM jobs WHERE state <> 1 OR claim_count <> 1;'
    )"

    if [[ "$VIOLATIONS" != "0" ]]; then
        echo "ERROR: $VIOLATIONS jobs were not claimed exactly once (rep $rep)" >&2
        exit 1
    fi

    TOTAL_ROWS="$(psql --no-psqlrc -tA -c 'SELECT count(*) FROM jobs;')"

    if [[ "$TOTAL_ROWS" != "$JOBS" ]]; then
        echo "ERROR: table holds $TOTAL_ROWS rows, expected $JOBS (rep $rep)" >&2
        exit 1
    fi

    ###########################################################################
    # Scalars for the summary
    ###########################################################################

    read -r \
        DRAIN_START_EPOCH \
        DRAIN_END_EPOCH \
        DRAIN_MS \
        RAMP_MS \
        PRODUCTIVE_TXNS \
        MEAN_FILL \
        P50_FILL \
        MIN_FILL \
        MAX_FILL \
        < <(
        psql --no-psqlrc -tA -F' ' -c "
WITH claimed AS (
    SELECT xmin, claimed_at, claimed_by
    FROM jobs
    WHERE state = 1
),
batches AS (
    SELECT xmin, count(*) AS fill
    FROM claimed
    GROUP BY xmin
),
firsts AS (
    SELECT claimed_by, min(claimed_at) AS first_claim
    FROM claimed
    GROUP BY claimed_by
)
SELECT
    (SELECT extract(epoch FROM min(claimed_at)) FROM claimed),
    (SELECT extract(epoch FROM max(claimed_at)) FROM claimed),
    (SELECT round(extract(epoch FROM max(claimed_at) - min(claimed_at))::numeric * 1000, 3) FROM claimed),
    (SELECT round(extract(epoch FROM max(first_claim) - min(first_claim))::numeric * 1000, 3) FROM firsts),
    (SELECT count(*) FROM batches),
    (SELECT round(avg(fill), 2) FROM batches),
    (SELECT percentile_disc(0.50) WITHIN GROUP (ORDER BY fill) FROM batches),
    (SELECT min(fill) FROM batches),
    (SELECT max(fill) FROM batches);
"
    )

    TOTAL_TXNS="$(
        awk -F': ' '/number of transactions actually processed:/ {
                split($2, a, "/")
                print a[1]
                exit
            }' "$REP_DIR/pgbench.txt"
    )"

    FAILED_TXNS="$(
        awk -F': ' '/number of failed transactions:/ { split($2, a, " "); print a[1]; exit }' \
            "$REP_DIR/pgbench.txt"
    )"

    FAILED_TXNS="${FAILED_TXNS:-0}"

    ###########################################################################
    # Claim latency
    #
    # Two populations, kept separate on purpose. Once the queue is empty the
    # surviving clients keep issuing claims that find nothing and return in
    # tens of microseconds; folding those into the percentiles would make
    # the claim path look faster than it is. The drain-window population
    # keeps only transactions that completed before the last job was
    # claimed, which is the number that matters.
    ###########################################################################

    mkdir -p "$REP_DIR/drain-window"

    for log in "$REP_DIR"/pgbench-latency.*; do
        [[ -e "$log" ]] || continue

        # Field 3 is latency in microseconds, fields 5 and 6 are the
        # completion timestamp, so completion minus latency is the start.
        # Selecting on start, not completion, keeps every transaction that
        # was issued while the burst was still outstanding, including each
        # client's last productive claim, whose commit necessarily lands
        # after the row timestamps it wrote.
        awk -v cutoff="$DRAIN_END_EPOCH" \
            'NF >= 6 && (($5 + $6 / 1000000) - $3 / 1000000) <= cutoff' \
            "$log" \
            > "$REP_DIR/drain-window/$(basename "$log")"
    done

    ( cd "$REP_DIR"              && "$ROOT/scripts/summarize-latency.py" 'pgbench-latency.*' ) \
        > "$REP_DIR/latency-all.txt"

    ( cd "$REP_DIR/drain-window" && "$ROOT/scripts/summarize-latency.py" 'pgbench-latency.*' ) \
        > "$REP_DIR/latency-drain-window.txt"

    JOBS_PER_SECOND="$(
        awk -v jobs="$JOBS" -v ms="$DRAIN_MS" \
            'BEGIN { if (ms > 0) printf "%.1f", jobs / (ms / 1000); else print "inf" }'
    )"

    {
        echo "rep=$rep"
        echo "burst_jobs=$JOBS"
        echo "claimers=$CLAIMERS"
        echo "batch=$BATCH"
        echo "drain_ms=$DRAIN_MS"
        echo "jobs_per_second=$JOBS_PER_SECOND"
        echo "ramp_ms=$RAMP_MS"
        echo "wall_seconds=$WALL_SECONDS"
        echo "transactions_total=$TOTAL_TXNS"
        echo "transactions_productive=$PRODUCTIVE_TXNS"
        echo "transactions_failed=$FAILED_TXNS"
        echo "mean_fill=$MEAN_FILL"
        echo "p50_fill=$P50_FILL"
        echo "min_fill=$MIN_FILL"
        echo "max_fill=$MAX_FILL"
        echo "exactly_once_violations=$VIOLATIONS"
        echo "still_ready=$STILL_READY"
        echo "drain_start_epoch=$DRAIN_START_EPOCH"
        echo "drain_end_epoch=$DRAIN_END_EPOCH"

        sed 's/^/drain_window_/' "$REP_DIR/latency-drain-window.txt"
        sed 's/^/all_/'          "$REP_DIR/latency-all.txt"
    } > "$REP_DIR/rep-summary.txt"

    echo "drain_ms=$DRAIN_MS jobs_per_second=$JOBS_PER_SECOND ramp_ms=$RAMP_MS mean_fill=$MEAN_FILL failed=$FAILED_TXNS"
    echo
done


###############################################################################
# Aggregate
###############################################################################

{
    echo "workload=one-shot-burst-pgbench"
    echo "claimers=$CLAIMERS"
    echo "batch=$BATCH"
    echo "burst_jobs=$JOBS"
    echo "reps=$REPS"
    echo "txns_per_client=$TXNS"
    echo

    cat "$RESULT"/rep-*/rep-summary.txt \
        | awk -F= '
            $1 ~ /^(drain_ms|jobs_per_second|ramp_ms|mean_fill|transactions_failed|drain_window_p50_ms|drain_window_p95_ms|drain_window_p99_ms|drain_window_max_ms)$/ {
                sum[$1]  += $2
                n[$1]    += 1

                if (!($1 in min) || $2 < min[$1]) min[$1] = $2
                if (!($1 in max) || $2 > max[$1]) max[$1] = $2

                if (!($1 in seen)) { order[++k] = $1; seen[$1] = 1 }
            }
            END {
                for (i = 1; i <= k; i++) {
                    key = order[i]
                    printf "%s: mean=%.3f min=%.3f max=%.3f (n=%d)\n",
                        key, sum[key] / n[key], min[key], max[key], n[key]
                }
            }
        '

    echo

    echo "exactly_once_violations_total=$(
        awk -F= '/^exactly_once_violations=/ { s += $2 } END { print s + 0 }' \
            "$RESULT"/rep-*/rep-summary.txt
    )"

} | tee "$RESULT/summary.txt"

echo
echo "Run complete: $RESULT"
