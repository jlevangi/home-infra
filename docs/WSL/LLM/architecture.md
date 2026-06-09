# Architecture — WSL/LLM Workstation

The design that connects `pierce-pc` to the in-cluster `llama-cpp` deployment, the reasoning behind each non-obvious choice, and the bits the cluster knows about the workstation.

## Components

```
                                        Windows (pierce-pc)
                                        ┌─────────────────────────────────┐
                                        │ llama-swap.exe v223 (winget)    │
                                        │  ├─ --listen 0.0.0.0:9080       │
                                        │  ├─ --config config.yaml        │
                                        │  └─ spawns llama-server.exe     │
                                        │     per model (AMD ROCm / HIP)  │
                                        │                                 │
                                        │ Start/Stop .lnk shortcuts +     │
                                        │ shell:Startup auto-launch       │
                                        └──────────────┬──────────────────┘
                                                       │ localhost
                                                       │ (mirrored loopback)
                                                       ▼
                                        WSL2 (Ubuntu, systemd, mirrored net)
                                        ┌─────────────────────────────────┐
                                        │ llama-metrics-sidecar.py        │
                                        │  ├─ polls :9080/running         │
                                        │  ├─ scrapes :9080/upstream/.../ │
                                        │  │   metrics for loaded models  │
                                        │  └─ exposes 0.0.0.0:9090 to LAN │
                                        │                                 │
                                        │ user systemd: enabled + linger  │
                                        └──────────────┬──────────────────┘
                                                       │ LAN
                                                       │ pierce-pc.levangie.org:9090
                                                       ▼
                                          k3s-prod (Atlas Proxmox)
                                          ┌─────────────────────────────────┐
                                          │ Prometheus (ScrapeConfig)       │
                                          │  job=llama-cpp-pc               │
                                          │  instance=workstation           │
                                          │                                 │
                                          │ llama-swap (in-cluster pod)     │
                                          │  peers.pierce-pc.proxy:         │
                                          │    http://pierce-pc...:9080     │
                                          └─────────────────────────────────┘
```

## Why a llama-swap peer (and not just two separate endpoints)

llama-swap natively supports a `peers:` config block. Peer models appear in the local `/v1/models` listing and `POST /v1/chat/completions` calls for those model IDs are transparently proxied. This means:

- LibreChat and agent code only point at the cluster's llama-swap; they see one unified model list.
- The cluster's choice of "which model lives where" is changed by editing one git file (`argocd/manifests/llama-cpp/base/config.yaml`), not by reconfiguring every client.
- Adding a third instance later (e.g. another workstation or a Mac) is another entry in the same block.

The peer block excludes `Gemma4-31B` and `Gemma4-26B-A4B` because those IDs collide with cluster-local models. llama-swap's resolver is first-match-wins (local always beats peer), so listing them would silently never route — the cluster's local copies serve every request. To peer-route a colliding model, rename it on the PC side (e.g. `Gemma4-31B-pc`) and add the renamed ID to the peers list.

## Why a separate metrics sidecar (and not just the proxy's own /metrics)

llama-swap's own `/metrics` exposes host-level gauges (`llamaswap_cpu_util_percent`, `llamaswap_gpu_*`, etc.) but **only for the local host**. It does not aggregate metrics across peers. Inference metrics (`llamacpp:prompt_tokens_total`, `llamacpp:predicted_tokens_seconds`, `llamacpp:kv_cache_usage_ratio`, …) are exposed by each llama-server child process on its own ephemeral port (`startPort + N`), accessible via `GET /upstream/<model>/metrics` on the proxy — but only for **currently-loaded** models. Inactive scrape paths block.

The sidecar resolves both gaps:

1. **Cross-instance metrics**: each llama-swap instance gets its own sidecar; Prometheus scrapes each sidecar with a different `instance=` label.
2. **Active-model filtering**: the sidecar polls `/running` every 10s, scrapes only loaded models' upstream `/metrics`, attaches a `model="<id>"` label, and synthesizes a `llamacpp_active_model_info{model="..."} 1` gauge so the dashboard can display the loaded model without parsing labels off other metrics.

The exact behaviour lives in `argocd/manifests/llama-cpp/base/sidecar-exporter.py`. The workstation copy is identical except for the `LLAMASWAP` constant being patched to `http://127.0.0.1:9080` (the Windows-side llama-swap bind address).

## Why WSL2 (and not Windows-native)

