# Traefik certificate outage during K3s upgrade

**Date:** 2026-10-07  
**Environment:** Production  
**Impact:** HTTPS clients rejected the certificate for most application hostnames after Traefik moved during the K3s worker drain. HTTP routing, the MetalLB VIP, and application backends remained available.

## Summary

The production Traefik deployment had one replica and stored `/data/acme.json` on an `emptyDir`, even though the Helm release values declared persistence. Draining the node hosting Traefik replaced the pod and erased its ACME account and certificate state. The replacement pod attempted to issue all certificates again and hit Let's Encrypt's five-certificates-per-exact-set weekly limit. Traefik then served its generated self-signed certificate.

The K3s worker wave was stopped after `k3s-prod-worker-4`; no later worker was changed during the incident.

## Detection

Pierce reported that no applications were reachable. Direct checks showed:

- `172.20.20.200` and Traefik routing still returned application HTTP responses with certificate verification disabled.
- Normal TLS verification failed with Traefik's default self-signed certificate.
- Traefik logged ACME HTTP 429 responses with retry times on 2026-10-08.
- The live Deployment used `emptyDir` for `traefik-certs` and no `traefik` PVC existed.
- The Helm release manifest expected a `traefik` PVC, proving live drift from the declared release.

## Recovery

1. Stopped the K3s upgrade runner.
2. Reconciled Traefik through Helm, creating and binding a 1 GiB Longhorn PVC for ACME state.
3. Requested alternate, non-rate-limited certificate identifier sets and verified trusted HTTPS for all active domain families.
4. Exported the recovered certificates into Kubernetes TLS Secrets without logging key material.
5. Reconfigured the Traefik `TLSStore` to serve those Secrets.
6. Disabled Traefik's file-based ACME resolver and scaled Traefik to two replicas on different nodes.
7. Added a PodDisruptionBudget requiring one available replica.
8. Deleted one Traefik pod while issuing 25 trusted HTTPS requests; all 25 succeeded and the Deployment returned to 2/2 Ready.

## Root cause

The live Deployment had drifted from the Helm release manifest: the certificate volume was an `emptyDir`, while the release manifest declared a retained Longhorn PVC. A single replica made the latent persistence defect user-visible on its first worker drain.

## Corrective actions

- Manage renewal with cert-manager and Kubernetes TLS Secrets, which are safe for multiple Traefik replicas.
- Keep Traefik at two replicas with required hostname anti-affinity and a `minAvailable: 1` PodDisruptionBudget.
- Disable Traefik's local ACME resolver in production.
- Keep TLSStore certificate references declarative.
- Add HTTPS certificate verification and Traefik replica checks to K3s upgrade gates before resuming worker maintenance.

## Verification

- Two Ready Traefik pods were scheduled on separate workers.
- The Traefik Service exposed both pod endpoints.
- Trusted HTTPS succeeded for `levangie.dev`, `levangie.org`, `everlyera.com`, `gambleking.app`, and `kayleewatkins.com` application hosts.
- A live single-pod deletion produced zero failures across 25 consecutive trusted HTTPS requests.

Related: [K3s upgrade runbook](../operations/cluster-operations.md)
