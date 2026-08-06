# setup-client.ps1
# opencodex LAN Share - Windows Client Setup (one-liner friendly)
#
# This script:
#   1. Detects Node.js (installs if missing)
#   2. Installs opencodex globally via npm
#   3. Tests connectivity to the LAN server
#   4. Configures opencodex to route through the LAN proxy
#   5. Sets the OPENAI_API_KEY environment variable
#
# Usage:
#   .\setup-client.ps1 -ServerIp 192.168.1.110 -AccessKey ocx_data_xxxx

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIp,

    [int]$Port = 10101,

    [Parameter(Mandatory=$true)]
    [string]$AccessKey,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$BaseUrl = "http://" + $ServerIp + ":" + $Port
$ConfigPath = Join-Path $HOME ".codex\config.toml"
$ConfigDir = Split-Path -Parent $ConfigPath

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  opencodex LAN Share - Client Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  Server: " + $BaseUrl)
Write-Host ("  Config: " + $ConfigPath)
if ($DryRun) { Write-Host "  Mode:   DRY RUN (preview only)" -ForegroundColor Yellow }
Write-Host ""

# ============================================================
# Step 0: Detect and install opencodex
# ============================================================
Write-Host "[0/5] Checking Node.js and opencodex..." -ForegroundColor Yellow

# 0a: Check Node.js
$nodeOk = $false
try {
    $nodeVersion = node --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  [OK] Node.js " + $nodeVersion.Trim())
        $nodeOk = $true
    }
} catch { }

if (-not $nodeOk) {
    Write-Host "  [WARN] Node.js not found. Attempting to install via winget..." -ForegroundColor Yellow
    try {
        if ($DryRun) {
            Write-Host "  [DRY] Would run: winget install OpenJS.NodeJS.LTS"
        } else {
            winget install OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
            Write-Host "  [OK] Node.js installed. Please restart this script in a new terminal."
            Write-Host ""
            Write-Host "  [!] Node.js was just installed. You need to:" -ForegroundColor Yellow
            Write-Host "      1. Close this PowerShell window"
            Write-Host "      2. Open a NEW PowerShell window"
            Write-Host "      3. Re-run this script:"
            Write-Host ("         .\setup-client.ps1 -ServerIp " + $ServerIp + " -AccessKey " + $AccessKey)
            exit 0
        }
    } catch {
        Write-Host "  [FAIL] Cannot install Node.js automatically." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Please install Node.js manually:" -ForegroundColor Yellow
        Write-Host "    1. Visit https://nodejs.org/"
        Write-Host "    2. Download and install the LTS version"
        Write-Host "    3. Restart your terminal and re-run this script"
        exit 1
    }
}

# 0b: Check opencodex
$ocxOk = $false
try {
    $ocxVersion = ocx --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  [OK] opencodex " + $ocxVersion.Trim())
        $ocxOk = $true
    }
} catch { }

if (-not $ocxOk) {
    Write-Host "  [WARN] opencodex not found. Installing via npm..." -ForegroundColor Yellow
    if ($DryRun) {
        Write-Host "  [DRY] Would run: npm install -g @bitkyc08/opencodex"
    } else {
        try {
            $installResult = npm install -g @bitkyc08/opencodex 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] opencodex installed successfully"
                $ocxOk = $true
            } else {
                throw "npm install failed"
            }
        } catch {
            Write-Host "  [FAIL] Cannot install opencodex." -ForegroundColor Red
            Write-Host ""
            Write-Host "  Please install manually:" -ForegroundColor Yellow
            Write-Host "    npm install -g @bitkyc08/opencodex"
            Write-Host ""
            Write-Host ("  Error details: " + $_.Exception.Message)
            exit 1
        }
    }
}

Write-Host ""

# ============================================================
# Step 1: Environment check
# ============================================================
Write-Host "[1/5] Checking environment..." -ForegroundColor Yellow

if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}
Write-Host "  [OK] Config directory ready"

Write-Host ""

