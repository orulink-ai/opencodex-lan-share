#!/usr/bin/env bash
# diagnostics.sh
# opencodex LAN Share - Diagnostic Tool (macOS)
# Usage: ./tools/diagnostics.sh [-s <server-ip>] [-p <port>]
# Runs on either server or client side to diagnose connectivity issues.

set -uo pipefail

SERVER_IP="127.0.0.1"
PORT=10100

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--server-ip) SERVER_IP="$2"; shift 2 ;;
        -p|--port) PORT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-s <server-ip>] [-p <port>]"
            echo "  -s  Server IP (default: 127.0.0.1)"
            echo "  -p  Proxy port (default: 10100)"
            exit 0
            ;;
        *) shift ;;
    esac
done

BASE_URL="http://${SERVER_IP}:${PORT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  opencodex LAN Share - Diagnostics${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  Target:  ${BASE_URL}"
echo -e "  Time:    $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Machine: $(hostname)"
echo ""

# === System Info ===
echo -e "${YELLOW}--- System ---${NC}"
echo "  OS:      $(sw_vers -productName 2>/dev/null || echo 'macOS') $(sw_vers -productVersion 2>/dev/null || echo '')"
echo "  User:    $(whoami)"
echo "  Arch:    $(uname -m)"

# Get LAN IPs
LAN_IPS=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | paste -sd ", " -)
echo "  LAN IPs: ${LAN_IPS:-none detected}"

# Sudo access
if sudo -n true 2>/dev/null; then
    echo "  Sudo:    Available (passwordless)"
else
    echo "  Sudo:    Requires password"
fi

# === Codex Status ===
echo ""
echo -e "${YELLOW}--- Codex ---${NC}"

# Check for codex binary in common locations
CODEX_FOUND=false
for path in "/Applications/Codex.app/Contents/MacOS/Codex" \
            "$HOME/Applications/Codex.app/Contents/MacOS/Codex" \
            "$(which codex 2>/dev/null || echo '')"; do
    if [[ -n "$path" ]] && [[ -f "$path" ]]; then
        echo "  Binary:  $path"
        CODEX_FOUND=true
        break
    fi
done
if ! $CODEX_FOUND; then
    echo "  Binary:  NOT FOUND (client-side - OK if server only)"
fi

CONFIG_PATH="$HOME/.codex/config.toml"
if [[ -f "$CONFIG_PATH" ]]; then
    echo "  Config:  $CONFIG_PATH (exists)"
    if grep -q 'base_url' "$CONFIG_PATH" 2>/dev/null; then
        PROXY_URL=$(grep 'base_url' "$CONFIG_PATH" | head -1 | sed "s/.*\"\(.*\)\".*/\1/")
        echo "  Proxy:   ${PROXY_URL:-unknown}"
    else
        echo -e "  Proxy:   ${RED}NOT CONFIGURED${NC}"
    fi
    if grep -q 'model_provider' "$CONFIG_PATH" 2>/dev/null; then
        echo -e "  Provider: $(grep 'model_provider' "$CONFIG_PATH" | head -1) ${RED}(should NOT be set!)${NC}"
    else
        echo "  Provider: (not set - using standard OpenAI protocol)"
    fi
else
    echo "  Config:  NOT FOUND"
fi

# === opencodex Status ===
echo ""
echo -e "${YELLOW}--- opencodex ---${NC}"
if command -v ocx &>/dev/null; then
    echo "  CLI:     $(which ocx)"
    ocx_version=$(ocx --version 2>&1 || echo "unknown")
    echo "  Version: ${ocx_version}"
else
    echo -e "  CLI:     ${YELLOW}NOT FOUND (client mode - OK)${NC}"
fi

# === Network ===
echo ""
echo -e "${YELLOW}--- Network ---${NC}"

# TCP connectivity
if command -v nc &>/dev/null; then
    if nc -z -w 3 "$SERVER_IP" "$PORT" 2>/dev/null; then
        echo -e "  TCP:     ${SERVER_IP}:${PORT} ${GREEN}REACHABLE${NC}"
    else
        echo -e "  TCP:     ${SERVER_IP}:${PORT} ${RED}UNREACHABLE${NC}"
    fi
elif timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null; then
    echo -e "  TCP:     ${SERVER_IP}:${PORT} ${GREEN}REACHABLE${NC}"
