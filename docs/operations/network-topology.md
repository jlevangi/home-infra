# Network Topology and Host Bonding

Use this runbook for the Proxmox host network configuration and the procedure for
changing it. The physical port map itself lives in NetBox, not here — see below.

The lab runs a single flat L2 segment, `172.20.20.0/22`, gateway `172.20.20.1`. There
are no VLANs. Two 8-port switches: a managed 2.5G switch as the fast core, and an
unmanaged 1G switch as the edge and bond-failover plane.

## Switch Port Map

**NetBox is the source of truth.** The port map is not duplicated here — read it from
[netbox.levangie.dev](https://netbox.levangie.dev), where both switches are modelled
as devices with eight interfaces each:

| Device | Role |
| --- | --- |
| [`sw-core-25g`](https://netbox.levangie.dev/dcim/devices/?q=sw-core-25g) | Fast core. All 2.5G links, both NAS LAG legs, the uplink. |
| [`sw-edge-1g`](https://netbox.levangie.dev/dcim/devices/?q=sw-edge-1g) | Edge / failover plane. Standby bond legs, router, future ProLiant. |

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

**Exactly one cable between the switches.** The 1G switch is unmanaged, so a second
cable is a broadcast storm with no STP to break it. Active-backup bonds never forward
on two legs at once, so the bonds themselves cannot create a loop.

## Host Bonding

Every Proxmox host runs `vmbr0` on top of an `active-backup` bond: a 2.5G primary and
a 1G standby on the other switch. The USB adapters are consumer Realtek RTL8156B
devices, so the standby leg exists to keep a host reachable when one resets.

| Host | Primary (2.5G) | Standby (1G) | `vmbr0` address |
| --- | --- | --- | --- |
| atlas | `nic0` (onboard) | `nic1` | `172.20.20.6/22` |
| elitedesk-1 | `enx6c1ff7cc61a4` (USB) | `nic0` | `172.20.20.7/22` |
| dellssf | `enx6c1ff7c0d19c` (USB) | `enp1s0` | `172.20.20.14/22` |

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

Target after cabling on the atlas <-> elitedesk-1 path is roughly 2.3-2.4 Gbit/s.

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
note is retired.

**Why two switches.** Without bonding, everything fits on the 2.5G switch alone:
three hosts, two NAS legs, the workstation and the router is seven of eight ports.
The second switch is required *because* of the active-backup bonds — three standby
legs need three more ports, and the 2.5G switch has only one spare. The 1G switch is
already owned and was otherwise idle, and it is also the only place the ProLiant's
4x 1G can land.

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
