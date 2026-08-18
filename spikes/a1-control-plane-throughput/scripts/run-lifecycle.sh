#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Gentzen A-1 — sustained job lifecycle.
#
# Producers, claimers and completers run concurrently for a fixed duration:
#
#   producer   INSERT jobs(state = READY, payload_hash = ...)
#   claimer    SELECT ... FOR UPDATE SKIP LOCKED, UPDATE state = CLAIMED
#   completer  DELETE the claimed rows  (or mark them COMPLETE, see RETAIN)
#
# Queue depth is controlled in two layers.
#
# The producer admits work at a fixed target rate (TARGET_RATE jobs/second).
# This is the layer that actually holds depth steady, and it is the knob
# worth sweeping: the question a control plane has to answer is what
# arrival rate it can absorb, not how fast INSERT can go. Left unthrottled,
# four producers admit ~220k jobs/second here, an order of magnitude past
# what the claimers retire, so the queue can only ever run away.
#
# The governor is the second layer and a safety cap, not the control. It
# polls READY depth and SIGSTOPs the producer above DEPTH_HIGH, resuming it
# below DEPTH_LOW. Polling has ~200ms of dead time, so on its own it is a
# bang-bang controller whose overshoot is the producer rate times that dead
# time; it can bound a rate-limited producer, and nothing else. If the
# summary reports a high producer_paused_pct, the run was cap-limited and
# TARGET_RATE was above what the claimers could retire, which is a finding
# rather than a knob to retune away.
#
# A producer stopped mid-transaction holds an open INSERT for up to one
# poll interval. It blocks nothing: claimers take no conflicting locks, and
# SKIP LOCKED means completers step around anything held. It does hold back
# the vacuum horizon for that interval, which is why the interval is short.
# --latency-limit makes the producer drop transactions it fell behind on
# rather than firing a catch-up burst the moment it is resumed.
#
# Usage:  ./scripts/run-lifecycle.sh <claimers> <batch> <duration-seconds>
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PGHOST="$ROOT/.state/socket"
export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-gentzen_a1}"
export PGUSER="${PGUSER:-$USER}"

CLAIMERS="${1:?claimers required}"
BATCH="${2:?batch required}"
DURATION="${3:-120}"

PRODUCERS="${PRODUCERS:-4}"
COMPLETERS="${COMPLETERS:-4}"
PRODUCE_BATCH="${PRODUCE_BATCH:-$BATCH}"
COMPLETE_BATCH="${COMPLETE_BATCH:-$BATCH}"

# The depth band the governor holds the READY queue inside. The default is
# centred on the 22,000-job burst: the sustained test should sit at roughly
# the depth the burst test measures as a one-shot event.
DEPTH_HIGH="${DEPTH_HIGH:-22000}"
DEPTH_LOW="${DEPTH_LOW:-11000}"
INITIAL_DEPTH="${INITIAL_DEPTH:-$DEPTH_LOW}"

# Jobs per second the producer tries to admit. This is the primary control.
TARGET_RATE="${TARGET_RATE:-20000}"

# A producer transaction that falls further behind its schedule than this
# is skipped rather than run late, so a governor pause is not repaid as a
# burst on resume.
PRODUCE_LATENCY_LIMIT_MS="${PRODUCE_LATENCY_LIMIT_MS:-1000}"

GOVERNOR_INTERVAL="${GOVERNOR_INTERVAL:-0.2}"

# 0 = completers DELETE claimed rows
# 1 = completers mark them COMPLETE and the rows are retained
RETAIN="${RETAIN:-0}"

SAMPLE_RATE="${SAMPLE_RATE:-1.0}"

CPU_COUNT="$(nproc)"

threads_for() {
    local clients="$1"

    if (( clients > CPU_COUNT )); then
        echo "$CPU_COUNT"
    else
        echo "$clients"
    fi
}

# pgbench --rate is an aggregate transaction rate across all its clients.
PRODUCE_TXN_RATE="$(
    awk -v jobs="$TARGET_RATE" -v batch="$PRODUCE_BATCH" \
        'BEGIN { printf "%.4f", jobs / batch }'
)"

if (( RETAIN == 1 )); then
    COMPLETE_SCRIPT="$ROOT/sql/complete-retain.sql"
    ARM="retain"
