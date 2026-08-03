# Immich PostgreSQL Renovate Major Upgrade

## Summary

On 2026-08-02, Renovate PR #55 changed the Immich PostgreSQL image from PostgreSQL 14 to PostgreSQL 16. ArgoCD applied the merged change, but PostgreSQL 16 could not start against the existing PostgreSQL 14 data directory. Immich was unavailable until the database image change was reverted.

## Impact

- Immich PostgreSQL entered `CrashLoopBackOff`.
- Immich Server entered `CrashLoopBackOff` because the database was unavailable.
- The machine-learning service remained healthy.
- The existing Longhorn PVC and database files were preserved unchanged.

## Detection

Post-deployment verification found ArgoCD stuck at `Progressing`. PostgreSQL logged:

```text
FATAL: database files are incompatible with server
DETAIL: The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.10.
```

## Recovery

The PostgreSQL image commit was reverted while retaining the Immich application upgrade to v3.1.0. PostgreSQL 14 restarted against the existing data directory, followed by a successful Immich Server startup.

## Preventive Action

Renovate now restricts `ghcr.io/immich-app/postgres` to PostgreSQL 14 tags. A future PostgreSQL major upgrade requires a separately planned `pg_upgrade` or logical dump/restore migration with backup and rollback validation.