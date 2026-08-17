#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PGDATA="$ROOT/.state/pgdata"
PGSOCKET="$ROOT/.state/socket"
PGLOG="$ROOT/.state/postgres.log"
PGPORT="${PGPORT:-55432}"

mkdir -p "$ROOT/.state" "$PGSOCKET"

case "${1:-}" in
    init)
        if [[ -d "$PGDATA" ]]; then
            echo "PostgreSQL cluster already exists: $PGDATA"
            exit 0
        fi

        initdb \
            -D "$PGDATA" \
            --auth=trust

        cat >> "$PGDATA/postgresql.conf" <<EOF

# Gentzen A-1 spike
port = $PGPORT
listen_addresses = ''
unix_socket_directories = '$PGSOCKET'
EOF

        echo "Initialized PostgreSQL cluster in $PGDATA"
        ;;

    start)
        pg_ctl \
            -D "$PGDATA" \
            -l "$PGLOG" \
            start

        echo "PostgreSQL started"
        ;;

    stop)
        pg_ctl \
            -D "$PGDATA" \
            stop

        echo "PostgreSQL stopped"
        ;;

    status)
        pg_ctl \
            -D "$PGDATA" \
            status
        ;;

    *)
        echo "usage: $0 {init|start|stop|status}"
        exit 1
        ;;
esac