# ============================================================
# Step 2: Connectivity test
# ============================================================
Write-Host "[2/5] Testing connectivity..." -ForegroundColor Yellow

$connected = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connected = $tcp.ConnectAsync($ServerIp, $Port).Wait(3000)
    $tcp.Close()
} catch { }

if ($connected) {
    Write-Host ("  [OK] Connected to " + $ServerIp + ":" + $Port)
} else {
    Write-Host ("  [FAIL] Cannot reach " + $ServerIp + ":" + $Port) -ForegroundColor Red
    Write-Host ""
    Write-Host "  Troubleshooting:"
    Write-Host "    1. Is the server online and on the same LAN?"
    Write-Host "    2. Is auth-proxy.py running on the server? (netstat -an | findstr 10101)"
    Write-Host ("    3. Is the firewall open for port " + $Port + "?")
    Write-Host "    4. Is your network profile set to Private?"
    exit 1
}

# Test API
try {
    $headers = @{"Authorization" = "Bearer " + $AccessKey}
    $result = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $headers -TimeoutSec 10 -ErrorAction Stop
    $count = if ($result.data) { @($result.data).Count } else { 0 }
    Write-Host ("  [OK] API OK, " + $count + " models available")
} catch {
    $msg = $_.Exception.Message
    if ($msg -match "401") {
        Write-Host "  [WARN] API returned 401 - your AccessKey may not be registered on the server." -ForegroundColor Yellow
        Write-Host "         Ask the server admin to run:"
        Write-Host "           .\scripts\server\manage-users.ps1 -Create \"YourName\""
        Write-Host "         Then re-run this script with your new AccessKey."
    } else {
        Write-Host ("  [WARN] API test: " + $msg) -ForegroundColor Yellow
    }
}

Write-Host ""

# ============================================================
# Step 2.5: Download model catalog
# ============================================================
Write-Host "[2.5/5] Downloading model catalog..." -ForegroundColor Yellow

$catalogPath = Join-Path $ConfigDir "opencodex-catalog.json"
$catalogOk = $false

try {
    $catalogHeaders = @{"Authorization" = "Bearer " + $AccessKey}
    $catalogData = Invoke-RestMethod -Uri ($BaseUrl + "/catalog.json") -Method Get -Headers $catalogHeaders -TimeoutSec 30 -ErrorAction Stop
    if ($catalogData.models) {
        $catalogJson = $catalogData | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($catalogPath, $catalogJson, [System.Text.Encoding]::UTF8)
        $modelCount = @($catalogData.models).Count
        Write-Host ("  [OK] Downloaded catalog with " + $modelCount + " models")
        $catalogOk = $true
    } else {
        Write-Host "  [WARN] Catalog response has no models field" -ForegroundColor Yellow
    }
} catch {
    $catalogMsg = $_.Exception.Message
    if ($catalogMsg -match "404") {
        Write-Host "  [WARN] Catalog endpoint not available on server (auth-proxy may need update)" -ForegroundColor Yellow
        Write-Host "         The server admin should update auth-proxy.py to the latest version."
    } else {
        Write-Host ("  [WARN] Catalog download failed: " + $catalogMsg) -ForegroundColor Yellow
        Write-Host "         Models may not appear in Codex Desktop until this is resolved."
    }
}

Write-Host ""

# ============================================================
# Step 3: Configure Codex
# ============================================================
Write-Host "[3/6] Configuring Codex..." -ForegroundColor Yellow

# Backup existing config
if (Test-Path $ConfigPath) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = $ConfigPath + ".backup-" + $ts
    if (-not $DryRun) {
        Copy-Item $ConfigPath $backupPath
        Write-Host ("  [OK] Backup saved: " + (Split-Path $backupPath -Leaf))
    }
}

# Read and clean old config
$lines = @()
if (Test-Path $ConfigPath) { $lines = Get-Content $ConfigPath }

$newLines = @()
$injected = $false
$skipSection = $false

