#!/usr/bin/env bash
# Create (or reuse) the k3d cluster, write an in-network kubeconfig, label the nodes.
# Idempotent: safe to re-run. Normally started by `docker compose up -d`.
source "$(dirname "$0")/lib.sh"

AGENTS="${AGENTS:-4}"
HTTP_PORT="${HTTP_PORT:-8080}"

if k3d cluster list -o json | jq -e --arg n "$CLUSTER_NAME" '.[] | select(.name==$n)' >/dev/null 2>&1; then
  log "cluster '$CLUSTER_NAME' exists"
  k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || true
else
  log "creating cluster '$CLUSTER_NAME' (1 server + $AGENTS agents); host port $HTTP_PORT -> ingress"
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 --agents "$AGENTS" \
    --network takehome-net \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --k3s-arg "--tls-san=k3d-${CLUSTER_NAME}-serverlb@server:0" \
    --kubeconfig-update-default=false --kubeconfig-switch-context=false \
    --wait --timeout 300s
fi

log "writing kubeconfig to $KUBECONFIG"
mkdir -p "$(dirname "$KUBECONFIG")"
k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG"
kubectl config set-cluster "k3d-$CLUSTER_NAME" --server="https://k3d-${CLUSTER_NAME}-serverlb:6443" >/dev/null
chmod 600 "$KUBECONFIG"

log "waiting for all nodes Ready"
kubectl wait --for=condition=Ready node --all --timeout=180s

log "labelling/tainting nodes (provided troubleshoot/prepare.sh)"
sh /work/troubleshoot/prepare.sh

log "making the ingress controller (Traefik) highly available (cluster/traefik-ha.yaml)"
kubectl apply -f /work/cluster/traefik-ha.yaml
# k3s re-renders its bundled chart asynchronously; wait until 2 replicas are ready on the new revision.
for _ in $(seq 1 60); do
  [ "$(kubectl -n kube-system get deploy traefik -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 2 ] \
    && [ "$(kubectl -n kube-system get deploy traefik -o jsonpath='{.status.updatedReplicas}' 2>/dev/null)" = 2 ] && break
  sleep 3
done
kubectl -n kube-system rollout status deploy/traefik --timeout=120s
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
