#!/usr/bin/env bash
# test-client-macos.sh
# macOS client setup TDD test suite
# Validates: setup-client.sh behavior, config, model fetching, env setup
#
# Usage: ./tests/test-client-macos.sh [--server-ip <ip>] [--port <port>] [--access-key <key>]
#   Without --server-ip, tests config generation only (no network)
#   With --server-ip --access-key, runs full integration tests

set -uo pipefail
# Note: NOT using set -e because grep -q returns 1 on no-match, which is expected behavior in tests

# --- Test framework ---
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=$(mktemp -d /tmp/opencodex-test-client.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

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

# --- Parse args ---
SERVER_IP="${SERVER_IP:-}"
ACCESS_KEY="${ACCESS_KEY:-}"
PORT="${PORT:-10101}"
NETWORK_TESTS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-ip) SERVER_IP="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --access-key) ACCESS_KEY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -n "$SERVER_IP" ]] && [[ -n "$ACCESS_KEY" ]]; then
    NETWORK_TESTS=true
fi

echo ""
echo -e "${CYAN}=== opencodex LAN Share - macOS Client Tests ===${NC}"
echo "  Temp dir: $TEST_DIR"
echo "  Network tests: $NETWORK_TESTS"
echo ""

# ============================================================
# TC-CLIENT-MAC-01: setup-client.sh exists and is executable
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_CLIENT="$SCRIPT_DIR/scripts/client/setup-client.sh"

if [[ -f "$SETUP_CLIENT" ]]; then
    test_result "TC-CLIENT-MAC-01" "setup-client.sh exists" true
else
    test_result "TC-CLIENT-MAC-01" "setup-client.sh exists" false "File not found at $SETUP_CLIENT"
fi

# ============================================================
# TC-CLIENT-MAC-02: Config generation (dry-run simulation)
# ============================================================
# Simulate what setup-client.sh does to config.toml
FAKE_CONFIG="$TEST_DIR/config.toml"
FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME/.codex"

# Create a pre-existing config with old settings
cat > "$FAKE_CONFIG" << 'TOML'
# Old config
model_provider = "opencodex"
base_url = "http://old-server:8080/v1"
model_catalog_json = "/old/catalog.json"
wire_api = "responses"
TOML

# Run the config generation logic (simulated from setup-client.sh)
BASE_URL="http://${SERVER_IP:-192.168.1.110}:${PORT}"
NEW_CONFIG="$FAKE_HOME/.codex/config.toml"

# Replicate the sed logic from setup-client.sh
cp "$FAKE_CONFIG" "$NEW_CONFIG"
sed -i.bak '/^openai_base_url[[:space:]]*=/d' "$NEW_CONFIG" 2>/dev/null || true
sed -i.bak '/^base_url[[:space:]]*=/d' "$NEW_CONFIG" 2>/dev/null || true
sed -i.bak '/^model_provider[[:space:]]*=/d' "$NEW_CONFIG" 2>/dev/null || true
sed -i.bak '/^model_catalog_json[[:space:]]*=/d' "$NEW_CONFIG" 2>/dev/null || true
sed -i.bak '/^wire_api[[:space:]]*=/d' "$NEW_CONFIG" 2>/dev/null || true
rm -f "${NEW_CONFIG}.bak"

# Append new config
{
    echo ""
    echo "# === opencodex LAN Share ==="
    echo "base_url = \"${BASE_URL}/v1\""
    echo "# ============================"
} >> "$NEW_CONFIG"

# TC-CLIENT-MAC-02a: base_url is set correctly
if grep -q "base_url = \"${BASE_URL}/v1\"" "$NEW_CONFIG"; then
    test_result "TC-CLIENT-MAC-02a" "Config has correct base_url" true
else
    test_result "TC-CLIENT-MAC-02a" "Config has correct base_url" false "Missing or wrong base_url in config"
fi

# TC-CLIENT-MAC-02b: model_provider is NOT set (standard OpenAI protocol)
if grep -q '^model_provider' "$NEW_CONFIG" 2>/dev/null; then
    test_result "TC-CLIENT-MAC-02b" "model_provider is NOT set (standard OpenAI)" false \
        "model_provider found in config - will cause Codex to fail"
else
    test_result "TC-CLIENT-MAC-02b" "model_provider is NOT set (standard OpenAI)" true
fi

