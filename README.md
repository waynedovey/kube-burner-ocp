# Load Test Runbook: kube-burner-ocp `cluster-density-v2` on 5-node hosting pool (ALL NODES SCHEDULABLE)

This README documents the exact steps to run **cluster-density-v2** with **kube-burner-ocp** when **all five hosting/HCP nodes are schedulable and accept workloads**.  
We assume these five nodes are your Dell **R7625** boxes (each CPU-capped to ~96 vCPUs). 

> Because all 5 nodes are schedulable “for the moment”, **we do not pass any `--pod-node-selector` or `--pod-tolerations` flags**. The load will spread across the five nodes by the scheduler. If you later want to constrain placement, see the **Optional: Pin to specific nodes** section at the end.

---

## Prerequisites

- `kube-burner-ocp` is installed and on your PATH (`kube-burner-ocp --help` works).
- You’re logged into the OpenShift cluster (`oc whoami` shows a valid user).
- Internal registry is functioning (cluster-density-v2 pushes an image). If not, smoke-test first with `cluster-density-ms`.

Optional sanity:
```bash
oc get nodes -o wide
```

---

## 0) Quick smoke (no churn)

Sanity-check API, registry, and router; runs fast.
```bash
kube-burner-ocp cluster-density-v2   --iterations=5   --churn=false   --qps=40 --burst=80   --timeout=1h
```

---

## 1) Baseline (light churn, good starting point)

Recommended first “real” run on your 5-node hosting pool.
```bash
kube-burner-ocp cluster-density-v2   --iterations=25   --churn-duration=10m --churn-cycles=1   --qps=50 --burst=100   --timeout=2h
```

---

## 2) Ramp 1 (moderate)

Bumps object count and API pressure; still appropriate for the 96-core cap.
```bash
kube-burner-ocp cluster-density-v2   --iterations=50   --churn-duration=15m --churn-cycles=1   --qps=60 --burst=120   --timeout=3h
```

---

## 3) Ramp 2 (heavier)

Run this once the baseline looks clean (no 429s, healthy apiserver/etcd p95/p99).
```bash
kube-burner-ocp cluster-density-v2   --iterations=100   --churn-duration=20m --churn-cycles=1   --qps=80 --burst=160   --timeout=4h
```

---

## Where do results go?

The wrapper writes a job summary locally (and may include cluster metadata). To keep each run’s output under a UUID’ed folder:
```bash
export KUBE_BURNER_METRICS_DIR=./metrics
```
Each run then writes to `./metrics/<uuid>/…`.

List results:
```bash
ls -R ${KUBE_BURNER_METRICS_DIR:-.}
```

**Cleanup** a specific run (use the UUID printed at start):
```bash
kube-burner destroy --uuid <uuid>
```

---

## What to watch during runs

- **etcd**: `etcd_disk_backend_commit_duration_seconds` p95/p99 (NVMe helps; keep p99 low).
- **kube-apiserver**: 429s and request latency p95/p99.
- **OVN/OVS**: CPU spikes/restarts on `ovnkube-node` / `ovs-vswitchd`.
- **Node kubelet**: headroom during churn; watch for throttling or fd/port exhaustion on the runner.

---

## Extras included

### `metrics-endpoints.yaml` (sample in-cluster + external Prom / optional remote-write)
Use this file to point kube-burner-ocp at specific Prometheus/Thanos endpoints for scraping.  
Pass it with:
```bash
kube-burner-ocp cluster-density-v2 ... --metrics-endpoint ./metrics-endpoints.yaml
```
Edit URLs/tokens as appropriate. You can use a mounted service account token (`tokenFile`), an inline `bearerToken`, or environment variables.

### `destroy.sh` (cleanup helper; `chmod +x destroy.sh` already applied)
Use this to remove objects created by a specific run:
```bash
./destroy.sh <uuid>
```

---

## Optional: Pin to specific nodes later

If, in the future, you want **only the hosting nodes** to take the load (and avoid others), add labels/taints and use selectors/tolerations. Example (adjust to your environment):
```bash
# Example labels/taints:
oc label node <host> node-role.kubernetes.io/infra= --overwrite
oc adm taint node <host> infra=only:NoSchedule --overwrite

# Then add flags to your run:
# --pod-node-selector=node-role.kubernetes.io/infra=
# --pod-tolerations='[{"key":"infra","operator":"Equal","value":"only","effect":"NoSchedule"}]'
```

That’s it — you’re ready to run density tests across all five R7625 nodes.