else
    COMPLETE_SCRIPT="$ROOT/sql/complete.sql"
    ARM="delete"
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="$ROOT/results/${TIMESTAMP}-lifecycle-${ARM}-c${CLAIMERS}-b${BATCH}"

mkdir -p "$RESULT"

PRODUCER_PID=""
CLAIMER_PID=""
COMPLETER_PID=""
GOVERNOR_PID=""


cleanup() {
    # The producer may be SIGSTOPped. Resume it first, or SIGTERM is
    # queued against a process that will never run to receive it.
    if [[ -n "$PRODUCER_PID" ]]; then
        kill -CONT "$PRODUCER_PID" 2>/dev/null || true
    fi

    local pid
    for pid in "$GOVERNOR_PID" "$PRODUCER_PID" "$CLAIMER_PID" "$COMPLETER_PID"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT INT TERM


echo "=== Gentzen A-1 sustained lifecycle ==="
echo "arm:                 $ARM"
echo "producers:           $PRODUCERS (batch $PRODUCE_BATCH)"
echo "target admit rate:   $TARGET_RATE jobs/s ($PRODUCE_TXN_RATE txn/s)"
echo "claimers:            $CLAIMERS (batch $BATCH)"
echo "completers:          $COMPLETERS (batch $COMPLETE_BATCH)"
echo "duration:            ${DURATION}s"
echo "depth band:          $DEPTH_LOW .. $DEPTH_HIGH READY"
echo "initial depth:       $INITIAL_DEPTH"
echo "results:             $RESULT"
echo


###############################################################################
# Environment
###############################################################################

{
    echo "date=$(date --iso-8601=seconds)"
    echo "workload=sustained-lifecycle"
    echo "arm=$ARM"
    echo "producers=$PRODUCERS"
    echo "produce_batch=$PRODUCE_BATCH"
    echo "target_rate_jobs_per_second=$TARGET_RATE"
    echo "produce_txn_rate=$PRODUCE_TXN_RATE"
    echo "produce_latency_limit_ms=$PRODUCE_LATENCY_LIMIT_MS"
    echo "claimers=$CLAIMERS"
    echo "batch=$BATCH"
    echo "completers=$COMPLETERS"
    echo "complete_batch=$COMPLETE_BATCH"
    echo "duration_seconds=$DURATION"
    echo "depth_low=$DEPTH_LOW"
    echo "depth_high=$DEPTH_HIGH"
    echo "initial_depth=$INITIAL_DEPTH"
    echo "governor_interval=$GOVERNOR_INTERVAL"
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
    findmnt -T "$ROOT/.state/pgdata"

} > "$RESULT/environment.txt"

psql --no-psqlrc -c 'SHOW ALL;' > "$RESULT/postgresql-config.txt"


###############################################################################
# Starting state
#
# seed.sql truncates, seeds, vacuums, checkpoints, and resets the table
# statistics counters, so every row counter read afterwards is a whole-run
# total for this run alone.
###############################################################################

if (( RETAIN == 1 )); then
    psql --no-psqlrc -f "$ROOT/sql/schema-retention.sql" > "$RESULT/schema-retention.txt"
fi

psql \
    --no-psqlrc \
    -v pool_size="$INITIAL_DEPTH" \
    -f "$ROOT/sql/seed.sql" \
    > "$RESULT/seed.txt"

psql --no-psqlrc -f "$ROOT/sql/system-stats.sql" > "$RESULT/system-before.txt"
psql --no-psqlrc -f "$ROOT/sql/bloat.sql"        > "$RESULT/bloat-before.txt"

WAL_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
CKPT_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"
SIZE_BEFORE="$(psql --no-psqlrc -tA -c "SELECT pg_total_relation_size('jobs');")"


###############################################################################
# The three roles
###############################################################################

pgbench \
    --no-vacuum \
    --client="$PRODUCERS" \
    --jobs="$(threads_for "$PRODUCERS")" \
    --time="$DURATION" \
    --rate="$PRODUCE_TXN_RATE" \
    --latency-limit="$PRODUCE_LATENCY_LIMIT_MS" \
    --protocol=prepared \
    --define="produce_batch=$PRODUCE_BATCH" \
    --file="$ROOT/sql/produce.sql" \
    --log \
    --sampling-rate="$SAMPLE_RATE" \
    --log-prefix="$RESULT/producer-latency" \
    "$PGDATABASE" \
    > "$RESULT/producer.txt" 2>&1 &

PRODUCER_PID=$!

pgbench \
    --no-vacuum \
    --client="$CLAIMERS" \
    --jobs="$(threads_for "$CLAIMERS")" \
    --time="$DURATION" \
    --protocol=prepared \
    --define="batch=$BATCH" \
    --file="$ROOT/sql/claim.sql" \
    --log \
    --sampling-rate="$SAMPLE_RATE" \
    --log-prefix="$RESULT/claimer-latency" \
    "$PGDATABASE" \
    > "$RESULT/claimer.txt" 2>&1 &

CLAIMER_PID=$!

pgbench \
    --no-vacuum \
    --client="$COMPLETERS" \
    --jobs="$(threads_for "$COMPLETERS")" \
    --time="$DURATION" \
    --protocol=prepared \
    --define="complete_batch=$COMPLETE_BATCH" \
    --file="$COMPLETE_SCRIPT" \
    --log \
    --sampling-rate="$SAMPLE_RATE" \
    --log-prefix="$RESULT/completer-latency" \
    "$PGDATABASE" \
    > "$RESULT/completer.txt" 2>&1 &

COMPLETER_PID=$!

sleep 0.5

for role in producer:$PRODUCER_PID claimer:$CLAIMER_PID completer:$COMPLETER_PID; do
    name="${role%%:*}"
    pid="${role##*:}"

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: $name exited during start-up" >&2
        cat "$RESULT/$name.txt" >&2
        exit 1
    fi
done


###############################################################################
# Depth governor
#
# Also the depth sampler: every poll is written out, so the CSV is a
# complete record of what the queue actually did, including how much of the
# run the producer spent paused.
###############################################################################

{
    echo "epoch,ready,claimed,producer_paused,poll_ms"

    paused=0

    while kill -0 "$PRODUCER_PID" 2>/dev/null; do
        poll_start_ns="$(date +%s%N)"

        depths="$(
            psql --no-psqlrc -tA -F' ' -c "
SELECT
    (SELECT count(*) FROM jobs WHERE state = 0),
    (SELECT count(*) FROM jobs WHERE state = 1);
" 2>/dev/null || true
        )"

        poll_end_ns="$(date +%s%N)"

        if [[ -z "$depths" ]]; then
            sleep "$GOVERNOR_INTERVAL"
            continue
        fi

        ready="${depths%% *}"
        claimed="${depths##* }"

        if (( paused == 0 && ready >= DEPTH_HIGH )); then
            kill -STOP "$PRODUCER_PID" 2>/dev/null && paused=1
        elif (( paused == 1 && ready <= DEPTH_LOW )); then
            kill -CONT "$PRODUCER_PID" 2>/dev/null && paused=0
        fi

        printf '%s,%s,%s,%s,%s\n' \
            "$(awk -v ns="$poll_end_ns" 'BEGIN { printf "%.3f", ns / 1000000000 }')" \
            "$ready" \
            "$claimed" \
            "$paused" \
            "$(awk -v ns="$((poll_end_ns - poll_start_ns))" 'BEGIN { printf "%.3f", ns / 1000000 }')"

        sleep "$GOVERNOR_INTERVAL"
    done
} > "$RESULT/depth.csv" &

