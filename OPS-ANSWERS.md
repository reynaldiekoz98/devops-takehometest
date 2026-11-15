# Part 7: Ops answers

## 1. EKS 1.33 → 1.35, zero downtime

EKS upgrades one minor version at a time and the control plane cannot be rolled back, so this is two passes
(1.33 → 1.34 → 1.35) of the same loop:

1. **Prepare.** Scan for APIs removed in the target version (`pluto`/`kubent`, EKS upgrade insights), check each addon
   (vpc-cni, CoreDNS, kube-proxy, EBS/EFS CSI) supports the target, make sure important workloads have 2+ replicas, a PDB
   and spread. Rehearse in a non-production cluster.
2. **Control plane.** Upgrade it (the API stays available). Watch API errors and admission webhooks.
3. **Addons.** Move to the recommended versions one at a time: kube-proxy and vpc-cni, CoreDNS, then the CSI drivers. Check pods and DNS in between.
4. **Nodes.** Replace nodes instead of patching: managed node group rolling update, or Karpenter drift, with low `maxUnavailable`. System and on-demand nodes first, spot last.
5. **Verify**, then repeat for the next minor.

**Top 3 risks:** (1) removed APIs, or a webhook with `failurePolicy: Fail` whose pods are down, blocking applies, so scan first and upgrade operators early;
(2) addon or AMI incompatibility breaking pod networking or DNS cluster-wide, so follow the version matrix and canary one node group;
(3) drains that stall (strict PDBs) or cut capacity (EBS volumes tied to one AZ), so review PDBs and keep spare capacity per AZ.

## 2. Spot reclaims paging at 3 AM

Page on what users feel, not on one node leaving, and make spot interruptions an expected event.

- **Handle the interruption.** Run the node termination handler or Karpenter interruption handling, so the node is cordoned and drained during the 2-minute notice.
- **Treat spot differently.** Label alerts by capacity type. `KubeNodeUnreachable` on a spot node becomes a ticket (or is inhibited when the node is already terminating); on on-demand and system nodes it still pages after a short `for:`.
- **Page on effect:** replicas unavailable for more than a few minutes, pods Pending over 10 minutes (capacity problem), and SLO burn-rate alerts on errors and latency. These stay quiet when pods moved cleanly.
- **Group and inhibit** in Alertmanager by cluster and nodepool, so ten nodes leaving is one notification.
- **Do not lose real failures:** alert when a nodepool has fewer Ready nodes than desired for about 10 minutes (the replacement never came), when an on-demand node is NotReady, and keep a dead-man's-switch alert to prove alerting works. Review the pages weekly and tune `for:` from data.

## 3. Cloudflare site, mobile LCP 5 s, HTML caching suspected

Cloudflare caches by file extension by default, so HTML is not cached unless a rule says so.

1. **Split the time.** Run WebPageTest or Lighthouse on a mobile profile and read TTFB separately. High TTFB (over about 800 ms) means origin or uncached HTML; low TTFB with slow LCP means images, fonts or blocking scripts.
2. **Headers.** `curl -sI https://site/` twice: `cf-cache-status` (`DYNAMIC` = not cacheable, `MISS` then `HIT` = working), `age`, `cache-control`, `set-cookie`, `vary`.
3. **Causes:** no Cache Rule making HTML eligible; origin sends `no-store`, `private` or `max-age=0`; a `Set-Cookie` on every response; `Vary: Cookie` or `User-Agent` splitting the cache; query strings (utm) making a new cache key per visit.
4. **Fix:** a Cache Rule for the marketing paths with an edge TTL, bypass on a login cookie, ignore tracking parameters in the cache key, no cookies on public pages, Tiered Cache, and a purge on each deploy.
5. **Verify:** `HIT` and lower TTFB with curl, cache hit ratio in analytics, then field data (CrUX) over a few weeks. If LCP is still slow, optimise and preload the hero image, use Early Hints, cut render-blocking scripts.

## 4. Application secrets on EKS

**A. External Secrets Operator + AWS Secrets Manager.** Values live in AWS; the operator reads them with the pod's IAM role
(IRSA / Pod Identity) and creates Kubernetes Secrets; Git only holds references. Rotation, versioning and audit (CloudTrail) come
from AWS, with a scoped role per cluster. Costs: a fee per secret, an AWS dependency, and values still sit in etcd (enable KMS envelope encryption).

**B. Sealed Secrets or SOPS in Git.** Encrypted secrets are committed and decrypted in the cluster. It fits GitOps and needs no
cloud service. Costs: you own key management (per cluster), rotation means re-encrypting and committing, no central audit of
who read what, and a lost key means lost secrets.

**Pick: A.** With several production clusters, one central place with IAM-scoped access, rotation and an audit log is worth the small cost, the team runs
no key management, and a leaked repo leaks no secrets. ArgoCD syncs the `ExternalSecret` objects from Git, with one IAM role per cluster and namespace.
