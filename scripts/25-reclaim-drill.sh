#!/usr/bin/env bash
# Simulate a spot reclaim: drain one spot node while hammering the service, show the
# pods rescheduling and the request success rate, then uncordon. Idempotent.
source "$(dirname "$0")/lib.sh"

URL="http://k3d-${CLUSTER_NAME}-serverlb/api/quote"
LOG=/tmp/drill-curl.log

show() {
  printf '%-30s %-20s %-10s %-9s %s\n' POD NODE CAPACITY STATUS READY
  kubectl -n "$NS_APP" get pods --no-headers \
    -o custom-columns='P:.metadata.name,N:.spec.nodeName,S:.status.phase,R:.status.containerStatuses[0].ready' |
  while read -r p n s r; do
    c="$(kubectl get node "$n" -o jsonpath='{.metadata.labels.acme\.io/capacity}' 2>/dev/null)"
    printf '%-30s %-20s %-10s %-9s %s\n' "$p" "$n" "${c:--}" "$s" "$r"
  done
}

kubectl -n "$NS_APP" rollout status deploy/quote-api --timeout=120s >/dev/null
# Pick a spot node that currently runs a replica.
NODE="$(kubectl -n "$NS_APP" get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | sort -u | while read -r n; do
      [ "$(kubectl get node "$n" -o jsonpath='{.metadata.labels.acme\.io/capacity}')" = spot ] && echo "$n" && break
    done)"
[ -n "$NODE" ] || { echo "no replica on a spot node to drain" >&2; exit 1; }

cleanup() { kill "${CURL_PID:-0}" 2>/dev/null || true; kubectl uncordon "$NODE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "BEFORE: replicas"; show
log "starting request loop against $URL (sequential, roughly 5 req/s)"
: > "$LOG"
( while true; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL" || echo 000)"
    echo "$(date +%T) $code" >> "$LOG"; sleep 0.1
  done ) &
CURL_PID=$!
sleep 5

log "DRAIN $NODE (simulated spot reclaim)"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>&1 | grep -vE '^(WARNING|evicting node)' || true
kubectl -n "$NS_APP" rollout status deploy/quote-api --timeout=120s
for _ in $(seq 1 30); do
  [ "$(kubectl -n "$NS_APP" get pods --field-selector=status.phase=Running --no-headers | grep -c ' 1/1 ')" -ge 3 ] && break; sleep 2
done
log "DURING the drain: replicas rescheduled"; show

sleep 5
log "UNCORDON $NODE"; kubectl uncordon "$NODE"
sleep 5
kill "$CURL_PID" 2>/dev/null || true

log "RESULT: HTTP status codes during the drill"
awk '{c[$2]++; n++} END{for(k in c) printf "  %s x %d\n", k, c[k]; printf "  total %d requests\n", n}' "$LOG"
ok="$(grep -c ' 200$' "$LOG" || true)"; total="$(wc -l < "$LOG")"
echo "  success rate: $(( 100 * ok / total ))%"
log "AFTER: replicas"; show
