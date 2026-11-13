#!/usr/bin/env bash
# Part 3: apply the fixed manifests and run the provided verifier. Idempotent.
# SHOW_BROKEN=1 applies the original broken manifest first, to show the failure.
source "$(dirname "$0")/lib.sh"

if [ "${SHOW_BROKEN:-0}" = 1 ]; then
  log "applying the ORIGINAL broken manifest (for demonstration)"
  kubectl apply -f troubleshoot/broken-app.yaml
  sleep 10
  kubectl -n troubleshoot get pods
fi

log "applying troubleshoot/fixed-app.yaml"
kubectl apply -f troubleshoot/fixed-app.yaml

log "running troubleshoot/verify.sh"
sh troubleshoot/verify.sh
