#!/usr/bin/env zsh
set -euo pipefail

OUT="${1:?output CSV required}"
INTERVAL="${2:-15}"

echo \
'timestamp,table_bytes,index_bytes,n_live_tup,n_dead_tup,n_tup_upd,n_tup_hot_upd,autovacuum_count,last_autovacuum' \
> "$OUT"

while true; do
    psql \
        --no-psqlrc \
        --tuples-only \
        --no-align \
        --field-separator=',' \
        -c "
SELECT
    extract(epoch FROM clock_timestamp()),
    pg_table_size('jobs'),
    pg_indexes_size('jobs'),
    n_live_tup,
    n_dead_tup,
    n_tup_upd,
    n_tup_hot_upd,
    autovacuum_count,
    COALESCE(extract(epoch FROM last_autovacuum)::text, '')
FROM pg_stat_user_tables
WHERE relname = 'jobs';
" >> "$OUT"

    sleep "$INTERVAL"
done