GOVERNOR_PID=$!


###############################################################################
# Wait for the run to finish
###############################################################################

echo "Running for ${DURATION}s..."

PRODUCER_STATUS=0
CLAIMER_STATUS=0
COMPLETER_STATUS=0

wait "$CLAIMER_PID"   || CLAIMER_STATUS=$?
wait "$COMPLETER_PID" || COMPLETER_STATUS=$?

# If the governor left the producer stopped, its -T deadline can never
# fire. Resume it and let it finish on its own.
kill -CONT "$PRODUCER_PID" 2>/dev/null || true

wait "$PRODUCER_PID" || PRODUCER_STATUS=$?

CLAIMER_PID=""
COMPLETER_PID=""
PRODUCER_PID=""

wait "$GOVERNOR_PID" 2>/dev/null || true
GOVERNOR_PID=""

for role in producer:$PRODUCER_STATUS claimer:$CLAIMER_STATUS completer:$COMPLETER_STATUS; do
    name="${role%%:*}"
    status="${role##*:}"

    if [[ "$status" != "0" ]]; then
        echo "ERROR: $name pgbench exited $status" >&2
        cat "$RESULT/$name.txt" >&2
        exit 1
    fi
done


###############################################################################
# State at stop
###############################################################################

psql --no-psqlrc -f "$ROOT/sql/system-stats.sql"     > "$RESULT/system-at-stop.txt"
psql --no-psqlrc -f "$ROOT/sql/bloat.sql"            > "$RESULT/bloat-at-stop.txt"
psql --no-psqlrc -f "$ROOT/sql/lifecycle-metrics.sql" > "$RESULT/metrics.txt"

