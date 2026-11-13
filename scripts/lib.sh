#!/usr/bin/env bash
# Shared helpers. Every script starts with:  source "$(dirname "$0")/lib.sh"
# Run on the host, a script transparently re-executes itself inside the toolbox.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPTS_DIR")"

if [ "${TOOLBOX:-}" != "1" ]; then
  cd "$REPO_ROOT"
  if ! docker compose ps --status running --services 2>/dev/null | grep -qx toolbox; then
    echo ">> harness not running, starting it (docker compose up -d)"
    docker compose up -d
  fi
  envs=(); for v in REPO_URL REVISION SHOW_BROKEN; do [ -n "${!v:-}" ] && envs+=(-e "$v=${!v}"); done
  exec docker compose exec -T "${envs[@]}" toolbox bash "/scripts/$(basename "$0")" "$@"
fi

# Inside the toolbox from here on.
cd /work
export CLUSTER_NAME="${CLUSTER_NAME:-takehome}"
export NS_APP="${NS_APP:-quote}"
log() { printf '\n==> %s\n' "$*"; }
