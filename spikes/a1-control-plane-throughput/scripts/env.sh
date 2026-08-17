#!/usr/bin/env zsh

SCRIPT_PATH="${(%):-%N}"
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

export PGHOST="$ROOT/.state/socket"
export PGPORT="${PGPORT:-55432}"
export PGDATABASE="${PGDATABASE:-gentzen_a1}"
export PGUSER="${PGUSER:-$USER}"