foreach ($line in $lines) {
    $trimmed = $line.Trim()
    # Skip old [model_providers.opencodex] section
    if ($trimmed -eq '[model_providers.opencodex]') { $skipSection = $true; continue }
    if ($skipSection) {
        if ($trimmed -match '^\[.*\]') { $skipSection = $false }
        else { continue }
    }
    # Remove old proxy/opencodex config lines
    if ($trimmed -match '^openai_base_url\s*=') { continue }
    if ($trimmed -match '^model_provider\s*=') { continue }
    if ($trimmed -match '^model_catalog_json\s*=') { continue }
    if ($trimmed -match '^wire_api\s*=') { continue }

    if ($trimmed -match '^base_url\s*=') {
        if (-not $injected) {
            $newLines += ""
            $newLines += "# === opencodex LAN Share ==="
            $newLines += "base_url = """ + $BaseUrl + "/v1"""
            if ($catalogOk) {
                $newLines += "model_catalog_json = '" + $catalogPath + "'"
            }
            $newLines += "model_provider = ""opencodex"""
            $newLines += "wire_api = ""responses"""
            $newLines += ""
            $newLines += "[model_providers.opencodex]"
            $newLines += "name = ""OpenCodex Proxy (" + $ServerIp + ")"""
            $newLines += "base_url = """ + $BaseUrl + "/v1"""
            if ($catalogOk) {
                $newLines += "model_catalog_json = '" + $catalogPath + "'"
            }
            $newLines += "wire_api = ""responses"""
            $newLines += "requires_openai_auth = true"
            $newLines += "# ============================"
            $newLines += ""
            $injected = $true
        }
        continue
    }
    $newLines += $line
}

if (-not $injected) {
    $newLines += ""
    $newLines += "# === opencodex LAN Share ==="
    $newLines += "base_url = """ + $BaseUrl + "/v1"""
            if ($catalogOk) {
                $newLines += "model_catalog_json = '" + $catalogPath + "'"
            }
    $newLines += "model_provider = ""opencodex"""
    $newLines += "wire_api = ""responses"""
    $newLines += ""
    $newLines += "[model_providers.opencodex]"
    $newLines += "name = ""OpenCodex Proxy (" + $ServerIp + ")"""
    $newLines += "base_url = """ + $BaseUrl + "/v1"""
            if ($catalogOk) {
                $newLines += "model_catalog_json = '" + $catalogPath + "'"
            }
    $newLines += "wire_api = ""responses"""
    $newLines += "requires_openai_auth = true"
    $newLines += "# ============================"
}

if (-not $DryRun) {
    $newLines -join "`r`n" | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host ("  [OK] base_url = " + $BaseUrl + "/v1")
    Write-Host "  [OK] model_provider = opencodex (with model_providers section)"
} else {
    Write-Host "  [DRY] Would update config"
}

Write-Host ""

