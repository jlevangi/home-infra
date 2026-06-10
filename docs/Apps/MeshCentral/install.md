# MeshCentral

Self-hosted at `https://mesh.levangie.dev`. Account-based remote management (browser + remote desktop + file transfer + terminal + scripts) — replaces the per-machine pairing model of RustDesk.

## Web access

Log in at **https://mesh.levangie.dev/?loginscreen=1**

(`/?loginscreen=1` skips the bare-bones landing page and goes straight to the login form. Bookmark that URL.)

## Adding a new device

1. Log in → **My Devices** → pick a device group (or create one with **Add Device Group**).
2. Click into the group → **Add Agent** → choose the OS/arch → MeshCentral generates an installer pre-baked with the server URL + group auth token.
3. Run the installer on the target machine — agent appears in the device list within seconds.

### Linux one-liner (from the Add Agent dialog)

The dialog gives you a `wget … | sudo -E …` command. Run it as printed. The download URL is `https://mesh.levangie.dev/meshagents?script=1` plus a group-specific auth token passed as a script argument.

If you ever need to **re-install** (e.g., after a server-side cert rotation), uninstall the old agent first or the bad cert hash sticks around:

```bash
sudo /usr/local/mesh_services/meshagent/meshagent -fulluninstall
rm -f ./meshinstall.sh   # delete any old empty/broken installer
# then re-run the one-liner from the admin UI
```

### Windows

Download the installer EXE/MSI from the Add Agent dialog and run as administrator. No special config.

## Remote desktop quirk on Linux Mint

MeshCentral's screen capture needs **real Xorg**, not XWayland. If you click the desktop viewer and get "configured for xwayland":

1. Log out
2. At the LightDM login screen click the gear icon → pick **"Cinnamon"** (not Wayland)
3. Log back in
4. `echo $XDG_SESSION_TYPE` should print `x11`

To force Xorg globally on a Mint machine:

```bash
sudo tee /etc/lightdm/lightdm.conf.d/60-force-xorg.conf <<'EOF'
[Seat:*]
greeter-session=slick-greeter
user-session=cinnamon
EOF
sudo systemctl restart lightdm
```

## Server-side notes

- Manifests: `argocd/manifests/meshcentral/`
- Image: `meshcentral/meshcentral:1.2.0`, NeDB built-in.
- TLS is terminated at Caddy on the edge; pod runs HTTP/80 internally with `TlsOffload: true`.
- `domains[""].CertUrl: https://mesh.levangie.dev/` + a pod-level `hostAliases` entry pointing that hostname at Caddy (172.20.20.3) so MeshCentral fetches Caddy's cert (the one external agents actually see) and bakes its hash into agent installers.
- Caddy vhost: `dev-sites-enabled/prod_cluster.caddy` (HTTPS upstream to `172.20.20.200:443` with `tls_insecure_skip_verify` because Traefik's cert is for the domain, not the IP).
- First admin (`pierce`) was created via the CLI (`--createaccount` + `--adminaccount`) since web signup isn't enabled.
