#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Payload-placement test.
#
# Drains an identical 22,000-job burst under two designs:
#
#   reference  the Gentzen design. The control-plane row holds a 32-byte
#              payload hash; the document itself lives in an external blob
#              store on the filesystem.
#
#   inline     the design Gentzen rejects. The document is stored in the
#              control-plane row as jsonb.
#
# Both arms are run at several payload sizes. The question is whether claim
# throughput and p99 stay flat as the payload grows.
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PGHOST="$ROOT/.state/socket"
export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-gentzen_a1}"
export PGUSER="${PGUSER:-$USER}"

ARM="${1:?arm required: reference|inline}"
PAYLOAD_BYTES="${2:?payload bytes required}"
JOBS="${3:-22000}"
REPS="${4:-3}"

CLAIMERS="${CLAIMERS:-8}"
BATCH="${BATCH:-50}"

DRIVER="$ROOT/burst/a1burst"
BLOBS="$ROOT/.state/blobs"

if [[ ! -x "$DRIVER" ]]; then
    echo "ERROR: burst driver not built: $DRIVER" >&2
    exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="$ROOT/results/${TIMESTAMP}-payload-${ARM}-${PAYLOAD_BYTES}B"

mkdir -p "$RESULT"

echo "=== Gentzen A-1 payload placement ==="
echo "arm:            $ARM"
echo "payload bytes:  $PAYLOAD_BYTES"
echo "burst:          $JOBS jobs"
echo "claimers:       $CLAIMERS x batch $BATCH"
echo "reps:           $REPS"
echo "results:        $RESULT"
echo

{
    echo "date=$(date --iso-8601=seconds)"
    echo "workload=payload-placement"
    echo "arm=$ARM"
    echo "payload_bytes=$PAYLOAD_BYTES"
    echo "burst_jobs=$JOBS"
    echo "claimers=$CLAIMERS"
    echo "batch=$BATCH"
    echo "reps=$REPS"
} > "$RESULT/environment.txt"


###############################################################################
# Schema for this arm
###############################################################################

case "$ARM" in
    reference)
        psql --no-psqlrc -f "$ROOT/sql/schema.sql" > "$RESULT/schema.txt"
        ;;

    inline)
        psql --no-psqlrc -f "$ROOT/sql/schema-inline.sql" > "$RESULT/schema.txt"
        ;;

    *)
        echo "ERROR: unknown arm: $ARM (expected reference|inline)" >&2
        exit 1
        ;;
esac


###############################################################################
# Payload plane
#
# The reference arm must actually put the bytes somewhere, otherwise the
# comparison is rigged: "PostgreSQL is faster when the data does not exist" is
# not a finding. The blob store is materialized once per payload size and
# reused across repetitions, exactly as an object store would be.
###############################################################################

if [[ "$ARM" == "reference" ]]; then
    BLOB_DIR="$BLOBS/$PAYLOAD_BYTES"

    if [[ ! -f "$BLOB_DIR/.complete" ]]; then
        echo "Materializing $JOBS external payloads of ${PAYLOAD_BYTES}B..."

        rm -rf "$BLOB_DIR"

        # Sharded so no single directory holds 22,000 entries.
        for shard in $(seq 0 63); do
            mkdir -p "$BLOB_DIR/$shard"
        done

        BLOB_START="$(date +%s%N)"

        for ((i = 1; i <= JOBS; i++)); do
            dd if=/dev/urandom \
                of="$BLOB_DIR/$((i % 64))/$i.bin" \
                bs="$PAYLOAD_BYTES" \
                count=1 \
                status=none
        done

        sync

        BLOB_END="$(date +%s%N)"

        echo "blob_store_build_seconds=$(awk -v ns=$((BLOB_END - BLOB_START)) \
            'BEGIN { printf "%.2f", ns / 1e9 }')" > "$BLOB_DIR/.complete"
    fi

    {
        echo "blob_store_path=$BLOB_DIR"
        echo "blob_store_bytes=$(du -sb "$BLOB_DIR" | cut -f1)"
        cat "$BLOB_DIR/.complete"
    } > "$RESULT/blob-store.txt"

    cat "$RESULT/blob-store.txt"
