# Isolated Gitea recovery trial

Executed 2026-10-06 on VM303 `gitea-recovery-1`, `172.20.21.124`.
The restore made no production mutations and used no Docker, ingress, public DNS, ESO or Longhorn runtime dependencies. The controller fetched the approved local login credential for verification; the restored service does not need production Vault or Keycloak.

## Safety and restore

Use only `kubectl --kubeconfig /home/pierce/.kube/gitea-recovery.yaml` for trial operations. Assert the minified server is exactly `https://172.20.21.124:6443` before writes. Keep guest `inet recovery` nftables input/output/forward policy drop unchanged; outbound allowances are only pod/service CIDRs and the guest itself. Images must already be cached.

Checkpoint: `/home/pierce/backups/gitea/recovery-trial-20261006/gitea-data.tar`; SHA256 `1e78311e151535d40fadd8fb85a7b2a3bf0b9f22ef756db76970b268e09ef4c1`. Parent validated safe archive paths, readability, native SQLite and independent official SQL import. Archive/config/database/key are confidential; never print their contents.

1. On an empty trial namespace, apply `gitea-trial-resources.yaml`. Never re-extract over an existing trial database.
2. Offline local-path provisioning needs a cached helper image. The default busybox helper was not cached and could not pull under isolation. Change **only the trial** `kube-system/local-path-config` data `helperPod.yaml` to the following and restart the trial local-path provisioner to reload it:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: helper-pod
   spec:
     containers:
       - name: helper-pod
         image: docker.gitea.com/gitea@sha256:c168e7ccb767164793a67e1e874639488260795567337452b06292d1515bea12
         imagePullPolicy: Never
         securityContext:
           runAsUser: 0
   ```

   Helper root is needed only to create the host volume directory. Gitea and restore run UID/GID1000 with fsGroup1000. Do not weaken firewall or enable pulls.
3. Wait for `restore` Ready. Stream the checkpoint on stdin to `kubectl ... -n gitea-recovery exec -i restore -- sh -ec 'test ! -e /var/lib/gitea/config/app.ini; tar -C /var/lib/gitea -xpf -'`. Preserve the full tree, SQLite sidecars and encryption material. The immutable source archive is not modified.
4. Offline fixture checks: `git --git-dir=/var/lib/gitea/git/repositories/hermes/recovery-pilot-20261006.git fsck --full` and `show-ref`. Both main and recovery-baseline tag must equal `1a9058d88c04029c25b9fd0ef2e57119a6e35344`.
5. Inspect `gitea admin auth list --config /var/lib/gitea/config/app.ini`. Attempted supported CLI deletion of copied Keycloak source ID1 failed because users still reference it. v28 update-oauth has no disable flag. **OIDC source removal is not proven.** No user deletion, password reset or direct SQL mutation was performed. Firewall blocks discovery/auth; production OIDC bootstrap is never run.
6. Delete only helper pod `restore`, then apply `gitea-trial-web.yaml`; wait for deployment rollout. It runs image setup against existing app.ini then web, without production wrapper/Secret. Missing app.ini or secret_key fails startup rather than generating replacements. Trial settings disable installer/signup/SSH/actions/mirrors/mail/webhooks/migrations/update checks; ROOT_URL is loopback.
7. Run `python3 scripts/maintenance/verify-gitea-trial.py`. It reads only approved `Gitea - Hermes` human credentials through scoped vw-get. Controller reads existing Vault master credential in memory using a read-only production Secret/API read; nothing is passed into the restored application. Never rotate credentials. The verifier binds port-forward on 127.0.0.1 only, tests local web login, authenticated APIs, authenticated mirror clone through askpass (no credential URLs/argv/files), deletes/recreates the trial pod and repeats checks. Temporary clones/askpass scripts are removed and port-forwards terminated.

## Executed evidence

`/tmp/gitea-recovery-results.json` records PASS before and after pod replacement for health/database/cache, local web login, authenticated user API, exact branches/tags, recovery-check.txt blob, issue title, authenticated mirror clone and clone fsck. Offline restored bare-repo fsck passed separately.

Old pod UID: `bc6dabf1-d718-4d04-82c3-3e0523798925`; replacement UID: `83b8ed15-c386-4aee-b89d-2f8e6c2dd9cc`.

Limits: baseline contains only issue title, not body/ID; no attachment fixture exists. These are not full issue/attachment recovery proofs. Copied Keycloak source remains due supported CLI restriction. v28 warns legacy avatar flags no longer take effect; firewall is the real outbound boundary. Local-path PVC is single-node test storage, not HA or disaster-resistant backup. Trial is left running with no exposed Service/Ingress and no active port-forward; removal of PVC/namespace/VM requires separate cleanup approval.