# ============================================================
# Step 3.5: Refresh Codex model cache (CRITICAL for model list update)
# ============================================================
# Codex Desktop does NOT fetch the model list from /v1/models at runtime.
# It reads ~/.codex/models_cache.json, which opencodex generates from the catalog
# with fetched_at forced to 2000-01-01 (so Codex always re-reads). Writing the
# catalog alone keeps the list stale. `ocx sync-cache` re-reads the catalog and
# rewrites models_cache.json WITHOUT starting a local proxy or touching base_url,
# so it is safe here and keeps traffic routed through the LAN server.
$modelsCachePath = Join-Path $ConfigDir "models_cache.json"
if ($catalogOk -and $ocxOk) {
    Write-Host "[3.5/6] Refreshing Codex model cache..." -ForegroundColor Yellow
    if (-not $DryRun) {
        # Preserve the previous $ErrorActionPreference and only trust $LASTEXITCODE,
        # because opencodex may write normal logs to stderr which, under
        # $ErrorActionPreference="Stop", would be misreported as a failure.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $syncOut = & ocx sync-cache 2>&1 | Out-String
            $syncExit = $LASTEXITCODE
            if ($syncExit -eq 0) {
                Write-Host "  [OK] Codex model cache refreshed (models_cache.json rewritten)"
            } else {
                Write-Host "  [WARN] ocx sync-cache 返回非零 (exit=$syncExit)" -ForegroundColor Yellow
                Write-Host ("         " + $syncOut.Trim())
                # Fallback: a stale models_cache.json is read verbatim by Codex Desktop
                # on next launch. Removing it (after backup) forces Codex to rebuild it.
                if (Test-Path $modelsCachePath) {
                    $mcBackup = $modelsCachePath + ".backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
                    Copy-Item $modelsCachePath $mcBackup
                    Remove-Item -LiteralPath $modelsCachePath -Force
                    Write-Host "  [WARN] 已备份并删除陈旧的 models_cache.json，下次启动 Codex 将强制重建" -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host "  [WARN] 无法刷新 Codex 模型缓存" -ForegroundColor Yellow
            Write-Host ("         " + $_.Exception.Message)
        } finally {
            $ErrorActionPreference = $prevEAP
        }
    } else {
        Write-Host "  [DRY] Would run: ocx sync-cache"
    }
    Write-Host ""
} elseif ($catalogOk) {
    Write-Host "  [SKIP] opencodex 未就绪，跳过缓存刷新" -ForegroundColor Yellow
    Write-Host "         请先安装 opencodex 后重跑本脚本，或手动执行: ocx sync-cache" -ForegroundColor Yellow
    Write-Host "         否则 Codex Desktop 模型列表仍不会更新" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
# Step 4: Set API key
# ============================================================
Write-Host "[4/6] Setting API key..." -ForegroundColor Yellow

$envSet = $false
try {
    if (-not $DryRun) {
        # Remove old conflicting vars
        [Environment]::SetEnvironmentVariable("OPENCODEX_OPENCODE_API_KEY", $null, "User")
        # Set standard OPENAI_API_KEY
        [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $AccessKey, "User")
        $envSet = $true
        Write-Host "  [OK] OPENAI_API_KEY set in User environment"
    }
} catch {
    Write-Host "  [WARN] Cannot set env var automatically" -ForegroundColor Yellow
    Write-Host "         Please add manually:"
    Write-Host "         Settings -> System -> Advanced -> Environment Variables"
    Write-Host "         Name:  OPENAI_API_KEY"
    Write-Host ("         Value: " + $AccessKey)
}

Write-Host ""

# ============================================================
# Step 5: Verify opencodex can read config
# ============================================================
Write-Host "[5/6] Verifying opencodex configuration..." -ForegroundColor Yellow

if ($ocxOk) {
    try {
        $modelResult = ocx models list 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] opencodex can read config and fetch models"
        } else {
            Write-Host "  [WARN] opencodex models list returned non-zero" -ForegroundColor Yellow
            Write-Host ("         " + ($modelResult -join " "))
        }
    } catch {
        Write-Host "  [WARN] Could not verify opencodex config" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [SKIP] opencodex not available for verification"
}

Write-Host ""

# ============================================================
# Done
# ============================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "========================================"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Fully quit Codex Desktop (right-click tray icon -> Quit)"
Write-Host "    2. Reopen Codex Desktop"
Write-Host "    3. Models should appear in the model selector"
Write-Host ""
Write-Host "  How it works:"
Write-Host "    Your opencodex -> OpenAI protocol -> Server auth-proxy"
Write-Host "    -> opencodex proxy -> Alibaba / DeepSeek / OpenAI"
Write-Host ""
Write-Host "  If models still do not appear after reopening:"
Write-Host "    Run in a terminal: ocx sync-cache"
Write-Host "    Then fully quit and reopen Codex Desktop."
Write-Host "    (ocx sync-cache --restart-codex will also restart Codex, but it may"
Write-Host "     interrupt any in-progress conversation.)"
Write-Host ""

if (-not $envSet) {
    Write-Host "  [!] Important: set OPENAI_API_KEY env var, then restart your PC" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  To revert:"
Write-Host ("    Restore from backup file in " + $ConfigDir)
Write-Host "    Or remove lines between # === opencodex LAN Share === markers"
Write-Host ""

exit 0
