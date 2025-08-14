# Longhorn Cross-Cluster Data Migration Guide

## Overview

This document describes the successful migration of production workloads from NFS hostPath storage to Longhorn distributed storage, including cross-cluster data migration patterns validated for production cluster rebuilds.

## Migration Summary

### Applications Migrated
1. **BookStack** (Production NFS → Production Longhorn) ✅
2. **Vaultwarden** (Production NFS → Test Longhorn) ✅

### Storage Architecture Transition
- **From:** NFS hostPath volumes with single-node dependency
- **To:** Longhorn distributed block storage with multi-node replication
- **Backup Strategy:** Shared NFS backup location for cross-cluster restore

## Migration Process

### Phase 1: Longhorn Deployment & Configuration

#### Key Configuration Changes Made
```yaml
# Dynamic replica count based on worker nodes
longhorn_replica_count: "{{ [groups[worker_group] | length, 3] | min }}"

# Shared backup configuration for cross-cluster access
longhorn_backup_shared_across_clusters: true
nfs_backup_target: "nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"
```

#### Critical Bug Fixes Applied
1. **NFS URL Format Fix:** Changed from `nfs://host/path` to `nfs://host:path` (colon separator required)
2. **Replica Count Override:** Added StorageClass recreation to override hardcoded 3-replica setting
3. **BackupTarget Resource:** Used proper Longhorn CRD instead of non-existent settings

### Phase 2: BookStack Migration (Production NFS → Production Longhorn)

**Data Profile:**
- Application Data: ~23MB
- Database Data: ~34MB
- Total Migration Time: ~5 minutes

**Migration Steps:**
1. Created backup of existing NFS data to `/tmp/bookstack-migration-backup`
2. Created Longhorn PVCs (5Gi each for app and database)
3. Scaled down applications safely (BookStack app + MariaDB)
4. Used temporary migration pod with both storage types mounted
5. Copied data using `cp -r` within the migration pod
6. Updated deployments to use Longhorn PVCs
7. Scaled applications back up

**Verification Results:**
- ✅ Both pods running and healthy (1/1 Ready)
- ✅ Longhorn volumes healthy with 2 replicas
- ✅ Application data preserved and accessible
- ✅ Database connectivity maintained

### Phase 3: Vaultwarden Cross-Cluster Migration (Production NFS → Test Longhorn)

**Data Profile:**
- SQLite Database: ~1.04MB (`db.sqlite3` + WAL files)
- Icon Cache: Multiple favicon files
- RSA Keys: Authentication credentials
- Total: ~2.3MB

**Migration Steps:**
1. **Data Extraction:** Created tar archive from production node
   ```bash
   ssh k3s-node-3 "cd /mnt/k3s-storage/apps/vaultwarden && tar czf /tmp/vaultwarden-prod-backup.tar.gz ."
   ```

2. **Cross-Cluster Transfer:** Copied archive via local workstation
   ```bash
   scp k3s-node-3:/tmp/vaultwarden-prod-backup.tar.gz /tmp/
   scp /tmp/vaultwarden-prod-backup.tar.gz k3s-test-node-1:/tmp/
   ```

3. **Test Cluster Preparation:** 
   - Scaled down test Vaultwarden safely
   - Created migration pod with Longhorn PVC mounted

4. **Data Import:** Streamed data directly into Longhorn volume
   ```bash
   cat /tmp/vaultwarden-prod-backup.tar.gz | kubectl exec -n vaultwarden vaultwarden-data-migrator -i -- tar xzf - -C /data/
   ```

5. **Application Restart:** Scaled test Vaultwarden back up

**Verification Results:**
- ✅ All production data accessible in test cluster
- ✅ SQLite database integrity maintained
- ✅ User accounts and vault data preserved
- ✅ Icon cache and RSA keys intact

## Technical Validation

### Longhorn Volume Health
```bash
# Production cluster volumes
kubectl get volumes -n longhorn-system
# Shows: healthy, 2 replicas, attached state

# Test cluster volumes  
kubectl get volumes -n longhorn-system
# Shows: healthy, 2 replicas, attached state
```

