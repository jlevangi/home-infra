# Documentation Index

This directory is organized around current operator workflows first. Historical migration and rollout notes are kept under `docs/archive/` so the active runbooks stay short and current.

## Getting Started

- [Repository Overview](getting-started/repository-overview.md)
  Start here for the architecture, environments, and source-of-truth layout.
- [Deployment Workflow](getting-started/deployment-workflow.md)
  Standard Terraform, Ansible, and ArgoCD flow for cluster and app deployment.

## Operations

- [Cluster Operations](operations/cluster-operations.md)
  Day-2 commands for cluster context switching, component deployment, health checks, and troubleshooting.
- [GitOps And ArgoCD](operations/gitops-and-argocd.md)
  Current path-based environment model, ArgoCD ownership, and rollout rules.
- [LXC Operations](operations/lxc-operations.md)
  Deploying and maintaining Ansible-managed LXC containers.
- [Network Topology](operations/network-topology.md)
  Switch port map, Proxmox host bonding, and the procedure for changing a host's network configuration.
- [LLM Default Model](operations/llm-default-model.md)
  How llama-cpp and automation clients coordinate the hot-loaded default model without hiding the real model name.

## Recovery

- [Backup And Restore](recovery/backup-and-restore.md)
  Longhorn backup model, disaster recovery commands, and manual restore mechanics.
- [Longhorn Troubleshooting](recovery/longhorn-troubleshooting.md)
  Common Longhorn recovery tasks for unhealthy volumes, replica imbalance, and cleanup.
- [Production Cutover Checklist](recovery/production-cutover-checklist.md)
  Pre-flight and post-flight checks for stage-to-prod changes.

## Post-Mortems

- [2026-05-16 — Longhorn Cascade Triggered by Failing SSD](post-mortems/2026-05-16-longhorn-cascade-failing-ssd.md)
  Hardware-rooted cascade where a failing SATA SSD in the `flash` ZFS pool's raidz1 caused Longhorn-wide flapping. Compounded by a stuck Longhorn engine upgrade, recurring tgtd orphans, and DIMM CE errors. Useful reference for Longhorn triage signals, known failure patterns, and recovery workarounds (PVC LimitRange, live engine upgrade, force-detach, etc.).

## Reference

- [Vault And External Secrets](reference/vault-and-eso.md)
  Current Vault and External Secrets bootstrap/reference workflow.
- [Traefik SSL](reference/traefik-ssl.md)
  Current ACME and Cloudflare-based TLS configuration.

## Workstation (WSL)

- [WSL/LLM Setup](WSL/LLM/README.md)
  Setting up `pierce-pc` as a standalone llama-swap workstation alongside the in-cluster `llama-cpp` deployment — Windows-side install, the WSL2 metrics sidecar, LibreChat direct endpoint wiring, and the operational fixes earned the hard way.

## Personal / Sensitive

- `SECRETS_RETRIEVAL.md`
  Left in place as-is for personal use.

## Archive

- [Archived Historical Docs](archive/)
  Older migration notes, rollout notes, and superseded runbooks that are kept for context only.
