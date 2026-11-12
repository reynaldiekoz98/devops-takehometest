# Rendered by scripts/20-deploy.sh (envsubst: REPO_URL, REVISION).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: quote-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: charts/quote-api
  destination:
    server: https://kubernetes.default.svc
    namespace: quote
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
