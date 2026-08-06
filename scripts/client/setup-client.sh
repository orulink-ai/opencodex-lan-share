#!/usr/bin/env bash
# setup-client.sh
# opencodex LAN Share - macOS/Linux 客户端一键接入脚本
#
# 一键命令（管理员把 IP 和密钥替换好发给同事）：
# curl -fsSL https://raw.githubusercontent.com/orulink-ai/opencodex-lan-share/main/scripts/client/setup-client.sh | bash -s -- <服务器IP> <密钥>

set -euo pipefail

SERVER_IP="${1:-${SERVER_IP:-}}"
ACCESS_KEY="${2:-${ACCESS_KEY:-}}"
PORT="${PORT:-10101}"
CONFIG_PATH="${HOME}/.codex/config.toml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$SERVER_IP" ] || [ -z "$ACCESS_KEY" ]; then
    echo -e "${RED}用法: bash setup-client.sh <服务器IP> <访问密钥>${NC}"
    echo "示例: bash setup-client.sh 192.168.1.110 ocx_data_xxxx"
    exit 1
fi

BASE_URL="http://${SERVER_IP}:${PORT}"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  opencodex LAN Share - 客户端接入${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  服务器: ${BASE_URL}"
echo -e "  配置:   ${CONFIG_PATH}"

# Step 1: 环境
echo -e "${YELLOW}[1/4] 检测环境...${NC}"
mkdir -p "$(dirname "$CONFIG_PATH")"
echo -e "  ${GREEN}[OK]${NC} 配置目录已就绪"

# Step 2: 连通性
echo -e "${YELLOW}[2/4] 测试网络...${NC}"
if command -v nc &>/dev/null && nc -z -w 3 "$SERVER_IP" "$PORT" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} 成功连接到 ${BASE_URL}"
elif timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} 成功连接到 ${BASE_URL}"
else
    echo -e "  ${RED}[失败]${NC} 无法连接，检查服务器是否开机、同一局域网、防火墙"
    exit 1
fi

# 测试 API
if command -v curl &>/dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${ACCESS_KEY}" "${BASE_URL}/v1/models" 2>/dev/null || echo "0")
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "  ${GREEN}[OK]${NC} API 正常"
    else
        echo -e "  ${YELLOW}[提示]${NC} API 返回 ${HTTP_CODE}（可能仍能使用）"
    fi
fi

# Step 3: 配置
echo -e "${YELLOW}[3/4] 配置 Codex...${NC}"

if [ -f "$CONFIG_PATH" ]; then
    BACKUP="${CONFIG_PATH}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$BACKUP"
    echo -e "  ${GREEN}[OK]${NC} 已备份到 $(basename "$BACKUP")"

    # 移除旧的 opencodex 配置
    sed -i.bak '/^openai_base_url\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^base_url\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^model_provider\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^model_catalog_json\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^wire_api\s*=/d' "$CONFIG_PATH"
    rm -f "${CONFIG_PATH}.bak"
fi

# 写入新配置（标准 OpenAI 协议，不设 model_provider）
{
    echo ""
    echo "# === opencodex LAN Share ==="
    echo "base_url = \"${BASE_URL}/v1\""
    echo "# ============================"
} >> "$CONFIG_PATH"
echo -e "  ${GREEN}[OK]${NC} 配置已更新"
echo -e "       ${GREEN}✓${NC} base_url = ${BASE_URL}/v1"
echo -e "       ${GREEN}✓${NC} 使用标准 OpenAI 协议（不设 model_provider）"

# Step 4: 环境变量（macOS 特殊处理）
echo -e "${YELLOW}[4/4] 设置密钥...${NC}"

if [ "$(uname)" = "Darwin" ] 2>/dev/null; then
    # macOS: GUI 应用不继承 shell rc，必须用 launchctl
    launchctl setenv OPENAI_API_KEY "${ACCESS_KEY}"
    echo -e "  ${GREEN}[OK]${NC} 已通过 launchctl 设置（所有应用可见）"

    # 创建 LaunchAgent 确保重启后也生效
    PLIST_DIR="${HOME}/Library/LaunchAgents"
    PLIST_FILE="${PLIST_DIR}/com.opencodex.lan-share.plist"
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
        <string>${ACCESS_KEY}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF
    launchctl load "$PLIST_FILE" 2>/dev/null || true
    echo -e "  ${GREEN}[OK]${NC} 已创建 LaunchAgent（重启后自动生效）"
else
    # Linux: 写入 shell rc
    SHELL_RC=""
    for f in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
        [ -f "$f" ] && SHELL_RC="$f" && break
    done

    if [ -n "$SHELL_RC" ]; then
        sed -i.bak '/^export OPENAI_API_KEY=/d' "$SHELL_RC" 2>/dev/null || true
        sed -i.bak '/^export OPENCODEX_OPENCODE_API_KEY=/d' "$SHELL_RC" 2>/dev/null || true
        rm -f "${SHELL_RC}.bak"
        echo "export OPENAI_API_KEY=\"${ACCESS_KEY}\"" >> "$SHELL_RC"
        echo -e "  ${GREEN}[OK]${NC} 已写入 ${SHELL_RC}"
        echo -e "  ${YELLOW}[提示]${NC} 运行 'source ${SHELL_RC}' 或新开终端生效"
    else
        echo -e "  ${YELLOW}[提示]${NC} 请手动设置: export OPENAI_API_KEY=\"${ACCESS_KEY}\""
    fi
fi

# 完成
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "  1. 完全退出 Codex Desktop"
echo "  2. 重新打开 Codex Desktop"
echo "  3. 模型选择器中就能看到所有模型了"
echo ""
echo "  原理: 你的 Codex → 标准 OpenAI 协议 → 服务器转发代理"
echo "        → opencodex → 阿里云百炼/DeepSeek"
echo ""
echo "  恢复: 删除 config.toml 中 # === opencodex LAN Share === 之间的内容"
echo "        或恢复备份文件"
echo ""