WAL_AFTER="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
CKPT_AFTER="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"
SIZE_AFTER="$(psql --no-psqlrc -tA -c "SELECT pg_total_relation_size('jobs');")"

read -r ROWS_INS ROWS_UPD ROWS_DEL ROWS_HOT ROWS_READY ROWS_CLAIMED ROWS_COMPLETED < <(
    psql --no-psqlrc -tA -F' ' -c "
SELECT
    s.n_tup_ins,
    s.n_tup_upd,
    s.n_tup_del,
    s.n_tup_hot_upd,
    (SELECT count(*) FROM jobs WHERE state = 0),
    (SELECT count(*) FROM jobs WHERE state = 1),
    (SELECT count(*) FROM jobs WHERE state = 2)
FROM pg_stat_user_tables AS s
WHERE s.relname = 'jobs';
"
)

# The claimer is the only writer of state = 1, so in the deleting arm every
# update is a claim. In the retention arm the completer updates too, and
# each retained row was updated exactly once by it.
if (( RETAIN == 1 )); then
    CLAIMS=$((ROWS_UPD - ROWS_COMPLETED))
    COMPLETIONS="$ROWS_COMPLETED"
else
    CLAIMS="$ROWS_UPD"
    COMPLETIONS="$ROWS_DEL"
fi

# The initial seed is not producer work.
PRODUCED=$((ROWS_INS - INITIAL_DEPTH))


###############################################################################
# Batch fill, per role
#
# A batch that comes back nearly empty means the role is faster than the
# queue can feed it and is burning transactions on an empty scan. It is the
# clearest signal of which of the three roles is actually the constraint.
###############################################################################

txns_for() {
    awk -F': ' '/number of transactions actually processed:/ {
        split($2, a, "/")
        gsub(/[^0-9]/, "", a[1])
        print a[1]
        exit
    }' "$RESULT/$1.txt"
}

PRODUCER_TXNS="$(txns_for producer)"
CLAIMER_TXNS="$(txns_for claimer)"
COMPLETER_TXNS="$(txns_for completer)"

fill_of() {
    awk -v rows="$1" -v txns="$2" -v batch="$3" \
        'BEGIN {
            if (txns > 0)
                printf "%.2f %.1f\n", rows / txns, (rows / txns) * 100 / batch
            else
                printf "0.00 0.0\n"
        }'
}

read -r CLAIMER_FILL CLAIMER_FILL_PCT \
    < <(fill_of "$CLAIMS" "$CLAIMER_TXNS" "$BATCH")

read -r COMPLETER_FILL COMPLETER_FILL_PCT \
    < <(fill_of "$COMPLETIONS" "$COMPLETER_TXNS" "$COMPLETE_BATCH")


###############################################################################
# Latency, per role
###############################################################################

for role in producer claimer completer; do
    ( cd "$RESULT" && "$ROOT/scripts/summarize-latency.py" "$role-latency.*" ) \
        > "$RESULT/latency-$role.txt" 2>/dev/null \
        || echo "samples=0" > "$RESULT/latency-$role.txt"
done


###############################################################################
# Depth behaviour
###############################################################################

