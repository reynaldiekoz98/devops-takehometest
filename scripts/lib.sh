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

# Download failure message, shared by every wait below.
slow_net_fail() {
  echo "ERROR: $1 did not become ready in ${2}s. The image download failed or is too slow (slow internet)." >&2
  echo "       Images already downloaded are kept, so run ./scripts/run-all.sh again; it continues where it stopped." >&2
}

# Wait for rollouts to finish, printing a line every 30s so a slow image download does not look frozen.
# Usage: wait_ready <seconds> <namespace> <kind/name>...   Returns at once when everything is ready.
wait_ready() {
  local total="$1" ns="$2" waited=0 r; shift 2
  for r in "$@"; do
    until kubectl -n "$ns" rollout status "$r" --timeout=30s >/dev/null 2>&1; do
      waited=$((waited + 30))
      if [ "$waited" -ge "$total" ]; then slow_net_fail "$r" "$total"; return 1; fi
      echo "   still waiting for $r (${waited}s of ${total}s): images may still be downloading"
    done
    echo "   $r is ready"
  done
}
