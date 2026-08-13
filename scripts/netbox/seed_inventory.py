#!/usr/bin/env python3
"""Seed NetBox with the verified homelab inventory (172.20.20.0/22).

Idempotent: safe to re-run. Uses name/address as the natural key for each
object type and only creates what's missing; existing objects are left
alone except for the fields this script owns (status, description,
primary IP assignment).

Usage:
    NETBOX_URL=https://netbox.levangie.dev NETBOX_TOKEN=... python3 seed_inventory.py
"""
import json
import os
import sys
import urllib.error
import urllib.request

NETBOX_URL = os.environ.get("NETBOX_URL", "https://netbox.levangie.dev").rstrip("/")
NETBOX_TOKEN = os.environ["NETBOX_TOKEN"]


def api(method, path, payload=None, params=None):
    url = f"{NETBOX_URL}/api{path}"
    if params:
        from urllib.parse import urlencode
        url += "?" + urlencode(params)
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Token {NETBOX_TOKEN}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        print(f"  ! {method} {path} -> {e.code}: {detail}", file=sys.stderr)
        raise


def get_or_create(list_path, filter_params, payload, label):
    results = api("GET", list_path, params=filter_params)["results"]
    if results:
        return results[0]
    created = api("POST", list_path, payload)
    print(f"  + created {label}")
    return created


def update(detail_path, payload):
    return api("PATCH", detail_path, payload)


# ---------------------------------------------------------------------------
# Static reference data
# ---------------------------------------------------------------------------

SITE = {"name": "Homelab", "slug": "homelab", "status": "active"}

MANUFACTURERS = ["Generic", "HP", "Dell", "Synology"]

DEVICE_ROLES = [
    ("Hypervisor", "hypervisor", "9b59b6"),
    ("Gateway", "gateway", "e74c3c"),
    ("NAS", "nas", "16a085"),
]

VM_ROLES = [
    ("K3s Control Plane", "k3s-control-plane", "2980b9"),
    ("K3s Worker", "k3s-worker", "3498db"),
    ("Infra Service", "infra-service", "27ae60"),
    ("App VM", "app-vm", "f39c12"),
]

DEVICE_TYPES = [
    # (manufacturer, model, slug)
    ("Generic", "Generic Server", "generic-server"),
    ("Generic", "Generic Router", "generic-router"),
    ("HP", "EliteDesk G9", "hp-elitedesk-g9"),
    ("HP", "ProLiant (legacy)", "hp-proliant-legacy"),
    ("Dell", "SFF Desktop", "dell-sff-desktop"),
    ("Synology", "DiskStation", "synology-diskstation"),
]

PREFIXES = [
    ("172.20.20.0/22", "Homelab primary network (parent)"),
    ("172.20.20.0/24", "Zone 1-3: core infra, hypervisors, OOB, k3s-prod"),
    ("172.20.21.0/24", "Zone 4: staging + test clusters (currently unprovisioned)"),
    ("172.20.22.0/24", "Zone 5: static dev VMs"),
    ("172.20.23.0/24", "Zone 6: dynamic DHCP pool"),
]

# Physical devices: name, ip, role_slug, device_type_slug, status, mac
DEVICES = [
    ("gateway", "172.20.20.1", "gateway", "generic-router", "active", None),
    ("atlas", "172.20.20.6", "hypervisor", "generic-server", "active", "14:5d:34:bf:76:2f"),
    ("dell-sff", "172.20.20.14", "hypervisor", "dell-sff-desktop", "active", "54:bf:64:76:93:5e"),
    ("pve1", "172.20.20.11", "hypervisor", "generic-server", "offline", None),
    ("nas-1", "172.20.20.5", "nas", "synology-diskstation", "active", "90:09:d0:23:02:89"),
    ("elitedesk-1", "172.20.20.7", "hypervisor", "hp-elitedesk-g9", "planned", None),
    ("proliant-1", "172.20.20.8", "hypervisor", "hp-proliant-legacy", "planned", None),
]

# Clusters: name -> host device name (None = no device yet)
CLUSTERS = [
    ("atlas", "atlas"),
    ("dell-sff", "dell-sff"),
    ("elitedesk-1", "elitedesk-1"),
    ("proliant-1", "proliant-1"),
]

