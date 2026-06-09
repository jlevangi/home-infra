# RustDesk client install

Pre-configured installers for the self-hosted hbbs/hbbr at `rustdesk.levangie.dev`. Each command downloads RustDesk, drops the server hostname + public key into config, restarts the service, and prints the device ID.

## Linux (Mint / Debian / Ubuntu)

In a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/jlevangi/home-infra/main/scripts/rustdesk/install-linux.sh | sudo bash
```

## Windows

In an **elevated** PowerShell (right-click PowerShell → Run as administrator):

```powershell
iwr -useb https://raw.githubusercontent.com/jlevangi/home-infra/main/scripts/rustdesk/install-windows.ps1 | iex
```

## After install

1. Note the device ID the script prints at the end.
2. (Optional) On the target machine: open RustDesk → Settings → Security → **Set Permanent Password**. Without this you'll get a fresh prompt-password every session.
3. On the controller machine, add the device ID + password to your address book for one-click reconnect.

## Server details (for manual config)

| Field | Value |
|-------|-------|
| ID server | `rustdesk.levangie.dev` |
| Relay server | `rustdesk.levangie.dev` |
| API server | *(blank)* |
| Key | `3V8rnL1ol+2F16Vaz7on0tD0aY4pdbbh3N2TYo500Cs=` |

Script sources:
- `scripts/rustdesk/install-linux.sh`
- `scripts/rustdesk/install-windows.ps1`
