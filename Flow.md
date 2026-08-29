# Cluster Proportional Autoscaler + CoreDNS on EKS: End-to-End

---

# 1. Our exact example

```text
AWS
└── EKS cluster: cpa-demo
    └── managed nodegroup: ng-1
        └── EC2 Auto Scaling Group   desired = 2  (min 2, max 6)

kube-system namespace
├── Deployment: coredns              (EKS managed add-on, starts at 2 replicas)
├── Deployment: coredns-autoscaler   (the CPA controller, 1 replica)
├── ConfigMap:  coredns-autoscaler   (linear OR ladder params)
└── ServiceAccount/ClusterRole/ClusterRoleBinding: cpa
```

Requirement:

> Scale `coredns` on the number of nodes and cores in the cluster, so that
> growing the nodegroup grows CoreDNS with it — with no metrics pipeline.

Policy (`linear`, tuned for `t3.medium` = 2 vCPU nodes):

```text
coresPerReplica = 4
nodesPerReplica = 1
min = 2
max = 10
preventSinglePointFailure = true
includeUnschedulableNodes = true
```

---

# 2. What CPA actually is

Not an operator. Not a CRD. Not an HPA. **One Deployment running one Go
binary**, plus a ConfigMap it reads and an RBAC triple.

```text
                Cluster Proportional Autoscaler
                            │
              ┌─────────────┼──────────────┐
              ▼             ▼              ▼
        list Nodes     read ConfigMap   update scale
        (apiserver)    (apiserver)      (apiserver)
```

Every one of those three arrows is a plain Kubernetes API call from the CPA
pod's ServiceAccount. There is no second process, no aggregated API, no
webhook, no external system.

Contrast with the sibling demos:

```text
Prometheus Adapter demo:  app → Prometheus → adapter → custom.metrics.k8s.io → HPA → Deployment
KEDA demo:                app → Prometheus → KEDA operator → external.metrics.k8s.io → HPA → Deployment
CPA (this demo):          Nodes + ConfigMap → CPA → Deployment
```

---

# 3. The two inputs

## 3a. The Node list

CPA lists `Node` objects from the API server and derives two numbers:

```text
SchedulableNodes (N) = count of Nodes that are schedulable
SchedulableCores (C) = Σ  node.status.capacity.cpu   over those Nodes
```

"Schedulable" means `node.spec.unschedulable == false` (i.e. not cordoned).
If `includeUnschedulableNodes: true`, cordoned/NotReady Nodes are counted
too — CPA then effectively counts *every* `Node` object that exists.

Notes:

- It's **`capacity.cpu`**, not `allocatable.cpu` — the raw hardware count,
  not what's left after system reservations.
- On EKS the control plane is fully managed and never appears as a `Node`,
  so `N` is exactly your worker-node count with no filtering.
- `--nodelabels=key=value` narrows both `N` and `C` to Nodes matching that
  label selector (e.g. count only one nodegroup).

## 3b. The params ConfigMap

```text
kube-system/ConfigMap/coredns-autoscaler
  data:
    linear: |
      { "coresPerReplica": 4, "nodesPerReplica": 1, "min": 2, "max": 10, ... }
```

- Exactly **one** of `linear` / `ladder`.
- CPA re-reads this **every poll**. It's read via the API, not mounted as a
  file, so `kubectl edit` on it applies within one `--poll-period-seconds`
  with no pod restart.
- If the ConfigMap is missing and `--default-params='<json>'` was passed,
  CPA **creates** it from that JSON on startup.

---

# 4. The linear controller, step by step

```text
replicasFromNodes = ceil( N / nodesPerReplica )
replicasFromCores = ceil( C / coresPerReplica )

replicas = max( replicasFromNodes, replicasFromCores )

if max != 0 :  replicas = min( replicas, max )
if min != 0 :  replicas = max( replicas, min )

if preventSinglePointFailure and replicas == 1 :
    replicas = 2
```

Worked, with `coresPerReplica=4, nodesPerReplica=1, min=2, max=10`:

```text
N=2  C=4  → max(ceil(2/1), ceil(4/4)) = max(2, 1) = 2 → clamp → 2
N=4  C=8  → max(ceil(4/1), ceil(8/4)) = max(4, 2) = 4 → clamp → 4
N=6  C=12 → max(ceil(6/1), ceil(12/4))= max(6, 3) = 6 → clamp → 6
N=1  C=2  → max(1, 1) = 1 → min:2 → 2   (also preventSinglePointFailure would force 2)
```

Fractions are allowed:

```text
nodesPerReplica = 0.5 ,  N=2  → ceil(2 / 0.5) = 4
```

To scale on **one dimension only**, make the other one large enough that it
never wins (e.g. `coresPerReplica: 100000`), or set it to `0` — a `0`
divisor makes CPA skip that term.

---

# 5. The ladder controller, step by step

```text
ladder:
  nodesToReplicas: [ [1,2], [3,3], [5,5] ]
  coresToReplicas: [ [1,2], [8,3], [16,5] ]
```

Algorithm for one array, given current count `x`:

```text
result = 0
for [threshold, replicas] in sortedAscending(array):
    if x < threshold: break
    result = replicas
return result
```

Then `replicas = max( ladder(nodesToReplicas, N), ladder(coresToReplicas, C) )`.

Worked:

```text
N=2 C=4  → nodes: 2≥1 →2, 2<3 stop        = 2
           cores: 4≥1 →2, 4<8 stop        = 2   → max = 2
N=4 C=8  → nodes: 4≥3 →3, 4<5 stop        = 3
           cores: 8≥8 →3, 8<16 stop       = 3   → max = 3
N=6 C=12 → nodes: 6≥5 →5                   = 5
           cores: 12≥8 →3, 12<16 stop     = 3   → max = 5
```

