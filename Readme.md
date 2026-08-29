<img width="1774" height="887" alt="CPA2" src="https://github.com/user-attachments/assets/6b27503b-b28b-4f9c-b483-3eb2aeb59d43" />

<img width="1536" height="1024" alt="CPA" src="https://github.com/user-attachments/assets/f8dc8b60-88cf-45d9-96bc-9d233b06511d" />


Scale a cluster add-on by **cluster size** (number of nodes and CPU cores),
not by traffic or CPU load.

- Add nodes → CPA adds CoreDNS replicas.
- Remove nodes → CPA removes them, down to a floor.
- Demo runs on EKS because the node count is easy to change there:
  `eksctl scale nodegroup`.

**Result with this demo's config:** nodegroup `2 → 4 → 6` nodes takes
CoreDNS `2 → 4 → 6` replicas, within ~10 s of each node joining.

---

## What is CPA?

- A single controller — one Deployment (`coredns-autoscaler`), one pod, one
  small Go binary — running in `kube-system` next to the add-on it manages.

- It scales its target on **cluster size only**: the number of schedulable
  nodes and total CPU cores. It never looks at traffic, CPU load, or any
  metric.

- Nothing else is installed: **no metrics-server, no HPA object, no CRD, no
  webhook.** Just this pod plus one ConfigMap.

- Good for add-ons that should grow with the cluster but have no useful
  per-pod load signal: **CoreDNS**, kube-proxy, ingress controllers,
  `metrics-server`.

---

## How it works

### 1. What tells CPA what to do

Three **container flags**, set from [`helm/values.yaml`](helm/values.yaml)
(`target`, `pollPeriodSeconds`, `config`), wire it up:

| Flag | Purpose |
|---|---|
| `--target=deployment/coredns` | the workload to resize |
| `--configmap=coredns-autoscaler` | the ConfigMap holding the scaling rules |
| `--namespace=kube-system` | where the target and the ConfigMap live |
| `--poll-period-seconds=10` | how often the loop runs |

### 2. How it connects to the cluster

- CPA talks **only to the Kubernetes API server** — no AWS calls, no metrics
  backend.

- It authenticates as a ServiceAccount bound to a ClusterRole
  ([`helm/templates/clusterrole.yaml`](helm/templates/clusterrole.yaml)) that
  grants exactly three things:
  - `get / list / watch` **nodes** — cluster-wide, to count them
  - `get / update` **deployments/scale** — to read and set the replica count
  - `get / create` **configmaps** — to read the rules (create only when
    seeding from `--default-params`)

### 3. The control loop — every `--poll-period-seconds` (~10 s)

```
1. LIST nodes           → N = schedulable nodes,  C = Σ node.status.capacity.cpu
2. GET  the ConfigMap   → parse its linear / ladder rules   (re-read every loop)
3. compute              → desired = f(N, C, rules)
4. GET  coredns /scale  → current replicas
5. if desired ≠ current → UPDATE coredns /scale   (.spec.replicas = desired)
6. sleep, repeat
```

- **Stateless** — each loop recomputes from scratch; a missed loop is just
  corrected on the next one.

- Step 5 writes the same `/scale` subresource that `kubectl scale` uses.
  After that it is ordinary Kubernetes: Deployment → ReplicaSet → pods added
  or removed, scheduler places them. CPA does not watch the rollout.

- Because CPA rewrites `.spec.replicas` every loop, **it owns that number** —
  a manual `kubectl scale`, or a second autoscaler on the same target, is
  overwritten within ~10 s. (So never put an HPA on CoreDNS as well.)

```
 ┌───────────────────────── kube-system ─────────────────────────┐
 │  Node objects ─┐                                              │
 │  (N, C)        ├──▶  coredns-autoscaler  ──▶  coredns/scale    │
 │  ConfigMap ────┘        (CPA pod)          (.spec.replicas)    │
 │  (linear/ladder)     loop every ~10s              │           │
 │                                                   ▼           │
 │                                    ReplicaSet ──▶ CoreDNS Pods │
 └──────────────────────────────────────────────────────────────┘
```

See [`docs/cpa-architecture.svg`](docs/cpa-architecture.svg) for the full
picture, [`docs/Flow.md`](docs/Flow.md) for a step-by-step model, and
[`docs/LinearVSLadder.md`](docs/LinearVSLadder.md) for a worked linear-vs-ladder
comparison.

---

## The ConfigMap — the live control surface

- The scaling rules live in a **ConfigMap**, not in flags or the Deployment
  spec, so you re-tune scaling without redeploying CPA.

- It holds **exactly one** of `linear` or `ladder`, as a JSON string:

  ```yaml
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: coredns-autoscaler      # matches --configmap
    namespace: kube-system        # matches --namespace
  data:
    linear: |-
      { "coresPerReplica": 4, "nodesPerReplica": 1, "min": 2, "max": 10,
        "preventSinglePointFailure": true, "includeUnschedulableNodes": true }
  ```

