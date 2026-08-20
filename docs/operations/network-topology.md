# Network Topology and Host Bonding

Use this runbook for the Proxmox host network configuration and the procedure for
changing it. The physical port map itself lives in NetBox, not here — see below.

The lab runs a single flat L2 segment, `172.20.20.0/22`, gateway `172.20.20.1`. There
are no VLANs. Two switches, both web-managed:

| Switch | Hardware | Management | Role |
| --- | --- | --- | --- |
| `sw-core-25g` | SODOLA SL902-SWTGW218AS, 8x 2.5GBASE-T + 1x 10G SFP+ | `sw-core-25g.levangie.org` (`172.20.20.250`), HTTP only | Fast core |
| `sw-edge-1g` | Netgear GS308E, 8x 1GbE (Plus) | not yet racked; defaults to DHCP, falls back to `192.168.0.239` | Edge and bond-failover plane |

The SODOLA answers on port 80 only — SSH, telnet, HTTPS and SNMP are all filtered, so
there is no way to poll it from Prometheus and LAG state must be checked by eye in the
web UI. Its address is static and sits outside the DHCP pool.

The SODOLA has a **ninth** interface: a 10G SFP+ uplink. It is deliberately left
free — see the design decisions below.

## Switch Port Map

**NetBox is the source of truth.** The port map is not duplicated here — read it from
[netbox.levangie.dev](https://netbox.levangie.dev), where both switches are modelled
as devices with eight interfaces each:

| Device | Role |
| --- | --- |
| [`sw-core-25g`](https://netbox.levangie.dev/dcim/devices/?q=sw-core-25g) | Fast core. All active 2.5G Proxmox links and the uplink. |
| [`sw-edge-1g`](https://netbox.levangie.dev/dcim/devices/?q=sw-edge-1g) | Edge plane. Router, both NAS LAG legs, and capacity for unplugged bond members. |

Each host's interfaces carry their LAG and bridge relationships, so a device's
Interfaces tab shows which physical NIC belongs to which bond and where it is cabled.

Cables use NetBox's `status` field, which makes the model double as the cabling
checklist: runs still to be made are **`planned`**, and links that physically exist
are **`connected`**. Flip each one to `connected` as you make it.

> Switch port numbers for the pre-existing links (atlas, both NAS legs, the
> workstation) are the proposed layout, not observed fact — correct them in NetBox if
> the physical ports differ.

The router lives on the 1G switch because its LAN port is 1G and can never exceed
that regardless of which switch it sits on, so the 1G uplink costs zero throughput
and frees a 2.5G port.

**Exactly one cable between the switches.** The GS308E has loop detection, but treat
that as a backstop rather than permission for a second cable. Active-backup bonds
never forward on two legs at once, so the bonds themselves cannot create a loop.

## Host Bonding

Every Proxmox host runs `vmbr0` on top of an `active-backup` bond. The 2.5G member is
active. The configured 1G member is intentionally unplugged and can be cabled later
to restore failover without changing the Proxmox network configuration.

| Host | Active (2.5G) | Configured 1G member | `vmbr0` address |
| --- | --- | --- | --- |
| atlas | `nic0` (onboard) | `nic1` (unplugged) | `172.20.20.6/22` |
| elitedesk-1 | `enx6c1ff7cc61a4` (USB) | `nic0` (unplugged) | `172.20.20.7/22` |
| dellssf | `enx6c1ff7c0d19c` (USB) | `enp1s0` (unplugged) | `172.20.20.14/22` |

### Reference configuration

`/etc/network/interfaces` on elitedesk-1:

```
iface enx6c1ff7cc61a4 inet manual

iface nic0 inet manual
    post-up ethtool -K nic0 tso off gso off gro off || true
    post-up ethtool --set-eee nic0 eee off || true

auto bond0
iface bond0 inet manual
    bond-slaves enx6c1ff7cc61a4 nic0
    bond-mode active-backup
    bond-primary enx6c1ff7cc61a4
    bond-primary-reselect always
    bond-miimon 100
    bond-downdelay 200
    bond-updelay 30000
    bond-num-grat-arp 5

auto vmbr0
iface vmbr0 inet static
    address 172.20.20.7/22
    gateway 172.20.20.1
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
```

atlas and dellssf use the same shape with their own slave names and addresses. The
`post-up ethtool` lines are specific to elitedesk-1's Intel I219 and should not be
copied to the other hosts.

Notes:

- **USB interface names are stable.** `/usr/lib/systemd/network/73-usb-net-by-mac.link`
  sets `NamePolicy=mac`, so an adapter is always `enx<its-mac>`. Replacing a dead
  adapter changes the name and you must edit `/etc/network/interfaces` to match.
- **`updelay 30000`** stops a flapping USB adapter from ping-ponging the active slave.
  Bonding activates a slave immediately when the bond has no active slave, so boot is
  not delayed by it.
- **Feature intersection.** Bonding ANDs netdev features across slaves, so
  elitedesk-1's disabled TSO/GSO/GRO can propagate to `bond0`. Check `ethtool -k bond0`
  after any change to that host.

## Changing a Host's Network Configuration

> **Get console access to the host first.** A bad `/etc/network/interfaces` makes the
> host unreachable with no remote rollback.

One host at a time. Each Proxmox host holds exactly one etcd member, so quorum (2 of 3)
survives a single host — but never take two down together.

Order by blast radius, lowest first:

1. **dellssf** — cp-3, haos, technitium, affirm-srv, gamble-king.
   technitium is the lab DNS server; confirm a fallback resolver first.
2. **elitedesk-1** — cp-4, worker-4, pbs, caddy (all public ingress).
3. **atlas** — cp-1 plus all four workers; the biggest capacity hit.

Per host:

```bash
# 1. Confirm the adapter is present and 2.5G-capable
ethtool <usb-nic> | grep -A5 'Supported link modes'

# 2. Cable USB -> 2.5G switch, then CONFIRM before editing anything
ethtool <usb-nic> | grep -E 'Speed|Link detected'   # expect 2500Mb/s, yes

# 3. Cable the onboard NIC -> 1G switch

# 4. Edit /etc/network/interfaces, then dry run before applying
ifreload -a -n
ifreload -a
```

### Verification

```bash
cat /proc/net/bonding/bond0     # mode active-backup, USB active, both slaves up
ip -br addr show vmbr0          # correct address
pvecm status                    # Quorate: Yes, 3 votes
```

Failover test — run a continuous ping to the host from elsewhere, then:

```bash
ip link set <usb-nic> down      # expect <=1s loss, traffic continues on 1G
ip link set <usb-nic> up        # expect reselect back to 2.5G after updelay
```

### Throughput baseline

Recorded 2026-08-14 with `iperf3`, single stream, before the 2.5G cabling:

| Path | Baseline (1GbE) |
| --- | --- |
| elitedesk-1 -> atlas | 932 Mbit/s |
| atlas -> elitedesk-1 | 917 Mbit/s |
| dellssf -> atlas | 945 Mbit/s |

Measured after cabling: roughly 2.34-2.35 Gbit/s across Atlas, EliteDesk, and Dell-SSF.

### Monitoring policy

`ProxmoxHostLinkBelowExpected` alerts when `bond0` reports less than 2.5 Gb/s and
remains actionable. Do not alert on configured slave count versus active slave count:
the 1G members are intentionally unplugged, so `ProxmoxHostBondDegraded` would be a
permanent false positive.

## NAS Link Aggregation

The Synology DS420+ has 2x 1GbE bonded, presenting a single MAC
(`90:09:d0:23:02:89`) to all hosts. It is a 2x1G device and stays one — the 2.5G
upgrade does not make it faster for a single stream.

- **Reads (NAS to host)** are pinned to one 1G link. The NAS bond picks the egress
  link and DSM does not expose `xmit_hash_policy`, so it hashes on MAC pairs and every
  conversation with a given host lands on the same leg. Reads stay ~1 Gb/s per host.
- **Writes (host to NAS)** can reach ~2 Gb/s, because the *switch* picks the LAG
  member. This needs a layer3+4 hash on the switch LAG and multiple TCP connections,
  which is what `nconnect=4` on the NFS mount provides.

If the bond is in Balance XOR, that is a *static* LAG and requires a matching static
trunk on the switch. Without it the switch sees one MAC on two ports and MAC-flaps —
silent packet loss. 802.3ad LACP is preferred: it detects miswiring and half-failures
that static XOR silently tolerates.

## Design Decisions

**NetBox owns the port map; this runbook owns the procedure.** The topology used to
live in an Obsidian note and again as tables in this file, which meant two copies
drifting apart. NetBox already drove DNS for the lab, and cables, LAGs and interfaces
are first-class DCIM objects there, so it became the single source of truth for
anything physical. What stays here is what NetBox cannot express: bond configuration,
the change procedure, throughput baselines, and these design decisions. The Obsidian
note `3. Homelab notes/Topology` is kept as a target-state planning summary that
points at NetBox, rather than as a competing record.

**Host DNS names match the Proxmox node name.** `atlas`, `elitedesk-1` and `dellssf`
resolve under `levangie.org` to exactly the name `pvecm nodes` reports. `dellssf` was
renamed from `dell-sff` on 2026-08-14 to follow this; `dell-sff.levangie.org` remains
as a CNAME transition alias (see `home-infra-texy`).

Records are created by the `netbox-technitium-sync` CronJob from each NetBox IP's
`dns_name`, but **only for IPs whose status is `active`** — a `reserved` IP is skipped
with no log line at all. That is why elitedesk-1 had no DNS record for a while after
it went into production. If a host is missing from DNS, check its IP status in NetBox
first.

**Why two switches.** Without bonding, everything fits on the SODOLA alone: three
hosts, two NAS legs, the workstation and the router is seven of its eight RJ45 ports.
The GS308E is required *because* of the active-backup bonds — three standby legs need
three more ports, and the SODOLA has only one spare. It was already owned and
otherwise idle, and it is also the only place the ProLiant's 4x 1G can land.

**The 10G SFP+ port stays free.** It could carry the inter-switch uplink with a
1000BASE-T SFP module, which would let the router keep a direct SODOLA port. That
buys nothing today: the GS308E is a 1G switch, so the uplink is 1 Gb/s either way,
and the port count works out the same (seven used, one spare) in both arrangements.
The genuinely valuable use is a future 10G link to atlas — atlas is the busiest
talker, serving Longhorn replicas, NFS and migration traffic, so a 10G uplink would
let it hold several 2.5G conversations at once without contending. Spending the SFP+
cage on a 1G uplink now would foreclose that.

**Proxmox migration is `insecure`.** `/etc/pve/datacenter.cfg` carries
`migration: type=insecure,network=172.20.20.0/22`. The default `secure` mode tunnels
the migration stream over SSH, and that encryption — not the wire — is the bottleneck
on dellssf (i3-8100T, 4 threads), so a 2.5G link would go largely unused. The
tradeoff is that VM memory and disk cross the LAN unencrypted, which is acceptable on
this trusted flat segment.

**No jumbo frames.** The network is a single flat `172.20.20.0/22` shared with the
router, the workstation, and every VM. Partial MTU 9000 on a flat subnet blackholes
traffic between 9000- and 1500-MTU hosts, and doing it properly needs a storage VLAN
and a second subnet. At 1 Gb/s — the NAS ceiling — a 1500-byte MTU already saturates
the link, so the payoff is near zero.

**No dedicated Longhorn storage network.** Four of the five storage-bearing k3s nodes
live on atlas, where replica traffic never leaves the box and is switched in-kernel by
`vmbr0`. The only cross-host path is atlas to elitedesk-1, and atlas has exactly one
2.5G port, so a separate storage network would run either on atlas's 1G onboard NICs
(slower than today) or as a VLAN on the same wire (isolation, not bandwidth). See
`home-infra-mi4.5`, closed for this reason.

**Not automated in Ansible.** There is a `proxmox_host` role and a `proxmox-hosts.yml`
playbook, but this is a one-time change on three hosts and a task that rewrites
`/etc/network/interfaces` incorrectly makes a host unreachable with no remote
rollback. The configuration is documented here instead.

## Monitoring

Two alerts in `argocd/manifests/monitoring-config/base/prometheusrule-platform.yaml`
cover the bonds, both scoped to `job="proxmox-node-exporter"`:

- `ProxmoxHostBondDegraded` — a bond has lost a slave. Active-backup hides NIC
  failures by design, so without this a host runs on its 1G standby leg unnoticed.
- `ProxmoxHostLinkBelowExpected` — `bond0` negotiated below 2.5 Gb/s
  (312500000 bytes/sec). Marginal cabling is the usual cause on 2.5GBASE-T; suspect
  the cable before the adapter.
