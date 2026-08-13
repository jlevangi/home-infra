"""Reconcile Technitium DNS/DHCP state from NetBox IPAM.

NetBox is the source of truth. This job is safe to run repeatedly:

DNS (levangie.org zone):
  - Every active NetBox IP address with a dns_name gets an A record.
  - Records this job creates are marked with a `_netbox.<name>` TXT
    record. Only records carrying that marker are ever updated or
    deleted, so hand-managed or other-owned records are never touched.
  - If a marked record's NetBox entry disappears, both the A and the
    TXT marker are removed.

DHCP (Technitium "DHCP Default" scope):
  - Any VM interface in NetBox that has a MAC address but no IP
    address object assigned to it is treated as "known infrastructure
    that wants a stable address." Its current dynamic lease (if any)
    is converted to a reserved lease, pinning it at whatever address
    it already has.
"""
import json
import logging
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("netbox-sync")

NETBOX_URL = os.environ["NETBOX_URL"].rstrip("/")
NETBOX_TOKEN = os.environ["NETBOX_TOKEN"]
TECHNITIUM_URL = os.environ["TECHNITIUM_URL"].rstrip("/")
TECHNITIUM_TOKEN = os.environ["TECHNITIUM_TOKEN"]
DNS_ZONE = os.environ.get("DNS_ZONE", "levangie.org")
DHCP_SCOPE = os.environ.get("DHCP_SCOPE", "DHCP Default")
OWNER_MARKER = "netbox-sync-managed"
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")


def netbox_get(path, params=None):
    url = f"{NETBOX_URL}/api{path}"
    results = []
    while url:
        req_url = url
        if params:
            req_url += "?" + urllib.parse.urlencode(params)
            params = None
        req = urllib.request.Request(req_url)
        req.add_header("Authorization", f"Token {NETBOX_TOKEN}")
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
        results.extend(data["results"])
        url = data.get("next")
    return results


def technitium(path, **params):
    params["token"] = TECHNITIUM_TOKEN
    url = f"{TECHNITIUM_URL}/api{path}?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        data = json.loads(e.read())
    if data.get("status") != "ok":
        log.warning("Technitium %s failed: %s", path, data)
    return data


def get_zone_records():
    data = technitium(
        "/zones/records/get", domain=DNS_ZONE, zone=DNS_ZONE, listZone="true"
    )
    return data.get("response", {}).get("records", [])


def sync_dns():
    log.info("=== DNS sync (zone: %s) ===", DNS_ZONE)

    ips = netbox_get(
        "/ipam/ip-addresses/", params={"status": "active", "limit": 500}
    )
    desired = {}
    for ip in ips:
        name = (ip.get("dns_name") or "").strip().rstrip(".")
        if not name:
            continue
        address = ip["address"].split("/")[0]
        desired[name] = address

    records = get_zone_records()
    existing_a = {r["name"]: r for r in records if r["type"] == "A"}
    marked_names = {
        r["name"][len("_netbox."):]
        for r in records
        if r["type"] == "TXT"
        and r["name"].startswith("_netbox.")
        and r["rData"].get("text") == OWNER_MARKER
    }

    # Create or fix records this job owns (or doesn't yet own but is free to claim)
    for name, address in desired.items():
        marker_name = f"_netbox.{name}"
        current = existing_a.get(name)
        owned = name in marked_names

        if current is None:
            log.info("create %s -> %s", name, address)
            if not DRY_RUN:
                technitium(
                    "/zones/records/add",
                    domain=name,
                    zone=DNS_ZONE,
                    type="A",
                    ipAddress=address,
                )
                technitium(
                    "/zones/records/add",
                    domain=marker_name,
                    zone=DNS_ZONE,
                    type="TXT",
                    text=OWNER_MARKER,
                )
            continue

        if not owned:
            log.info("skip %s -> %s (exists, not netbox-sync managed)", name, address)
            continue

        current_ip = current["rData"].get("ipAddress")
        if current_ip != address:
            log.info("update %s: %s -> %s", name, current_ip, address)
            if not DRY_RUN:
                technitium(
                    "/zones/records/delete",
                    domain=name,
                    zone=DNS_ZONE,
                    type="A",
                    ipAddress=current_ip,
                )
                technitium(
                    "/zones/records/add",
                    domain=name,
                    zone=DNS_ZONE,
                    type="A",
                    ipAddress=address,
                )

    # Remove records this job owns whose NetBox entry disappeared
    for name in marked_names - set(desired.keys()):
        current = existing_a.get(name)
        if current is None:
            continue
        log.info("delete %s (no longer in NetBox)", name)
        if not DRY_RUN:
            technitium(
                "/zones/records/delete",
                domain=name,
                zone=DNS_ZONE,
                type="A",
                ipAddress=current["rData"].get("ipAddress"),
            )
            technitium(
                "/zones/records/delete",
                domain=f"_netbox.{name}",
                zone=DNS_ZONE,
                type="TXT",
                text=OWNER_MARKER,
            )


def sync_dhcp():
    log.info("=== DHCP reservation sync (scope: %s) ===", DHCP_SCOPE)

    vm_ifaces = netbox_get(
        "/virtualization/interfaces/", params={"limit": 500}
    )
    ips = netbox_get("/ipam/ip-addresses/", params={"limit": 500})
    ifaces_with_ip = {
        ip["assigned_object"]["id"]
        for ip in ips
        if ip.get("assigned_object_type") == "virtualization.vminterface"
        and ip.get("assigned_object")
    }

    candidates = [
        iface
        for iface in vm_ifaces
        if iface.get("primary_mac_address") and iface["id"] not in ifaces_with_ip
    ]

    for iface in candidates:
        mac = iface["primary_mac_address"]["mac_address"]
        vm_name = iface["virtual_machine"]["name"]
        hw = mac.replace(":", "-").upper()
        log.info("reserve DHCP lease for %s (%s)", vm_name, mac)
        if not DRY_RUN:
            technitium(
                "/dhcp/leases/convertToReserved",
                name=DHCP_SCOPE,
                hardwareAddress=hw,
            )


def main():
    if DRY_RUN:
        log.info("DRY_RUN enabled - no changes will be made")
    sync_dns()
    sync_dhcp()
    log.info("done")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log.exception("sync failed")
        sys.exit(1)
