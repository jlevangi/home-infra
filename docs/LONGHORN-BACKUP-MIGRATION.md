# Longhorn Storage: Backup and Migration Guide

This guide explains Longhorn's storage structure and provides comprehensive methods for backing up and migrating data in your K3s cluster.

## 📁 Longhorn Storage Structure

### File Types Explained

**`.img` files**: These are the actual volume data files - sparse disk images containing your data
- `volume-head-000.img` - The current active data (e.g., 524MB for BookStack DB)
- Additional numbered files for snapshots when created

**`.meta` files**: Metadata files that track volume information
- `volume.meta` - Volume-level metadata (size, head pointer, dirty state, sector size)
- `volume-head-000.img.meta` - Image-level metadata (creation time, parent snapshot info)

### Directory Structure
```
/var/lib/longhorn/replicas/
├── pvc-{uuid}-{replica-id}/          # Each PVC gets a unique directory
│   ├── volume-head-000.img           # Current data (sparse disk image)
│   ├── volume-head-000.img.meta      # Image metadata
│   └── volume.meta                   # Volume metadata
```

### Key Concepts
- Each volume has **multiple replicas** (configured as 2 for test, 3 for prod) distributed across different nodes
- Replicas provide data redundancy and high availability
- Storage is block-level, not file-level like NFS
- Volumes can be dynamically resized and snapshotted

## 🔄 Backup & Migration Methods

### Method 1: Application-Level Backup (Recommended for Config Files)

Best for: Configuration files, small data sets, cross-cluster migration

```bash
# Copy FROM container TO local machine
kubectl cp namespace/pod-name:/path/in/container ./local-backup-folder

# Example: Backup Homepage config
kubectl cp homepage/homepage-deployment-xxx:/app/config ./homepage-backup

# Copy TO container FROM local machine
kubectl cp ./local-backup-folder namespace/pod-name:/path/in/container

# Example: Restore Homepage config
kubectl cp ./homepage-backup homepage/homepage-deployment-xxx:/app/config
```

**Advantages:**
- Simple and straightforward
- Works across different storage systems
- Perfect for config files and small datasets
- No storage system dependencies

**Use Cases:**
- Migrating Homepage configurations
- Backing up small application configs
- Moving data between different clusters

### Method 2: Longhorn Native Snapshots (Best for Databases)

Best for: Database backups, full volume recovery, point-in-time snapshots

#### Via Longhorn UI:
```bash
# Access Longhorn UI (replace with your node IP)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Navigate to http://localhost:8080
```

#### Via kubectl:
```bash
# Create a snapshot
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta1
kind: VolumeSnapshot
metadata:
  name: bookstack-db-backup-$(date +%Y%m%d-%H%M%S)
  namespace: longhorn-system
spec:
  volumeName: pvc-d3b94ec7-7895-431b-83b5-d1d370b342a1
EOF

# List snapshots
kubectl get volumesnapshot -n longhorn-system

# Create recurring backup schedule
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta1
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"  # Daily at 2 AM
  task: "backup"
  groups:
  - default
  retain: 7  # Keep 7 backups
EOF
```

**Advantages:**
- Block-level snapshots (very fast)
- Space-efficient (only stores changes)
- Can restore entire volumes
- Automated scheduling available

**Use Cases:**
- Database backups (MariaDB, PostgreSQL)
- Full application state snapshots
- Disaster recovery preparation

### Method 3: PVC Cloning (Best for Testing/Staging)

Best for: Creating test environments, migrating between namespaces

```bash
# Clone an existing PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: homepage-config-clone
  namespace: homepage
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: homepage-config-pvc
    kind: PersistentVolumeClaim
EOF
```

**Advantages:**
- Creates identical copy of volume
- Maintains file permissions and structure
- Good for creating staging environments

**Use Cases:**
- Creating test environments
- Migrating between namespaces
- Rapid environment provisioning

### Method 4: Direct Volume Access (Advanced)

Best for: Bulk operations, file-level access, troubleshooting

```bash
# Create a utility pod to access the volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: volume-backup-utility
  namespace: homepage
spec:
  containers:
  - name: utility
    image: alpine:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: source-volume
      mountPath: /source
    - name: backup-volume
      mountPath: /backup
  volumes:
  - name: source-volume
    persistentVolumeClaim:
      claimName: homepage-config-pvc
  - name: backup-volume
    hostPath:
      path: /tmp/backups
  restartPolicy: Never
EOF

# Execute backup operations
kubectl exec volume-backup-utility -- sh -c "
  mkdir -p /backup/homepage-$(date +%Y%m%d)
  cp -r /source/* /backup/homepage-$(date +%Y%m%d)/
  tar -czf /backup/homepage-$(date +%Y%m%d).tar.gz -C /backup homepage-$(date +%Y%m%d)
"

# Copy backup to local machine
kubectl cp homepage/volume-backup-utility:/backup/homepage-20250813.tar.gz ./homepage-backup.tar.gz

# Cleanup
kubectl delete pod volume-backup-utility -n homepage
```

**Advantages:**
- Full file-system access
- Can perform complex operations
- Good for bulk file operations

**Use Cases:**
- Complex file manipulations
- Bulk data migrations
- Troubleshooting storage issues