# VMs: name, ip (None = dhcp), cluster, role_slug, status, mac, dns_name
VMS = [
    # atlas cluster - k3s-prod
    ("k3s-prod-worker-1", "172.20.20.101", "atlas", "k3s-worker", "active", "76:5a:f1:57:5a:01", "k3s-prod-worker-1.levangie.org"),
    ("k3s-prod-worker-2", "172.20.20.102", "atlas", "k3s-worker", "active", "76:5a:f1:57:5a:02", "k3s-prod-worker-2.levangie.org"),
    ("k3s-prod-worker-3", "172.20.20.103", "atlas", "k3s-worker", "active", "76:5a:f1:57:5a:03", "k3s-prod-worker-3.levangie.org"),
    ("k3s-prod-cp-1", "172.20.20.104", "atlas", "k3s-control-plane", "active", "76:5a:f1:57:5a:11", "k3s-prod-cp-1.levangie.org"),
    ("k3s-prod-cp-2", "172.20.20.105", "atlas", "k3s-control-plane", "active", "76:5a:f1:57:5a:12", "k3s-prod-cp-2.levangie.org"),
    ("k3s-prod-cp-3", "172.20.20.106", "atlas", "k3s-control-plane", "active", "76:5a:f1:57:5a:13", "k3s-prod-cp-3.levangie.org"),
    ("k3s-prod-worker-gpu-1", "172.20.20.107", "atlas", "k3s-worker", "active", "76:5a:f1:57:5a:07", "k3s-prod-worker-gpu-1.levangie.org"),
    ("warpgate", "172.20.20.25", "atlas", "infra-service", "active", "bc:24:11:e8:6d:32", "warpgate.levangie.org"),
    ("jotta-connect", "172.20.20.249", "atlas", "app-vm", "active", None, "jotta-connect.levangie.org"),
    ("proxyd", "172.20.20.247", "atlas", "infra-service", "offline", None, "proxyd.levangie.org"),
    ("sema", "172.20.20.28", "atlas", "infra-service", "offline", None, "sema.levangie.org"),
    ("pierce-mint-vm", None, "atlas", "app-vm", "active", "bc:24:11:e1:94:31", "pierce-mint-vm.levangie.org"),
    # dell-sff cluster - core infra
    ("caddy-srv", "172.20.20.3", "dell-sff", "infra-service", "active", "bc:24:11:74:f9:e4", "caddy.levangie.org"),
    ("technitium", "172.20.20.4", "dell-sff", "infra-service", "active", "bc:24:11:b5:ac:bc", "dns-1.levangie.org"),
    ("haos", "172.20.20.21", "dell-sff", "app-vm", "active", "02:5f:35:3f:e9:df", "homeassistant.levangie.org"),
    ("pbs", "172.20.20.22", "dell-sff", "infra-service", "active", "bc:24:11:85:22:a0", "pbs.levangie.org"),
    ("guacamole", "172.20.20.26", "dell-sff", "infra-service", "active", "bc:24:11:33:d9:80", "guacamole.levangie.org"),
    ("wg-easy", "172.20.20.248", "dell-sff", "infra-service", "active", "bc:24:11:61:f0:9a", "wireguard.levangie.org"),
    ("cloudflare", "172.20.20.254", "dell-sff", "infra-service", "active", "bc:24:11:b7:71:5e", "cloudflare-tunnel.levangie.org"),
    ("auth-srv", "172.20.20.18", "dell-sff", "infra-service", "offline", "76:e3:77:66:a7:72", None),
    ("affirm-srv", None, "dell-sff", "app-vm", "active", "bc:24:11:b1:ed:4a", "affirm-srv.levangie.org"),
    ("bambu-connect", None, "dell-sff", "app-vm", "active", "ba:a1:54:b8:c7:0c", "bambu-connect.levangie.org"),
    ("gamble-king", None, "dell-sff", "app-vm", "active", "bc:24:11:5d:63:aa", "gamble-king.levangie.org"),
    # planned new hardware
    ("k3s-prod-worker-4", "172.20.20.108", "elitedesk-1", "k3s-worker", "planned", None, "k3s-prod-worker-4.levangie.org"),
    ("k3s-prod-worker-5", "172.20.20.109", "dell-sff", "k3s-worker", "planned", None, "k3s-prod-worker-5.levangie.org"),
    ("k3s-prod-worker-6", "172.20.20.110", "proliant-1", "k3s-worker", "planned", None, "k3s-prod-worker-6.levangie.org"),
]

