# Vault Raft cluster-cert-drift recovery

## Symptom

After a cluster restart (cluster reboot, network event, simultaneous pod
restarts), Vault never elects a Raft leader even though every pod is
unsealed. The `vault-unseal.yml` playbook gets through all its unseal tasks
but fails the "Login to Vault" step with 12 retries exhausted; the active
service has no endpoints.

Confirming diagnostics:

```bash
# All pods unsealed, all in standby:
for i in 0 1 2; do
  kubectl exec -n vault-raft vault-raft-$i -- vault status | grep -E "Sealed|HA Mode"
done

# Inter-pod TLS handshake fails on cluster RPC port 8201:
kubectl logs -n vault-raft vault-raft-0 --tail=50 | grep "tls: unrecognized name"
```

Expected output of the second command (each line indicates a refused vote):

```
[ERROR] storage.raft: failed to make requestVote RPC: target="..." error="remote error: tls: unrecognized name"
```

## Root cause

Vault auto-generates an internal TLS certificate for cluster RPC (port
8201) and stores it inside its own encrypted core data. That cert's
SNI/SAN matches whatever `VAULT_CLUSTER_ADDR` (env var) was in effect
when the cert was issued by the then-active node.

If `VAULT_CLUSTER_ADDR` later changes — chart upgrade with a different
template default, a manual values change, a migration between
environments — the new pods advertise a different cluster address than
what's baked into the stored cert. Inter-pod connections present the
new SNI; the receiving pod's cert doesn't match → `unrecognized_name`
TLS alert → no votes accepted → no leader.

Only an active leader can regenerate the cluster cert. The cluster cert
is needed to elect a leader. Chicken and egg.

## Prevention

The prod and stage Vault Helm values pin `server.ha.clusterAddr` explicitly so
a chart upgrade can't silently shift the address. Don't remove that line
without understanding the consequence.

## Recovery (automated)

The standard maintenance wrappers now enable this recovery path by default:

```bash
./scripts/maintenance/recover-vault.sh --prod
./scripts/maintenance/restart-k3s-cluster.sh --prod
./scripts/maintenance/power-on-k3s-cluster.sh --prod
```

Those scripts still only perform destructive follower-data recovery after the
playbook has detected the exact no-leader plus `tls: unrecognized name`
signature. To force detection-only behavior for debugging, pass
`--no-cluster-cert-recovery` to the wrapper script.

When running the playbook directly, pass the recovery flag explicitly:

```bash
ansible-playbook ansible/playbooks/maintenance/vault-unseal.yml \
  -e kubectl_context=k3s-prod \
  -e vault_recover_cluster_cert=true
```

The playbook will:

1. Detect the no-leader + TLS-mismatch state via `vault status` and log search
2. Scale `vault-raft` StatefulSet to 0
3. Spawn a temporary `vault-cluster-cert-recovery` pod mounting all 3 PVCs
4. Wipe `/vault/data` on follower PVCs (`vault-raft-1`, `vault-raft-2`)
5. Write a single-node `peers.json` on the primary PVC (`vault-raft-0`)
6. Scale to 1, unseal the bootstrap pod → it elects itself leader and
   regenerates the cluster cert against the *current* `VAULT_CLUSTER_ADDR`
7. Scale back to 3 → followers boot empty, `retry_join` finds the
   leader, get a Raft snapshot, unseal, rejoin
8. Verify `vault operator raft list-peers` shows 3 voters
9. Proceed with the normal Login + Kubernetes auth refresh

No data loss occurs — Raft replicated everything to all 3 nodes before
the cluster broke, so wiping the followers just discards stale duplicates.

## Longhorn replica strategy for Vault Raft

Vault Raft volumes use the dedicated `longhorn-vault-raft` StorageClass with
`numberOfReplicas: "1"` by design. Vault already keeps the logical data set on
three anti-affined Raft voters. Adding Longhorn-level replicas to each voter
made every Vault write fan out through two replication systems and, during the
2026-05-23 storage cascade, Longhorn replica rebuilds produced enough I/O
pressure to time out Vault engines and trigger repeated reseals.

The intended durability model is:

- **Short-term pod/node loss:** Vault Raft remains available with quorum as long
  as two of the three voters are healthy.
- **Single Vault PV loss:** Replace or wipe the affected follower data dir; the
  empty pod rejoins through `retry_join` and receives a Raft snapshot from the
  leader.
