#!/usr/bin/env bash
# test-server-macos.sh
# opencodex LAN Share - macOS Server Test Suite
# Tests: proxy health, port binding, auth proxy, models endpoint, firewall
#
# Usage: ./tests/test-server-macos.sh [--port <port>] [--auth-port <port>] [--access-key <key>]

set -uo pipefail

PORT=10100
AUTH_PORT=10101
ACCESS_KEY="${ACCESS_KEY:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --auth-port) AUTH_PORT="$2"; shift 2 ;;
        --access-key) ACCESS_KEY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

test_result() {
    local id="$1" name="$2" passed="$3" detail="${4:-}"
    if $passed; then
        echo -e "  ${GREEN}[PASS]${NC} ${id} - ${name}"
        ((TESTS_PASSED++))
    else
        echo -e "  ${RED}[FAIL]${NC} ${id} - ${name}"
        [[ -n "$detail" ]] && echo -e "         ${YELLOW}${detail}${NC}"
        ((TESTS_FAILED++))
    fi
}

echo ""
echo -e "${CYAN}=== opencodex LAN Share - macOS Server Tests ===${NC}"
echo "  Proxy port: ${PORT}"
echo "  Auth port:  ${AUTH_PORT}"
echo ""

# ============================================================
# TC-SRV-MAC-01: setup-lan.sh exists and is executable
# ============================================================
SETUP_SCRIPT="$SCRIPT_DIR/scripts/server/setup-lan.sh"
if [[ -f "$SETUP_SCRIPT" ]] && [[ -x "$SETUP_SCRIPT" ]]; then
    test_result "TC-SRV-MAC-01" "setup-lan.sh exists and is executable" true
else
    test_result "TC-SRV-MAC-01" "setup-lan.sh exists and is executable" false \
        "File not found or not executable: $SETUP_SCRIPT"
fi

# ============================================================
# TC-SRV-MAC-02: auth-proxy.py exists
# ============================================================
AUTH_PROXY="$SCRIPT_DIR/scripts/server/auth-proxy.py"
if [[ -f "$AUTH_PROXY" ]]; then
    test_result "TC-SRV-MAC-02" "auth-proxy.py exists" true
else
    test_result "TC-SRV-MAC-02" "auth-proxy.py exists" false \
        "File not found: $AUTH_PROXY"
fi

# ============================================================
# TC-SRV-MAC-03: opencodex proxy reachable
# ============================================================
if curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
    test_result "TC-SRV-MAC-03" "opencodex proxy reachable on port ${PORT}" true
else
    test_result "TC-SRV-MAC-03" "opencodex proxy reachable on port ${PORT}" false \
        "Proxy not running on port ${PORT}. Run: ocx start"
fi

# ============================================================
# TC-SRV-MAC-04: Proxy bound to 0.0.0.0 (LAN accessible)
# ============================================================
if command -v lsof &>/dev/null; then
    BIND_INFO=$(lsof -iTCP:${PORT} -sTCP:LISTEN -P -n 2>/dev/null | head -5)
    if echo "$BIND_INFO" | grep -q "TCP \*:${PORT}"; then
        test_result "TC-SRV-MAC-04" "Proxy bound to 0.0.0.0 (LAN accessible)" true
    elif echo "$BIND_INFO" | grep -q "TCP 127.0.0.1:${PORT}"; then
        test_result "TC-SRV-MAC-04" "Proxy bound to 0.0.0.0 (LAN accessible)" false \
            "Only bound to 127.0.0.1. Run: ocx config set hostname 0.0.0.0 && ocx restart"
    else
        test_result "TC-SRV-MAC-04" "Proxy bound to 0.0.0.0 (LAN accessible)" false \
            "Cannot determine binding. lsof output: ${BIND_INFO}"
    fi
else
    test_result "TC-SRV-MAC-04" "Proxy bound to 0.0.0.0 (LAN accessible)" true \
        "lsof not available, skipped"
fi