Gotchas:

- `x` below the first threshold ⇒ `0` for that array. If both arrays give 0,
  the workload is scaled to **0**. Keep a `[1, N]` (or `[0, N]`) floor.
- Ladder mode ignores `min` / `max` / `preventSinglePointFailure` — the
  ladder *is* the complete specification.

---

# 6. The one output: the scale subresource

Each poll, after computing `desired`:

```text
CPA ──GET──▶ apiserver : /apis/apps/v1/namespaces/kube-system/deployments/coredns/scale
              ◀── current .spec.replicas

if desired != current:
    CPA ──UPDATE──▶ apiserver : .../coredns/scale   (spec.replicas = desired)
```

That's the same endpoint `kubectl scale` uses. From there it's **stock
Kubernetes**:

```text
apiserver writes Deployment.spec.replicas
        │
        ▼
Deployment controller (kube-controller-manager)  → resizes the ReplicaSet
        │
        ▼
ReplicaSet controller                            → creates / deletes Pods
        │
        ▼
scheduler                                        → places new CoreDNS Pods
                                                   (soft podAntiAffinity spreads them per node)
```

CPA has no further involvement — it doesn't watch the rollout, doesn't care
whether Pods become Ready. Next poll it just reads `.spec.replicas` again.

---

# 7. The poll loop

```text
every --poll-period-seconds (default 10s):

  ① list Nodes                    → N, C
  ② read ConfigMap                → params  (rebuild only if resourceVersion changed)
  ③ compute desired               → linear or ladder math above
  ④ GET target /scale             → current
  ⑤ if desired != current: UPDATE /scale
  ⑥ sleep
```

Consequences:

- Reaction time to a node joining/leaving or a ConfigMap edit is **≤ one
  poll period** (plus, for scale-up, however long the node takes to reach
  the state you're counting).
- CPA is **level-triggered**: it doesn't need events, it just re-derives the
  right answer from scratch every tick. A missed poll changes nothing; the
  next one corrects.
- It is **authoritative** over `.spec.replicas`. Any other writer (a human
  `kubectl scale`, an HPA, an EKS add-on update) is overwritten on the next
  poll.

---

# 8. Where the node count comes from (EKS)

```text
eksctl scale nodegroup --nodes 4
        │
        ▼
EKS UpdateNodegroupConfig  → sets ASG desired capacity = 4
        │
        ▼
EC2 Auto Scaling Group launches 2 more instances
        │
        ▼
kubelet on each new instance registers a Node object   (~1–3 min)
        │
        ▼
apiserver now lists 4 Nodes  ── CPA's next poll sees N=4
```

In a production cluster the same `Node`-count change is driven by the
**Cluster Autoscaler** or **Karpenter** reacting to pending Pods — CPA
doesn't know or care which. It only reads the resulting `Node` list.

---

# 9. Failure modes

## 9a. CPA pod is down

```text
Nodes            ✅ still there
ConfigMap        ✅ still there
coredns.spec.replicas  ❄️  frozen at last value CPA wrote
```

Nothing else breaks — there's no metric pipeline to go stale, no HPA to
error. CoreDNS keeps running at whatever count it had. When CPA comes back
it re-derives and corrects in one poll.

## 9b. ConfigMap deleted or malformed

```text
CPA logs a parse/read error every poll
coredns.spec.replicas  ❄️  held at last good value (CPA takes no action)
```

If `--default-params` was set and the ConfigMap is *missing* (not just
broken), CPA recreates it from that JSON.

Malformed = bad JSON, negative numbers, or **both** `linear` and `ladder`
present.

## 9c. RBAC missing

```text
can't list nodes         → "nodes is forbidden"                → no scaling, CrashLoop or error loop
can't update scale       → "cannot get/update resource scale"  → CPA computes desired but can't write
can't get configmap      → "configmaps ... is forbidden"       → no params, no scaling
```

## 9d. Target wrong

```text
--target=deployment/coredns  but no such Deployment  → error each poll, no action
--target=daemonset/...                               → unsupported (no /scale subresource)
```

## 9e. Two controllers on one workload

```text
CPA says 4   ─┐
              ├─▶ .spec.replicas flaps 4 ↔ 7 every few seconds
HPA says 7   ─┘
```

Never put both on `coredns`. Same applies to an EKS CoreDNS add-on with
native autoscaling enabled *and* CPA — pick one.

## 9f. EKS add-on update

```text
aws eks update-addon --addon-name coredns ...   → may reset .spec.replicas to the add-on default (2)
CPA next poll                                    → sets it back to the computed value (~10s window)
```

---

# 10. Who talks to whom — the cheat sheet

```text
1. eksctl / Cluster Autoscaler / Karpenter
      ↓  changes desired node count
2. EC2 ASG
      ↓  instances join
3. kubelet
      ↓  registers Node objects
4. CPA  (every --poll-period-seconds)
      ↓  LIST nodes            → N, C
      ↓  GET  configmap        → linear/ladder params
      ↓  compute desired = f(N, C, params)
      ↓  GET  deployments/scale (coredns) → current
      ↓  if desired ≠ current: UPDATE deployments/scale
5. Deployment controller
      ↓  resizes ReplicaSet
6. ReplicaSet controller + scheduler
      ↓  add / remove CoreDNS Pods across nodes
7. (loop back to step 4 on the next poll)
```

**The single most important thing to remember:** CPA is a stateless,
level-triggered loop with two reads (Nodes, ConfigMap) and one write
(`/scale`). It scales on cluster *size*, never on load, and it owns
`.spec.replicas` outright — so it belongs on cluster add-ons like CoreDNS,
and never on a workload that also has an HPA.
