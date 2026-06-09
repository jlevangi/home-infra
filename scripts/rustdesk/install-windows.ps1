# RustDesk Windows installer pre-configured for the home-infra self-hosted server.
#
# Usage (in an *elevated* PowerShell window):
#   iwr -useb https://raw.githubusercontent.com/jlevangi/home-infra/main/scripts/rustdesk/install-windows.ps1 | iex
#
# After this finishes:
#   1. Open RustDesk (Start Menu).
#   2. (Optional) Settings -> Security -> Set Permanent Password
#      so the controller can reconnect without a prompt each time.
#   3. The Device ID printed at the end goes into your address book.

$ErrorActionPreference = 'Stop'

$RustdeskVersion = '1.4.7'
$ServerHost      = 'rustdesk.levangie.dev'
$ServerKey       = '3V8rnL1ol+2F16Vaz7on0tD0aY4pdbbh3N2TYo500Cs='

# --- Elevation check -------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Must run elevated. Right-click PowerShell -> Run as administrator, then re-run.'
    exit 1
}

# --- Arch detection --------------------------------------------------------
$arch = 'x86_64'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
    $arch = 'aarch64'
}
$exeName = "rustdesk-$RustdeskVersion-$arch.exe"
$url     = "https://github.com/rustdesk/rustdesk/releases/download/$RustdeskVersion/$exeName"

# --- Download --------------------------------------------------------------
$tmp = Join-Path $env:TEMP 'rustdesk-install'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$exe = Join-Path $tmp $exeName

Write-Host "==> Downloading RustDesk $RustdeskVersion ($arch)..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing

# --- Silent install --------------------------------------------------------
Write-Host '==> Silent installing (may take 30-60s)...'
Start-Process -FilePath $exe -ArgumentList '--silent-install' -Wait -NoNewWindow

$rustdeskExe = 'C:\Program Files\RustDesk\rustdesk.exe'
if (-not (Test-Path $rustdeskExe)) {
    # Some installer flows return before the file is in place; give it a moment.
    Start-Sleep -Seconds 10
}
if (-not (Test-Path $rustdeskExe)) {
    Write-Error 'Install appears to have failed: C:\Program Files\RustDesk\rustdesk.exe not found.'
    exit 1
}

# --- Stop service while we write config ------------------------------------
$svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host '==> Stopping RustDesk service...'
    Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue
}

# --- Generate TOML ---------------------------------------------------------
$configToml = @"
rendezvous_server = '$ServerHost'
nat_type = 0
serial = 0

[options]
'custom-rendezvous-server' = '$ServerHost'
'relay-server' = '$ServerHost'
'api-server' = ''
key = '$ServerKey'
"@

function Write-RustdeskConfig {
    param([string]$ConfigDir)
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    $target = Join-Path $ConfigDir 'RustDesk2.toml'
    Set-Content -Path $target -Value $configToml -Encoding utf8 -Force
    Write-Host "    Wrote: $target"
}

# --- Write to the service profile (LocalSystem) and every real user --------
Write-Host '==> Writing server settings...'
Write-RustdeskConfig 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config'

$skipUsers = @('Default','Default User','Public','All Users','defaultuser0')
foreach ($u in Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
    if ($skipUsers -contains $u.Name) { continue }
    $userCfg = Join-Path $u.FullName 'AppData\Roaming\RustDesk\config'
    Write-RustdeskConfig $userCfg
}

# --- Start service ---------------------------------------------------------
if ($svc) {
    Write-Host '==> Starting RustDesk service...'
    Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

# --- Get device ID ---------------------------------------------------------
$deviceId = ''
try {
    $deviceId = (& $rustdeskExe --get-id 2>$null | Out-String).Trim()
} catch { }

Write-Host ''
Write-Host '===================================================================='
Write-Host " RustDesk $RustdeskVersion installed and pointed at $ServerHost"
Write-Host '===================================================================='
if ($deviceId) {
    Write-Host " Device ID: $deviceId"
} else {
    Write-Host ' Device ID: (could not auto-detect; open RustDesk to see it)'
}
Write-Host ''
Write-Host ' Next steps:'
Write-Host '   1. Open RustDesk from the Start menu.'
Write-Host '   2. Optional: Settings -> Security -> Set a permanent password'
Write-Host '      so the controller can reconnect without a prompt each time.'
Write-Host '   3. Add the Device ID above to your address book on the controller.'
Write-Host '===================================================================='