The sidecar is stdlib-only Python — it could run anywhere. Three reasons it lives in WSL2 rather than as a Windows service:

1. **systemd**: clean lifecycle + journald integration matches every other long-running service the operator manages. Linger (`loginctl enable-linger`) makes it survive logouts and reboots without ever needing a console session.
2. **No NSSM dependency**: NSSM is the usual answer for "long-running script as a Windows service" but adds a third-party install. Avoidable here.
3. **Mirrored WSL2 networking** (set in `.wslconfig`) eliminates the networking penalty that historically made WSL2 services awkward for LAN exposure. Specifically:
   - WSL2's `127.0.0.1:9080` IS the Windows-side llama-swap (loopback is shared)
   - WSL2's `0.0.0.0:9090` bind IS reachable from the LAN as `pierce-pc.levangie.org:9090` (no `netsh portproxy` needed)
   - No Windows Firewall rule needed — the rule for the Windows host applies

The `.wslconfig` requirement is the only non-default piece. The setup script verifies it.

## Why llama-swap.exe binds to :9080 (and not :8080)

Default port for llama-swap is 8080. The `Start Llama-Swap.lnk` shortcut on `pierce-pc` invokes it with `--listen 0.0.0.0:9080` explicitly. Reason: port 8080 was already in use on `pierce-pc` (Hyper-V default management endpoints + various dev tools commonly squat there), so the operator chose 9080 to avoid collision. The cluster's `peers.pierce-pc.proxy` URL must match. This was committed in `addc051` after the original `cb43756` shipped with the wrong port.

## Why `instance=workstation` (label strategy)

The Grafana `llama-cpp` dashboard's `$instance` template variable runs `label_values(llamaswap_load_average, instance)` against Prometheus. Both scrape jobs set a static, human-readable `instance` label via target relabeling:

| Source | `instance` | Set by |
|---|---|---|
| In-cluster sidecar | `cluster` | `argocd/manifests/monitoring-config/base/servicemonitor-llama-cpp.yaml` — `relabelings: targetLabel=instance replacement=cluster` |
| `pierce-pc` sidecar | `workstation` | `argocd/manifests/monitoring-config/overlays/prod/scrapeconfig-llama-cpp-pc.yaml` — `staticConfigs[0].labels.instance: workstation` |

This avoids the default `<pod-ip>:9090` instance label that the user can't reason about, and gives the dashboard dropdown stable values. Adding a third workstation later only requires another `ScrapeConfig` with a different `instance:` value.

## What the cluster knows about the workstation

The two cluster-side files that reference `pierce-pc` are the entire surface:

```yaml
# argocd/manifests/llama-cpp/base/config.yaml — peers block (excerpt)
peers:
  pierce-pc:
    proxy: http://pierce-pc.levangie.org:9080
    models:
      - Qwen3.6-27B
      - Qwen3.6-35B-A3B
      - Qwen3.6-27B-hermes
      - Qwen3.6-35B-A3B-hermes
    timeouts:
      connect: 10
      responseHeader: 60
```

```yaml
# argocd/manifests/monitoring-config/overlays/prod/scrapeconfig-llama-cpp-pc.yaml
spec:
  jobName: llama-cpp-pc
  scrapeInterval: 30s
  scrapeTimeout: 20s
  metricsPath: /metrics
  staticConfigs:
    - targets:
        - pierce-pc.levangie.org:9090
      labels:
        instance: workstation
```

If `pierce-pc` is renamed, moved, or replaced, those two paths are the only edits needed on the cluster side.

## Caveats and known gaps

- **No GPU metrics for `workstation`**. llama-swap's AMD GPU support requires `rocm-smi` on PATH; `pierce-pc` only has the ROCm runtime DLLs bundled with the llama.cpp build, not the standalone SDK. The Grafana dashboard's GPU panels are empty for `instance=workstation`. To fix, install AMD's ROCm SDK or the `amd-smi` tool on Windows.
- **Sidecar HELP/TYPE dedup is overly aggressive**. Cosmetic — Prometheus accepts metrics without HELP lines, and metric values flow correctly. Filed for cleanup.
- **No auth between cluster and workstation**. LAN-trust only. If `pierce-pc:9080` is ever exposed beyond the LAN, add `apiKeys` to the PC config and reference an ExternalSecret-backed key in the cluster's `peers.pierce-pc.apiKey`.
- **The workstation setup is not yet Ansible-managed**. Tracked separately; see the open beads issue referenced in `README.md`.
