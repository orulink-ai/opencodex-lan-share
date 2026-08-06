#!/usr/bin/env bash
# setup-client.sh
# opencodex LAN Share - macOS/Linux Client Setup Script
# Usage: SERVER_IP=192.168.1.110 ./scripts/client/setup-client.sh
#    or: bash setup-client.sh 192.168.1.110

set -euo pipefail

SERVER_IP="${1:-${SERVER_IP:-}}"
PORT="${PORT:-10100}"
CONFIG_PATH="${HOME}/.codex/config.toml"
DRY_RUN="${DRY_RUN:-false}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Error: Server IP is required.${NC}"
    echo "Usage: bash setup-client.sh <server-ip>"
    echo "   or: SERVER_IP=192.168.1.110 bash setup-client.sh"
    exit 1
fi

BASE_URL="http://${SERVER_IP}:${PORT}"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  opencodex LAN Share - Client Setup${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  Server: ${BASE_URL}"
echo -e "  Config: ${CONFIG_PATH}"
if [ "$DRY_RUN" = "true" ]; then
    echo -e "  Mode:   ${YELLOW}DRY RUN (no changes)${NC}"
fi
echo ""

# Step 1: Prerequisites
echo -e "${YELLOW}Step 1/4: Checking prerequisites...${NC}"

if command -v codex &>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} Codex CLI found: $(codex --version 2>&1 | head -1)"
else
    echo -e "  ${YELLOW}[WARN]${NC} Codex CLI not in PATH. If you use Codex Desktop only, this is OK."
fi

CONFIG_DIR="$(dirname "$CONFIG_PATH")"
if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    echo -e "  ${GREEN}[OK]${NC} Created config directory: $CONFIG_DIR"
fi

# Step 2: Connectivity test
echo -e "${YELLOW}Step 2/4: Testing connectivity...${NC}"

if command -v nc &>/dev/null; then
    if nc -z -w 3 "$SERVER_IP" "$PORT" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} Successfully connected to ${BASE_URL}"
    else
        echo -e "  ${RED}[FAIL]${NC} Cannot reach ${BASE_URL}"
        echo ""
        echo -e "  ${YELLOW}Troubleshooting:${NC}"
        echo "    1. Is the server machine online and on the same LAN?"
        echo "    2. Is the opencodex proxy running? (ocx status)"
        echo "    3. Is the firewall configured? (run setup-lan.ps1 on server)"
        exit 1
    fi
elif command -v timeout &>/dev/null; then
    if timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} Successfully connected to ${BASE_URL}"
    else
        echo -e "  ${RED}[FAIL]${NC} Cannot reach ${BASE_URL}"
        exit 1
    fi
else
    echo -e "  ${YELLOW}[WARN]${NC} Cannot test connectivity (nc/timeout not found). Continuing anyway..."
fi

# Test models endpoint
if command -v curl &>/dev/null; then
    MODEL_COUNT=$(curl -s "${BASE_URL}/v1/models" 2>/dev/null | grep -o '"id"' | wc -l || echo "0")
    if [ "$MODEL_COUNT" -gt 0 ]; then
        echo -e "  ${GREEN}[OK]${NC} Proxy serving ~${MODEL_COUNT} models"
    fi
fi

# Step 3: Configure Codex
echo -e "${YELLOW}Step 3/4: Configuring Codex...${NC}"

if [ -f "$CONFIG_PATH" ] && grep -q "$SERVER_IP" "$CONFIG_PATH" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} Already configured for this proxy"
else
    # Backup
    if [ -f "$CONFIG_PATH" ]; then
        BACKUP="${CONFIG_PATH}.backup-$(date +%Y%m%d-%H%M%S)"
        if [ "$DRY_RUN" != "true" ]; then
            cp "$CONFIG_PATH" "$BACKUP"
            echo -e "  ${GREEN}[OK]${NC} Backed up to $(basename "$BACKUP")"
        else
            echo -e "  ${YELLOW}[DRY]${NC} Would backup to $(basename "$BACKUP")"
        fi
    fi

    if [ "$DRY_RUN" != "true" ]; then
        # Remove existing base_url/openai_base_url lines
        if [ -f "$CONFIG_PATH" ]; then
            sed -i.bak '/^base_url\s*=/d' "$CONFIG_PATH"
            sed -i.bak '/^openai_base_url\s*=/d' "$CONFIG_PATH"
            sed -i.bak '/^model_provider\s*=/d' "$CONFIG_PATH"
            rm -f "${CONFIG_PATH}.bak"
        fi

        # Add proxy configuration
        {
            echo ""
            echo "# opencodex LAN Share - Proxy Configuration"
            echo "openai_base_url = \"${BASE_URL}/v1\""
            echo "model_provider = \"opencodex\""
        } >> "$CONFIG_PATH"

        echo -e "  ${GREEN}[OK]${NC} Configuration updated"
    else
        echo -e "  ${YELLOW}[DRY]${NC} Would add:"
        echo "       openai_base_url = \"${BASE_URL}/v1\""
        echo "       model_provider = \"opencodex\""
    fi
fi

# Step 4: Available models
echo -e "${YELLOW}Step 4/4: Available models...${NC}"

if command -v curl &>/dev/null; then
    echo ""
    echo -e "  ${GREEN}Model groups available through the proxy:${NC}"
    curl -s "${BASE_URL}/v1/models" 2>/dev/null | \
        grep -o '"id":"[^"]*"' | \
        sed 's/"id":"//;s/"//' | \
        grep -E "^(qwen-cloud/qwen3-coder|deepseek/|gpt-5)" | \
        sort -u | \
        head -10 | \
        while read -r model; do
            echo "    - $model"
        done
fi

# Summary
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  Client Setup Complete!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "  Your Codex is configured to use the LAN proxy at:"
echo "    ${BASE_URL}/v1"
echo ""
echo "  To use: Open Codex and select any qwen-cloud/* or deepseek/* model."
echo ""
echo "  To revert: Restore from backup in ${CONFIG_DIR}/"
echo ""
