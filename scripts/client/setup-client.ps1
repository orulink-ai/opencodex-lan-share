# setup-client.ps1
# opencodex LAN Share - Windows 客户端一键接入脚本
#
# 方式一（推荐）：从 GitHub 直接运行
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -Uri 'https://raw.githubusercontent.com/orulink-ai/opencodex-lan-share/main/scripts/client/setup-client.ps1' -OutFile 'setup.ps1'; .\setup.ps1 -ServerIp 192.168.1.110 -AccessKey <密钥>"
#
# 方式二：手动下载后运行
#   .\setup-client.ps1 -ServerIp 192.168.1.110 -AccessKey <密钥>

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIp,

    [int]$Port = 10100,

    [Parameter(Mandatory=$true)]
    [string]$AccessKey,

    [switch]$DryRun,

    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
$BaseUrl = "http://${ServerIp}:${Port}"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $HOME ".codex\config.toml"
}
$configDir = Split-Path -Parent $ConfigPath
$CatalogPath = Join-Path $configDir "opencodex-catalog.json"

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
Write-Host "[1/5] 检测环境..." -ForegroundColor Yellow

# 检查 Codex 是否安装
$codexFound = $false
try { codex --version 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $codexFound = $true } } catch { }
if (-not $codexFound) {
    $exePath = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
    if (Test-Path $exePath) { $codexFound = $true }
}
if ($codexFound) {
    Write-Host "  [OK] Codex 已安装"
} else {
    Write-Host "  [提示] 未检测到 Codex CLI（只用桌面版不影响）" -ForegroundColor Yellow
}

# 确保配置目录存在
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-Host "  [OK] 已创建配置目录"
}

Write-Host ""

# ============================================================
# Step 2: 网络连通性测试
# ============================================================
Write-Host "[2/5] 测试网络连通性..." -ForegroundColor Yellow

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
    Write-Host "    2. 服务器上 opencodex 是否在运行？"
    Write-Host "    3. 服务器防火墙是否已放行端口 ${Port}？"
    Write-Host "    4. 你的网络是不是设成了'公用'？（改成'专用'）"
    exit 1
}

# 测试 API 是否正常
try {
    $result = Invoke-RestMethod -Uri "${BaseUrl}/v1/models" -Method Get -Headers @{"x-opencodex-api-key"=$AccessKey} -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($result.data) { $modelList = @($result.data) }
    Write-Host ("  [OK] 代理正常，提供 " + $modelList.Count + " 个模型")
} catch {
    Write-Host "  [警告] 无法获取模型列表（Codex 桌面版可能仍能使用）" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================
# Step 3: 下载模型目录
# ============================================================
Write-Host "[3/5] 同步模型目录..." -ForegroundColor Yellow

$catalogDownloaded = $false
try {
    $catalogUrl = "${BaseUrl}/v1/models"
    $modelsResponse = Invoke-RestMethod -Uri $catalogUrl -Method Get -Headers @{"x-opencodex-api-key"=$AccessKey} -TimeoutSec 10 -ErrorAction Stop

    # 将模型列表写入 Codex 兼容的 catalog 格式
    $catalog = @{
        fetched_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        models = @()
    }

    if ($modelsResponse.data) {
        foreach ($m in $modelsResponse.data) {
            $catalog.models += @{
                slug = $m.id
                display_name = if ($m.owned_by) { "$($m.id) ($($m.owned_by))" } else { $m.id }
                context_window = 131072
                input_modalities = @("text")
            }
        }
    }

    if (-not $DryRun) {
        $catalog | ConvertTo-Json -Depth 4 | Set-Content -Path $CatalogPath -Encoding UTF8
        $catalogDownloaded = $true
        Write-Host ("  [OK] 模型目录已同步 (" + $catalog.models.Count + " 个模型)")
    } else {
        Write-Host "  [预览] 将下载模型目录到 $CatalogPath"
        $catalogDownloaded = $true
    }
} catch {
    Write-Host "  [警告] 模型目录下载失败，将使用在线模式" -ForegroundColor Yellow
    Write-Host ("         错误: " + $_.Exception.Message)
}

Write-Host ""

# ============================================================
# Step 4: 配置 Codex
# ============================================================
Write-Host "[4/5] 配置 Codex..." -ForegroundColor Yellow

# 备份现有配置
if (Test-Path $ConfigPath) {
    $backupPath = $ConfigPath + ".backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    if (-not $DryRun) {
        Copy-Item $ConfigPath $backupPath
        Write-Host "  [OK] 已备份原配置到 $(Split-Path $backupPath -Leaf)"
    } else {
        Write-Host "  [预览] 将备份到 $(Split-Path $backupPath -Leaf)"
    }
}

