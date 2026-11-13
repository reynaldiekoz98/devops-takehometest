# Part 3: Troubleshooting log

`troubleshoot/broken-app.yaml` contains **9 independent faults** in the `web` and `ai-inference` Deployments, the `web-svc` Service and the NetworkPolicy setup. All are fixed in [`troubleshoot/fixed-app.yaml`](troubleshoot/fixed-app.yaml); every fix is marked `# FIX n` in the file.

**Result:** `./troubleshoot/verify.sh` prints `PASS`, including from an empty namespace in a single `kubectl apply` (about 16 seconds with images cached).

**Reproduce:**
```bash
./scripts/30-troubleshoot.sh                   # apply fixed-app.yaml, run verify.sh
SHOW_BROKEN=1 ./scripts/30-troubleshoot.sh     # apply the broken manifest first (new pods go Pending), then fix it
```

**Rules respected:** the `default-deny` NetworkPolicy is kept (three narrow allow rules are added next to it), and node labels and taints were never touched. `verify.sh` checks both, and the node taint was re-read at the end: `[{"effect":"NoSchedule","key":"nvidia.com/gpu","value":"true"}]`.

## How I worked

I applied `broken-app.yaml` unchanged and fixed one thing at a time, re-checking after each fix. One broken thing often hides the next: for example the Service port problem could not be seen until the pods were Ready. The order below is the order Kubernetes revealed them.

The commands are plain `kubectl` against the `troubleshoot` namespace. Run them from the toolbox (`docker compose exec toolbox ...`) or from the host with a kubeconfig.

| # | Symptom | Root cause |
|---|---|---|
| 1 | `web` pods `Pending`, `Insufficient memory` | memory request `16Gi`, larger than any node |
| 2 | `ai-inference` `Pending`, `didn't match Pod's node affinity/selector` and `untolerated taint` | wrong label key in `nodeSelector`, and no toleration for the GPU taint |
| 3 | `web` stuck in `ContainerCreating`, `FailedMount` | volume points at ConfigMap `web-conf`; the real name is `web-config` |
| 4 | `web` `ImagePullBackOff` | image tag `nginx:1.25.99` does not exist |
| 5 | `web` `Running` but `READY 0/1` | probes use port 8080, nginx listens on 80 |
| 6 | `web-svc` has no endpoints | selector `app: webapp` matches nothing; `targetPort` is 8080, not 80 |
| 7 | `verify.sh` step 7: smoke test fails | `default-deny` blocks DNS, egress and ingress |

---

## Issue 1: `web` pods are Pending: memory request too large

**Symptom.** Right after applying the manifest, both `web` pods and the `ai-inference` pod stay `Pending`, and the Service has no endpoints.
```
pod/web-7dfd85c595-d45qb   0/1   Pending
```

**Diagnosis.**
```bash
kubectl apply -f troubleshoot/broken-app.yaml
kubectl -n troubleshoot get pods,svc,endpoints -o wide
kubectl -n troubleshoot get events --sort-by=.lastTimestamp
kubectl -n troubleshoot get deploy web -o jsonpath='requests={.spec.template.spec.containers[0].resources.requests} limits={.spec.template.spec.containers[0].resources.limits}{"\n"}'
kubectl get nodes -o custom-columns=NODE:.metadata.name,ALLOCATABLE_MEM:.status.allocatable.memory
```
The event for `web`: `0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 Insufficient memory.` The Deployment asks for `requests={"cpu":"100m","memory":"16Gi"}`. Every node has `10082388Ki` allocatable, about 9.6 Gi. (The "1 untolerated taint" is the GPU node, which `web` rightly avoids.)

**Root cause.** The `web` container requests and limits `16Gi` of memory, more than a whole node has, so the scheduler can never place it. For nginx serving one static page, tens of MiB is plenty.

**Fix.** `requests.memory: 64Mi`, `limits.memory: 128Mi`.

## Issue 2: `ai-inference` cannot land on the GPU node

**Symptom.** `ai-inference` stays `Pending`.

**Diagnosis.**
```bash
kubectl -n troubleshoot get events --sort-by=.lastTimestamp
kubectl get node k3d-takehome-agent-3 -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep -E 'acme|gpu'
kubectl get node k3d-takehome-agent-3 -o jsonpath='{.spec.taints}{"\n"}'
kubectl -n troubleshoot get deploy ai-inference -o jsonpath='nodeSelector={.spec.template.spec.nodeSelector} tolerations={.spec.template.spec.tolerations}{"\n"}'
```
Event: `0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector.` The GPU node has the label `acme.io/node-type=gpu` and the taint `nvidia.com/gpu=true:NoSchedule`. The Deployment has `nodeSelector={"node-type":"gpu"}` and no tolerations.

**Root cause.** Two independent mistakes on the pod, which is why the event lists two reasons:
1. The `nodeSelector` key is `node-type`, but the real label key is `acme.io/node-type`. That key exists on no node, so every node is rejected.
2. There is no toleration for `nvidia.com/gpu=true:NoSchedule`. Even with the right selector, the GPU node would reject the pod because of its taint.

