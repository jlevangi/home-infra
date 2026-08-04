#!/bin/bash
# Fail-closed grouped Longhorn PVC migration for multi-PVC applications.
#
# Encodes the proven Affine coordinated-wave sequence using the existing
# one-PVC playbook flags (migration_prepaused, migration_extra_controllers,
# migration_defer_acceptance).  Stops all application controllers once,
# migrates every PVC while stopped, accepts at the application level once,
# and creates exact post-cutover backups for every target.
#
# Usage:  scripts/k3s/migrate-longhorn-group.sh <group.yaml> [--dry-run]
#
# group.yaml shape:
#   target_env: prod
#   namespace: hoarder
#   child_app: hoarder
#   root_app: root-prod
#   integrity_command: 'kubectl ...'
#   controllers:
#     - {kind: Deployment, name: hoarder, replicas: 1}
#     - {kind: Deployment, name: hoarder-chrome, replicas: 1}
#   pvcs:
#     - pvc_name: hoarder-data-pvc
#       backup_name: backup-xxx
#       source_pool: unselected
#       target_pool: tank
#       target_pv: hoarder-data-pv
#       target_volume: hoarder-data
#     - ...
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PLAYBOOK="ansible/playbooks/k3s-migrate-longhorn-pvc.yml"
VAULT_FILE="/home/pierce/.ansible_vault_pass"
DRY_RUN=false

[ $# -ge 1 ] || { echo "Usage: $0 <group.yaml> [--dry-run]" >&2; exit 64; }
GROUP_FILE="$1"; shift
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

[ -f "$GROUP_FILE" ] || { echo "group file not found: $GROUP_FILE" >&2; exit 64; }
[ -f "$PLAYBOOK" ] || { echo "playbook not found: $PLAYBOOK" >&2; exit 64; }
[ -f "$VAULT_FILE" ] || { echo "vault password file not found: $VAULT_FILE" >&2; exit 64; }

# Parse group YAML with python3 (stdlib only)
parse() { python3 -c "import yaml,sys,json; print(json.dumps(yaml.safe_load(open('$GROUP_FILE'))))"; }
GROUP=$(parse)
ENV=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['target_env'])")
NS=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['namespace'])")
CHILD=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['child_app'])")
ROOT=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_app'])")
INTEGRITY=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['integrity_command'])")
PVC_COUNT=$(echo "$GROUP" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['pvcs']))")
CONTROLLERS_JSON=$(echo "$GROUP" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('controllers',[]),separators=(',',':')))")

[ "$ROOT" = "root-$ENV" ] || { echo "root_app must be root-$ENV" >&2; exit 64; }
[ "$PVC_COUNT" -ge 2 ] || { echo "group needs at least 2 PVCs" >&2; exit 64; }
[ -n "$INTEGRITY" ] || { echo "integrity_command is required" >&2; exit 64; }

# Validate each PVC entry
echo "$GROUP" | python3 -c "
import json,sys
g=json.load(sys.stdin)
for i,p in enumerate(g['pvcs']):
    for k in ('pvc_name','backup_name','source_pool','target_pool','target_pv','target_volume'):
        assert p.get(k), f'pvc[{i}] missing {k}'
    assert p['source_pool'] in ('flash','tank','unselected'), f'pvc[{i}] bad source_pool'
    assert p['target_pool'] in ('flash','tank'), f'pvc[{i}] bad target_pool'
    assert not p['target_pv'].startswith('lh-'), f'pvc[{i}] target_pv must not start with lh-'
    assert not p['target_volume'].startswith('lh-'), f'pvc[{i}] target_volume must not start with lh-'
    assert '-migrated' not in p['target_pv'], f'pvc[{i}] target_pv must not contain -migrated'
    assert '-migrated' not in p['target_volume'], f'pvc[{i}] target_volume must not contain -migrated'
pvs=[p['pvc_name'] for p in g['pvcs']]
assert len(pvs)==len(set(pvs)), 'duplicate pvc_name'
pvs_t=[p['target_pv'] for p in g['pvcs']]
assert len(pvs_t)==len(set(pvs_t)), 'duplicate target_pv'
vols_t=[p['target_volume'] for p in g['pvcs']]
assert len(vols_t)==len(set(vols_t)), 'duplicate target_volume'
print('group validation OK')
"

run() {
    echo "+ $*" >&2
    if $DRY_RUN; then return 0; fi
    ANSIBLE_JINJA2_NATIVE=true KUBECONFIG="/home/pierce/.kube/config" \
        ansible-playbook "$PLAYBOOK" "$@" -i localhost, \
        --vault-password-file "$VAULT_FILE"
}

echo "=== Group: $NS ($PVC_COUNT PVCs) ==="

