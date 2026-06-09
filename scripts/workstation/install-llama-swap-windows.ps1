#requires -Version 5.1
<#
.SYNOPSIS
    Installs (or upgrades) llama-swap on the Windows side of pierce-pc and
    wires up the Start/Stop .lnk shortcuts that the operator uses to launch
    it. Idempotent — re-run safely.

.DESCRIPTION
    Step 1 of the workstation install. Companion to
    scripts/workstation/install-metrics-sidecar-wsl.sh (Step 2).

    Actions:
      * winget install / upgrade mostlygeek.llama-swap
      * ensure C:\Users\pierc\llama-cpp\ exists (config goes here)
      * write Start Llama-Swap.lnk and Stop Llama-Swap.lnk with the
        canonical Arguments strings
      * copy Start shortcut into shell:Startup so it auto-launches at login

    Does NOT touch C:\Users\pierc\llama-cpp\config.yaml — that file is
    operator-authored (model entries point at local GGUFs and must include
    --metrics on every model). See docs/WSL/LLM/setup.md Step 2.

.NOTES
    Requires elevated PowerShell only for the initial winget install on a
    fresh user profile. Subsequent runs are no-ops and don't need elevation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LlamaDir       = 'C:\Users\pierc\llama-cpp'
$StartShortcut  = Join-Path $LlamaDir 'Start Llama-Swap.lnk'
$StopShortcut   = Join-Path $LlamaDir 'Stop Llama-Swap.lnk'
$StartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Start Llama-Swap.lnk'
$MinVersion     = 218  # /metrics endpoint was added in v218

function Write-Section($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host "  ok   $msg"   -ForegroundColor Green }
function Write-Skip($msg)    { Write-Host "  skip $msg"   -ForegroundColor DarkGray }
function Write-Do($msg)      { Write-Host "  do   $msg"   -ForegroundColor Yellow }

function Get-LlamaSwapVersion {
    $cmd = Get-Command llama-swap -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $output = & $cmd.Source --version 2>&1
    if ($output -match 'version:\s*(\d+)') { return [int]$Matches[1] }
    return $null
}

Write-Section 'llama-swap binary'
$currentVer = Get-LlamaSwapVersion
if ($null -eq $currentVer) {
    Write-Do "winget install mostlygeek.llama-swap"
    winget install --id mostlygeek.llama-swap --silent --accept-source-agreements --accept-package-agreements | Out-Null
    $currentVer = Get-LlamaSwapVersion
    if ($null -eq $currentVer) { throw 'install completed but llama-swap not on PATH; re-open shell or check winget logs' }
    Write-Ok "installed v$currentVer"
} elseif ($currentVer -lt $MinVersion) {
    Write-Do "v$currentVer < required v$MinVersion (no /metrics endpoint) — upgrading"
    # Stop any running instance so the binary can be replaced
    Get-Process llama-swap -ErrorAction SilentlyContinue | Stop-Process -Force
    winget upgrade --id mostlygeek.llama-swap --silent --accept-source-agreements --accept-package-agreements | Out-Null
    $currentVer = Get-LlamaSwapVersion
    Write-Ok "upgraded to v$currentVer"
} else {
    Write-Skip "v$currentVer already meets minimum v$MinVersion"
}

Write-Section 'config directory'
if (-not (Test-Path $LlamaDir)) {
    Write-Do "create $LlamaDir"
    New-Item -ItemType Directory -Path $LlamaDir -Force | Out-Null
}
Write-Ok $LlamaDir
if (-not (Test-Path (Join-Path $LlamaDir 'config.yaml'))) {
    Write-Host "  note config.yaml not present — author it manually per docs/WSL/LLM/setup.md Step 2" -ForegroundColor DarkYellow
}

Write-Section 'Start / Stop shortcuts'
$shell = New-Object -ComObject WScript.Shell

$startArgs = '-WindowStyle Hidden -Command "Start-Process llama-swap -ArgumentList ''--config config.yaml --listen 0.0.0.0:9080'' -WorkingDirectory ''C:\Users\pierc\llama-cpp'' -WindowStyle Hidden"'
$stopArgs  = '-WindowStyle Hidden -Command "Stop-Process -Name ''llama-swap'', ''llama-server'' -Force -ErrorAction SilentlyContinue"'

function Set-Shortcut($path, $args) {
    $changed = $true
    if (Test-Path $path) {
        $existing = $shell.CreateShortcut($path)
        if ($existing.Arguments -eq $args) { $changed = $false }
    }
    if ($changed) {
        Write-Do "write $path"
        $sc = $shell.CreateShortcut($path)
        $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $sc.Arguments        = $args
        $sc.WorkingDirectory = "$env:SystemRoot\System32\WindowsPowerShell\v1.0"
        $sc.WindowStyle      = 7  # Minimized
        $sc.Save()
    } else {
        Write-Skip "$path already correct"
    }
}

Set-Shortcut $StartShortcut $startArgs
Set-Shortcut $StopShortcut  $stopArgs

Write-Section 'autostart on login'
if (-not (Test-Path $StartupShortcut) -or (Get-Item $StartupShortcut).LastWriteTime -lt (Get-Item $StartShortcut).LastWriteTime) {
    Write-Do "copy Start shortcut into shell:Startup"
    Copy-Item -Path $StartShortcut -Destination $StartupShortcut -Force
} else {
    Write-Skip "shell:Startup already has the current Start shortcut"
}

Write-Section 'summary'
Write-Host "  llama-swap v$currentVer installed at: $((Get-Command llama-swap).Source)"
Write-Host "  config:  $LlamaDir\config.yaml  (operator-authored)"
Write-Host "  startup: $StartupShortcut"
Write-Host ''
Write-Host "Next step:  bash scripts/workstation/install-metrics-sidecar-wsl.sh  (inside WSL2)"
Write-Host "Then:       bash scripts/workstation/verify-setup.sh"