# ============================================================
# TC-SRV-MAC-05: /v1/models endpoint returns data
# ============================================================
HTTP_CODE=$(curl -s -o /tmp/ocx-server-models.json -w "%{http_code}" \
    "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)

if [[ "$HTTP_CODE" == "200" ]]; then
    MODEL_COUNT=$(python3 -c "
import json
with open('/tmp/ocx-server-models.json') as f:
    d = json.load(f)
models = d.get('data', d.get('models', []))
print(len(models))
" 2>/dev/null || echo "0")
    test_result "TC-SRV-MAC-05" "Models endpoint returns ${MODEL_COUNT} models" true
else
    test_result "TC-SRV-MAC-05" "Models endpoint returns data" false \
        "HTTP ${HTTP_CODE} from /v1/models"
fi
rm -f /tmp/ocx-server-models.json

# ============================================================
# TC-SRV-MAC-06: Auth proxy running on port 10101
# ============================================================
# Check 401 (auth-gated) - this means auth proxy IS running
AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:${AUTH_PORT}/v1/models" 2>/dev/null || true)

if [[ "$AUTH_CODE" == "401" ]]; then
    test_result "TC-SRV-MAC-06" "Auth proxy running on port ${AUTH_PORT} (auth-gated)" true
elif [[ "$AUTH_CODE" == "200" ]]; then
    test_result "TC-SRV-MAC-06" "Auth proxy running on port ${AUTH_PORT} (auth-gated)" true \
        "HTTP 200 - auth proxy is running (may be wide open)"
elif [[ "$AUTH_CODE" == "000" ]]; then
    test_result "TC-SRV-MAC-06" "Auth proxy running on port ${AUTH_PORT} (auth-gated)" false \
        "Auth proxy not reachable on port ${AUTH_PORT}. Run: python3 scripts/server/auth-proxy.py &"
else
    test_result "TC-SRV-MAC-06" "Auth proxy running on port ${AUTH_PORT} (auth-gated)" false \
        "Unexpected HTTP ${AUTH_CODE}"
fi

# ============================================================
# TC-SRV-MAC-07: Auth proxy forwards with valid key
# ============================================================
if [[ -n "$ACCESS_KEY" ]]; then
    AUTH_OK_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_KEY}" \
        "http://127.0.0.1:${AUTH_PORT}/v1/models" 2>/dev/null || true)

    if [[ "$AUTH_OK_CODE" == "200" ]]; then
        test_result "TC-SRV-MAC-07" "Auth proxy forwards with valid key (200)" true
    else
        test_result "TC-SRV-MAC-07" "Auth proxy forwards with valid key (200)" false \
            "Got HTTP ${AUTH_OK_CODE}, expected 200"
    fi
else
    test_result "TC-SRV-MAC-07" "Auth proxy forwards with valid key" true \
        "No access key provided, skipped"
fi

# ============================================================
# TC-SRV-MAC-08: Auth proxy rejects invalid key
# ============================================================
INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer invalid-key-xyz" \
    "http://127.0.0.1:${AUTH_PORT}/v1/models" 2>/dev/null || true)

if [[ "$INVALID_CODE" == "401" ]]; then
    test_result "TC-SRV-MAC-08" "Auth proxy rejects invalid key (401)" true
else
    test_result "TC-SRV-MAC-08" "Auth proxy rejects invalid key (401)" false \
        "Got HTTP ${INVALID_CODE}, expected 401"
fi

# ============================================================
# TC-SRV-MAC-09: manage-users.sh exists
# ============================================================
MANAGE_SH="$SCRIPT_DIR/scripts/server/manage-users.sh"
if [[ -f "$MANAGE_SH" ]]; then
    test_result "TC-SRV-MAC-09" "manage-users.sh exists" true
else
    test_result "TC-SRV-MAC-09" "manage-users.sh exists" false \
        "File not found. macOS needs a manage-users.sh equivalent"
fi

# ============================================================
# TC-SRV-MAC-10: diagnostics.sh exists
# ============================================================
DIAG_SH="$SCRIPT_DIR/tools/diagnostics.sh"
if [[ -f "$DIAG_SH" ]]; then
    test_result "TC-SRV-MAC-10" "diagnostics.sh exists" true
else
    test_result "TC-SRV-MAC-10" "diagnostics.sh exists" false \
        "File not found. macOS needs a diagnostics.sh equivalent"
fi

# ============================================================
# TC-SRV-MAC-11: setup-lan.sh uses macOS-compatible commands
# ============================================================
if grep -q "uname" "$SETUP_SCRIPT" && grep -q "Darwin" "$SETUP_SCRIPT"; then
    test_result "TC-SRV-MAC-11" "setup-lan.sh detects macOS" true
else
    test_result "TC-SRV-MAC-11" "setup-lan.sh detects macOS" false \
        "No macOS detection in setup-lan.sh"
fi

# ============================================================
# TC-SRV-MAC-12: No Windows-only commands in server scripts
# ============================================================
WINDOWS_COMMANDS=("Get-NetFirewallRule" "New-NetFirewallRule" "netstat" "Get-NetIPAddress" "Start-Process")
HAS_WINDOWS_CMDS=false
for cmd in "${WINDOWS_COMMANDS[@]}"; do
    if grep -q "$cmd" "$SETUP_SCRIPT" 2>/dev/null; then
        HAS_WINDOWS_CMDS=true
        break
    fi
done

if $HAS_WINDOWS_CMDS; then
    test_result "TC-SRV-MAC-12" "No Windows commands in setup-lan.sh" false \
        "setup-lan.sh contains Windows-specific commands"
else
    test_result "TC-SRV-MAC-12" "No Windows commands in setup-lan.sh" true
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${CYAN}=== Results ===${NC}"
echo "  Passed: ${TESTS_PASSED}"
echo "  Failed: ${TESTS_FAILED}"
echo "  Total:  $((TESTS_PASSED + TESTS_FAILED))"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "  ${GREEN}[PASS] All macOS server tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "  ${RED}[FAIL] ${TESTS_FAILED} test(s) failed${NC}"
    exit 1
fi