# YAMS Migration Notes

This app migrates the active YAMS compose stack from `media-srv:/home/pierce/docker/yams`
to the production K3s GitOps model. The manifests intentionally keep only Kubernetes
desired state in Git; runtime secrets and copied application config stay out of the repo.

## Required Vault Keys

Create `prod/yams` and `test/yams` in Vault with these keys before syncing the
app in each environment:

```text
OPENVPN_USER
OPENVPN_PASSWORD
NZBGET_USER
NZBGET_PASS
```

Rotate the values from the original compose stack before storing them.

`jellyplex-watched` uses its own Vault path so the background sync credentials
do not have to be merged into the shared YAMS secret bundle:

```text
prod/jellyplex-watched
  PLEX_TOKEN
  JELLYFIN_TOKEN
```

## Config Seeding

The prod overlay intentionally renders all Deployments with `replicas: 0` for the
initial sync. After ArgoCD creates the PVCs, copy each source directory from
`media-srv:/home/pierce/docker/yams/config` into its matching PVC:

```text
tautulli      -> tautulli-config-pvc:/config
seerr         -> seerr-config-pvc:/app/config
jellyseerr    -> jellyseerr-config-pvc:/app/config
gluetun       -> gluetun-config-pvc:/config
qbittorrent   -> qbittorrent-config-pvc:/config
sonarr        -> sonarr-config-pvc:/config
radarr        -> radarr-config-pvc:/config
radarr4k      -> radarr4k-config-pvc:/config
bazarr        -> bazarr-config-pvc:/config
prowlarr      -> prowlarr-config-pvc:/config
wizarr        -> wizarr-config-pvc:/data/database
maintainerr   -> maintainerr-config-pvc:/opt/data
```

`maintainerr` keeps its media-server integration state in the SQLite database on
`maintainerr-config-pvc`; Plex/Seerr connectivity is not declaratively managed in
Git. After any fresh cutover or PVC restore, verify that `media_server_type`,
Plex host/token, and any Seerr integration settings are populated before relying
on Maintainerr health checks.

For an Overseerr to Seerr cutover, seed `seerr-config-pvc` from the existing
Overseerr config while both workloads are stopped, then start Seerr and let its
first-boot migration update the database in place before pruning the old
Overseerr Kubernetes resources.

The old compose stack mounted `./config` at `/config` for NZBGet. Seed
`nzbget-config-pvc` with the root-level NZBGet config files, especially
`nzbget.conf`, without copying every sibling app directory into that PVC.

## Storage And Cutover

Large media remains on NFS at `172.20.20.5:/volume1/media`; only app config/state
moves to Longhorn PVCs. private-app and `/mnt/NoEnter` are not part of this YAMS app and
must be handled separately without reading or copying the private collection.

Use a parallel cutover: seed the PVCs, change the prod overlay replica patch from
`0` to `1`, deploy and validate the K3s workloads, then stop the old compose stack
on `media-srv` after the Kubernetes UIs, VPN egress, downloader paths, and Arr
integrations are confirmed.

The test overlay runs with replicas enabled so the stack can be exercised before
production cutover. Seed only the config needed for the test scenario, and keep
test changes isolated from the running compose stack on `media-srv`.
