# Cluster Platform Refactor Notes

## Summary

This branch consolidates the old K3s-specific platform-install logic and the
separate `k8s_platform` role into a single shared `cluster_platform` role, then
reorganizes the operator scripts around clearer ownership boundaries.

The main goal was to keep K3s node lifecycle work separate from in-cluster
platform service management so the same platform install flow can be reused for
both K3s and Talos-backed clusters.

## Decisions And Reasons

### Rename `k8s_platform` to `cluster_platform`

- `k8s_platform` was ambiguous and sounded like a full replacement for the K3s
  role.
- In practice, the role only managed shared in-cluster services after a cluster
  API was already reachable.
- Renaming it to `cluster_platform` makes the boundary explicit:
  `roles/k3s` handles node bootstrap, while `roles/cluster_platform` handles
  Longhorn, MetalLB, Traefik, ArgoCD, Vault, and related DNS/bootstrap tasks.

### Keep `roles/k3s` focused on host and node lifecycle

- The old `roles/k3s` mixed two responsibilities:
  K3s bootstrap on nodes, and in-cluster platform installation via Helm and
  `kubectl`.
- The refactor removed duplicated platform task files from `roles/k3s` so the
  role now stays focused on:
  - prepare and host tuning
  - master and worker install logic
  - K3s health/reinstall detection
  - K3s-specific handlers and post-install kubeconfig setup

### Run shared platform work from the controller with a fetched kubeconfig

- `kubernetes.core` and `kubectl` operations in the shared platform role should
  not depend on files existing on a remote K3s node.
- The K3s playbooks now fetch the reachable kubeconfig prepared on the first
  master and write it to a temporary file on the controller.
- This keeps the shared platform role kubeconfig-driven and makes it usable from
  both K3s and Talos entrypoints without coupling it to a specific node layout.

### Split the Longhorn and Traefik “god files”

- `longhorn.yml` and `traefik.yml` had grown into broad, hard-to-debug task
  files that mixed readiness checks, deployment, mutation, and validation.
- Longhorn is now split into:
  - `longhorn-readiness.yml`
  - `longhorn-install.yml`
  - `longhorn-node-config.yml`
  - `longhorn-storage-config.yml`
  - `longhorn-post-config.yml`
  - `longhorn-validation.yml`
- Traefik is now split into:
  - `traefik-install.yml`
  - `traefik-crds.yml`
  - `traefik-dashboard.yml`
  - `traefik-validation.yml`
- This was done to make debugging and targeted reruns practical without trying
  to redesign the whole behavior in one pass.

### Fix the Traefik CRD race instead of ignoring it

- Stage deploys were failing because Traefik custom resources were applied
  before the Traefik CRDs were established.
- The shared role now waits explicitly for the required CRDs before applying the
  dashboard, TLSStore, and ArgoCD IngressRoute resources.
- This removed the recurring `IngressRoute` / `Middleware` “no matches for
  kind” failure on stage.

### Keep Helm shell-driven for now, but improve correctness around it

- A full conversion to `kubernetes.core.helm` and `kubernetes.core.k8s` was not
  the right first step for this branch.
- The immediate priority was stabilizing deploys and consolidating ownership,
  not rewriting every platform task at once.
- The role still uses Helm and `kubectl` shell flows in many places, but the
  race-prone and state-sensitive parts were tightened up first.

### Improve K3s host-side preparation where the payoff was high

- Repeated iSCSI edits were replaced with a managed template for Longhorn’s
  `iscsid` settings.
- Swap disable logic in `prepare.yml` was made more structured.
- Master and worker install-state facts were clarified so reinstall decisions no
  longer depend on variables set in the same `set_fact` task.

### Reorganize scripts by responsibility

- The old `scripts/` layout mixed K3s deploys, Talos helpers, restore flows,
  and maintenance utilities at the top level.
- The new structure separates them into:
  - `scripts/k3s/`
  - `scripts/talos/`
  - `scripts/maintenance/`
- This makes operator intent clearer and reduces the chance of grabbing the
  wrong script path during normal operations or incident work.

### Update docs and repository guidance to match the new structure

- Script examples, playbook references, and operational docs were updated to use
  the new paths and role names.
- Vault credential docs and secrets-retrieval docs were moved into the main docs
  tree so the repo layout stays consistent with the current documentation model.

## Validation Performed

- `ansible/playbooks/k3s-deploy-cluster.yml --syntax-check`
- `ansible/playbooks/k3s-deploy-component.yml --syntax-check`
- `ansible/playbooks/k8s-bootstrap-cluster.yml --syntax-check`
- Stage validation with:
  - `bash scripts/k3s/deploy-cluster.sh --stage`
  - `bash scripts/k3s/deploy-component.sh --stage longhorn`
  - `bash scripts/k3s/deploy-component.sh --stage traefik`
  - `bash scripts/k3s/deploy-component.sh --stage argocd`

## Explicit Non-Goals

- No full migration of Longhorn task logic to `kubernetes.core` modules yet.
- No redesign of Talos lifecycle management beyond sharing the platform role.
- No broader secret-store architecture change in this branch; the attempted
  shared-Vault experiment was intentionally backed out.