else
    echo -e "  TCP:     ${SERVER_IP}:${PORT} ${RED}UNREACHABLE${NC}"
fi

# HTTP health
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "  HTTP:    ${BASE_URL}/health -> ${GREEN}${HTTP_CODE}${NC}"
else
    echo -e "  HTTP:    ${BASE_URL}/health -> ${RED}FAILED (HTTP ${HTTP_CODE})${NC}"
fi

# Models endpoint
MODEL_CODE=$(curl -s -o /tmp/ocx-diag-models.json -w "%{http_code}" "${BASE_URL}/v1/models" 2>/dev/null || echo "000")
if [[ "$MODEL_CODE" == "200" ]]; then
    MODEL_COUNT=$(python3 -c "
import json
with open('/tmp/ocx-diag-models.json') as f:
    d = json.load(f)
models = d.get('data', d.get('models', []))
print(len(models))
" 2>/dev/null || echo "0")
    echo -e "  Models:  ${GREEN}${MODEL_COUNT} available${NC}"
elif [[ "$MODEL_CODE" == "401" ]]; then
    echo -e "  Models:  ${YELLOW}${MODEL_COUNT} available (auth required)${NC}"
else
    echo -e "  Models:  ${RED}FAILED (HTTP ${MODEL_CODE})${NC}"
fi
rm -f /tmp/ocx-diag-models.json

# DNS/name resolution
if host "$SERVER_IP" >/dev/null 2>&1; then
    echo "  DNS:     ${SERVER_IP} resolves OK"
else
    echo -e "  DNS:     ${SERVER_IP} - ${YELLOW}no reverse DNS${NC}"
fi

# === Firewall (server-side only) ===
if [[ "$SERVER_IP" == "127.0.0.1" ]]; then
    echo ""
    echo -e "${YELLOW}--- Firewall ---${NC}"

    # Check pf status
    if sudo pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        echo "  pf:      Enabled"
        if sudo pfctl -s Anchors 2>/dev/null | grep -q "com.opencodex.lan-share"; then
            echo -e "  Anchor:  ${GREEN}com.opencodex.lan-share found${NC}"
        else
            echo -e "  Anchor:  ${RED}NOT FOUND${NC}"
            echo -e "  Fix:     ${YELLOW}Run ./scripts/server/setup-lan.sh${NC}"
        fi
    else
        echo -e "  pf:      ${YELLOW}Disabled${NC}"
    fi

    # Check app firewall
    if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q "enabled"; then
        echo -e "  App FW:  Enabled ${YELLOW}(may block incoming connections)${NC}"
        echo "  Fix:     System Settings > Network > Firewall > Options"
        echo "           Disable 'Block all incoming connections'"
    else
        echo "  App FW:  Disabled"
    fi
fi

# === Port listening (server-side only) ===
if [[ "$SERVER_IP" == "127.0.0.1" ]]; then
    echo ""
    echo -e "${YELLOW}--- Port ---${NC}"

    if command -v lsof &>/dev/null; then
        PORT_LISTEN=$(lsof -iTCP:${PORT} -sTCP:LISTEN -P -n 2>/dev/null)
        if [[ -n "$PORT_LISTEN" ]]; then
            echo "  Port ${PORT}: LISTENING"
            if echo "$PORT_LISTEN" | grep -q "TCP \*:${PORT}"; then
                echo -e "  Binding: ${GREEN}0.0.0.0 (LAN accessible)${NC}"
            elif echo "$PORT_LISTEN" | grep -q "TCP 127.0.0.1:${PORT}"; then
                echo -e "  Binding: ${RED}127.0.0.1 (localhost only)${NC}"
                echo -e "  Fix:     ${YELLOW}ocx config set hostname 0.0.0.0 && ocx restart${NC}"
            fi
        else
            echo -e "  Port ${PORT}: ${RED}NOT LISTENING${NC}"
            echo -e "  Fix:     ${YELLOW}ocx start${NC}"
        fi
    else
        echo -e "  Port ${PORT}: ${YELLOW}Cannot check (lsof not available)${NC}"
    fi
fi

# === Summary ===
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Diagnostics complete.${NC}"
echo -e "  If issues found, check the 'Fix:' suggestions above."
echo -e "${CYAN}========================================${NC}"
echo ""