### Data Integrity Verification
- **Database Files:** SQLite + WAL files transferred completely
- **Application State:** All user data and configuration preserved
- **Authentication:** RSA keys and tokens maintained
- **Cache Data:** Icon cache fully transferred

### Performance Characteristics
- **Migration Speed:** ~2.3MB in under 30 seconds
- **Zero Downtime:** Possible with proper load balancing
- **Rollback Capability:** Original data preserved until verification complete

## Shared Backup Configuration

### NFS Backup Target Setup
```yaml
# Backup target configured for cross-cluster access
backup_target_url: "nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"

# Backup schedules
longhorn_backup_schedule_daily: "0 2 * * *"    # 2 AM daily
longhorn_backup_schedule_weekly: "0 3 * * 0"   # 3 AM Sunday
longhorn_backup_retain_daily: 7                # Keep 7 daily
longhorn_backup_retain_weekly: 4               # Keep 4 weekly
```

### Backup Migration Process
- Moved existing backups from `/test` to `/shared` folder
- Updated both clusters to use shared backup location
- Enables cross-cluster backup/restore capabilities

## Production Cluster Rebuild Strategy

### Validated Approach
1. **Stage Data in Test Cluster** ✅
   - All production data successfully migrated to test
   - Longhorn storage validated with real workloads
   - Cross-cluster data transfer process proven

2. **Rebuild Production VMs** (Next Phase)
   - Deploy fresh VMs with clean Debian installation
   - Apply Longhorn-enabled K3s configuration from day 1
   - No legacy NFS hostPath dependencies

3. **Data Migration Back to Production**
   - Use Longhorn backup/restore for clean migration
   - Leverage shared backup location for seamless transfer
   - Maintain data consistency throughout process

### Benefits of This Approach
- ✅ Clean infrastructure with no legacy baggage
- ✅ Proven migration process with real data
- ✅ Distributed storage from the start
- ✅ Robust backup and disaster recovery capabilities
- ✅ Simplified storage management

## Key Lessons Learned

### Configuration Requirements
1. **NFS URL Format:** Must use colon (`:`) separator, not slash
2. **Replica Count:** StorageClass requires recreation to override defaults
3. **BackupTarget Resource:** Use Longhorn CRD, not helm settings

### Migration Best Practices
1. **Always backup before migration** - Original data preserved until verified
2. **Use migration pods** - Simplifies data transfer between storage types
3. **Verify volume health** - Check Longhorn volume status post-migration
4. **Test application functionality** - Ensure data integrity and app connectivity

### Cross-Cluster Considerations
1. **Shared backup location** - Enables backup/restore between clusters
2. **Network access** - Ensure NFS connectivity from all cluster nodes
3. **Data verification** - Validate data integrity after cross-cluster transfer

## Next Steps

1. **Proceed with production VM rebuild** using validated Longhorn configuration
2. **Implement automated backup monitoring** for both clusters
3. **Test disaster recovery scenarios** using cross-cluster restore
4. **Document rollback procedures** for production safety

## Files Created/Modified

### Ansible Playbooks
- `ansible/playbooks/testing/migrate-bookstack-to-longhorn.yml`
- `ansible/playbooks/testing/migrate-vaultwarden-prod-to-test.yml`
- `ansible/playbooks/testing/migrate-longhorn-backups.yml`

### Configuration Updates  
- `ansible/group_vars/k3s_cluster.yml` - Longhorn UI enabled temporarily
- `ansible/roles/k3s/tasks/longhorn.yml` - NFS format fix and replica count logic

### Verification Commands
```bash
# Check volume health
kubectl get volumes -n longhorn-system

# Verify pod status
kubectl get pods -n bookstack
kubectl get pods -n vaultwarden

# Check PVC binding
kubectl get pvc -A
```

---
*Migration completed successfully on August 14, 2025*
*Production cluster rebuild ready to proceed*