**Fix.** Fix the workload, not the node (the rules forbid touching node labels and taints):
```yaml
nodeSelector:
  acme.io/node-type: gpu
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
```
Result: `ai-inference` runs on `k3d-takehome-agent-3`. The taint stays, because it is what keeps other workloads off the GPU node.

## Issue 3: `web` is stuck in ContainerCreating: wrong ConfigMap name

**Symptom.** After the memory fix, a `web` pod is scheduled (onto agent-1) but never starts.

**Diagnosis.**
```bash
P=$(kubectl -n troubleshoot get pods -l app=web --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl -n troubleshoot describe $P | sed -n '/^Events/,$p'
kubectl -n troubleshoot get configmap
kubectl -n troubleshoot get deploy web -o jsonpath='{.spec.template.spec.volumes}{"\n"}'
```
Event: `MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found`. `get configmap` lists `web-config`. The volume asks for `{"configMap":{"name":"web-conf"}}`.

**Root cause.** The Deployment's volume references `web-conf`, but the ConfigMap is called `web-config`. A one-character typo.

**Fix.** `configMap.name: web-config`.

## Issue 4: `ImagePullBackOff`: the image tag does not exist

**Symptom.** With the volume fixed, the new pod goes `ErrImagePull`, then `ImagePullBackOff`.

**Diagnosis.**
```bash
P=$(kubectl -n troubleshoot get pods -l app=web --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl -n troubleshoot describe $P | sed -n '/^Events/,$p'
for t in 1.25.99 1.25.5 1.25; do printf "nginx:%-8s " $t; docker manifest inspect nginx:$t >/dev/null 2>&1 && echo exists || echo "NOT FOUND"; done
```
Event: `Failed to pull image "nginx:1.25.99": rpc error: code = NotFound`. The registry check: `nginx:1.25.99 NOT FOUND`, `nginx:1.25.5 exists`, `nginx:1.25 exists`.

**Root cause.** The tag `1.25.99` was never published.

**Fix.** `image: nginx:1.25.5`, a real, specific patch version (not `latest`), so the fix is reproducible.

## Issue 5: the pod is Running but never Ready: probes on the wrong port

**Symptom.** The new pod starts (`Pulled`, `Created`, `Started`), but shows `READY 0/1`.

**Diagnosis.**
```bash
P=$(kubectl -n troubleshoot get pods -l app=web --field-selector=status.phase=Running -o name | head -1)
kubectl -n troubleshoot describe $P | sed -n '/^Events/,$p'
kubectl -n troubleshoot exec $P -- grep -n listen /etc/nginx/conf.d/default.conf
kubectl -n troubleshoot get deploy web -o jsonpath='{range .spec.template.spec.containers[0]}containerPort={.ports[0].containerPort} liveness={.livenessProbe.httpGet.port} readiness={.readinessProbe.httpGet.port}{"\n"}{end}'
```
Event: `Readiness probe failed: Get "http://10.42.4.9:8080/": dial tcp 10.42.4.9:8080: connect: connection refused`. nginx's config says `listen 80;`. The Deployment: `containerPort=80 liveness=8080 readiness=8080`.

**Root cause.** nginx listens on 80 (and `containerPort` says 80), but both probes check port 8080. The failing readiness probe keeps the pod out of the Service. The liveness probe uses the same wrong port, so the kubelet would eventually kill and restart the container too. (In this run the pod was replaced by the next rollout before I saw a restart. An earlier run of mine showed `3 restarts` on a pod after about 80 seconds.)

**Fix.** Both probes: `port: 80`. The rollout then completes with `web` 2/2 Ready.

## Issue 6: the Service has no endpoints: selector and targetPort

**Symptom.** `web` is fully rolled out, yet the Service is empty.

**Diagnosis.**
```bash
kubectl -n troubleshoot get endpoints web-svc
kubectl -n troubleshoot get svc web-svc -o jsonpath='selector={.spec.selector}  port->targetPort={.spec.ports[0].port}->{.spec.ports[0].targetPort}{"\n"}'
kubectl -n troubleshoot get pods -l app=web --show-labels
kubectl -n troubleshoot get pods -l app=webapp          # what the Service actually selects
```
`ENDPOINTS <none>`. Selector `{"app":"webapp"}`, but the pods carry `app=web`, and selecting `app=webapp` returns `No resources found`. The same `get svc` output also shows `port->targetPort=80->8080`.

**Root cause.** Two faults in the same object:
- The selector `app: webapp` matches no pods; they are labelled `app: web`.
- `targetPort: 8080` points at a closed port; nginx serves on 80. This is invisible while the selector is wrong, because a Service with no endpoints never shows where it would send traffic. It is why the two were fixed together.

**Fix.** `selector: app: web` and `targetPort: 80`. Endpoints become `10.42.3.9:80,10.42.4.10:80`.

## Issue 7: the smoke test fails: NetworkPolicy blocks everything

