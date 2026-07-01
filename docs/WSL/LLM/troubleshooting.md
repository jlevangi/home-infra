# Troubleshooting — WSL/LLM Workstation

Concrete failure modes seen during the original buildout (2026-06-07/08), what they look like, and how to fix them. If you hit something new, add it here.

## Prometheus target `llama-cpp-pc` is `down`

This is expected when Pierce is not actively running PC-side `llama-swap`.
Prometheus still scrapes the target so Grafana has workstation metrics while it
is in use, but Alertmanager routes `TargetDown{job="llama-cpp-pc"}` to the null
receiver so it should not page or notify.

Only troubleshoot this state when the workstation endpoint is supposed to be
running and Grafana/Prometheus data is missing.

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

## LibreChat `llama.cpp PC` endpoint fails or shows no models

LibreChat talks to the workstation directly at `http://pierce-pc.levangie.org:9080/v1`. Check the configured endpoint:

```bash
git --no-pager show HEAD:argocd/apps/prod/librechat.yaml | grep -A4 'name: "llama-pc"'
```

Expected: `baseURL: "http://pierce-pc.levangie.org:9080/v1"`. If you see `:8080`, that's the pre-`addc051` port mistake — rebase / pull / sync.

If the URL is right but LibreChat still cannot fetch models:

```bash
# from any cluster pod - can it reach the workstation llama-swap directly?
kubectl --context k3s-prod -n monitoring exec deploy/kube-prometheus-stack-grafana -- \
  wget -qO- --timeout=5 http://pierce-pc.levangie.org:9080/v1/models
```

If that hangs, the workstation's llama-swap port is firewalled, the host is not running, or DNS lies. Test from the operator's machine: `curl http://pierce-pc.levangie.org:9080/v1/models`.

If reachable but the actual chat request fails, look at the PC's llama-swap stdout. The Start shortcut hides the window; re-launch without `-WindowStyle Hidden` temporarily, or rely on the in-process log capture via `GET http://127.0.0.1:9080/api/events`.

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

## Stale entries in LibreChat after changing workstation models

LibreChat fetches model lists from the endpoint, but the UI can hold client-side state. First confirm the workstation reports the expected list:

```bash
curl -s http://pierce-pc.levangie.org:9080/v1/models
```

If the API is correct but LibreChat is stale, refresh the browser session or restart the LibreChat pod so it reloads its config.
