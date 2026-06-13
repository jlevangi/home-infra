# Troubleshooting — WSL/LLM Workstation

Concrete failure modes seen during the original buildout (2026-06-07/08), what they look like, and how to fix them. If you hit something new, add it here.

## Prometheus target `llama-cpp-pc` is `down`

Most likely failure path. Diagnose by checking each layer from the outside in:

```bash
# (1) does the sidecar respond to the cluster?
kubectl --context k3s-prod -n monitoring exec deploy/kube-prometheus-stack-grafana -- \
  wget -qO- --timeout=5 http://pierce-pc.levangie.org:9090/healthz
# expected: ok
```

If that hangs or refuses, the problem is networking (firewall, DNS, mirrored mode misconfigured, sidecar dead). Go to "Sidecar not reachable from LAN" below.

If `/healthz` returns `ok` but `/metrics` returns no body, the sidecar is up but llama-swap is unreachable to the sidecar. Go to "Sidecar runs but emits zero `llamaswap_*` metrics".

## Sidecar runs but emits zero `llamaswap_*` metrics

The sidecar's `_aggregate()` writes a comment line `# llama-swap host metrics scrape failed: <error>` on top of the body when it can't reach llama-swap. Check:

```bash
curl -s http://127.0.0.1:9090/metrics | head -3
```

Common causes:

