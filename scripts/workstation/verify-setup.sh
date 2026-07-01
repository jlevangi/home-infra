#!/bin/bash
# verify-setup.sh
# End-to-end sanity check for the pierce-pc WSL/LLM stack. Probes each
# layer in dependency order and exits non-zero on the first failure with
# a short diagnostic. Safe to re-run any time; makes no changes.
#
# See docs/WSL/LLM/setup.md Step 5.

set -u

LLAMASWAP_PORT=9080
SIDECAR_PORT=9090
WORKSTATION_HOST=pierce-pc.levangie.org
CLUSTER_CONTEXT=k3s-prod
GRAFANA_NS=monitoring
GRAFANA_SELECTOR='app.kubernetes.io/name=grafana'

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
header() { printf "\n${CYAN}== %s ==${NC}\n" "$*"; }
pass()   { printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
fail()   { printf "  ${RED}FAIL${NC}  %s\n" "$*" >&2; FAILED=1; }
skip()   { printf "  ${YELLOW}SKIP${NC}  %s\n" "$*"; }

FAILED=0

header "1. llama-swap.exe /running on :$LLAMASWAP_PORT"
if BODY=$(curl -s --max-time 5 "http://127.0.0.1:$LLAMASWAP_PORT/running" 2>&1) && [[ "$BODY" == *'"running"'* ]]; then
    pass "responded — $BODY"
else
    fail "no JSON response — llama-swap may be down (start it with: & \"C:\\Users\\pierc\\llama-cpp\\Start Llama-Swap.lnk\")"
fi

header "2. llama-swap host metrics on :$LLAMASWAP_PORT/metrics (requires v218+)"
if HTTP=$(curl -s --max-time 5 -o /tmp/lmw.met -w '%{http_code}' "http://127.0.0.1:$LLAMASWAP_PORT/metrics") && [[ "$HTTP" == 200 ]]; then
    COUNT=$(grep -c '^llamaswap_' /tmp/lmw.met || true)
    if (( COUNT > 0 )); then
        pass "$COUNT llamaswap_* value lines"
    else
        fail "HTTP 200 but no llamaswap_* values — version too old? (need v218+; check 'llama-swap --version')"
    fi
else
    fail "HTTP $HTTP — llama-swap < v218 doesn't expose /metrics; run: winget upgrade --id mostlygeek.llama-swap"
fi
rm -f /tmp/lmw.met

header "3. sidecar /healthz on :$SIDECAR_PORT"
if BODY=$(curl -s --max-time 3 "http://127.0.0.1:$SIDECAR_PORT/healthz") && [[ "$BODY" == 'ok' ]]; then
    pass "healthz ok"
else
    fail "no 'ok' from sidecar — check: systemctl --user status llama-metrics-sidecar"
fi

header "4. sidecar /metrics on :$SIDECAR_PORT (host + active-model)"
if curl -s --max-time 5 "http://127.0.0.1:$SIDECAR_PORT/metrics" > /tmp/sm.met; then
    SWAP=$(grep -c '^llamaswap_' /tmp/sm.met || true)
    INFO=$(grep -c '^llamacpp_active_model_info' /tmp/sm.met || true)
    LCPP=$(grep -c '^llamacpp:' /tmp/sm.met || true)
    if (( SWAP > 0 )); then
        pass "llamaswap_* lines: $SWAP   active_model_info: $INFO   llamacpp:*: $LCPP"
    else
        fail "sidecar returned no llamaswap_* — check sidecar log: journalctl --user -u llama-metrics-sidecar -n 30"
    fi
else
    fail "sidecar /metrics did not respond"
fi
rm -f /tmp/sm.met

header "5. LAN reachability: $WORKSTATION_HOST:$SIDECAR_PORT"
# Try from this host's LAN-facing IP first; fall back to cluster pod
if BODY=$(curl -s --max-time 5 "http://$WORKSTATION_HOST:$SIDECAR_PORT/healthz") && [[ "$BODY" == 'ok' ]]; then
    pass "$WORKSTATION_HOST:$SIDECAR_PORT reachable from this host"
else
    fail "$WORKSTATION_HOST:$SIDECAR_PORT not reachable from this host — check: DNS, Windows Firewall, .wslconfig networkingMode=mirrored"
fi

header "6. cluster Prometheus target"
skip "workstation llama-swap is intentionally not scraped by cluster Prometheus"

echo
if (( FAILED == 0 )); then
    printf "${GREEN}all checks passed${NC}\n"
    exit 0
else
    printf "${RED}one or more checks failed — see docs/WSL/LLM/troubleshooting.md${NC}\n"
    exit 1
fi
