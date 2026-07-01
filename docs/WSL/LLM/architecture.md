# Architecture — WSL/LLM Workstation

The design that runs `pierce-pc` alongside the in-cluster `llama-cpp` deployment, the reasoning behind each non-obvious choice, and the bits the cluster knows about the workstation.

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
                                                       │ LAN, operator-started only
                                                       │ pierce-pc.levangie.org:9090
                                                       ▼
                                          k3s-prod (Atlas Proxmox)
                                          ┌─────────────────────────────────┐
                                          │ No Prometheus scrape            │
                                          │  workstation can stay stopped   │
                                          │  without TargetDown alerts      │
                                          │                                 │
                                          │ LibreChat direct endpoint       │
                                          │  http://pierce-pc...:9080/v1    │
                                          └─────────────────────────────────┘
```

## Why separate endpoints

The cluster previously used llama-swap's `peers:` block to aggregate workstation models into the in-cluster `/v1/models` list. That was convenient for clients that only support one OpenAI-compatible base URL, but it made model ownership ambiguous in UIs such as LibreChat.

The current design keeps each machine as its own OpenAI-compatible endpoint:

- `llama.cpp Server` points at the in-cluster llama-swap service and fetches cluster-local models.
- `llama.cpp PC` points directly at `http://pierce-pc.levangie.org:9080/v1` and fetches workstation models.

This is simpler operationally: model lists stay machine-scoped, duplicate model IDs are not hidden behind first-match routing, and clients that care where a model runs can choose the endpoint explicitly.

## Why a separate metrics sidecar (and not just the proxy's own /metrics)

llama-swap's own `/metrics` exposes host-level gauges (`llamaswap_cpu_util_percent`, `llamaswap_gpu_*`, etc.) for the local host. Inference metrics (`llamacpp:prompt_tokens_total`, `llamacpp:predicted_tokens_seconds`, `llamacpp:kv_cache_usage_ratio`, …) are exposed by each llama-server child process on its own ephemeral port (`startPort + N`), accessible via `GET /upstream/<model>/metrics` on the proxy — but only for **currently-loaded** models. Inactive scrape paths block.

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

Default port for llama-swap is 8080. The `Start Llama-Swap.lnk` shortcut on `pierce-pc` invokes it with `--listen 0.0.0.0:9080` explicitly. Reason: port 8080 was already in use on `pierce-pc` (Hyper-V default management endpoints + various dev tools commonly squat there), so the operator chose 9080 to avoid collision. LibreChat's `llama.cpp PC` endpoint points at this port directly.

## Why `instance=workstation` (label strategy)

The Grafana `llama-cpp` dashboard's `$instance` template variable runs `label_values(llamaswap_load_average, instance)` against Prometheus. The cluster-side scrape sets a static, human-readable `instance` label via target relabeling:

| Source | `instance` | Set by |
|---|---|---|
| In-cluster sidecar | `cluster` | `argocd/manifests/monitoring-config/base/servicemonitor-llama-cpp.yaml` — `relabelings: targetLabel=instance replacement=cluster` |
| `pierce-pc` sidecar | not scraped | intentionally disabled so the PC can stay stopped without alerts |

This avoids the default `<pod-ip>:9090` instance label that the user can't reason about. Adding workstation scraping back later would require a new `ScrapeConfig` with an explicit `instance:` value.

## What the cluster knows about the workstation

The cluster-side surface for `pierce-pc` is intentionally limited to the optional LibreChat endpoint:

```yaml
# argocd/apps/prod/librechat.yaml — LibreChat custom endpoint (excerpt)
endpoints:
  custom:
    - name: "llama-pc"
      baseURL: "http://pierce-pc.levangie.org:9080/v1"
      models:
        fetch: true
      modelDisplayLabel: "llama.cpp PC"
```

Prometheus scraping of `pierce-pc` was removed because llama-swap is not intended to run on the PC full-time.

## Caveats and known gaps

- **No GPU metrics for `workstation` — upstream-blocked.** llama-swap v223's Windows GPU monitor (`internal/perf/monitor_windows.go`) only supports `nvidia-smi`; AMD support exists in the Linux build but has never been ported to Windows. Tracked upstream by [mostlygeek/llama-swap PR #779](https://github.com/mostlygeek/llama-swap/pull/779) which adds PDH (Windows Performance Counters) + D3DKMT backends. When that merges + we `winget upgrade`, GPU panels for `instance=workstation` populate automatically. No local install required (PDH does not need rocm-smi or the AMD HIP SDK).
- **Sidecar HELP/TYPE dedup is overly aggressive**. Cosmetic — Prometheus accepts metrics without HELP lines, and metric values flow correctly. Filed for cleanup.
- **No auth between cluster and workstation**. LAN-trust only. If `pierce-pc:9080` is ever exposed beyond the LAN, add `apiKeys` to the PC config and pass the key to clients through Kubernetes secrets.
- **The workstation setup is not yet Ansible-managed**. Tracked separately; see the open beads issue referenced in `README.md`.