- CPA **re-reads it every loop**, so an edit applies within ~10 s — no
  restart, no rollout:

  ```bash
  kubectl -n kube-system edit configmap coredns-autoscaler
  ```

- `--default-params='<json>'` on the CPA Deployment is a fallback only: if
  the ConfigMap is missing at startup, CPA **creates** it from that JSON. If
  the ConfigMap exists, `--default-params` is ignored and the ConfigMap
  wins.

---

## Scaling modes

Set **one** of these in the ConfigMap.

### Linear — replicas rise on a straight line with cluster size

```
replicasFromNodes = ceil( N / nodesPerReplica )
replicasFromCores = ceil( C / coresPerReplica )
desired           = max( replicasFromNodes, replicasFromCores )
desired           = clamp( desired, min, max )
```

| Field | Meaning |
|---|---|
| `nodesPerReplica` | one replica per this many nodes (fractions allowed, e.g. `0.5`) |
| `coresPerReplica` | one replica per this many CPU cores |
| `min` / `max` | replica floor / ceiling |
| `preventSinglePointFailure` | if the formula gives `1`, use `2` |
| `includeUnschedulableNodes` | also count cordoned / NotReady nodes |

- The result is the **larger** of the node-based and core-based numbers,
  then clamped.

### Ladder — replicas step up at fixed thresholds

```
nodesToReplicas: [ [1,2], [3,3], [5,5] ]     # 2 nodes→2, 4 nodes→3, 6 nodes→5
coresToReplicas: [ [1,2], [8,3], [16,5] ]
```

- Each pair is `[threshold, replicas]`. CPA takes the replicas of the
  **highest pair whose threshold ≤ the current count**, for nodes and cores
  separately, then uses the larger.

- No `min` / `max` / `preventSinglePointFailure` — the ladder is the whole
  spec. Keep a `[1, N]` floor entry or a tiny cluster scales to `0`.

---

## Files

| Path | What |
|---|---|
| [`eksctl/cluster.yaml`](eksctl/cluster.yaml) | EKS cluster + managed nodegroup (2 nodes, min 2 / max 6) |
| [`helm/`](helm/) | Helm chart — the primary install path |
| [`helm/values.yaml`](helm/values.yaml) | All the knobs: image, `target`, `pollPeriodSeconds`, `config.mode` + `linear`/`ladder` blocks, RBAC |
| [`helm/templates/`](helm/templates/) | ServiceAccount, ClusterRole(+Binding), ConfigMap, Deployment |
| [`manifests/`](manifests/) | The same objects as plain YAML, for a no-Helm `kubectl apply` |

---

## Prerequisites

- `aws` CLI v2 with credentials (EKS, EC2, VPC, IAM, CloudFormation).
- `eksctl` (a recent build — EKS 1.35 needs ~0.210+), `kubectl` (within one minor of 1.35), and `helm` (only for the Helm path).
- **Cost:** EKS control plane (hourly) + 2–6 × `t3.medium`. ~30–45 min end
  to end — run cleanup when done.

All commands assume this folder is your working directory.

---

## 1. Create the cluster

```bash
eksctl create cluster -f eksctl/cluster.yaml
```

- ~15–20 min. Creates the VPC, a public API endpoint, IAM roles, nodegroup
  `ng-1` (2 nodes), and the CoreDNS add-on. kubeconfig is set for you.

```bash
kubectl get nodes
```

- Expect **2** worker nodes.
- EKS control-plane nodes never show here → CPA's node count is exactly your
  worker count.

---

## 2. Check the starting state

```bash
kubectl -n kube-system get deploy coredns
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu
```

- CoreDNS starts at **2 replicas**, fixed.
- `t3.medium` = **2 vCPU** each → 2 nodes = 4 cores.

---

## 3. Install CPA

```bash
helm install coredns-autoscaler ./helm -n kube-system
kubectl -n kube-system rollout status deploy/coredns-autoscaler
```

- Install into `kube-system` so the release namespace matches where CoreDNS
  lives — CPA resolves `--target` and its ConfigMap in that namespace.
- Override any value inline, e.g.:

  ```bash
  helm install coredns-autoscaler ./helm -n kube-system \
    --set config.linear.nodesPerReplica=0.5 \
    --set pollPeriodSeconds=15
  ```

