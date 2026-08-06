#!/usr/bin/env bash
# setup-lan.sh
# opencodex LAN Share - macOS Server Setup Script
# Usage: ./scripts/server/setup-lan.sh [-p <port>] [--skip-firewall] [--no-launchd]
#
# This script is IDEMPOTENT - safe to run multiple times.

set -uo pipefail

PORT=10100
SKIP_FIREWALL=false
NO_LAUNCHD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port) PORT="$2"; shift 2 ;;
        --skip-firewall) SKIP_FIREWALL=true; shift ;;
        --no-launchd) NO_LAUNCHD=true; shift ;;
        -h|--help)
            echo "Usage: $0 [-p <port>] [--skip-firewall] [--no-launchd]"
            exit 0
            ;;
        *) shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTH_PROXY_PORT=10101

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

STEPS_COMPLETED=0
WARNINGS=()

step() { echo -e "  [$(date +%H:%M:%S)] ${1}"; }
step_ok() { echo -e "    ${GREEN}[OK]${NC} ${1}"; ((STEPS_COMPLETED++)); }
step_warn() { echo -e "    ${YELLOW}[WARN]${NC} ${1}"; WARNINGS+=("$1"); }
step_fail() { echo -e "    ${RED}[FAIL]${NC} ${1}"; }

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  opencodex LAN Share - Server Setup${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  Port: ${PORT}"
echo -e "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ============================================================
# Step 1: Prerequisite checks
# ============================================================
step "Step 1/5: Checking prerequisites..."

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    step_fail "This script is for macOS only. For Windows, use setup-lan.ps1"
    exit 1
fi
step_ok "Running on macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"

# Check sudo access (not strictly required but warned)
if ! sudo -n true 2>/dev/null; then
    step_warn "No passwordless sudo. Firewall config will require sudo password."
else
    step_ok "Sudo access available"
fi

# Check opencodex binary
if command -v ocx &>/dev/null; then
    ocx_version=$(ocx --version 2>&1 || echo "unknown")
    step_ok "opencodex found: ${ocx_version}"
else
    step_fail "opencodex CLI not found. Please install: npm install -g opencodex"
    exit 1
fi

# Check Python 3
PYTHON3=""
for py in python3 /usr/bin/python3; do
    if command -v "$py" &>/dev/null; then
        PYTHON3="$py"
        break
    fi
done
if [[ -z "$PYTHON3" ]]; then
    step_fail "python3 not found. Please install Python 3."
    exit 1
fi
step_ok "python3 found: ${PYTHON3}"

# ============================================================
# Step 2: Ensure proxy is running
# ============================================================
step "Step 2/5: Ensuring proxy is running on port ${PORT}..."

PROXY_RUNNING=false
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q "200"; then
    step_ok "Proxy is already running on port ${PORT}"
    PROXY_RUNNING=true
else
    step_warn "Proxy not running. Starting..."
    ocx start 2>&1 | tail -1 || true
    sleep 3

    # Verify it started
    for i in {1..5}; do
        if curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
            step_ok "Proxy started successfully on port ${PORT}"
            PROXY_RUNNING=true
            break
        fi
        sleep 2
    done

    if ! $PROXY_RUNNING; then
        step_fail "Failed to start proxy. Run 'ocx logs --tail 20' to diagnose."
        exit 1
    fi
fi

# ============================================================
# Step 3: Check network binding
# ============================================================
step "Step 3/5: Checking network binding..."

BIND_ADDR=$(ocx config get hostname 2>&1 || echo "unknown")
if echo "$BIND_ADDR" | grep -q "0\.0\.0\.0"; then
    step_ok "Proxy bound to 0.0.0.0 (accessible from LAN)"
else
    step_warn "Proxy bound to ${BIND_ADDR}. Setting to 0.0.0.0 for LAN access..."
    ocx config set hostname "0.0.0.0" 2>&1 | tail -1 || true
    ocx restart 2>&1 | tail -1 || true
    sleep 3
    step_ok "Proxy now bound to 0.0.0.0"
fi

# ============================================================
# Step 4: Firewall configuration (macOS)
# ============================================================
step "Step 4/5: Configuring macOS Firewall..."

if $SKIP_FIREWALL; then
    step_warn "Firewall configuration skipped (--skip-firewall flag)"
else
    # macOS has two firewall layers:
    # 1. Application Firewall (socketfilterfw) - for signed apps
    # 2. Packet Filter (pf) - for port-based rules

    FW_CONFIGURED=false

    # Check if pf is enabled
    if sudo pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        step_ok "pf (Packet Filter) is enabled"

        # Check if our anchor already exists
        PF_ANCHOR="/etc/pf.anchors/com.opencodex.lan-share"
        if sudo pfctl -s Anchors 2>/dev/null | grep -q "com.opencodex.lan-share"; then
            step_ok "pf anchor already configured for opencodex"
            FW_CONFIGURED=true
        else
            step_warn "Creating pf rules for ports ${PORT}, ${AUTH_PROXY_PORT}..."

            # Create pf anchor file
            sudo tee "$PF_ANCHOR" > /dev/null << PFEOF
# opencodex LAN Share - allow LAN access to proxy ports
pass in proto tcp from any to any port ${PORT} keep state
pass in proto tcp from any to any port ${AUTH_PROXY_PORT} keep state
PFEOF

            # Add anchor reference to pf.conf if not already present
            if ! grep -q "com.opencodex.lan-share" /etc/pf.conf 2>/dev/null; then
                echo "anchor \"com.opencodex.lan-share\"" | sudo tee -a /etc/pf.conf > /dev/null
                echo "load anchor \"com.opencodex.lan-share\" from \"${PF_ANCHOR}\"" | sudo tee -a /etc/pf.conf > /dev/null
            fi

            # Reload pf
            sudo pfctl -f /etc/pf.conf 2>/dev/null || true
            FW_CONFIGURED=true
            step_ok "pf rules added for ports ${PORT}, ${AUTH_PROXY_PORT}"
        fi
    else
        # pf not enabled, try application firewall approach
        step_warn "pf is not enabled. Using application firewall."

        # Check if the app firewall is on
        if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q "enabled"; then
            step_ok "Application Firewall is enabled"
            step_warn "App Firewall doesn't allow port-based rules."
            step_warn "To allow LAN access, you may need to:"
            step_warn "  1. System Settings > Network > Firewall > Options"
            step_warn "  2. Disable 'Block all incoming connections'"
            step_warn "  OR: Enable pf with: sudo pfctl -E"
        else
            step_warn "Application Firewall is off. No firewall blocking."
            FW_CONFIGURED=true
        fi
    fi
fi

# ============================================================
# Step 5: Auth Proxy (port 10101) + LaunchDaemon
# ============================================================
step "Step 5/5: Auth Proxy (port ${AUTH_PROXY_PORT})..."

AUTH_PROXY_SCRIPT="$SCRIPT_DIR/auth-proxy.py"

if [[ ! -f "$AUTH_PROXY_SCRIPT" ]]; then
    step_warn "auth-proxy.py not found at $AUTH_PROXY_SCRIPT"
else
    # Check if auth proxy already running
    AUTH_PROXY_RUNNING=false
    if curl -s -o /dev/null "http://127.0.0.1:${AUTH_PROXY_PORT}/v1/models" \
        -H "Authorization: Bearer test" 2>/dev/null; then
        step_ok "Auth proxy already running on port ${AUTH_PROXY_PORT}"
        AUTH_PROXY_RUNNING=true
    fi

    if ! $AUTH_PROXY_RUNNING; then
        step_warn "Starting auth proxy..."

        # Kill any existing auth proxy processes
        pkill -f "auth-proxy.py" 2>/dev/null || true
        sleep 1

        # Start auth proxy in background
        nohup "$PYTHON3" "$AUTH_PROXY_SCRIPT" --port "$AUTH_PROXY_PORT" \
            > /tmp/opencodex-auth-proxy.log 2>&1 &
        AUTH_PROXY_PID=$!
        sleep 2

        # Verify it started
        if kill -0 "$AUTH_PROXY_PID" 2>/dev/null; then
            step_ok "Auth proxy started on port ${AUTH_PROXY_PORT} (PID: ${AUTH_PROXY_PID})"
        else
            step_fail "Auth proxy failed to start. Check /tmp/opencodex-auth-proxy.log"
            exit 1
        fi
    fi

    # Set up LaunchDaemon for auto-start on boot
    if ! $NO_LAUNCHD; then
        LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.opencodex.auth-proxy.plist"
        LAUNCHD_PLIST_DIR="$(dirname "$LAUNCHD_PLIST")"
        mkdir -p "$LAUNCHD_PLIST_DIR"

        cat > "$LAUNCHD_PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.opencodex.auth-proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3}</string>
        <string>${AUTH_PROXY_SCRIPT}</string>
        <string>--port</string>
        <string>${AUTH_PROXY_PORT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/opencodex-auth-proxy.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/opencodex-auth-proxy.log</string>
</dict>
</plist>
PLISTEOF

        # Unload old version if exists, then load new
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
        launchctl load "$LAUNCHD_PLIST" 2>/dev/null
        step_ok "LaunchDaemon installed (auto-start on boot)"
    else
        step_warn "LaunchDaemon skipped (--no-launchd flag)"
    fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  Setup Complete${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Detect LAN IP
LAN_IP="unknown"
# Try primary interface first
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
if [[ -z "$LAN_IP" ]]; then
    LAN_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1)
fi
if [[ -z "$LAN_IP" ]]; then
    LAN_IP="unknown"
fi

echo "  Proxy endpoint:  http://${LAN_IP}:${PORT}/v1"
echo "  Local endpoint:  http://127.0.0.1:${PORT}/v1"
echo ""

# Check/create access keys
echo -e "  ${YELLOW}Access Keys:${NC}"
if ocx access key list 2>&1 | grep -q "No keys\|no access keys\|empty"; then
    echo "    No access keys found. Create one for each colleague:"
    echo "      ocx access key create <colleague-name>"
else
    ocx access key list 2>&1 || true
fi

echo ""
echo -e "  ${YELLOW}Next Steps:${NC}"
echo "    1. Create access keys for colleagues:"
echo "       ./scripts/server/manage-users.sh -Create <name>"
echo ""
echo "    2. Send each colleague:"
echo "       - Their access key (keep it secret!)"
echo "       - The proxy address: http://${LAN_IP}:${AUTH_PROXY_PORT}/v1"
echo "       - The client setup script: ./scripts/client/setup-client.sh"
echo ""
echo "    3. Colleague runs:"
echo "       bash ./scripts/client/setup-client.sh ${LAN_IP} <their-key>"
echo ""

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Warnings (${#WARNINGS[@]}):${NC}"
    for w in "${WARNINGS[@]}"; do
        echo "    - $w"
    done
fi

echo -e "  Run tests to verify: bash ./tests/test-server-macos.sh${CYAN}"
echo ""

exit 0