### Method 5: Cross-Cluster Migration

Best for: Moving between different Kubernetes clusters

#### Step 1: Export from Source Cluster
```bash
# Create compressed backup
kubectl exec -n homepage deployment/homepage -- tar -czf - /app/config > homepage-config-backup.tar.gz

# Or for database volumes, use a backup pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: export-pod
  namespace: bookstack
spec:
  containers:
  - name: exporter
    image: alpine:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: db-volume
      mountPath: /data
  volumes:
  - name: db-volume
    persistentVolumeClaim:
      claimName: bookstack-db-data-pvc
  restartPolicy: Never
EOF

kubectl exec export-pod -n bookstack -- tar -czf - /data > bookstack-db-backup.tar.gz
```

#### Step 2: Import to Target Cluster
```bash
# Switch to target cluster context
kubectl config use-context target-cluster

# Deploy applications first (they will create empty PVCs)
ansible-playbook -i inventory playbooks/k3s-deploy-apps.yml

# Import data to running containers
kubectl exec -n homepage deployment/homepage -- sh -c "rm -rf /app/config/* && tar -xzf -" < homepage-config-backup.tar.gz

# Or use import pod for databases
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: import-pod
  namespace: bookstack
spec:
  containers:
  - name: importer
    image: alpine:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: db-volume
      mountPath: /data
  volumes:
  - name: db-volume
    persistentVolumeClaim:
      claimName: bookstack-db-data-pvc
  restartPolicy: Never
EOF

kubectl exec import-pod -n bookstack -- sh -c "rm -rf /data/* && tar -xzf -" < bookstack-db-backup.tar.gz

# Restart applications to pick up restored data
kubectl rollout restart deployment/homepage -n homepage
kubectl rollout restart deployment/bookstack -n bookstack
kubectl rollout restart deployment/bookstack-mariadb -n bookstack
```

## 🎯 Practical Examples

### Example 1: Homepage Configuration Migration

```bash
# 1. Backup existing config
kubectl cp homepage/homepage-deployment-xxx:/app/config ./homepage-configs

# 2. Edit configurations locally as needed
# Edit files in ./homepage-configs/

# 3. Deploy to new cluster
kubectl cp ./homepage-configs homepage/homepage-deployment-xxx:/app/config/

# 4. Restart to apply changes
kubectl rollout restart deployment/homepage -n homepage

# 5. Create snapshot for future backups
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta1
kind: VolumeSnapshot
metadata:
  name: homepage-post-migration-$(date +%Y%m%d)
  namespace: longhorn-system
spec:
  volumeName: $(kubectl get pv $(kubectl get pvc homepage-config-pvc -n homepage -o jsonpath='{.spec.volumeName}') -o jsonpath='{.metadata.name}')
EOF
```

### Example 2: BookStack Database Backup

```bash
# 1. Create database snapshot
VOLUME_NAME=$(kubectl get pvc bookstack-db-data-pvc -n bookstack -o jsonpath='{.spec.volumeName}')
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta1
kind: VolumeSnapshot
metadata:
  name: bookstack-db-backup-$(date +%Y%m%d-%H%M%S)
  namespace: longhorn-system
spec:
  volumeName: $VOLUME_NAME
EOF

# 2. Verify snapshot created
kubectl get volumesnapshot -n longhorn-system | grep bookstack

# 3. Schedule recurring backups
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta1
kind: RecurringJob
metadata:
  name: bookstack-daily-backup
  namespace: longhorn-system
spec:
  cron: "0 3 * * *"  # Daily at 3 AM
  task: "backup"
  groups:
  - default
  retain: 14  # Keep 14 days of backups
EOF
```

## 🛠️ Troubleshooting Tips

### Common Issues and Solutions

1. **Pod stuck on volume attach**:
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   # Check for volume attachment errors
   kubectl get volumeattachment
   ```

2. **Volume degraded state**:
   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system
   # Check replica status in Longhorn UI
   ```

3. **Backup/restore failures**:
   ```bash
   kubectl logs -n longhorn-system -l app=longhorn-manager
   # Check Longhorn manager logs for errors
   ```

### Useful Commands

```bash
# Check all Longhorn volumes
kubectl get volumes.longhorn.io -n longhorn-system

# Check PVC to volume mapping
kubectl get pvc -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName,SIZE:.spec.resources.requests.storage

# Monitor volume health
kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,SIZE:.spec.size

# Access Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Then navigate to http://localhost:8080
```

## 📋 Best Practices

1. **Regular Snapshots**: Set up recurring jobs for critical data
2. **Test Restores**: Regularly verify backup integrity by testing restores
3. **Monitor Health**: Keep an eye on volume robustness status
4. **Size Appropriately**: Start with smaller initial sizes, let Longhorn expand as needed
5. **Use Application-Level Backups**: For config files and small datasets, application-level copies are often simpler
6. **Document Recovery Procedures**: Keep procedures documented and tested

## 🔗 References

- [Longhorn Documentation](https://longhorn.io/docs/)
- [Kubernetes Backup Best Practices](https://kubernetes.io/docs/concepts/cluster-administration/backup/)
- [PVC Cloning](https://kubernetes.io/docs/concepts/storage/volume-pvc-datasource/)