# 读取现有配置
$lines = @()
if (Test-Path $ConfigPath) { $lines = Get-Content $ConfigPath }

# 构建新配置
$newLines = @()
$hasOpenaiUrl = $false
$hasProvider = $false
$hasCatalog = $false
$injected = $false

foreach ($line in $lines) {
    # 跳过旧的 openai_base_url / base_url / model_provider / model_catalog_json 行
    if ($line -match '^\s*openai_base_url\s*=') { continue }
    if ($line -match '^\s*base_url\s*=') {
        # 替换为 openai_base_url
        if (-not $injected) {
            $newLines += ""
            $newLines += "# === opencodex LAN Share 配置 ==="
            $newLines += ('openai_base_url = "' + $BaseUrl + '/v1"')
            $newLines += ('model_provider = "opencodex"')
            if ($catalogDownloaded) {
                $escapedPath = $CatalogPath -replace '\\', '\\'
                $newLines += ('model_catalog_json = "' + $escapedPath + '"')
            }
            $newLines += "# === 以上由 opencodex LAN Share 自动添加 ==="
            $newLines += ""
            $injected = $true
        }
        continue
    }
    if ($line -match '^\s*model_provider\s*=') { continue }
    if ($line -match '^\s*model_catalog_json\s*=') { continue }
    $newLines += $line
}

# 如果没注入过，在文件末尾追加
if (-not $injected) {
    $newLines += ""
    $newLines += "# === opencodex LAN Share 配置 ==="
    $newLines += ('openai_base_url = "' + $BaseUrl + '/v1"')
    $newLines += ('model_provider = "opencodex"')
    if ($catalogDownloaded) {
        $escapedPath = $CatalogPath -replace '\\', '\\'
        $newLines += ('model_catalog_json = "' + $escapedPath + '"')
    }
    $newLines += "# === 以上由 opencodex LAN Share 自动添加 ==="
}

if (-not $DryRun) {
    $newLines -join "`r`n" | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "  [OK] 配置已更新："
    Write-Host "       openai_base_url = ${BaseUrl}/v1"
    Write-Host "       model_provider = opencodex"
    if ($catalogDownloaded) {
        Write-Host "       model_catalog_json = $CatalogPath"
    }
} else {
    Write-Host "  [预览] 将更新配置"
}

Write-Host ""

# ============================================================
# Step 5: 设置环境变量
# ============================================================
Write-Host "[5/5] 设置认证密钥..." -ForegroundColor Yellow

# 设置用户级环境变量，Codex 启动时会读取
$envSet = $false
try {
    if (-not $DryRun) {
        [Environment]::SetEnvironmentVariable("OPENCODEX_OPENCODE_API_KEY", $AccessKey, "User")
        $envSet = $true
        Write-Host "  [OK] 已设置 OPENCODEX_OPENCODE_API_KEY 用户环境变量"
    } else {
        Write-Host "  [预览] 将设置 OPENCODEX_OPENCODE_API_KEY 环境变量"
    }
} catch {
    Write-Host "  [警告] 无法自动设置环境变量，请手动添加：" -ForegroundColor Yellow
    Write-Host "         Windows 设置 → 系统 → 高级系统设置 → 环境变量"
    Write-Host "         变量名: OPENCODEX_OPENCODE_API_KEY"
    Write-Host ("        变量值: " + $AccessKey)
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
Write-Host "    3. 在模型选择器中找 qwen-cloud/qwen3-coder-plus"
Write-Host ""
Write-Host "  常用模型："
Write-Host "    qwen-cloud/qwen3-coder-plus   （编程推荐）"
Write-Host "    qwen-cloud/qwen3-coder-flash  （更快更便宜）"
Write-Host "    deepseek/deepseek-v4-flash    （DeepSeek 最新）"
Write-Host ""

if (-not $envSet) {
    Write-Host "  ⚠ 重要：请设置环境变量后重启电脑生效" -ForegroundColor Yellow
    Write-Host ("  变量名: OPENCODEX_OPENCODE_API_KEY")
    Write-Host ("  变量值: " + $AccessKey)
    Write-Host ""
}

Write-Host "  如需恢复原配置："
Write-Host ("    备份文件在: " + $configDir)
Write-Host ""

exit 0
