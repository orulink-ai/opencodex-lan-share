# setup-client.ps1
# opencodex LAN Share - Windows 客户端一键接入脚本
#
# 一键命令（管理员把 IP 和密钥替换好发给同事）：
# powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -Uri 'https://raw.githubusercontent.com/orulink-ai/opencodex-lan-share/main/scripts/client/setup-client.ps1' -OutFile 'setup.ps1'; .\setup.ps1 -ServerIp 192.168.1.110 -AccessKey ocx_data_xxxx"

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIp,

    [int]$Port = 10101,

    [Parameter(Mandatory=$true)]
    [string]$AccessKey,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$BaseUrl = "http://${ServerIp}:${Port}"
$ConfigPath = Join-Path $HOME ".codex\config.toml"
$configDir = Split-Path -Parent $ConfigPath

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  opencodex LAN Share - 客户端接入" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  服务器: ${BaseUrl}"
Write-Host "  配置:   $ConfigPath"
if ($DryRun) { Write-Host "  模式:   DRY RUN（预览不修改）" -ForegroundColor Yellow }
Write-Host ""

# ============================================================
# Step 1: 环境检测
# ============================================================
Write-Host "[1/4] 检测环境..." -ForegroundColor Yellow

# 确保配置目录存在
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}
Write-Host "  [OK] 配置目录已就绪"

Write-Host ""

# ============================================================
# Step 2: 网络连通性测试
# ============================================================
Write-Host "[2/4] 测试网络连通性..." -ForegroundColor Yellow

$connected = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connected = $tcp.ConnectAsync($ServerIp, $Port).Wait(3000)
    $tcp.Close()
} catch { }

if ($connected) {
    Write-Host "  [OK] 成功连接到 ${ServerIp}:${Port}"
} else {
    Write-Host "  [失败] 无法连接到 ${ServerIp}:${Port}" -ForegroundColor Red
    Write-Host ""
    Write-Host "  排查建议："
    Write-Host "    1. 服务器是否开机并且在同一个局域网？"
    Write-Host "    2. 服务器上 auth-proxy.py 是否在运行？"
    Write-Host "    3. 端口是否正确？（默认 10101）"
    Write-Host "    4. 你的网络是不是设成了'公用'？（改成'专用'）"
    exit 1
}

# 测试 API
try {
    $result = Invoke-RestMethod -Uri "${BaseUrl}/v1/models" -Method Get `
        -Headers @{"Authorization"="Bearer ${AccessKey}"} -TimeoutSec 10 -ErrorAction Stop
    $count = if ($result.data) { @($result.data).Count } else { 0 }
    Write-Host ("  [OK] 代理正常，" + $count + " 个模型可用")
} catch {
    $msg = $_.Exception.Message
    Write-Host "  [警告] API 测试异常: $msg" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================
# Step 3: 配置 Codex
# ============================================================
Write-Host "[3/4] 配置 Codex..." -ForegroundColor Yellow

# 备份现有配置
if (Test-Path $ConfigPath) {
    $backupPath = $ConfigPath + ".backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    if (-not $DryRun) {
        Copy-Item $ConfigPath $backupPath
        Write-Host "  [OK] 已备份到 $(Split-Path $backupPath -Leaf)"
    }
}

# 读取并清理旧配置
$lines = @()
if (Test-Path $ConfigPath) { $lines = Get-Content $ConfigPath }

$newLines = @()
$injected = $false

foreach ($line in $lines) {
    # 跳过旧的代理配置行
    if ($line -match '^\s*openai_base_url\s*=') { continue }
    if ($line -match '^\s*base_url\s*=') {
        if (-not $injected) {
            $newLines += ""
            $newLines += "# === opencodex LAN Share ==="
            $newLines += ('base_url = "' + $BaseUrl + '/v1"')
            $newLines += "# ============================"
            $newLines += ""
            $injected = $true
        }
        continue
    }
    # 删除 model_provider = "opencodex"（会导致 Codex 启动失败！）
    if ($line -match '^\s*model_provider\s*=') { continue }
    # 删除旧的 model_catalog_json
    if ($line -match '^\s*model_catalog_json\s*=') { continue }
    # 删除旧的 wire_api = "responses"（用默认的 chat 协议）
    if ($line -match '^\s*wire_api\s*=') { continue }
    $newLines += $line
}

# 追加配置
if (-not $injected) {
    $newLines += ""
    $newLines += "# === opencodex LAN Share ==="
    $newLines += ('base_url = "' + $BaseUrl + '/v1"')
    $newLines += "# ============================"
}

if (-not $DryRun) {
    $newLines -join "`r`n" | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "  [OK] 配置已更新（base_url = ${BaseUrl}/v1）"
    Write-Host "       ✓ 不设 model_provider（兼容标准 OpenAI 协议）"
    Write-Host "       ✓ 不设 model_catalog_json（在线获取模型）"
} else {
    Write-Host "  [预览] 将更新配置"
}

Write-Host ""

# ============================================================
# Step 4: 设置认证密钥
# ============================================================
Write-Host "[4/4] 设置认证密钥..." -ForegroundColor Yellow

$envSet = $false
try {
    if (-not $DryRun) {
        # 清除可能冲突的旧变量
        [Environment]::SetEnvironmentVariable("OPENCODEX_OPENCODE_API_KEY", $null, "User")
        # 设置标准 OPENAI_API_KEY（Codex 会自动用）
        [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $AccessKey, "User")
        $envSet = $true
        Write-Host "  [OK] 已设置 OPENAI_API_KEY 用户环境变量"
    }
} catch {
    Write-Host "  [警告] 无法自动设置，请手动添加环境变量：" -ForegroundColor Yellow
    Write-Host "        变量名: OPENAI_API_KEY"
    Write-Host ("       变量值: " + $AccessKey)
}

Write-Host ""

# ============================================================
# 完成
# ============================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  配置完成！" -ForegroundColor Green
Write-Host "========================================"
Write-Host ""
Write-Host "  接下来："
Write-Host "    1. 完全退出 Codex Desktop（任务栏右键 → 退出）"
Write-Host "    2. 重新打开 Codex Desktop"
Write-Host "    3. 模型选择器中就能看到所有模型了"
Write-Host ""
Write-Host "  原理："
Write-Host "    你的 Codex → 标准 OpenAI 协议 → 服务器转发代理"
Write-Host "    → 转成 opencodex 格式 → 路由到阿里云百炼/DeepSeek"
Write-Host ""

if (-not $envSet) {
    Write-Host "  ⚠ 请设置环境变量后重启电脑生效" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  恢复方法："
Write-Host "    删除 ~/.codex/config.toml 中 # === opencodex LAN Share ==="
Write-Host "    之间的内容，或恢复备份文件"
Write-Host ""

exit 0
