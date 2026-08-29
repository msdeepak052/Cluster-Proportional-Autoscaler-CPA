<img width="1369" height="1149" alt="CPA" src="https://github.com/user-attachments/assets/b6554bb9-3bfe-4d12-a325-0deeb56aeab3" />


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

- A single controller Deployment that runs next to the add-on it manages.

- Every ~10 s it:
  - counts schedulable **nodes** and **cores**
  - reads a **ConfigMap** of scaling rules
  - computes a target replica count
  - writes it to the target's `.spec.replicas`

- No metrics-server. No HPA. No CRD. Just node count + a ConfigMap.

- Typical targets: **CoreDNS**, kube-proxy, ingress controllers,
  `metrics-server` — add-ons that should grow with the cluster but have no
  useful per-pod load signal.

```
 nodes + cores ─┐
                ├─→  CPA controller  ──→  set coredns .spec.replicas
 ConfigMap ─────┘        (loops continuously, every ~10s)
```

See [`docs/cpa-architecture.svg`](docs/cpa-architecture.svg) for the full
picture, and [`Flow.md`](Flow.md) for a step-by-step model.

---

## How it scales — two modes

Pick **one** in the ConfigMap.

**Linear** — replicas rise on a straight line with cluster size:

```
replicas = max( ceil(nodes / nodesPerReplica), ceil(cores / coresPerReplica) )
replicas = clamp(replicas, min, max)
```

**Ladder** — replicas step up at fixed thresholds:

```
nodesToReplicas: [ [1,2], [3,3], [5,5] ]     # 2 nodes→2, 4 nodes→3, 6 nodes→5
```

---

## Files

| Path | What |
|---|---|
| [`eksctl/cluster.yaml`](eksctl/cluster.yaml) | EKS cluster + managed nodegroup (2 nodes, min 2 / max 6) |
| [`manifests/00-cpa-rbac.yaml`](manifests/00-cpa-rbac.yaml) | ServiceAccount + RBAC: read nodes, write `deployments/scale` |
| [`manifests/10-cpa-configmap-linear.yaml`](manifests/10-cpa-configmap-linear.yaml) | Linear policy (default) |
| [`manifests/11-cpa-configmap-ladder.yaml`](manifests/11-cpa-configmap-ladder.yaml) | Ladder policy (swap-in) |
| [`manifests/20-cpa-deployment.yaml`](manifests/20-cpa-deployment.yaml) | The CPA controller, targeting `deployment/coredns` |
| [`helm/cpa-values.yaml`](helm/cpa-values.yaml) | Same setup via the Helm chart |

---

## Prerequisites

- `aws` CLI v2 with credentials (EKS, EC2, VPC, IAM, CloudFormation).
- `eksctl` ≥ 0.190, `kubectl`, and `helm` (only for the Helm path).
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
kubectl apply -f manifests/00-cpa-rbac.yaml
kubectl apply -f manifests/10-cpa-configmap-linear.yaml
kubectl apply -f manifests/20-cpa-deployment.yaml
kubectl -n kube-system rollout status deploy/coredns-autoscaler
```

<details>
<summary>Helm alternative (don't run both)</summary>

```bash
helm repo add cluster-proportional-autoscaler \
  https://kubernetes-sigs.github.io/cluster-proportional-autoscaler
helm repo update
helm install coredns-autoscaler \
  cluster-proportional-autoscaler/cluster-proportional-autoscaler \
  -n kube-system -f helm/cpa-values.yaml
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
eksctl scale nodegroup --cluster cpa-demo --region us-east-1 --name ng-1 --nodes 4
```

- New nodes take 1–3 min to join.
- Within ~10 s of node 4 becoming `Ready`: `ceil(4 / 1) = 4` → CoreDNS
  scales to **4**.

Then push to 6:

```bash
eksctl scale nodegroup --cluster cpa-demo --region us-east-1 --name ng-1 --nodes 6
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
eksctl scale nodegroup --cluster cpa-demo --region us-east-1 --name ng-1 --nodes 2
```

- As nodes drain and their `Node` objects disappear, CPA scales CoreDNS back
  toward **2** (the `min`).
- Scale-in trails the nodegroup by a minute or two — expected.

---

## 7. Try ladder mode (optional)

```bash
kubectl apply -f manifests/11-cpa-configmap-ladder.yaml
```

- CPA picks up the new ConfigMap on its next poll — no restart.
- This ladder: 2 nodes → **2**, 4 nodes → **3**, 6 nodes → **5**.

Or edit live:

```bash
kubectl -n kube-system edit configmap coredns-autoscaler
# in the linear JSON:  "nodesPerReplica": 1  →  0.5
```

- At 2 nodes: `ceil(2 / 0.5) = 4` → CoreDNS jumps to 4 with no node change.

Revert:

```bash
kubectl apply -f manifests/10-cpa-configmap-linear.yaml
```

---

## 8. Cleanup

```bash
kubectl delete -f manifests/ --ignore-not-found
kubectl -n kube-system scale deploy/coredns --replicas=2    # if keeping the cluster
eksctl delete cluster -f eksctl/cluster.yaml
```

---

## Config reference — linear

[`manifests/10-cpa-configmap-linear.yaml`](manifests/10-cpa-configmap-linear.yaml):

| Field | Meaning |
|---|---|
| `coresPerReplica` | one replica per this many cores |
| `nodesPerReplica` | one replica per this many nodes (fractions allowed) |
| `min` / `max` | replica floor / ceiling |
| `preventSinglePointFailure` | if the formula gives 1, use 2 |
| `includeUnschedulableNodes` | count cordoned / NotReady nodes too |

- Result = **max** of the nodes calc and the cores calc, then clamped.
- Exactly **one** of `linear` / `ladder` may be present.

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
- `failed to parse` → ConfigMap JSON is malformed, or has both `linear` and
  `ladder`.

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
