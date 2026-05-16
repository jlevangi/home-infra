# K3s Role Refactoring Plans

This directory contains structured improvement plans for the `ansible/roles/k3s` role. Each plan addresses a specific area of technical debt and is designed to be executed incrementally, with each plan being independently testable.

## Execution Order

Execute the plans in the order listed below, as later plans depend on the foundational changes introduced by earlier ones.

| # | Plan | Description | Estimated Effort |
|---|------|-------------|------------------|
| 1 | `01-shell-to-kubernetes-modules.md` | Replace `shell` calls with `kubernetes.core` and `kubernetes.core.helm` modules across all task files | Large |
| 2 | `02-decompose-longhorn-god-file.md` | Split `longhorn.yml` (963 lines) into 5 focused task files | Medium |
| 3 | `03-templatize-iscsi-configurations.md` | Replace `lineinfile` blocks in `main.yml` with Jinja2 templates | Small |
| 4 | `04-modernize-prepare.yml.md` | Replace procedural `shell`/`get_url` patterns with native Ansible modules | Small |
| 5 | `05-refine-k3s-installation-logic.md` | Streamline and standardize the K3s master/worker install/reinstall detection logic | Medium |

## Prerequisites

- The `kubernetes.core` Ansible collection must be installed on the control node:
  ```bash
  ansible-galaxy collection install kubernetes.core
  ```
- Each plan should be validated by running the K3s deployment playbook against a test cluster before applying to production.
- All changes are additive or refactor-only; no functional behavior is intended to change.

## How to Use These Plans

Each plan file contains:
- **Goal**: What the improvement aims to achieve
- **Current State**: The problematic patterns in the existing code
- **Target State**: The desired implementation
- **Affected Files**: Which files will be created or modified
- **Step-by-Step Tasks**: Actions to implement the plan
- **Validation**: How to verify the plan was applied correctly

Execute each plan sequentially, validating after each step before proceeding to the next.