# Phase 1: Preflight each PVC (first normal, rest prepaused)
for i in $(seq 0 $((PVC_COUNT - 1))); do
    PVC=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['pvc_name'])")
    BK=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['backup_name'])")
    if [ "$i" -eq 0 ]; then
        echo "=== Phase 1: Preflight [$i] $PVC (initial) ==="
        run --tags preflight-stop \
            -e "target_env=$ENV" -e "restore_namespace=$NS" -e "restore_pvc_name=$PVC" \
            -e "restore_child_app=$CHILD" -e "restore_root_app=$ROOT" \
            -e "migration_phase=preflight-stop" -e "restore_backup_name=$BK" \
            -e "migration_extra_controllers=$CONTROLLERS_JSON"
    else
        echo "=== Phase 1: Preflight [$i] $PVC (prepaused) ==="
        run --tags preflight-stop \
            -e "target_env=$ENV" -e "restore_namespace=$NS" -e "restore_pvc_name=$PVC" \
            -e "restore_child_app=$CHILD" -e "restore_root_app=$ROOT" \
            -e "migration_phase=preflight-stop" -e "restore_backup_name=$BK" \
            -e "migration_prepaused=true" \
            -e "migration_extra_controllers=$CONTROLLERS_JSON"
    fi
done

# Phase 2: Cutover each PVC (all deferred except last)
for i in $(seq 0 $((PVC_COUNT - 1))); do
    PVC=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['pvc_name'])")
    TPV=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['target_pv'])")
    TVOL=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['target_volume'])")
    SP=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['source_pool'])")
    TP=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['target_pool'])")
    # Find the state file for this PVC
    STATE_DIR="/var/tmp/longhorn-migration/${NS}-${PVC}"
    STATE_FILE=$(ls -t "$STATE_DIR"/state-*.json 2>/dev/null | head -1)
    [ -n "$STATE_FILE" ] || { echo "no state file for $PVC" >&2; exit 70; }

    ALLOW_POOL=""
    [ "$SP" != "$TP" ] && ALLOW_POOL="-e migration_allow_pool_change=true"

    if [ "$i" -lt $((PVC_COUNT - 1)) ]; then
        echo "=== Phase 2: Cutover [$i] $PVC (deferred) ==="
        run --tags cutover \
            -e "target_env=$ENV" -e "restore_namespace=$NS" -e "restore_pvc_name=$PVC" \
            -e "restore_child_app=$CHILD" -e "restore_root_app=$ROOT" \
            -e "migration_phase=cutover" -e "migration_state_file=$STATE_FILE" \
            -e "migration_target_pv=$TPV" -e "migration_target_volume=$TVOL" \
            -e "migration_source_pool=$SP" -e "migration_target_pool=$TP" \
            $ALLOW_POOL \
            -e "migration_defer_acceptance=true" \
            -e "migration_integrity_command=true"
    else
        echo "=== Phase 2: Cutover [$i] $PVC (final acceptance) ==="
        run --tags cutover \
            -e "target_env=$ENV" -e "restore_namespace=$NS" -e "restore_pvc_name=$PVC" \
            -e "restore_child_app=$CHILD" -e "restore_root_app=$ROOT" \
            -e "mutation_phase=cutover" -e "migration_state_file=$STATE_FILE" \
            -e "migration_target_pv=$TPV" -e "migration_target_volume=$TVOL" \
            -e "migration_source_pool=$SP" -e "migration_target_pool=$TP" \
            $ALLOW_POOL \
            -e "migration_integrity_command=$INTEGRITY"
    fi
done

# Phase 3: Create post-cutover backups for deferred members (target-bound acceptance)
for i in $(seq 0 $((PVC_COUNT - 2))); do
    PVC=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['pvc_name'])")
    TPV=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['target_pv'])")
    TVOL=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['target_volume'])")
    SP=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['source_pool'])")
    TP=$(echo "$GROUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['pvcs'][$i]['target_pool'])")
    STATE_DIR="/var/tmp/longhorn-migration/${NS}-${PVC}"
    STATE_FILE=$(ls -t "$STATE_DIR"/state-*.json 2>/dev/null | head -1)
    [ -n "$STATE_FILE" ] || { echo "no state file for $PVC" >&2; exit 70; }
    ALLOW_POOL=""
    [ "$SP" != "$TP" ] && ALLOW_POOL="-e migration_allow_pool_change=true"
    echo "=== Phase 3: Backup deferred [$i] $PVC ==="
    run --tags cutover \
        -e "target_env=$ENV" -e "restore_namespace=$NS" -e "restore_pvc_name=$PVC" \
        -e "restore_child_app=$CHILD" -e "restore_root_app=$ROOT" \
        -e "migration_phase=cutover" -e "migration_state_file=$STATE_FILE" \
        -e "migration_target_pv=$TPV" -e "migration_target_volume=$TVOL" \
        -e "migration_source_pool=$SP" -e "migration_target_pool=$TP" \
        $ALLOW_POOL \
        -e "migration_integrity_command=true"
done

echo "=== Group migration complete: $NS ==="