# Bare reserved/free IPs not yet tied to a device (status, ip, description)
BARE_IPS = [
    ("172.20.20.199", "reserved", "kube-vip: k3s-prod control plane API VIP"),
    ("172.20.20.200", "reserved", "Traefik prod ingress LoadBalancer VIP (fronts most app hostnames)"),
    ("172.20.20.203", "reserved", "Plex direct LoadBalancer VIP"),
    ("172.20.20.204", "reserved", "Factorio LoadBalancer VIP"),
    ("172.20.20.205", "reserved", "RustDesk LoadBalancer VIP"),
    ("172.20.20.60", "reserved", "iLO: proliant-1 (planned)"),
    ("172.20.20.61", "reserved", "iLO: proliant-2, if second ProLiant is racked"),
    ("172.20.20.250", "active", "Unidentified host, answered scan - verify before reassigning"),
    ("172.20.20.12", "deprecated", "pve2 - stale DNS name, origin unclear, not the new hardware"),
    ("172.20.20.13", "deprecated", "pve3 - stale DNS name, origin unclear, not the new hardware"),
    ("172.20.23.27", "active", "affirm-srv - DHCP lease, candidate for static reservation"),
    ("172.20.23.89", "active", "gamble-king - DHCP lease, candidate for static reservation"),
    ("172.20.23.94", "active", "pierce-mint-vm - DHCP, should be static 172.20.22.10 eventually"),
]

# VMs whose interface should carry a *reserved* target IP (future static
# migration) rather than being treated as a DHCP-reservation candidate.
# (name, target_ip) - target_ip is attached to the VM's eth0 with status=reserved.
RESERVED_TARGETS = [
    ("pierce-mint-vm", "172.20.22.10"),
]