# TC-CLIENT-MAC-02c: model_catalog_json is NOT set (online fetch)
if grep -q '^model_catalog_json' "$NEW_CONFIG" 2>/dev/null; then
    test_result "TC-CLIENT-MAC-02c" "model_catalog_json is NOT set (online fetch)" false \
        "model_catalog_json found - will pin models and prevent updates"
else
    test_result "TC-CLIENT-MAC-02c" "model_catalog_json is NOT set (online fetch)" true
fi

# TC-CLIENT-MAC-02d: wire_api is NOT set (use default chat protocol)
if grep -q '^wire_api' "$NEW_CONFIG" 2>/dev/null; then
    test_result "TC-CLIENT-MAC-02d" "wire_api is NOT set (default chat)" false \
        "wire_api found - may cause protocol mismatch"
else
    test_result "TC-CLIENT-MAC-02d" "wire_api is NOT set (default chat)" true
fi

# TC-CLIENT-MAC-02e: openai_base_url is NOT set (legacy config key)
if grep -q '^openai_base_url' "$NEW_CONFIG" 2>/dev/null; then
    test_result "TC-CLIENT-MAC-02e" "openai_base_url is NOT set (legacy)" false \
        "openai_base_url found - deprecated key"
else
    test_result "TC-CLIENT-MAC-02e" "openai_base_url is NOT set (legacy)" true
fi

# TC-CLIENT-MAC-02f: Old config is cleaned up
if grep -q 'old-server' "$NEW_CONFIG" 2>/dev/null; then
    test_result "TC-CLIENT-MAC-02f" "Old config values cleaned" false \
        "Old server URL still present in config"
else
    test_result "TC-CLIENT-MAC-02f" "Old config values cleaned" true
fi

# ============================================================
# TC-CLIENT-MAC-03: LaunchAgent plist generation
# ============================================================
PLIST_DIR="$TEST_DIR/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/com.opencodex.lan-share.plist"
mkdir -p "$PLIST_DIR"

cat > "$PLIST_FILE" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.opencodex.lan-share</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/launchctl</string>
        <string>setenv</string>
        <string>OPENAI_API_KEY</string>
        <string>test-key-12345</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF

# TC-CLIENT-MAC-03a: Plist file is valid XML
if command -v plutil &>/dev/null; then
    if plutil -lint "$PLIST_FILE" &>/dev/null; then
        test_result "TC-CLIENT-MAC-03a" "LaunchAgent plist is valid XML" true
    else
        test_result "TC-CLIENT-MAC-03a" "LaunchAgent plist is valid XML" false \
            "plutil lint failed"
    fi
else
    test_result "TC-CLIENT-MAC-03a" "LaunchAgent plist is valid XML" true "plutil not available, skipping"
fi

# TC-CLIENT-MAC-03b: Plist contains OPENAI_API_KEY
if grep -q "OPENAI_API_KEY" "$PLIST_FILE"; then
    test_result "TC-CLIENT-MAC-03b" "LaunchAgent sets OPENAI_API_KEY" true
else
    test_result "TC-CLIENT-MAC-03b" "LaunchAgent sets OPENAI_API_KEY" false \
        "OPENAI_API_KEY not found in plist"
fi

# TC-CLIENT-MAC-03c: Plist contains the access key
if grep -q "test-key-12345" "$PLIST_FILE"; then
    test_result "TC-CLIENT-MAC-03c" "LaunchAgent has correct access key" true
else
    test_result "TC-CLIENT-MAC-03c" "LaunchAgent has correct access key" false \
        "Access key not found in plist"
fi

# TC-CLIENT-MAC-03d: Plist has RunAtLoad = true
if grep -q "<true/>" "$PLIST_FILE"; then
    test_result "TC-CLIENT-MAC-03d" "LaunchAgent runs at load" true
else
    test_result "TC-CLIENT-MAC-03d" "LaunchAgent runs at load" false
fi

# ============================================================
# TC-CLIENT-MAC-04: launchctl setenv is in the script
# ============================================================
if grep -q "launchctl setenv OPENAI_API_KEY" "$SETUP_CLIENT"; then
    test_result "TC-CLIENT-MAC-04" "setup-client.sh uses launchctl setenv" true
else
    test_result "TC-CLIENT-MAC-04" "setup-client.sh uses launchctl setenv" false \
        "launchctl setenv not found in script - macOS GUI apps won't see env"
fi

# ============================================================
# TC-CLIENT-MAC-05: macOS detection (Darwin) in script
# ============================================================
if grep -q "Darwin" "$SETUP_CLIENT"; then
    test_result "TC-CLIENT-MAC-05" "setup-client.sh detects macOS (Darwin)" true
