# Longhorn Volume Troubleshooting Guide

This guide documents common Longhorn volume issues and their resolution steps.

## Read-Only Filesystem / I/O Errors

### Symptoms

- Pod stuck in CrashLoopBackOff with high restart count
- Logs show `Read-only file system` errors
- Logs show `I/O error` when writing to `/config` or other mounted paths
- Readiness probe failures with `connection refused`

### Diagnosis Commands

```bash
# Check pod status and restart count
kubectl get pods -n <namespace> -o wide

# Check deployment status
kubectl get deployment -n <namespace>

# Check recent events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# Check pod logs for filesystem errors
kubectl logs <pod-name> -n <namespace> --tail=50

# Check PVC status
kubectl get pvc -n <namespace>

# Check Longhorn volume health
kubectl get volumes.longhorn.io -n longhorn-system | grep <app-name>

# Check Longhorn volume details
kubectl describe volume <volume-name> -n longhorn-system

# Check Longhorn replicas
kubectl get replicas.longhorn.io -n longhorn-system | grep <volume-name>
```

### Resolution Steps

#### Step 1: Force Delete Stuck Pods

If pods are stuck or in CrashLoopBackOff, force delete them:

```bash
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0
```

#### Step 2: Scale Down Old ReplicaSets

If old ReplicaSets are preventing new pods from starting (RWO volume contention):

```bash
# List replicasets
kubectl get replicasets -n <namespace>

# Scale down old replicaset
kubectl scale replicaset <old-replicaset-name> --replicas=0 -n <namespace>
```

#### Step 3: Detach and Reattach Volume

This is the key fix for filesystem corruption. Scale down to detach the volume, then scale back up:

```bash
# Scale deployment to 0 to detach volume
kubectl scale deployment <deployment-name> --replicas=0 -n <namespace>

# Wait for volume to detach (check status)
kubectl get volumes.longhorn.io <volume-name> -n longhorn-system -o jsonpath='{.status.state}'
# Should show: detached

# Scale back up to reattach volume
kubectl scale deployment <deployment-name> --replicas=1 -n <namespace>

# Wait for rollout to complete
kubectl rollout status deployment/<deployment-name> -n <namespace> --timeout=120s
```

#### Step 4: Verify Resolution

```bash
# Check pod is running and ready
kubectl get pods -n <namespace>

# Check logs for any remaining errors
kubectl logs <pod-name> -n <namespace> --tail=50

# Verify deployment is available
kubectl get deployment -n <namespace>
```

## Example: BookStack Recovery

Full command sequence used to recover BookStack from read-only filesystem:

```bash
# 1. Diagnose the issue
kubectl get pods -n bookstack -o wide
kubectl logs <bookstack-pod> -n bookstack --tail=50

# 2. Force delete stuck pod
kubectl delete pod <bookstack-pod> -n bookstack --force --grace-period=0

# 3. Scale down old replicaset if needed
kubectl get replicasets -n bookstack
kubectl scale replicaset bookstack-<old-hash> --replicas=0 -n bookstack

# 4. Detach volume by scaling to 0
kubectl scale deployment bookstack --replicas=0 -n bookstack

# 5. Wait for detach (about 15 seconds)
sleep 15
kubectl get volumes.longhorn.io bookstack-app-restored-volume -n longhorn-system -o jsonpath='{.status.state}'

# 6. Scale back up
kubectl scale deployment bookstack --replicas=1 -n bookstack

# 7. Wait for rollout
kubectl rollout status deployment/bookstack -n bookstack --timeout=120s

# 8. Verify
kubectl get pods -n bookstack
kubectl get deployment -n bookstack
```

## Root Causes

Common causes of read-only filesystem issues:

1. **Pod crash during write operation** - Filesystem inconsistency triggers read-only remount
2. **Node failure** - Unclean volume detach can corrupt filesystem
3. **Storage pressure** - Volume running out of space
4. **Longhorn replica issues** - Replica sync problems

## Prevention

- Ensure adequate storage capacity on volumes
- Monitor Longhorn volume health regularly
- Consider increasing replica count for critical volumes
- Set up alerts for pod restart counts

## Related Documentation

- [LONGHORN-BACKUP-MIGRATION.md](LONGHORN-BACKUP-MIGRATION.md)
- [LONGHORN-CROSS-CLUSTER-MIGRATION.md](LONGHORN-CROSS-CLUSTER-MIGRATION.md)