<details>
<summary>No-Helm alternative (don't run both)</summary>

```bash
kubectl apply -f manifests/00-cpa-rbac.yaml
kubectl apply -f manifests/10-cpa-configmap-linear.yaml
kubectl apply -f manifests/20-cpa-deployment.yaml
kubectl -n kube-system rollout status deploy/coredns-autoscaler
```
</details>

---

## 4. Verify it's working

```bash
kubectl -n kube-system logs deploy/coredns-autoscaler
```

- Look for: `Cluster status: SchedulableNodes[2], SchedulableCores[4]`.
- At 2 nodes the policy wants 2 and CoreDNS is already at 2 → no change yet.

Confirm CPA owns the replica count:

```bash
kubectl -n kube-system scale deploy/coredns --replicas=1
sleep 15
kubectl -n kube-system get deploy coredns      # back to 2
```

- CPA reverts manual changes.
- **Never also put an HPA on CoreDNS** — the two would fight over
  `.spec.replicas`.

---

## 5. Scale up → watch CoreDNS follow

Terminal 1:

```bash
kubectl -n kube-system get deploy coredns -w
```

Terminal 2:

```bash
eksctl scale nodegroup --cluster cpa-demo --region ap-south-1 --name ng-1 --nodes 4
```

- New nodes take 1–3 min to join.
- Within ~10 s of node 4 becoming `Ready`: `ceil(4 / 1) = 4` → CoreDNS
  scales to **4**.

Then push to 6:

```bash
eksctl scale nodegroup --cluster cpa-demo --region ap-south-1 --name ng-1 --nodes 6
```

- → CoreDNS scales to **6**, one pod per node.

| Nodes | Cores | `ceil(N/1)` | `ceil(C/4)` | Replicas |
|---|---|---|---|---|
| 2 | 4 | 2 | 1 | **2** |
| 4 | 8 | 4 | 2 | **4** |
| 6 | 12 | 6 | 3 | **6** |

---

## 6. Scale back down

```bash
eksctl scale nodegroup --cluster cpa-demo --region ap-south-1 --name ng-1 --nodes 2
```

- As nodes drain and their `Node` objects disappear, CPA scales CoreDNS back
  toward **2** (the `min`).
- Scale-in trails the nodegroup by a minute or two — expected.

---

## 7. Try ladder mode (optional)

```bash
helm upgrade coredns-autoscaler ./helm -n kube-system --set config.mode=ladder
```

- Re-renders the ConfigMap; CPA picks it up on its next poll — no restart.
- Default ladder in [`helm/values.yaml`](helm/values.yaml): 2 nodes → **2**,
  4 nodes → **3**, 6 nodes → **5**.

Or edit the live ConfigMap directly (a quick test; the next `helm upgrade`
overwrites it):

```bash
kubectl -n kube-system edit configmap coredns-autoscaler
# in the linear JSON:  "nodesPerReplica": 1  →  0.5
```

- At 2 nodes: `ceil(2 / 0.5) = 4` → CoreDNS jumps to 4 with no node change.

Revert:

```bash
helm upgrade coredns-autoscaler ./helm -n kube-system --reset-values
```

---

## 8. Cleanup

```bash
helm uninstall coredns-autoscaler -n kube-system         # or: kubectl delete -f manifests/
kubectl -n kube-system scale deploy/coredns --replicas=2  # if keeping the cluster
eksctl delete cluster -f eksctl/cluster.yaml
```

---

## Notes

- **EKS manages CoreDNS as an add-on.** An add-on *update* can reset the
  replica count; CPA re-corrects within ~10 s.

- **No AWS IAM needed** — CPA only calls the Kubernetes API.

- **DaemonSets can't be targeted** — they have no `scale` subresource. Use a
  Deployment, ReplicaSet, or ReplicationController.

- **Works with Cluster Autoscaler / Karpenter** — they change the node
  count, CPA reacts to the result.

---

## Troubleshooting

**CPA pod `CrashLoopBackOff`**
- `kubectl -n kube-system logs deploy/coredns-autoscaler --previous`
- `nodes is forbidden` → RBAC not applied, or wrong `serviceAccountName`.
- `failed to parse` → ConfigMap JSON is malformed (if you hand-edited it).

**CoreDNS doesn't move after scaling the nodegroup**
- `kubectl get nodes` — did the new nodes reach `Ready`?
- Check the log line `SchedulableNodes[..]`. If the count updated but
  replicas didn't, the policy doesn't move at that scale, or you hit `max`.

**Manual `kubectl scale` on coredns keeps reverting**
- Expected — CPA owns that number. Scale `coredns-autoscaler` to 0 to hold a
  manual value.

---

## References

- [kubernetes-sigs/cluster-proportional-autoscaler](https://github.com/kubernetes-sigs/cluster-proportional-autoscaler)
- [Kubernetes — Autoscale the DNS Service in a Cluster](https://kubernetes.io/docs/tasks/administer-cluster/dns-horizontal-autoscaling/)
- [eksctl — Managing nodegroups](https://eksctl.io/usage/nodegroups/)
- [EKS — Managing the CoreDNS add-on](https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html)