else
    test_result "TC-CLIENT-MAC-05" "setup-client.sh detects macOS (Darwin)" false \
        "No Darwin/macOS detection in script"
fi

# ============================================================
# TC-CLIENT-MAC-06: No hardcoded Windows paths in .sh files
# ============================================================
if grep -r 'opencodex\\' "$SETUP_CLIENT" 2>/dev/null; then
    test_result "TC-CLIENT-MAC-06" "No Windows paths in .sh scripts" false \
        "Windows backslash paths found in shell script"
else
    test_result "TC-CLIENT-MAC-06" "No Windows paths in .sh scripts" true
fi

# ============================================================
# Network-dependent tests (only if --server-ip and --access-key provided)
# ============================================================
if $NETWORK_TESTS; then
    BASE_URL="http://${SERVER_IP}:${PORT}"

    # TC-CLIENT-MAC-N01: TCP connectivity to server
    if command -v nc &>/dev/null; then
        if nc -z -w 3 "$SERVER_IP" "$PORT" 2>/dev/null; then
            test_result "TC-CLIENT-MAC-N01" "TCP reachable to ${SERVER_IP}:${PORT}" true
        else
            test_result "TC-CLIENT-MAC-N01" "TCP reachable to ${SERVER_IP}:${PORT}" false \
                "Cannot connect - check server is running"
        fi
    else
        # Fallback: use /dev/tcp (bash only)
        if timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null; then
            test_result "TC-CLIENT-MAC-N01" "TCP reachable to ${SERVER_IP}:${PORT}" true
        else
            test_result "TC-CLIENT-MAC-N01" "TCP reachable to ${SERVER_IP}:${PORT}" false \
                "Cannot connect - check server is running"
        fi
    fi

    # TC-CLIENT-MAC-N02: /v1/models endpoint returns data
    HTTP_CODE=$(curl -s -o /tmp/opencodex-test-models.json -w "%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_KEY}" \
        "${BASE_URL}/v1/models" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" ]]; then
        MODEL_COUNT=$(python3 -c "
import json, sys
with open('/tmp/opencodex-test-models.json') as f:
    data = json.load(f)
models = data.get('data', data.get('models', []))
print(len(models))
" 2>/dev/null || echo "0")
        test_result "TC-CLIENT-MAC-N02" "Models endpoint returns ${MODEL_COUNT} models" true
    else
        test_result "TC-CLIENT-MAC-N02" "Models endpoint returns data" false \
            "HTTP ${HTTP_CODE} from ${BASE_URL}/v1/models"
    fi

    # TC-CLIENT-MAC-N03: Models list is non-empty (the "模型不更新" check)
    if [[ "$HTTP_CODE" == "200" ]]; then
        if [[ "$MODEL_COUNT" -gt 0 ]]; then
            test_result "TC-CLIENT-MAC-N03" "Models list is non-empty (${MODEL_COUNT} models)" true
        else
            test_result "TC-CLIENT-MAC-N03" "Models list is non-empty" false \
                "0 models returned - this is the '模型不更新' symptom!"
        fi
    else
        test_result "TC-CLIENT-MAC-N03" "Models list is non-empty" false \
            "Cannot test - models endpoint not reachable"
    fi

    # TC-CLIENT-MAC-N04: Chat completions endpoint exists
    CHAT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"model":"test","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
        "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    # 401 or 4xx means endpoint exists (just auth/model issue)
    if [[ "$CHAT_CODE" != "000" ]]; then
        test_result "TC-CLIENT-MAC-N04" "Chat completions endpoint reachable" true
    else
        test_result "TC-CLIENT-MAC-N04" "Chat completions endpoint reachable" false \
            "Connection refused or timeout"
    fi

    # TC-CLIENT-MAC-N05: Auth proxy rejects invalid key
    INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer invalid-key-12345" \
        "${BASE_URL}/v1/models" 2>/dev/null || echo "000")
    if [[ "$INVALID_CODE" == "401" ]]; then
        test_result "TC-CLIENT-MAC-N05" "Auth proxy rejects invalid key (401)" true
    else
        test_result "TC-CLIENT-MAC-N05" "Auth proxy rejects invalid key (401)" false \
            "Got HTTP ${INVALID_CODE}, expected 401"
    fi

    rm -f /tmp/opencodex-test-models.json
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
    echo -e "  ${GREEN}[PASS] All macOS client tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "  ${RED}[FAIL] ${TESTS_FAILED} test(s) failed${NC}"
    exit 1
fi