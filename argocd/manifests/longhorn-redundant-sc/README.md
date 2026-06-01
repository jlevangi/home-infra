# longhorn-singleton / longhorn-redundant StorageClass

Higher-redundancy Longhorn storage class for apps that **lack application-layer
HA** (single-pod, SQLite-backed, etc.). `longhorn-singleton` is the canonical
name; `longhorn-redundant` remains as a legacy alias during the PVC migration
window. Compared to the general/default path and `longhorn-media`:

| | longhorn-general / longhorn | longhorn-media | longhorn-singleton / longhorn-redundant |
|---|---:|---:|---:|
| numberOfReplicas | 3 | 3 | **3** |
| nodeSelector | (none) | media-storage | **general-storage** |
| Can place on GPU worker? | yes | yes | **no** |
| dataLocality | disabled | best-effort | disabled |
| Target apps | most things | Plex/Jellyfin media | SQLite-backed singletons |

## Why this exists

The May 2026 ssd3 adapter failure cascade exposed that single-pod SQLite-backed
apps (Jellyfin, Plex, Grafana) crash hard the moment their Longhorn volume goes
from `attached/degraded` to `attached/faulted`. Vault and other HA workloads
survive because they have application-layer redundancy across multiple pods.

Bumping these volumes to 3 replicas (lose 2 before fault) and excluding the
GPU worker (which is I/O-stressed by transcoding + llama-cpp) raises the bar
significantly.

The three volumes currently in this category have been **live-patched** with
matching settings via `kubectl patch` (see comments in their PVC manifests).
The patches survive cluster reboots but are not visible in the IaC tree. To
fully converge IaC and runtime state, **migrate each PVC to the canonical
`longhorn-singleton` class** using the procedure below.

## Migration procedure (one PVC at a time)

PVC `storageClassName` is immutable after binding, so migration requires a
new PVC + data copy. ~30 min per app, scheduled downtime for that one app.

```bash
# Variables you'll set per migration
APP_NS=jellyfin                              # or plex / monitoring
OLD_PVC=jellyfin-config-pvc                  # current PVC name
NEW_PVC=jellyfin-config-pvc-redundant        # transient name during copy
APP_DEPLOY=jellyfin                          # deployment name
VOLUME_SIZE=80Gi                             # match the source PVC

# 1. Snapshot the live volume to NFS backup (safety net)
kubectl annotate -n longhorn-system volume.longhorn.io/$OLD_PVC \
  longhorn.io/take-snapshot=pre-migration --overwrite

# 2. Scale the app to 0 so nothing else writes during copy
kubectl scale -n $APP_NS deployment $APP_DEPLOY --replicas=0
kubectl wait -n $APP_NS --for=delete pod -l app=$APP_DEPLOY --timeout=2m

# 3. Create the new PVC using longhorn-singleton
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
  namespace: $APP_NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-singleton
  resources:
    requests:
      storage: $VOLUME_SIZE
EOF

# 4. Spin up a sidecar pod that mounts BOTH PVCs, rsync the data
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-migrate-$APP_DEPLOY
  namespace: $APP_NS
spec:
  restartPolicy: Never
  containers:
    - name: rsync
      image: alpine:3.19
      command: ["sh", "-c"]
      args:
        - |
          apk add --no-cache rsync &&
          rsync -aHAX --info=progress2 /src/ /dst/ &&
          echo "rsync complete" &&
          sleep 60
      volumeMounts:
        - { name: src, mountPath: /src }
        - { name: dst, mountPath: /dst }
  volumes:
    - name: src
      persistentVolumeClaim:
        claimName: $OLD_PVC
    - name: dst
      persistentVolumeClaim:
        claimName: $NEW_PVC
EOF

# 5. Watch the copy
kubectl logs -n $APP_NS pvc-migrate-$APP_DEPLOY -f

# 6. After "rsync complete", swap PVC names in your manifests:
#    edit argocd/manifests/$APP/base/pvc.yaml — rename PVC to use $NEW_PVC's spec
#    edit deployment.yaml to point claimName at the new PVC
#    commit, push, let ArgoCD sync
#
#    OR for a faster cutover: rename the new PVC to match the old name
#    (delete old PVC first, then `kubectl edit pvc $NEW_PVC` to rename).

# 7. Scale the app back up
kubectl scale -n $APP_NS deployment $APP_DEPLOY --replicas=1

# 8. Verify, then delete the migration pod and the old PVC
kubectl delete pod -n $APP_NS pvc-migrate-$APP_DEPLOY
kubectl delete pvc -n $APP_NS $OLD_PVC
```

## Apps to migrate (in order of importance)

1. **Grafana** (2 GiB) — smallest, easiest, safest first test
2. **Plex config** (50 GiB) — medium
3. **Jellyfin config** (80 GiB) — largest, most disruptive

After all three migrate, the live `kubectl patch` markers can be removed
from the PVC manifests' comments since the live state matches IaC.

## Removing the live patches (post-migration)

Once a PVC is on `longhorn-singleton`, the Volume CRD's `numberOfReplicas` and
`nodeSelector` are automatically set from the SC at create time. No manual
patches needed.
