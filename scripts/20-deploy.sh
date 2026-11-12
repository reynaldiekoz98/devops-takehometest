#!/usr/bin/env bash
# Part 2: install ArgoCD and deploy the quote-api Helm chart through an ArgoCD
# Application (the app is never installed with `helm install`). Idempotent.
# Optional env: REPO_URL (default: this repo's git origin), REVISION (default: main).
source "$(dirname "$0")/lib.sh"

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.1}"
REVISION="${REVISION:-main}"

if [ -z "${REPO_URL:-}" ]; then
  git config --global --add safe.directory /work
  origin="$(git -C /work remote get-url origin 2>/dev/null || true)"
  [ -n "$origin" ] || { echo "ERROR: no git 'origin' remote and REPO_URL not set; ArgoCD needs a Git URL to sync from." >&2; exit 1; }
  # git@github.com:user/repo.git -> https://github.com/user/repo.git
  REPO_URL="$(echo "$origin" | sed -E 's#^git@([^:]+):#https://\1/#')"
fi
export REPO_URL REVISION

log "installing ArgoCD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
kubectl -n argocd rollout status deploy/argocd-repo-server deploy/argocd-server deploy/argocd-applicationset-controller --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

log "applying the Application (repo: $REPO_URL @ $REVISION)"
envsubst '${REPO_URL} ${REVISION}' < argocd/application.yaml.tpl | kubectl apply -f -

log "waiting for the Application to be Synced + Healthy"
for _ in $(seq 1 90); do
  sync="$(kubectl -n argocd get app quote-api -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl -n argocd get app quote-api -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  echo "   sync=${sync:-?} health=${health:-?}"
  [ "$sync" = Synced ] && [ "$health" = Healthy ] && break
  sleep 5
done
if [ "$sync" != Synced ] || [ "$health" != Healthy ]; then
  kubectl -n argocd get app quote-api -o jsonpath='{.status.conditions}' ; echo
  exit 1
fi

log "pods and placement"
kubectl -n "$NS_APP" get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
kubectl get nodes -L acme.io/capacity -L acme.io/node-type

log "smoke test through the ingress"
curl -fsS --retry 10 --retry-delay 3 --retry-connrefused "http://k3d-${CLUSTER_NAME}-serverlb/api/quote"; echo
echo "From the host:  curl http://localhost:${HTTP_PORT:-8080}/api/quote"