**Symptom.** Steps 1 to 6 of `verify.sh` pass. Step 7 fails:
```
curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 0 ms: Couldn't connect to server
FAIL: smoke test failed (check NetworkPolicy/DNS/Service path)
```

**Diagnosis.** The message does not say which layer is blocked, so I tested each layer from a long-lived pod that carries the smoke client's label, `app=smoke-client`:
```bash
kubectl -n troubleshoot get networkpolicy default-deny -o jsonpath='{.spec}{"\n"}'
kubectl -n troubleshoot run dbg --image=curlimages/curl:8.7.1 --restart=Never --labels=app=smoke-client --command -- sleep 900
kubectl -n troubleshoot wait --for=condition=Ready pod/dbg --timeout=90s

kubectl -n troubleshoot exec dbg -- nslookup -timeout=3 web-svc.troubleshoot.svc.cluster.local     # layer 1: DNS
IP=$(kubectl -n troubleshoot get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
kubectl -n troubleshoot exec dbg -- curl -s -m 4 -o /dev/null -w 'http=%{http_code}\n' http://$IP   # layer 2: straight to a pod
CIP=$(kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.clusterIP}')
kubectl -n troubleshoot exec dbg -- curl -s -m 4 -o /dev/null -w 'http=%{http_code}\n' http://$CIP  # layer 3: Service IP, no DNS
```
`default-deny` is `{"podSelector":{},"policyTypes":["Ingress","Egress"]}`: every pod, both directions, and no rules. Results: DNS `connection timed out; no servers could be reached`; both direct connections exit with code 7 (no connection).

**Root cause.** With default-deny and no allow rules, three separate paths the smoke client needs are all blocked:
1. Egress from the client to CoreDNS (the name cannot be resolved).
2. Egress from the client to the `web` pods.
3. Ingress into the `web` pods from the client.

**Why the smoke job's log was misleading.** It says `Couldn't connect`, which suggests DNS worked. It did, but only for the first moment. I measured two things:
- A brand-new pod can resolve DNS for about the first second, then the policy takes effect (`t+0s RESOLVES`, then `blocked` from `t+1s`).
- Five separate curl processes, one per second, from a new pod: `t+0s Couldn't connect`, then `Resolving timed out` for every later one.

The smoke job uses `curl --retry`, whose retries share one process and its in-memory DNS cache. So only the first lookup ever happens, inside that first second, and every later attempt fails at the connect step. A fix for only the ingress rule would therefore have looked fine in the job log but left DNS blocked.

**Fix.** Keep `default-deny` and add three policies, each scoped to exact pods and ports:

| Policy | Applies to | Allows |
|---|---|---|
| `allow-smoke-client-dns` | pods `app=smoke-client` | egress UDP and TCP 53, to `kube-system` pods `k8s-app=kube-dns` only |
| `allow-smoke-client-to-web` | pods `app=smoke-client` | egress TCP 80, to pods `app=web` only |
| `allow-web-ingress-from-smoke-client` | pods `app=web` | ingress TCP 80, from pods `app=smoke-client` only |

No rule is needed for the kubelet's probes: the `web` pods became Ready under default-deny, so probe traffic is not filtered.

**Least privilege checked, not assumed.**
```bash
kubectl -n troubleshoot exec dbg -- curl -s -m 5 http://web-svc.troubleshoot.svc.cluster.local     # TROUBLESHOOT-OK
kubectl -n troubleshoot run intruder --image=curlimages/curl:8.7.1 --restart=Never --command -- sleep 120
kubectl -n troubleshoot exec intruder -- curl -s -m 4 -o /dev/null -w 'http=%{http_code}\n' http://$IP   # http=000, exit 7: blocked
kubectl -n troubleshoot exec intruder -- nslookup -timeout=3 web-svc.troubleshoot.svc.cluster.local     # timed out: blocked
```
The labelled client reaches the service; an unlabelled pod can neither resolve names nor connect, so default-deny still holds for everything else.

---

## Final result

```
$ kubectl delete ns troubleshoot && ./scripts/30-troubleshoot.sh
...
[7/7] In-cluster smoke test through the Service...

PASS
```
`ai-inference` runs on the GPU node, `web` has 2/2 Ready replicas, `web-svc` has two endpoints, the policy `default-deny` still exists, and the node labels and taints are unchanged.

## Notes

- One `web` replica was scheduled on the control-plane node (`k3d-takehome-server-0`). k3s servers are schedulable by default, so this is not a fault in the manifest. In production I would keep application pods off control-plane nodes.
- While rolling out fixes, old ReplicaSets keep their pods (`Pending` or `ImagePullBackOff`) until a newer revision becomes Ready. If a rollout looks stuck, inspect the **newest** pod, not the old ones.
- `scripts/lib.sh` originally forwarded only `REPO_URL` and `REVISION` into the toolbox, so `SHOW_BROKEN=1` was silently ignored when a script ran from the host. I found this while testing the script and added `SHOW_BROKEN` to the forwarded variables.
