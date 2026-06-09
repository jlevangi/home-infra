# WSL / LLM — Workstation Setup

This directory documents the workstation-side half of the home-infra LLM topology: `pierce-pc` running a Windows-native `llama-swap.exe` (with AMD ROCm) plus a Python metrics sidecar in WSL2, paired with the in-cluster `llama-cpp` deployment.

The cluster side lives in `argocd/manifests/llama-cpp/` and `argocd/manifests/monitoring-config/` and is fully GitOps-managed. This directory captures the parts of the system that ArgoCD cannot reconcile — the Windows install, the WSL2 user service, and the operational knowledge that was earned the hard way.

## Topology at a glance

```
                                ┌────────────────────────┐
   LibreChat ──► cluster:8080 ──► │  llama-swap (cluster)  │
   agents     ──►                 │  local: MiniMax + ...  │
                                 │  peers.pierce-pc ──────┼──► pierce-pc:9080
                                 └─────┬──────────────────┘    (llama-swap.exe, Windows, ROCm)
                                       │ sidecar @ :9090              │
   Prometheus ── scrape ──► cluster:9090                               │ sidecar @ :9090
   Prometheus ── scrape ──► pierce-pc.levangie.org:9090 ───────────────┘
                                       │
                                       ▼
                       Grafana dashboard `llama-cpp`
                       $instance ∈ {cluster, workstation}
```

## Documents

| File | Contents |
|---|---|
| [setup.md](setup.md) | Step-by-step reproducible install for both Windows and WSL2 sides. Each step is either an inline command or a script reference. |
| [architecture.md](architecture.md) | Why this design — peer routing semantics, sidecar pattern, WSL2 mirrored networking, instance labeling, what the cluster side knows about the PC. |
| [troubleshooting.md](troubleshooting.md) | Concrete failure modes from the original buildout: wrong port, missing `--metrics`, old llama-swap version, missing `rocm-smi`, etc. |

## Setup scripts

The three scripts under [`scripts/workstation/`](../../../scripts/workstation/) are the executable form of `setup.md`. They are intentionally idempotent so they can be re-run safely after partial failures and so a future Ansible role can wrap them mechanically.

| Script | Runs in | Purpose |
|---|---|---|
| `install-llama-swap-windows.ps1` | Windows PowerShell | winget-install llama-swap, ensure config dir, write Start/Stop shortcuts |
| `install-metrics-sidecar-wsl.sh` | WSL2 bash | Copy + patch the sidecar script, install the systemd user unit, enable linger |
| `verify-setup.sh` | WSL2 bash | End-to-end probe — exits non-zero if anything in the chain is broken |

## Cluster-side files referenced by this setup

- `argocd/manifests/llama-cpp/base/config.yaml` — `peers.pierce-pc` block points at this workstation
- `argocd/manifests/llama-cpp/base/sidecar-exporter.py` — canonical source of the Python sidecar (the workstation copy is a patched fork)
- `argocd/manifests/monitoring-config/overlays/prod/scrapeconfig-llama-cpp-pc.yaml` — Prometheus ScrapeConfig that pulls `pierce-pc.levangie.org:9090`

## Status

Manually deployed and operational since 2026-06-08 (commits `addc051`, `cb43756`, `eba66de`, `3ab50b1`). A beads issue tracks converting the manual procedure into an Ansible role.