- **llama-swap is bound to a different port.** Verify with `powershell.exe -Command "Get-NetTCPConnection -State Listen | Where-Object { $_.OwningProcess -eq (Get-Process llama-swap).Id }"`. If the port differs from 9080, either change the Start shortcut (and restart llama-swap) or patch the sidecar's `LLAMASWAP` constant and restart it.
- **llama-swap version < v218.** The host `/metrics` endpoint was added in v218 (we're on v223). `winget upgrade --id mostlygeek.llama-swap` then restart llama-swap.
- **llama-swap is not running.** `& "C:\Users\pierc\llama-cpp\Start Llama-Swap.lnk"` to start it.

## `llamacpp:*` inference metrics never appear (only `llamaswap_*` host metrics)

The sidecar synthesizes `llamacpp_active_model_info{model="..."}` for each model in `/running`, and proxies `/upstream/<model>/metrics` for each. If you see ZERO `llamacpp:*` lines and ZERO `llamacpp_active_model_info`:

- **No model is currently loaded.** Trigger one with a chat request and re-check after a few seconds.
- **`--metrics` is missing from the running model's `cmd`.** Spawned llama-server returns HTTP 501 on `/metrics`. Check `C:\Users\pierc\llama-cpp\config.yaml` — every model's `cmd:` block should contain a `--metrics` line. After fixing, restart llama-swap so it re-reads the config.
- **Older `/running` schema bug.** The original sidecar (pre-`3ab50b1`) filtered `/running` entries with `isinstance(m, str)` but the API actually returns dicts like `{"model": "...", "state": "ready"}`. The fixed parser handles both. If the workstation copy is older than the canonical script, re-run `install-metrics-sidecar-wsl.sh`.

## Sidecar not reachable from LAN (Prometheus target stuck `down`)

Verify the WSL2 networking mode is `mirrored`:

```bash
cat /mnt/c/Users/$USER/.wslconfig
# should contain:
# [wsl2]
# networkingMode=mirrored
```

If it's not there, set it, then **fully restart WSL** from PowerShell:

```powershell
wsl --shutdown
# wait a few seconds, then start a new WSL session
```

Without mirrored mode, WSL2 services on `0.0.0.0:9090` are NOT reachable from the LAN — they sit behind a NAT'd Hyper-V virtual network. The fallback is `netsh interface portproxy add v4tov4 listenport=9090 listenaddress=0.0.0.0 connectport=9090 connectaddress=<wsl-ip>` from elevated PowerShell, but mirrored mode is the cleaner answer and the rest of this setup assumes it.

## Peer routing returns 502 (cluster's `/v1/chat/completions` to a Qwen model fails)

The cluster's `peers.pierce-pc.proxy` URL must point at the right host + port. Check:

```bash
git --no-pager show HEAD:argocd/manifests/llama-cpp/base/config.yaml | grep -A1 'pierce-pc:' | head
```

Expected: `proxy: http://pierce-pc.levangie.org:9080`. If you see `:8080`, that's the pre-`addc051` bug — rebase / pull / sync.

If the proxy URL is right but routing still 502s:

```bash
# from any cluster pod — can it reach the workstation llama-swap directly?
kubectl --context k3s-prod -n monitoring exec deploy/kube-prometheus-stack-grafana -- \
  wget -qO- --timeout=5 http://pierce-pc.levangie.org:9080/running
```

If that hangs, the workstation's llama-swap port is firewalled, or the host isn't running, or DNS lies. Test from the operator's machine: `curl http://pierce-pc.levangie.org:9080/running`.

If reachable but the actual chat request fails, look at the PC's llama-swap stdout (the Start shortcut hides the window — re-launch without `-WindowStyle Hidden` temporarily, OR rely on the in-process log capture via `GET http://127.0.0.1:9080/api/events`).

## GPU panels for `instance=workstation` are empty

**Upstream-blocked, not a local config problem.** llama-swap v223's Windows GPU monitor (`internal/perf/monitor_windows.go`) only supports `nvidia-smi`. The Linux build's fallback chain (LACT → nvidia-smi → rocm-smi → sysfs) does NOT exist on Windows. Installing `rocm-smi.exe` on this host would not help — llama-swap on Windows literally never calls it.

This is tracked upstream by mostlygeek/llama-swap [PR #779 — "perf: add vendor-agnostic GPU monitoring for Windows (experimental)"](https://github.com/mostlygeek/llama-swap/pull/779) by `noctrex`. It adds PDH (Windows Performance Counters) + D3DKMT (DirectX) backends with the new fallback chain: `nvidia-smi → D3DKMT+PDH → ErrNoGpuTool`. Tested upstream on AMD 7900XTX with ROCm; confirmed working. As of last check it was open and under coderabbit review.

**What to do today**: nothing — the dashboard panels for `instance=cluster` (NVIDIA + `nvidia-smi`) work fine; the workstation panels just sit empty until PR #779 lands and we `winget upgrade --id mostlygeek.llama-swap`. PDH does not require `rocm-smi.exe` or the AMD HIP SDK, so when this lights up, no additional installs are needed.

Watch the PR; once merged + released, run `winget upgrade --id mostlygeek.llama-swap` and restart llama-swap via the Start/Stop shortcuts. GPU panels for `instance=workstation` should populate within ~30s (one scrape interval).

## Sidecar service shows `active` but port is unreachable for a moment after start

Race condition between systemd marking the service `active` and the Python HTTP server actually calling `bind()`. Lasts < 1 second. Wait briefly and retry. Not worth fixing; the service stays up long enough that subsequent scrapes work.

## Sidecar dies / restarts repeatedly

```bash
journalctl --user -u llama-metrics-sidecar -n 50 --no-pager
```

Most likely cause: the script file at `~/.local/bin/llama-metrics-sidecar.py` was deleted, replaced with a malformed version, or has Windows line endings. The systemd unit's `Restart=always RestartSec=10` will keep the service running but the script will throw and exit every 10s. Re-run the install script:

```bash
bash scripts/workstation/install-metrics-sidecar-wsl.sh
```

## Linger not enabled (sidecar stops at logout/reboot)

Symptoms: dashboard's `instance=workstation` data goes flat for hours, returns when the operator logs in.

```bash
loginctl show-user $USER | grep Linger
# expected: Linger=yes
```

Fix:

```bash
sudo loginctl enable-linger $USER
```

The setup script attempts this, but if `sudo` was declined during install it will silently skip — re-run the script and approve the prompt.

## llama-swap process is killed but the Start shortcut won't relaunch it

The Start shortcut uses `Start-Process llama-swap ...` which depends on `llama-swap` being on PATH (it is, by way of `C:\Users\pierc\AppData\Local\Microsoft\WinGet\Links\` being in the user PATH). If a recent winget upgrade broke the alias:

```powershell
where.exe llama-swap
# should return a path under WinGet\Links
```

If empty, `winget repair --id mostlygeek.llama-swap` or simply `winget uninstall --id mostlygeek.llama-swap; winget install --id mostlygeek.llama-swap`.

## Stale entries in `/v1/models` after removing a peer model

llama-swap caches the peer model list at proxy startup. If you remove a model from `peers.pierce-pc.models` in the cluster config, ArgoCD will sync, the configmap hash changes, the pod rolls, and the new list takes effect. If you skipped the pod roll for some reason, force it: `kubectl --context k3s-prod -n llama-cpp rollout restart deploy/llama-cpp`.
