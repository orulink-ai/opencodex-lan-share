#!/usr/bin/env bash
# setup-client.sh
# opencodex LAN Share - macOS/Linux 客户端一键接入脚本
#
# 方式一（推荐）：
#   curl -fsSL https://raw.githubusercontent.com/orulink-ai/opencodex-lan-share/main/scripts/client/setup-client.sh | bash -s -- <服务器IP> <密钥>
#
# 方式二：手动下载后运行
#   bash setup-client.sh 192.168.1.110 <密钥>

set -euo pipefail

SERVER_IP="${1:-${SERVER_IP:-}}"
ACCESS_KEY="${2:-${ACCESS_KEY:-}}"
PORT="${PORT:-10100}"
CONFIG_PATH="${HOME}/.codex/config.toml"
CATALOG_PATH="${HOME}/.codex/opencodex-catalog.json"
DRY_RUN="${DRY_RUN:-false}"

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

# Step 1: 环境检测
echo -e "${YELLOW}[1/5] 检测环境...${NC}"
CONFIG_DIR="$(dirname "$CONFIG_PATH")"
mkdir -p "$CONFIG_DIR"
echo -e "  ${GREEN}[OK]${NC} 配置目录已就绪"

# Step 2: 网络测试
echo -e "${YELLOW}[2/5] 测试网络连通性...${NC}"
if command -v nc &>/dev/null; then
    if nc -z -w 3 "$SERVER_IP" "$PORT" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} 成功连接到 ${BASE_URL}"
    else
        echo -e "  ${RED}[失败]${NC} 无法连接到 ${SERVER_IP}:${PORT}"
        echo "  排查：服务器是否开机？防火墙是否放行？是否同一局域网？"
        exit 1
    fi
elif timeout 3 bash -c "echo >/dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} 成功连接到 ${BASE_URL}"
else
    echo -e "  ${YELLOW}[警告]${NC} 无法测试连通性，继续..."
fi

# 测试 API
if command -v curl &>/dev/null; then
    MODEL_COUNT=$(curl -s -H "x-opencodex-api-key: ${ACCESS_KEY}" "${BASE_URL}/v1/models" 2>/dev/null | grep -o '"id"' | wc -l || echo "0")
    if [ "$MODEL_COUNT" -gt 0 ]; then
        echo -e "  ${GREEN}[OK]${NC} 代理正常，约 ${MODEL_COUNT} 个模型"
    fi
fi

# Step 3: 下载模型目录
echo -e "${YELLOW}[3/5] 同步模型目录...${NC}"
if command -v curl &>/dev/null && [ "$DRY_RUN" != "true" ]; then
    if curl -s -H "x-opencodex-api-key: ${ACCESS_KEY}" "${BASE_URL}/v1/models" -o /tmp/ocx-models.json 2>/dev/null; then
        # 转换为简易 catalog 格式
        MODEL_COUNT=$(python3 -c "
import json, sys
data = json.load(open('/tmp/ocx-models.json'))
models = []
for m in data.get('data', []):
    models.append({
        'slug': m['id'],
        'display_name': f\"{m['id']} ({m.get('owned_by', 'system')})\",
        'context_window': 131072,
        'input_modalities': ['text']
    })
catalog = {'fetched_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'models': models}
json.dump(catalog, open('${CATALOG_PATH}', 'w'), indent=2)
print(len(models))
" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}[OK]${NC} 模型目录已同步 (${MODEL_COUNT} 个模型)"
        rm -f /tmp/ocx-models.json
        CATALOG_DOWNLOADED=true
    else
        echo -e "  ${YELLOW}[警告]${NC} 无法下载模型目录"
        CATALOG_DOWNLOADED=false
    fi
else
    CATALOG_DOWNLOADED=false
fi

# Step 4: 配置 Codex
echo -e "${YELLOW}[4/5] 配置 Codex...${NC}"

# 备份
if [ -f "$CONFIG_PATH" ] && [ "$DRY_RUN" != "true" ]; then
    BACKUP="${CONFIG_PATH}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$BACKUP"
    echo -e "  ${GREEN}[OK]${NC} 已备份到 $(basename "$BACKUP")"
fi

# 清理旧配置 + 写入新配置
if [ "$DRY_RUN" != "true" ] && [ -f "$CONFIG_PATH" ]; then
    sed -i.bak '/^openai_base_url\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^base_url\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^model_provider\s*=/d' "$CONFIG_PATH"
    sed -i.bak '/^model_catalog_json\s*=/d' "$CONFIG_PATH"
    rm -f "${CONFIG_PATH}.bak"
fi

if [ "$DRY_RUN" != "true" ]; then
    {
        echo ""
        echo "# === opencodex LAN Share ==="
        echo "openai_base_url = \"${BASE_URL}/v1\""
        echo "model_provider = \"opencodex\""
        if [ "${CATALOG_DOWNLOADED:-false}" = "true" ]; then
            echo "model_catalog_json = \"${CATALOG_PATH}\""
        fi
        echo "# ============================"
    } >> "$CONFIG_PATH"
    echo -e "  ${GREEN}[OK]${NC} 配置已更新"
else
    echo -e "  ${YELLOW}[预览]${NC} 将更新配置"
fi

# Step 5: 环境变量
echo -e "${YELLOW}[5/5] 设置认证密钥...${NC}"

SHELL_RC=""
if [ -f "${HOME}/.zshrc" ]; then SHELL_RC="${HOME}/.zshrc"; fi
if [ -f "${HOME}/.bashrc" ]; then SHELL_RC="${HOME}/.bashrc"; fi
if [ -f "${HOME}/.bash_profile" ]; then SHELL_RC="${HOME}/.bash_profile"; fi

if [ -n "$SHELL_RC" ] && [ "$DRY_RUN" != "true" ]; then
    # 移除旧的配置
    sed -i.bak '/^export OPENCODEX_OPENCODE_API_KEY=/d' "$SHELL_RC" 2>/dev/null || true
    rm -f "${SHELL_RC}.bak"
    # 添加新配置
    echo "export OPENCODEX_OPENCODE_API_KEY=\"${ACCESS_KEY}\"" >> "$SHELL_RC"
    echo -e "  ${GREEN}[OK]${NC} 已添加到 ${SHELL_RC}"
    echo -e "  ${YELLOW}[提示]${NC} 运行 'source ${SHELL_RC}' 或新开终端生效"
else
    echo -e "  ${YELLOW}[提示]${NC} 请手动设置环境变量："
    echo "       export OPENCODEX_OPENCODE_API_KEY=\"${ACCESS_KEY}\""
fi

# 完成
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "  接下来："
echo "    1. 完全退出 Codex Desktop"
echo "    2. 重新打开 Codex Desktop"
echo "    3. 模型选择器中找 qwen-cloud/qwen3-coder-plus"
echo ""
echo "  常用模型："
echo "    qwen-cloud/qwen3-coder-plus   （编程推荐）"
echo "    qwen-cloud/qwen3-coder-flash  （更快更便宜）"
echo "    deepseek/deepseek-v4-flash    （DeepSeek 最新）"
echo ""
