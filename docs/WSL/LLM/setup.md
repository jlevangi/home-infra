# Setup — WSL/LLM Workstation

End-to-end reproducible install for `pierce-pc` (Windows 11 + WSL2 Ubuntu, AMD ROCm GPU). Use this for a fresh machine, after re-imaging, or to verify an existing install.

Each step is either an inline command or a reference to a script under [`scripts/workstation/`](../../../scripts/workstation/). All scripts are idempotent: rerunning them on a working system is a no-op.

## Prerequisites

| Requirement | Why | How to verify |
|---|---|---|
| Windows 11 with WSL2 | WSL2 systemd + mirrored networking | `wsl --version` reports `WSL version: 2.x` |
| WSL2 distro with systemd enabled | sidecar runs as a user service | `systemctl is-system-running` inside WSL is not `offline` |
| `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig` | sidecar port is LAN-reachable without portproxy | `grep networkingMode /mnt/c/Users/$USER/.wslconfig` returns `mirrored` |
| `winget` available | installs llama-swap | `winget --version` returns a 1.x string |
| Python 3.12 in WSL2 | runs the sidecar | `python3 --version` |
| AMD ROCm runtime DLLs in `C:\Users\pierc\llama-cpp\` (provided by the llama.cpp bundle the operator built) | llama-server.exe needs HIP | `ls C:\Users\pierc\llama-cpp\ggml-hip.dll` |
| LAN DNS resolves `pierce-pc.levangie.org` | cluster Prometheus scrapes by hostname | `getent hosts pierce-pc.levangie.org` returns the LAN IP |

If any of these are missing, fix them first. The setup scripts assume they're in place.

## Step 1 — Install llama-swap on Windows

Run from an elevated PowerShell on Windows (right-click → Run as Administrator):

```powershell
.\scripts\workstation\install-llama-swap-windows.ps1
```

The script:

1. Runs `winget install --id mostlygeek.llama-swap --accept-source-agreements --accept-package-agreements` (no-op if already installed)
2. Detects existing versions below `v218` and runs `winget upgrade` (the host `/metrics` endpoint was added in v218)
3. Ensures `C:\Users\pierc\llama-cpp\` exists
4. Writes `C:\Users\pierc\llama-cpp\Start Llama-Swap.lnk` and `Stop Llama-Swap.lnk` with the canonical Arguments strings (see below)
5. Drops a copy of the Start shortcut into `shell:Startup` so llama-swap launches automatically at login

Canonical Start shortcut Arguments (also captured in the script):

```
-WindowStyle Hidden -Command "Start-Process llama-swap -ArgumentList '--config config.yaml --listen 0.0.0.0:9080' -WorkingDirectory 'C:\Users\pierc\llama-cpp' -WindowStyle Hidden"
```

## Step 2 — Author the llama-swap model config

The PC-side `config.yaml` lives at `C:\Users\pierc\llama-cpp\config.yaml`. This file is **not** in version control — it points at local model files that don't exist on the cluster. It must contain:

1. The model entries the operator wants to expose (currently 6: Qwen3.6-27B, Qwen3.6-35B-A3B, both `-hermes` variants, Gemma4-31B, Gemma4-26B-A4B)
2. `--metrics` flag on every model's `cmd:` so the spawned `llama-server.exe` exposes its native `/metrics` endpoint — without this, `/upstream/<model>/metrics` returns HTTP 501 and the sidecar emits only host stats
3. `--host 0.0.0.0` and `--port ${PORT}` (llama-swap substitutes `${PORT}` per model)

The reference shape for one entry (matches what's on disk today):

```yaml
models:
  Qwen3.6-27B:
    cmd: >
      C:\Users\pierc\llama-cpp\llama-server.exe
      --model "C:\Users\pierc\llama-cpp\models\qwen3.6\27b\Qwen_Qwen3.6-27B-Q4_K_S.gguf"
      --alias "Qwen3.6-27B"
      --port ${PORT}
      --host 0.0.0.0
      --device ROCm0
      --split-mode none
      --gpu-layers all
      --fit off
      --ctx-size 262144
      --parallel 1
      --batch-size 2048
      --ubatch-size 512
      --flash-attn on
      --cache-type-k q4_0
      --cache-type-v q4_0
      --direct-io
      --no-host
      --cache-ram 0
      --no-cache-prompt
      --reasoning auto
      --no-mmproj
      --metrics
      --no-webui
    env:
      - "HIP_VISIBLE_DEVICES=0"
    ttl: 300
