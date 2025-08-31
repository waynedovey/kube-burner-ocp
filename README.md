# Load Test Runbook: kube-burner-ocp `cluster-density-v2` on 5× Hosting/HCP Nodes

This README documents the exact steps to run **cluster-density-v2** with **kube-burner-ocp** on *five hosting/HCP nodes* only (not masters). It assumes your hosting nodes are the **Dell R7625** boxes and that you’ve CPU-capped them to ~96 vCPUs.

---

## Prerequisites

- You can run `kube-burner-ocp --help` on your runner host (binary installed and on PATH).
- You’re logged in to the target OpenShift cluster: `oc whoami` shows a valid user.
- You want **all test pods to land on the 5 hosting nodes**, not on masters.

> If your setup uses different labels/taints than below, swap them in the commands as needed.

---

## Labels/taints assumed on the 5 hosting nodes

- **Label:** `node-role.kubernetes.io/infra=`  
- **Taint:** `infra=only:NoSchedule`

Verify:
```bash
oc get nodes -L node-role.kubernetes.io/infra
oc get nodes -o json | jq -r '.items[] | [.metadata.name, (.spec.taints // [])] | @tsv'
```

(If you have to add them:)
```bash
oc label node <host> node-role.kubernetes.io/infra= --overwrite
oc adm taint node <host> infra=only:NoSchedule --overwrite
```

---

## 0) Quick smoke (no churn)

Sanity-check API, registry, router; runs fast.
```bash
kube-burner-ocp cluster-density-v2   --iterations=5   --churn=false   --qps=40 --burst=80   --timeout=1h   --pod-node-selector=node-role.kubernetes.io/infra=   --pod-tolerations='[{"key":"infra","operator":"Equal","value":"only","effect":"NoSchedule"}]'
```

---

## 1) Baseline (light churn, good starting point)

This is the one to start with on your 5 hosting nodes.
```bash
kube-burner-ocp cluster-density-v2   --iterations=25   --churn-duration=10m --churn-cycles=1   --qps=50 --burst=100   --timeout=2h   --pod-node-selector=node-role.kubernetes.io/infra=   --pod-tolerations='[{"key":"infra","operator":"Equal","value":"only","effect":"NoSchedule"}]'
```

---

## 2) Ramp 1 (moderate)

Bumps object count and API pressure, still safe for 96-core cap.
```bash
kube-burner-ocp cluster-density-v2   --iterations=50   --churn-duration=15m --churn-cycles=1   --qps=60 --burst=120   --timeout=3h   --pod-node-selector=node-role.kubernetes.io/infra=   --pod-tolerations='[{"key":"infra","operator":"Equal","value":"only","effect":"NoSchedule"}]'
```

---

## 3) Ramp 2 (heavier)

Use once the baseline looks clean (no 429s, healthy p95/p99).
```bash
kube-burner-ocp cluster-density-v2   --iterations=100   --churn-duration=20m --churn-cycles=1   --qps=80 --burst=160   --timeout=4h   --pod-node-selector=node-role.kubernetes.io/infra=   --pod-tolerations='[{"key":"infra","operator":"Equal","value":"only","effect":"NoSchedule"}]'
```

---

## Where do results go?

The wrapper writes a job summary locally (and may enrich with cluster metadata). If you prefer a fixed directory per run:
```bash
export KUBE_BURNER_METRICS_DIR=./metrics
```
Then each run writes under `./metrics/<uuid>/…`.

To list results:
```bash
ls -R ${KUBE_BURNER_METRICS_DIR:-.}
```

## Cleanup

Destroy all objects for a specific run (use the UUID printed at start):
```bash
kube-burner destroy --uuid <uuid>
```

---

## Quick tips

- If you see **HTTP 429s** from the API, lower `--qps/--burst` or split across additional runners.
- If you hit **“Too many open files”** on the runner, raise the limit (example):  
  `ulimit -n 1048576` and add a matching entry in `/etc/security/limits.d/`.
- If pods land on the wrong nodes, re-check the **selector/tolerations** and your node labels/taints.

Happy testing.


---

## Extras included

### `metrics-endpoints.yaml` (sample in-cluster + external Prom / optional remote-write)
Use this file to point kube-burner-ocp at specific Prometheus/Thanos endpoints for scraping.
Pass it with the flag:
```bash
kube-burner-ocp cluster-density-v2 ... --metrics-endpoint ./metrics-endpoints.yaml
```
Edit the URLs/tokens as appropriate for your environment. You can use a mounted service account token (tokenFile), an inline bearer token, or environment variables.

### `destroy.sh` (cleanup helper; `chmod +x destroy.sh` already applied)
Use this to clean up objects created by a specific run (UUID printed at start of the run):
```bash
./destroy.sh <uuid>
```
