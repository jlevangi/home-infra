# IMPORTANT NOTE — K3s datastore configuration

## TL;DR

`ansible/roles/k3s/defaults/main.yml` ships with `--cluster-init` in
`k3s_server_args`, which switches k3s from its default SQLite/kine backend
to **embedded etcd**. Embedded etcd is only appropriate for HA control
planes (≥3 server nodes). All three clusters in this repo (prod, stage,
test) run a single-master topology, so `--cluster-init` provides zero
HA benefit and introduces a hard dependency on very fast disk I/O.

The test and stage clusters explicitly override `k3s_server_args` to drop
`--cluster-init` (see `ansible/group_vars/k3s_cluster_test.yml` and
`ansible/group_vars/k3s_cluster_stage.yml`). **Production still inherits
the role default** and therefore still runs embedded etcd until we
deliberately rebuild it.

## Why this matters

Embedded etcd enforces a ~100ms fsync watchdog. When the storage layer
cannot meet that bound — which our local-lvm Proxmox storage cannot
reliably do during Longhorn + ArgoCD install spikes — etcd fails leader
election, the k3s process exits, systemd restarts it, and the service
enters a crash loop.

Symptoms observed on the test cluster before the override:

- `systemctl show k3s -p NRestarts` climbs above 15
- k3s journal shows: `"apply request took too long","took":"2.99s","expected-duration":"100ms"`
- `leaderelection lost: failed to renew lease kube-system/k3s-cloud-controller-manager`
- k3s API on 127.0.0.1:6443 intermittently refuses connections during
  Ansible post-install tasks, causing spurious CoreDNS / Helm failures
- Helm leaves releases stuck in `pending-install` state because the
  in-progress install was interrupted by a k3s restart

None of these are memory issues (the master had 2.8Gi free and no OOM
kills in dmesg). They are all downstream of etcd fsync starvation.

## Why SQLite/kine is the right choice here

- k3s defaults to SQLite (via kine) when `--cluster-init` is absent
- SQLite tolerates slower disks gracefully — no hard fsync watchdog
- No HA benefit is lost, because a 1-master cluster cannot be HA regardless
- SQLite uses less RAM than embedded etcd, which helps these 4GB test VMs
- The datastore is a single file under `/var/lib/rancher/k3s/server/db/`,
  which is easy to back up and inspect

## Switching between the two backends

The on-disk format of embedded etcd and SQLite is incompatible. You
**cannot** flip a running cluster from one to the other by editing
`k3s_server_args` and re-running the playbook. Either:

1. **Clean reinstall of k3s** on each node (fastest, preserves VMs):
   ```bash
   # On every node (master and workers)
   sudo /usr/local/bin/k3s-uninstall.sh         # master
   sudo /usr/local/bin/k3s-agent-uninstall.sh   # workers
   ```
   Then re-run the deploy playbook. This wipes all cluster state
   (Longhorn volumes, ArgoCD apps, etc.) so treat it as a full rebuild.

2. **Full VM rebuild** via Terraform:
   ```bash
   cd terraform/stacks/k3s/compact-3node/test
   terraform destroy -auto-approve
   terraform apply -auto-approve
   cd ../..
   ./scripts/deploy-k3s-cluster.sh --test
   ```

Either path requires restoring application data from backups afterward
if you care about it.

## Follow-up: fix the default

The long-term fix is to drop `--cluster-init` from
`ansible/roles/k3s/defaults/main.yml` entirely and only add it back per-
environment when an actual HA control plane (≥3 masters) is deployed.
That change is deferred out of this branch to keep the blast radius
contained — it would affect prod on the next rebuild and warrants its
own PR + stage validation cycle.

When ready:

1. Remove `--cluster-init` from `k3s_server_args` in
   `ansible/roles/k3s/defaults/main.yml`
2. Drop the now-redundant `k3s_server_args` override from
   `ansible/group_vars/k3s_cluster_test.yml` and
   `ansible/group_vars/k3s_cluster_stage.yml`
3. Schedule a prod rebuild window (Longhorn data must be backed up and
   restored — prod currently runs embedded etcd with real state)
