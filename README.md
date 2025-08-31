# Load Test Runbook: kube-burner-ocp `cluster-density-v2` on 5-node hosting pool (ALL NODES SCHEDULABLE)

This README documents the exact steps to run **cluster-density-v2** with **kube-burner-ocp** when **all five hosting/HCP nodes are schedulable and accept workloads**.  
We assume these five nodes are your Dell **R7625** boxes (each CPU-capped to ~96 vCPUs). This guide does **not** target your R660 masters.

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


---

## Recommended settings for the load‑testing server (runner)

These OS tweaks prevent common bottlenecks (file descriptors, ephemeral ports, TCP queues) and reduce jitter. They apply to a standalone runner VM (e.g., Amazon Linux 2023, RHEL 9, or Ubuntu 22.04).

### 1) Packages you’ll want
```bash
# RHEL 9 / AL2023
sudo dnf install -y jq curl tar ethtool iproute bind-utils
# Ubuntu
# sudo apt-get update && sudo apt-get install -y jq curl tar ethtool iproute2 dnsutils
```

### 2) File descriptors (avoid “Too many open files”)
```bash
# Session
ulimit -n 1048576

# Persist across logins
sudo tee /etc/security/limits.d/99-kubeburner.conf >/dev/null <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF
# Ensure pam_limits is enabled (RHEL/AL2023 default): check /etc/pam.d/system-auth and /etc/pam.d/password-auth
```

### 3) Network sysctls (ephemeral ports & TCP queues)
```bash
sudo tee /etc/sysctl.d/99-kubeburner.conf >/dev/null <<'EOF'
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
EOF
sudo sysctl --system
```

### 4) ENA / NIC checks (AWS Nitro)
```bash
# Expect 'ena' as the driver
ethtool -i eth0 | grep -E 'driver|version'
```
If you’re pushing lots of connections/metrics, choose a **c7i/c7a** (balanced) or **c7gn** (very high PPS) instance and place it in the **same AZ** as your OCP API/Prometheus.

### 5) CPU governor / tuned profile
```bash
# RHEL/AL2023: use tuned for low jitter
sudo dnf install -y tuned
sudo systemctl enable --now tuned
sudo tuned-adm profile throughput-performance   # or: network-latency if you care more about tail latency
```
(Alternatively, if `cpupower` is available: `sudo cpupower frequency-set -g performance`.)

### 6) Go runtime threads
```bash
# Let kube-burner-ocp fully use vCPUs
export GOMAXPROCS=$(nproc)
```

### 7) DNS resolver hygiene (optional but useful at high QPS)
- Ensure a local caching resolver is active (`systemd-resolved` on AL2023/RHEL9, or install `nscd`/`unbound` on Ubuntu).  
- Or pin the API/Prom endpoints by IP if you know they won’t move.

Quick check:
```bash
resolvectl status || true
```

### 8) Time sync
```bash
# Ensure chrony/systemd-timesyncd is running to keep TLS and metrics timestamps sane
systemctl status chronyd || systemctl status systemd-timesyncd
```

### 9) Environment & output hygiene
```bash
# Store per-run outputs in a stable place (each run gets its own UUID folder)
export KUBE_BURNER_METRICS_DIR=~/kbo-metrics
mkdir -p "$KUBE_BURNER_METRICS_DIR"
```

### 10) Verify before running
```bash
ulimit -n
sysctl net.ipv4.ip_local_port_range
sysctl net.core.somaxconn
#ethtool -i eth0 | grep driver
oc whoami
kube-burner-ocp version
```

> If you still hit 429s or runner-side socket errors, lower `--qps/--burst`, or add a second runner and split traffic across both (same commands, different UUIDs).