```

`ttl: 300` means models unload after 5 minutes idle. That's appropriate for the workstation (limited VRAM, multiple variants); it does NOT need to match the cluster's `globalTTL: 0` (which exists specifically to keep MiniMax pinned).

## Step 3 — Start llama-swap

Either reboot (the Startup folder shortcut runs at login) or invoke the Start shortcut manually:

```powershell
& "C:\Users\pierc\llama-cpp\Start Llama-Swap.lnk"
```

Confirm it's bound to :9080:

```powershell
Get-NetTCPConnection -State Listen | Where-Object { $_.OwningProcess -eq (Get-Process llama-swap).Id }
```

Should show `LocalPort 9080`. Then:

```bash
# from WSL2
curl -s http://127.0.0.1:9080/running
# {"running":[]}
curl -s http://127.0.0.1:9080/metrics | head -3
# # HELP llamaswap_cpu_util_percent ...
```

If `/metrics` returns 404, the installed llama-swap is older than v218 — re-run the install script which forces an upgrade.

## Step 4 — Install the metrics sidecar in WSL2

From the repo root (this repo, on the WSL2 side):

```bash
bash scripts/workstation/install-metrics-sidecar-wsl.sh
```

The script:

1. Copies `argocd/manifests/llama-cpp/base/sidecar-exporter.py` to `~/.local/bin/llama-metrics-sidecar.py`
2. Patches the `LLAMASWAP` constant from `http://localhost:8080` to `http://127.0.0.1:9080`
3. Writes `~/.config/systemd/user/llama-metrics-sidecar.service`
4. Runs `systemctl --user daemon-reload && systemctl --user enable --now llama-metrics-sidecar.service`
5. Prompts once for `sudo` to run `loginctl enable-linger $USER` so the service survives logout and reboot

Verify it's up:

```bash
systemctl --user status llama-metrics-sidecar --no-pager
curl -s http://127.0.0.1:9090/healthz   # -> ok
curl -s http://127.0.0.1:9090/metrics | grep -c llamaswap_   # -> non-zero
```

## Step 5 — Verify end-to-end (LAN reachability + cluster integration)

Run the verify script:

```bash
bash scripts/workstation/verify-setup.sh
```

It checks, in order:

1. `llama-swap.exe` responds on `127.0.0.1:9080/running`
2. `llama-swap.exe` exposes host metrics on `127.0.0.1:9080/metrics` (gates on v218+)
3. Sidecar `/healthz` returns `ok` on `127.0.0.1:9090`
4. Sidecar `/metrics` returns at least one `llamaswap_*` value line
5. From the operator's machine: `kubectl exec` in a cluster pod can fetch `http://pierce-pc.levangie.org:9090/metrics` (proves Prometheus will be able to)

If any step fails, the script prints which one and exits non-zero. Use [troubleshooting.md](troubleshooting.md) for the common failures.

## Step 6 — Confirm the cluster side is already wired

These two files in the repo encode everything the cluster knows about `pierce-pc`. They should already be present and pushed:

```bash
git --no-pager show HEAD:argocd/apps/prod/librechat.yaml | grep -A4 'name: "llama-pc"'
git --no-pager show HEAD:argocd/manifests/monitoring-config/overlays/prod/scrapeconfig-llama-cpp-pc.yaml
```

If the workstation is brand-new and these don't exist yet, the operator needs to add them. Use the cluster-side commit history as reference:

- `cb43756` — original workstation + ScrapeConfig wiring
- `addc051` — port fix (8080 -> 9080)
- `3ab50b1` — sidecar `/running` parser fix (dict-shaped entries)

## Step 7 — Confirm metrics flow in Grafana

Open Grafana → `llama-cpp` dashboard. The `$instance` dropdown should list `cluster` and `workstation`. Switch to `workstation`:

- CPU per-core, RAM, swap, network, load average → populated
- GPU panels → **empty** (expected; see troubleshooting.md "no GPU metrics")
- Active model → empty until a Qwen request fires; populated within ~30s after

Trigger a peer request from any cluster node:

```bash
kubectl --context k3s-prod -n llama-cpp exec deploy/llama-cpp -c llama-swap -- \
  curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3.6-27B","messages":[{"role":"user","content":"hi"}],"max_tokens":4}'
```

Within ~30s, the dashboard's `Active model(s)` panel shows `Qwen3.6-27B`, the prompt/generation tok/s panels populate, and `llamacpp:*` metrics in Prometheus carry the `model="Qwen3.6-27B"` label.

## Operational reference

| Action | Command |
|---|---|
| Restart sidecar | `systemctl --user restart llama-metrics-sidecar` |
| Tail sidecar logs | `journalctl --user -u llama-metrics-sidecar -f` |
| Re-copy script after an upstream change in `sidecar-exporter.py` | `bash scripts/workstation/install-metrics-sidecar-wsl.sh` (idempotent — re-runs the install) |
| Stop llama-swap on Windows | `& "C:\Users\pierc\llama-cpp\Stop Llama-Swap.lnk"` |
| Start llama-swap on Windows | `& "C:\Users\pierc\llama-cpp\Start Llama-Swap.lnk"` |
| Upgrade llama-swap on Windows | `winget upgrade --id mostlygeek.llama-swap` then restart |
| Confirm linger | `loginctl show-user $USER \| grep Linger` should show `Linger=yes` |
