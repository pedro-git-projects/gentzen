#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Gentzen A-1 — find the sustained admission ceiling.
#
# Runs the lifecycle at a series of producer rates and prints one line per
# rate. The ceiling is the highest TARGET_RATE that still satisfies all of:
#
#   balance ~= 100%                          completers keep up with producers
#   producer_paused_pct ~= 0                 the safety cap never fired
#   ready_max well inside the band           no runaway READY backlog
#   claimed_max stays flat                   no runaway CLAIMED backlog
#
# Above that rate the queue grows until the governor pauses the producer,
# and the run is measuring the cap rather than PostgreSQL.
#
# Both backlogs have to be read, not just READY. The governor only watches
# READY, so a rate at which claimers outrun completers shows a healthy
# READY depth while CLAIMED grows without bound. balance and claimed_max
# are the columns that catch it.
#
# Usage:  ./scripts/run-lifecycle-sweep.sh <claimers> <batch> <duration> [rates...]
###############################################################################

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLAIMERS="${1:?claimers required}"
BATCH="${2:?batch required}"
DURATION="${3:-60}"

shift 3 || true

RATES=("$@")

if (( ${#RATES[@]} == 0 )); then
    RATES=(20000 40000 80000 120000 160000 200000)
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SWEEP="$ROOT/results/${TIMESTAMP}-lifecycle-sweep-c${CLAIMERS}-b${BATCH}"

mkdir -p "$SWEEP"

REPORT="$SWEEP/sweep.txt"

{
    printf '%8s %11s %11s %11s %9s %10s %10s %11s %8s %9s %6s\n' \
        target produced/s claimed/s completed/s balance% ready_mean ready_max claimed_max paused% claim_p99 fill
} | tee "$REPORT"

for rate in "${RATES[@]}"; do
    out="$(TARGET_RATE="$rate" "$ROOT/scripts/run-lifecycle.sh" "$CLAIMERS" "$BATCH" "$DURATION" 2>&1)"

    echo "$out" > "$SWEEP/rate-$rate.txt"

    printf '%8s %11s %11s %11s %9s %10s %10s %11s %8s %9s %6s\n' \
        "$rate" \
        "$(awk -F= '/^produced_per_second=/  { print $2 }' <<<"$out")" \
        "$(awk -F= '/^claimed_per_second=/   { print $2 }' <<<"$out")" \
        "$(awk -F= '/^completed_per_second=/ { print $2 }' <<<"$out")" \
        "$(awk -F= '/^balance_pct=/          { print $2 }' <<<"$out")" \
        "$(awk -F= '/^depth_mean=/           { print $2 }' <<<"$out")" \
        "$(awk -F= '/^depth_max=/            { print $2 }' <<<"$out")" \
        "$(awk -F= '/^claimed_depth_max=/    { print $2 }' <<<"$out")" \
        "$(awk -F= '/^producer_paused_pct=/  { print $2 }' <<<"$out")" \
        "$(awk -F= '/^claimer_p99_ms=/       { print $2 }' <<<"$out")" \
        "$(awk -F= '/^claimer_mean_fill=/    { print $2 }' <<<"$out")" \
        | tee -a "$REPORT"
done

echo
echo "Sweep complete: $SWEEP"
