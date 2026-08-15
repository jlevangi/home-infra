# NetBox

NetBox at [netbox.levangie.dev](https://netbox.levangie.dev) is the source of truth for
the lab's physical and virtual inventory: racks and cabling, hosts and their interfaces,
IP addresses, and the Proxmox guests. Two CronJobs in the `netbox` namespace keep it
connected to the rest of the lab.

```
Proxmox cluster API                                Technitium DNS
        |                                                ^
        | netbox-proxmox-reconcile (*/15)                | netbox-technitium-sync (*/15)
        v                                                |
    +---------------------------- NetBox ----------------+
         guests, hosts, cabling, IPAM
```

Neither job is authoritative for everything. Proxmox owns *which guests exist and where
they run*; NetBox owns *names, IPs and DNS intent*; Technitium owns nothing — it is a
downstream consumer.

## Data model conventions

| Concept | How it is modelled |
| --- | --- |
| Proxmox cluster | One Cluster named `oasis`, type Proxmox VE |
| Proxmox nodes | Devices (`atlas`, `elitedesk-1`, `dellssf`) with `cluster = oasis` |
| Guests (VM + LXC) | VirtualMachines with `cluster = oasis` and `device = <host it runs on>` |
| Guest identity | Custom field `proxmox_vmid` — **not** the name |
| Switches | Devices `sw-core-25g`, `sw-edge-1g` with an interface per port |
| Cabling | Cables between interfaces; `planned` vs `connected` marks what is physically made |

Device names match the Proxmox node names exactly, so `pvecm nodes` and NetBox agree.
There must never be a Cluster per host — that was the original shape and it loses the
host relationship entirely, since a VM's `device` can only point at a device that
belongs to its cluster.

## Proxmox → NetBox reconcile

`argocd/manifests/netbox/base/cronjob-proxmox-reconcile.yaml`, script in the adjacent
`configmap-proxmox-reconcile.yaml`. Runs at 7/22/37/52 past the hour, offset from the
DNS sync so the two never overlap.

It reads `/cluster/resources?type=vm` and reconciles guest identity, host placement and
running state. Templates are excluded.

**It never deletes.** A guest absent from Proxmox is set to `offline` with a note. This
is deliberate: deleting a NetBox VM cascades to its IP address, and those IPs carry the
`dns_name` values that drive the `levangie.org` zone, so a delete here could silently
remove a DNS record.

**Matching is on `proxmox_vmid`, not name.** Two guests legitimately differ between the
systems — Proxmox `mint-vm` is NetBox `pierce-mint-vm`, and Proxmox
`caddy-srv.levangie.org` is NetBox `caddy-srv`. Those are listed in the script's
`ALIASES` and used only to adopt an existing VM on first sight; afterwards the VMID
carries the identity. NetBox names are never overwritten, because IP records point at
them.

Polling rather than Proxmox hookscripts, because polling is self-healing: it catches
live migrations and anything done by hand in the Proxmox UI. Hookscripts must be
attached per guest and are easy to miss on a new one.

### Credentials

A dedicated Proxmox user `netbox-sync@pve` with the `PVEAuditor` role at `/`, and a
token `netbox-sync@pve!reconcile` with `privsep 0`. Verified read-only — a write attempt
returns HTTP 403. Stored at `kv/prod/netbox-proxmox-sync` and delivered by the
`netbox-proxmox-sync-secrets` ExternalSecret.

To rotate:

```bash
ssh root@172.20.20.6 'pveum user token remove netbox-sync@pve reconcile'
ssh root@172.20.20.6 'pveum user token add netbox-sync@pve reconcile --privsep 0'
# then vault kv patch kv/prod/netbox-proxmox-sync PROXMOX_TOKEN_SECRET='<new value>'
```

## NetBox → Technitium DNS

`cronjob-technitium-sync.yaml`, image `ghcr.io/jlevangi/netbox-sync`. Publishes A records
into the `levangie.org` zone from each IP's `dns_name`.

Two behaviours that are easy to trip over:

- **Only IPs with `status: active` are considered.** A `reserved` IP is skipped *with no
  log line at all*, indistinguishable from one the tool never saw. This is the first
  thing to check when a host has no DNS record — it is why `elitedesk-1` had none for a
  while after going into production.
- **It never overwrites a record it did not create**, logging
  `skip <name> (exists, not netbox-sync managed)`. So editing `dns_name` in NetBox does
  not by itself change DNS; a hand-made record wins and the Technitium side must be
  changed by hand.

It also never deletes, so renaming a host means removing the old record manually. The
zone is DNSSEC-signed and Technitium re-signs automatically on add or delete.

## Troubleshooting

- **A host has no DNS record** — check the IP's status is `active` in NetBox first, then
  its `dns_name`, then whether a manual Technitium record already owns the name.
- **A guest shows the wrong host** — run the reconcile job by hand:
  `kubectl -n netbox create job fix --from=cronjob/netbox-proxmox-reconcile`, then read
  its logs. Every change it makes is logged with the before and after.
- **Reconcile reports guests it cannot place** — it logs `WARN ... is on <node>, which is
  not a device in oasis`. That means a Proxmox node has no matching NetBox device, or the
  device is not assigned to the `oasis` cluster.
- **Dry run** — set `DRY_RUN=true` in the CronJob env to log intended changes without
  writing.