- **Cluster/data disaster:** Restore from Longhorn/NFS backups using the normal
  recovery runbooks.

Do not raise `longhorn-vault-raft` above one replica unless the extra Longhorn
rebuild risk has been explicitly accepted.

## Recovery (manual)

If the playbook automation can't reach the cluster or you're debugging
the recovery itself, the procedure is:

```bash
NS=vault-raft
SS=vault-raft
PRIMARY=vault-raft-0
PODS=(vault-raft-0 vault-raft-1 vault-raft-2)
FOLLOWERS=(vault-raft-1 vault-raft-2)

# 1. Snapshot the broken state for reference
kubectl exec -n $NS vault-raft-0 -- vault status

# 2. Scale down
kubectl scale -n $NS statefulset $SS --replicas=0
kubectl wait -n $NS --for=delete pod -l app.kubernetes.io/name=vault --timeout=2m

# 3. Spawn recovery pod with all 3 PVCs mounted
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vault-cluster-cert-recovery
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: recover
      image: alpine:3.19
      command: ["sh","-c","sleep 900"]
      volumeMounts:
        - { name: d0, mountPath: /d0 }
        - { name: d1, mountPath: /d1 }
        - { name: d2, mountPath: /d2 }
  volumes:
    - name: d0
      persistentVolumeClaim: { claimName: data-vault-raft-0 }
    - name: d1
      persistentVolumeClaim: { claimName: data-vault-raft-1 }
    - name: d2
      persistentVolumeClaim: { claimName: data-vault-raft-2 }
EOF

kubectl wait -n $NS --for=condition=Ready pod/vault-cluster-cert-recovery --timeout=2m

# 4. Wipe followers
kubectl exec -n $NS vault-cluster-cert-recovery -- sh -c 'rm -rf /d1/* /d2/*'

# 5. Write single-node peers.json on the primary's data dir
kubectl exec -i -n $NS vault-cluster-cert-recovery -- sh -c 'cat > /d0/raft/peers.json' <<'JSON'
[
  {"id": "vault-raft-0", "address": "vault-raft-0.vault-raft-internal:8201", "non_voter": false}
]
JSON

# 6. Cleanup recovery pod
kubectl delete pod -n $NS vault-cluster-cert-recovery --grace-period=10

# 7. Bring up the bootstrap pod
kubectl scale -n $NS statefulset $SS --replicas=1
kubectl wait -n $NS --for=condition=Ready=False pod/$PRIMARY --timeout=2m  # Running but sealed

# 8. Unseal it with the keys from the vault-init secret
KEY1=$(kubectl get secret vault-init -n $NS -o jsonpath='{.data.unseal-key-1}' | base64 -d)
KEY2=$(kubectl get secret vault-init -n $NS -o jsonpath='{.data.unseal-key-2}' | base64 -d)
KEY3=$(kubectl get secret vault-init -n $NS -o jsonpath='{.data.unseal-key-3}' | base64 -d)
for K in "$KEY1" "$KEY2" "$KEY3"; do
  kubectl exec -n $NS $PRIMARY -- vault operator unseal "$K"
done

# 9. Wait for HA Mode=active
kubectl exec -n $NS $PRIMARY -- vault status | grep "HA Mode"

# 10. Scale back up; followers boot empty, retry_join finds the leader
kubectl scale -n $NS statefulset $SS --replicas=3

# 11. Unseal each follower as it comes up
for POD in "${FOLLOWERS[@]}"; do
  kubectl wait -n $NS --for=jsonpath='{.status.phase}'=Running pod/$POD --timeout=2m
  for K in "$KEY1" "$KEY2" "$KEY3"; do
    kubectl exec -n $NS $POD -- vault operator unseal "$K"
  done
done

# 12. Verify the cluster has 3 voters
ROOT=$(kubectl get secret vault-init -n $NS -o jsonpath='{.data.root-token}' | base64 -d)
kubectl exec -n $NS $PRIMARY -- sh -c "VAULT_TOKEN='$ROOT' vault operator raft list-peers"
```

## Reference

- Vault docs: [Recovery using peers.json](https://developer.hashicorp.com/vault/docs/concepts/integrated-storage#manual-recovery-using-peers-json)
- Incident: 2026-05-21 — first occurrence in prod after the atlas SATA
  adapter physical swap caused multiple host reboots in quick succession
- Beads: `home-infra-at9` (automation), `home-infra-6qy` (no-leader alert)