fi


###############################################################################
# Repetitions
###############################################################################

for ((rep = 1; rep <= REPS; rep++)); do
    REP_DIR="$RESULT/rep-$rep"

    mkdir -p "$REP_DIR"

    echo "--- rep $rep/$REPS ---"

    # Ingest is measured too. Writing the burst in is part of the real cost of
    # a design, and it is where inline payloads are expected to hurt most.
    SEED_START="$(date +%s%N)"
    WAL_SEED_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"

    if [[ "$ARM" == "inline" ]]; then
        psql \
            --no-psqlrc \
            -v pool_size="$JOBS" \
            -v payload_bytes="$PAYLOAD_BYTES" \
            -f "$ROOT/sql/seed-inline.sql" \
            > "$REP_DIR/seed.txt"
    else
        psql \
            --no-psqlrc \
            -v pool_size="$JOBS" \
            -f "$ROOT/sql/seed.sql" \
            > "$REP_DIR/seed.txt"
    fi

    WAL_SEED_AFTER="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
    SEED_END="$(date +%s%N)"

    psql --no-psqlrc -f "$ROOT/sql/payload-stats.sql" > "$REP_DIR/payload-stats.txt"

    WAL_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
    CKPT_BEFORE="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"

    "$DRIVER" \
        -claimers "$CLAIMERS" \
        -batch "$BATCH" \
        -jobs "$JOBS" \
        -out "$REP_DIR" \
        | tee "$REP_DIR/driver.txt"

    WAL_AFTER="$(psql --no-psqlrc -tA -c 'SELECT wal_bytes FROM pg_stat_wal;')"
    CKPT_AFTER="$(psql --no-psqlrc -tA -c 'SELECT num_requested FROM pg_stat_checkpointer;')"

    HEAP="$(psql --no-psqlrc -tA -c "SELECT pg_relation_size('jobs');")"
    TOAST="$(psql --no-psqlrc -tA -c "
SELECT COALESCE(pg_total_relation_size(reltoastrelid), 0)
FROM pg_class WHERE oid = 'jobs'::regclass;")"
    TOTAL="$(psql --no-psqlrc -tA -c "SELECT pg_total_relation_size('jobs');")"
    TUPLES_PER_PAGE="$(psql --no-psqlrc -tA -c "
SELECT CASE WHEN relpages > 0 THEN round((reltuples / relpages)::numeric, 1) ELSE 0 END
FROM pg_class WHERE oid = 'jobs'::regclass;")"

    {
        echo "arm=$ARM"
        echo "payload_bytes=$PAYLOAD_BYTES"
        echo "wal_bytes_delta=$((WAL_AFTER - WAL_BEFORE))"
        echo "requested_checkpoints_delta=$((CKPT_AFTER - CKPT_BEFORE))"
        echo "seed_seconds=$(awk -v ns=$((SEED_END - SEED_START)) \
            'BEGIN { printf "%.3f", ns / 1e9 }')"
        echo "seed_wal_bytes=$((WAL_SEED_AFTER - WAL_SEED_BEFORE))"
        echo "heap_bytes=$HEAP"
        echo "toast_bytes=$TOAST"
        echo "total_relation_bytes=$TOTAL"
        echo "tuples_per_page=$TUPLES_PER_PAGE"
    } > "$REP_DIR/deltas.txt"

    psql --no-psqlrc -f "$ROOT/sql/verify-burst.sql" > "$REP_DIR/verify.txt"

    VIOLATIONS="$(
        psql --no-psqlrc -tA -c "
SELECT count(*) FROM jobs WHERE state <> 1 OR claim_count <> 1;"
    )"

    echo "exactly_once_violations=$VIOLATIONS" | tee "$REP_DIR/exactly-once.txt"

    if [[ "$VIOLATIONS" != "0" ]]; then
        echo "ERROR: burst did not claim every job exactly once (rep $rep)" >&2
        exit 1
    fi

    echo
done

"$ROOT/scripts/summarize-burst.py" "$RESULT" | tee "$RESULT/summary.txt"

echo
echo "Run complete: $RESULT"