DEPTH_STATS="$(
    awk -F, 'NR > 1 {
        n++

        ready_sum += $2
        if (n == 1 || $2 < ready_min) ready_min = $2
        if (n == 1 || $2 > ready_max) ready_max = $2

        claimed_sum += $3
        if (n == 1 || $3 > claimed_max) claimed_max = $3

        if ($4 == 1) paused++
        poll_sum += $5
    }
    END {
        if (n == 0) {
            print "depth_samples=0"
            exit
        }
        printf "depth_samples=%d\n", n
        printf "depth_mean=%.1f\n", ready_sum / n
        printf "depth_min=%d\n", ready_min
        printf "depth_max=%d\n", ready_max
        printf "claimed_depth_mean=%.1f\n", claimed_sum / n
        printf "claimed_depth_max=%d\n", claimed_max
        printf "producer_paused_pct=%.1f\n", (paused + 0) * 100 / n
        printf "governor_poll_mean_ms=%.3f\n", poll_sum / n
    }' "$RESULT/depth.csv"
)"


###############################################################################
# Summary
###############################################################################

per_second() {
    awk -v v="$1" -v s="$DURATION" 'BEGIN { printf "%.1f", v / s }'
}

{
    echo "workload=sustained-lifecycle"
    echo "arm=$ARM"
    echo "producers=$PRODUCERS"
    echo "produce_batch=$PRODUCE_BATCH"
    echo "claimers=$CLAIMERS"
    echo "batch=$BATCH"
    echo "completers=$COMPLETERS"
    echo "complete_batch=$COMPLETE_BATCH"
    echo "duration_seconds=$DURATION"
    echo

    echo "target_rate_jobs_per_second=$TARGET_RATE"
    echo "jobs_produced=$PRODUCED"
    echo "jobs_claimed=$CLAIMS"
    echo "jobs_completed=$COMPLETIONS"
    echo "produced_per_second=$(per_second "$PRODUCED")"
    echo "claimed_per_second=$(per_second "$CLAIMS")"
    echo "completed_per_second=$(per_second "$COMPLETIONS")"
    echo

    echo "producer_transactions=$PRODUCER_TXNS"
    echo "claimer_transactions=$CLAIMER_TXNS"
    echo "completer_transactions=$COMPLETER_TXNS"
    echo "claimer_mean_fill=$CLAIMER_FILL"
    echo "claimer_mean_fill_pct=$CLAIMER_FILL_PCT"
    echo "completer_mean_fill=$COMPLETER_FILL"
    echo "completer_mean_fill_pct=$COMPLETER_FILL_PCT"
    echo

    echo "$DEPTH_STATS"
    echo "depth_low=$DEPTH_LOW"
    echo "depth_high=$DEPTH_HIGH"
    echo "balance_pct=$(
        awk -v c="$COMPLETIONS" -v p="$PRODUCED" \
            'BEGIN { if (p > 0) printf "%.1f", c * 100 / p; else print "0.0" }'
    )"
    echo "final_ready=$ROWS_READY"
    echo "final_claimed=$ROWS_CLAIMED"
    echo "final_completed=$ROWS_COMPLETED"
    echo

    echo "rows_inserted=$ROWS_INS"
    echo "rows_updated=$ROWS_UPD"
    echo "rows_hot_updated=$ROWS_HOT"
    echo "rows_deleted=$ROWS_DEL"
    echo "wal_bytes_delta=$((WAL_AFTER - WAL_BEFORE))"
    echo "requested_checkpoints_delta=$((CKPT_AFTER - CKPT_BEFORE))"
    echo "total_relation_bytes_before=$SIZE_BEFORE"
    echo "total_relation_bytes_after=$SIZE_AFTER"
    echo

    for role in producer claimer completer; do
        sed "s/^/${role}_/" "$RESULT/latency-$role.txt"

        awk -F': ' -v r="$role" \
            '/number of failed transactions:/ {
                split($2, a, " ")
                printf "%s_failed_transactions=%s\n", r, a[1]
            }
            /number of transactions skipped:/ {
                split($2, a, " ")
                printf "%s_skipped_transactions=%s\n", r, a[1]
            }' "$RESULT/$role.txt"

        echo
    done

} | tee "$RESULT/summary.txt"

echo
echo "Run complete: $RESULT"
