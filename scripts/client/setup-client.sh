#!/usr/bin/env bash
# setup-client.sh
# opencodex LAN Share - macOS/Linux 客户端一键接入脚本
#
# This script:
#   1. Detects Node.js (installs if missing)
#   2. Installs opencodex globally via npm
#   3. Tests connectivity to the LAN server
#   4. Configures opencodex to route through the LAN proxy
#   5. Sets the OPENAI_API_KEY environment variable
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

# ============================================================
# Step 0: Detect and install Node.js + opencodex
# ============================================================
echo -e "${YELLOW}[0/5] 检测 Node.js 和 opencodex...${NC}"

# 0a: Check Node.js
NODE_OK=false
if command -v node &>/dev/null; then
    NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}[OK]${NC} Node.js ${NODE_VERSION}"
    NODE_OK=true
fi

if [ "$NODE_OK" = false ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Node.js 未安装，尝试自动安装..."
    if command -v brew &>/dev/null; then
        echo -e "  ${YELLOW}[INFO]${NC} 使用 Homebrew 安装 Node.js..."
        brew install node 2>/dev/null || {
            echo -e "  ${RED}[FAIL]${NC} 无法通过 Homebrew 安装 Node.js"
            echo ""
            echo "  请手动安装 Node.js："
            echo "    1. 访问 https://nodejs.org/"
            echo "    2. 下载并安装 LTS 版本"
            echo "    3. 重启终端后重新运行此脚本"
            exit 1
        }
        echo -e "  ${GREEN}[OK]${NC} Node.js 安装完成"
    elif command -v apt-get &>/dev/null; then
        echo -e "  ${YELLOW}[INFO]${NC} 使用 apt-get 安装 Node.js..."
        sudo apt-get update -qq && sudo apt-get install -y nodejs npm 2>/dev/null || {
            echo -e "  ${RED}[FAIL]${NC} 无法通过 apt-get 安装 Node.js"
            echo "  请手动安装：https://nodejs.org/"
            exit 1
        }
        echo -e "  ${GREEN}[OK]${NC} Node.js 安装完成"
    else
        echo -e "  ${RED}[FAIL]${NC} 未检测到包管理器，请手动安装 Node.js"
        echo "  下载地址：https://nodejs.org/"
        exit 1
    fi
fi

# 0b: Check opencodex
OCX_OK=false
if command -v ocx &>/dev/null; then
    OCX_VERSION=$(ocx --version 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}[OK]${NC} opencodex ${OCX_VERSION}"
    OCX_OK=true
fi

if [ "$OCX_OK" = false ]; then
    echo -e "  ${YELLOW}[WARN]${NC} opencodex 未安装，通过 npm 安装..."
    npm install -g opencodex 2>/dev/null || {
        # Retry with sudo on Linux
        if [ "$(uname)" != "Darwin" ]; then
            echo -e "  ${YELLOW}[INFO]${NC} 尝试使用 sudo..."
            sudo npm install -g opencodex 2>/dev/null || {
                echo -e "  ${RED}[FAIL]${NC} 无法安装 opencodex"
                echo "  请手动安装：npm install -g opencodex"
                exit 1
            }
        else
            echo -e "  ${RED}[FAIL]${NC} 无法安装 opencodex"
            echo "  请手动安装：npm install -g opencodex"
            exit 1
        fi
    }
    echo -e "  ${GREEN}[OK]${NC} opencodex 安装完成"
    OCX_OK=true
fi

# Step 1: 环境
echo -e "${YELLOW}[1/5] 检测环境...${NC}"
mkdir -p "$(dirname "$CONFIG_PATH")"
echo -e "  ${GREEN}[OK]${NC} 配置目录已就绪"

# Step 2: 连通性
echo -e "${YELLOW}[2/5] 测试网络...${NC}"
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
echo -e "${YELLOW}[3/5] 配置 Codex...${NC}"

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
    sed -i.bak '/^\[model_providers\.opencodex\]/,/^\[/d' "$CONFIG_PATH"
    rm -f "${CONFIG_PATH}.bak"
fi

# 写入新配置
{
    echo ""
    echo "# === opencodex LAN Share ==="
    echo "base_url = \"${BASE_URL}/v1\""
    echo "model_provider = \"opencodex\""
    echo "wire_api = \"responses\""
    echo ""
    echo "[model_providers.opencodex]"
    echo "name = \"OpenCodex Proxy (${SERVER_IP})\""
    echo "base_url = \"${BASE_URL}/v1\""
    echo "wire_api = \"responses\""
    echo "requires_openai_auth = true"
    echo "# ============================"
} >> "$CONFIG_PATH"
echo -e "  ${GREEN}[OK]${NC} 配置已更新"
echo -e "       ${GREEN}✔${NC} base_url = ${BASE_URL}/v1"
echo -e "       ${GREEN}✔${NC} model_provider = opencodex"
echo -e "       ${GREEN}✔${NC} 已添加 model_providers 配置段"

# Step 4: 环境变量（macOS 特殊处理）
echo -e "${YELLOW}[4/5] 设置密钥...${NC}"

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

# Step 5: 验证 opencodex 配置
echo -e "${YELLOW}[5/5] 验证 opencodex 配置...${NC}"
if [ "$OCX_OK" = true ] && command -v ocx &>/dev/null; then
    if ocx models list &>/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} opencodex 可以读取配置并获取模型列表"
    else
        echo -e "  ${YELLOW}[WARN]${NC} opencodex models list 返回非零"
    fi
else
    echo -e "  ${YELLOW}[SKIP]${NC} opencodex 不可用，跳过验证"
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
echo "  原理: 你的 opencodex → 标准 OpenAI 协议 → 服务器转发代理"
echo "        → opencodex proxy → 阿里云百炼 / DeepSeek"
echo ""
echo "  恢复: 删除 config.toml 中 # === opencodex LAN Share === 之间的内容"
echo "        或恢复备份文件"
echo ""