def main():
    print("== Site ==")
    site = get_or_create("/dcim/sites/", {"slug": SITE["slug"]}, SITE, SITE["name"])

    print("== Manufacturers ==")
    mfr_by_name = {}
    for name in MANUFACTURERS:
        slug = name.lower().replace(" ", "-")
        mfr_by_name[name] = get_or_create(
            "/dcim/manufacturers/", {"slug": slug}, {"name": name, "slug": slug}, name
        )

    print("== Device roles ==")
    drole_by_slug = {}
    for name, slug, color in DEVICE_ROLES:
        drole_by_slug[slug] = get_or_create(
            "/dcim/device-roles/",
            {"slug": slug},
            {"name": name, "slug": slug, "color": color, "vm_role": False},
            name,
        )

    print("== VM roles (device roles usable by VMs) ==")
    for name, slug, color in VM_ROLES:
        drole_by_slug[slug] = get_or_create(
            "/dcim/device-roles/",
            {"slug": slug},
            {"name": name, "slug": slug, "color": color, "vm_role": True},
            name,
        )

    print("== Device types ==")
    dtype_by_slug = {}
    for mfr_name, model, slug in DEVICE_TYPES:
        dtype_by_slug[slug] = get_or_create(
            "/dcim/device-types/",
            {"slug": slug},
            {"manufacturer": mfr_by_name[mfr_name]["id"], "model": model, "slug": slug},
            model,
        )

    print("== Prefixes ==")
    for prefix, description in PREFIXES:
        get_or_create(
            "/ipam/prefixes/",
            {"prefix": prefix},
            {"prefix": prefix, "site": site["id"], "status": "active", "description": description},
            prefix,
        )

    print("== Physical devices ==")
    device_by_name = {}
    for name, ip, role_slug, dtype_slug, status, mac in DEVICES:
        dev = get_or_create(
            "/dcim/devices/",
            {"name": name},
            {
                "name": name,
                "site": site["id"],
                "role": drole_by_slug[role_slug]["id"],
                "device_type": dtype_by_slug[dtype_slug]["id"],
                "status": status,
            },
            name,
        )
        device_by_name[name] = dev
        if dev["status"]["value"] != status:
            update(f"/dcim/devices/{dev['id']}/", {"status": status})

        # Interface + IP
        iface = get_or_create(
            "/dcim/interfaces/",
            {"device_id": dev["id"], "name": "eth0"},
            {"device": dev["id"], "name": "eth0", "type": "1000base-t", "mac_address": mac},
            f"{name} eth0",
        )
        ipobj = get_or_create(
            "/ipam/ip-addresses/",
            {"address": f"{ip}/22"},
            {
                "address": f"{ip}/22",
                "status": "reserved" if status == "planned" else "active",
                "assigned_object_type": "dcim.interface",
                "assigned_object_id": iface["id"],
                "dns_name": f"{name}.levangie.org",
            },
            f"{name} -> {ip}",
        )
        if not dev.get("primary_ip4"):
            update(f"/dcim/devices/{dev['id']}/", {"primary_ip4": ipobj["id"]})

    print("== Clusters ==")
    ctype = get_or_create(
        "/virtualization/cluster-types/",
        {"slug": "proxmox-ve"},
        {"name": "Proxmox VE", "slug": "proxmox-ve"},
        "Proxmox VE",
    )
    cluster_by_name = {}
    for cname, host_device in CLUSTERS:
        cluster = get_or_create(
            "/virtualization/clusters/",
            {"name": cname},
            {"name": cname, "type": ctype["id"], "site": site["id"]},
            cname,
        )
        cluster_by_name[cname] = cluster

    print("== VMs ==")
    for name, ip, cluster_name, role_slug, status, mac, dns_name in VMS:
        vm = get_or_create(
            "/virtualization/virtual-machines/",
            {"name": name},
            {
                "name": name,
                "cluster": cluster_by_name[cluster_name]["id"],
                "role": drole_by_slug[role_slug]["id"],
                "status": status,
            },
            name,
        )
        if vm["status"]["value"] != status:
            update(f"/virtualization/virtual-machines/{vm['id']}/", {"status": status})

        vmiface = get_or_create(
            "/virtualization/interfaces/",
            {"virtual_machine_id": vm["id"], "name": "eth0"},
            {"virtual_machine": vm["id"], "name": "eth0", "mac_address": mac},
            f"{name} eth0",
        )

        if ip:
            ipobj = get_or_create(
                "/ipam/ip-addresses/",
                {"address": f"{ip}/22"},
                {
                    "address": f"{ip}/22",
                    "status": "reserved" if status == "planned" else "active",
                    "assigned_object_type": "virtualization.vminterface",
                    "assigned_object_id": vmiface["id"],
                    "dns_name": dns_name or "",
                },
                f"{name} -> {ip}",
            )
            if not vm.get("primary_ip4"):
                update(f"/virtualization/virtual-machines/{vm['id']}/", {"primary_ip4": ipobj["id"]})
        elif dns_name:
            # DHCP host: still record the hostname/mac association via interface,
            # no static IP object.
            pass

    print("== Reserved target IPs (future static migration) ==")
    vm_by_name = {v["name"]: v for v in api("GET", "/virtualization/virtual-machines/", params={"limit": 200})["results"]}
    for name, target_ip in RESERVED_TARGETS:
        vm = vm_by_name[name]
        vmiface = api(
            "GET", "/virtualization/interfaces/", params={"virtual_machine_id": vm["id"], "name": "eth0"}
        )["results"][0]
        get_or_create(
            "/ipam/ip-addresses/",
            {"address": f"{target_ip}/22"},
            {
                "address": f"{target_ip}/22",
                "status": "reserved",
                "assigned_object_type": "virtualization.vminterface",
                "assigned_object_id": vmiface["id"],
                "dns_name": "",
                "description": f"Future static target for {name}",
            },
            f"{name} reserved target -> {target_ip}",
        )

    print("== Bare / unassigned IPs ==")
    for ip, status, description in BARE_IPS:
        get_or_create(
            "/ipam/ip-addresses/",
            {"address": f"{ip}/22"},
            {"address": f"{ip}/22", "status": status, "description": description},
            f"{ip} ({description[:40]})",
        )

    print("\nDone.")


if __name__ == "__main__":
    main()
