# Cloudflare Tunnel route parity matrix

Status: **awaiting authoritative Zero Trust route export**.

Do not populate this matrix from Kubernetes Ingress resources alone. Every current ordered route must be exported through the Cloudflare API and accounted for exactly once before connector manifests or DNS resources are generated.

| hostname | current rule index | Cloudflare zone | DNS record | origin | K8s Ingress | exposure | migration wave | test |
|---|---:|---|---|---|---|---|---:|---|
| _pending account-scoped API inventory_ |  |  |  |  |  |  |  |  |

Allowed exposure classifications:

- `public and migrate`
- `intentionally internal-only; do not publish`
- `legacy/stale; remove after owner confirmation`
- `non-K3s origin; preserve exact LAN target or defer`

Completion gate:

- Current route count and order match the Zero Trust dashboard.
- The final catch-all rule is identified.
- Every hostname has one owner and one exposure classification.
- Every public K3s hostname maps to an existing Ingress.
- Every non-K3s route preserves its exact protocol, path, origin, and origin request options.
