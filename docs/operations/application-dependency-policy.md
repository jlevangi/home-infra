# Application dependency update policy

Renovate detects image and chart references, but it cannot infer application compatibility or data-migration requirements. Review updates by component role.

| Role | Examples | Policy |
|---|---|---|
| Application | Immich server, Affine, Paperless, n8n | Normal reviewed PR and application rollout verification |
| Helper | BusyBox init containers, curl hooks, Python metrics scripts | Review every affected application; shared-image PRs have broad blast radius |
| Authentication | oauth2-proxy | Dependency Dashboard approval and end-to-end login/redirect verification |
| Stateful dependency | PostgreSQL, MariaDB, Redis/Valkey, ClickHouse, Meilisearch, SurrealDB | Dashboard approval for same-major updates; major updates disabled and handled as migration projects |

## Lifecycle-coupled applications

| Application | Stateful dependencies | Compatibility constraint |
|---|---|---|
| Immich | Custom PostgreSQL 14, Valkey | PostgreSQL major is encoded in the image tag; migrate separately |
| Affine | PostgreSQL, Redis | Verify Affine support before either engine update |
| Hoarder | Meilisearch 1.6, Redis | Meilisearch requires dump/import or `--upgrade-db` |
| Paperless | MariaDB, Redis | Database/cache changes are separate from Paperless updates |
| n8n | PostgreSQL 16 | Preserve the database PVC and verify workflow executions |
| Plausible | PostgreSQL, ClickHouse 24.12 | ClickHouse changes require Plausible-specific validation |
| Open Notebook | SurrealDB 2 | SurrealDB major upgrades require a planned data migration |

## Review rules

1. Do not infer safety from a Renovate PR being mergeable.
2. Do not group an application update with a database-engine update.
3. Resolve rolling-tag digest updates to an upstream version before merging.
4. Render the production overlay; base-manifest changes may be production no-ops.
5. Merge one application at a time and verify ArgoCD revision, rollout, logs, endpoint behavior, and PVC continuity.
6. Treat database majors as maintenance projects with backups, migration, compatibility validation, and rollback plans.

Mend IaC scanning complements this policy by identifying configuration risks. It starts non-blocking and without issue creation so existing homelab exceptions can be triaged before findings become a required check.
