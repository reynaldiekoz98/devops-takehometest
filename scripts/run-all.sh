#!/usr/bin/env bash
# Run every numbered task script (10-99) in order. Works from the host or inside the toolbox.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
for s in "$DIR"/[1-9][0-9]-*.sh; do
  [ -e "$s" ] || continue
  echo; echo "################ $(basename "$s") ################"
  bash "$s"
done
echo; echo "ALL DONE"
