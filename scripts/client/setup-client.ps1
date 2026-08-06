# setup-client.ps1
# opencodex LAN Share - Windows Client Setup Script
# Usage: .\scripts\client\setup-client.ps1 -ServerIp <ip> [-Port <port>]
#
# Configures a colleague's Codex desktop to use the LAN opencodex proxy.
# IDEMPOTENT - safe to run multiple times.

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerIp,

    [int]$Port = 10100,

    [switch]$DryRun,

    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Determine Codex config path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $HOME ".codex\config.toml"
}

$BaseUrl = "http://" + $ServerIp + ":" + $Port

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  opencodex LAN Share - Client Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  Server: " + $BaseUrl)
Write-Host ("  Config: " + $ConfigPath)
if ($DryRun) {
    Write-Host "  Mode:   DRY RUN (no changes will be made)" -ForegroundColor Yellow
}
Write-Host ""

# ============================================================
# Step 1: Prerequisites
# ============================================================
Write-Host "Step 1/4: Checking prerequisites..." -ForegroundColor Yellow

# Check Codex is installed
$codexFound = $false
try {
    $codexVersion = codex --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  [OK] Codex CLI found: " + $codexVersion.Trim())
        $codexFound = $true
    }
} catch { }

if (-not $codexFound) {
    # Check for Codex in default install location
    $codexPaths = @(
        "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe",
        "$env:APPDATA\OpenAI\Codex\bin\codex.exe"
    )
    foreach ($p in $codexPaths) {
        if (Test-Path $p) {
            Write-Host ("  [OK] Codex found at: " + $p)
            $codexFound = $true
            break
        }
    }
}

if (-not $codexFound) {
    Write-Host "  [WARN] Codex CLI not detected. If you use Codex Desktop only, this is OK." -ForegroundColor Yellow
    Write-Host "         Install Codex from: https://codex.openai.com" -ForegroundColor Yellow
}

# Check config directory exists
$configDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-Host ("  [OK] Created config directory: " + $configDir)
}

# ============================================================
# Step 2: Connectivity test
# ============================================================
Write-Host "Step 2/4: Testing connectivity to proxy..." -ForegroundColor Yellow

$connected = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connected = $tcp.ConnectAsync($ServerIp, $Port).Wait(3000)
    $tcp.Close()
} catch { }

if ($connected) {
    Write-Host ("  [OK] Successfully connected to " + $BaseUrl)
} else {
    Write-Host ("  [FAIL] Cannot reach " + $BaseUrl) -ForegroundColor Red
    Write-Host ""
    Write-Host "  Troubleshooting:" -ForegroundColor Yellow
    Write-Host "    1. Is the server machine online and on the same LAN?"
    Write-Host "    2. Is the opencodex proxy running on the server? (ocx status)"
    Write-Host "    3. Is the Windows Firewall configured on the server? (run setup-lan.ps1)"
    Write-Host "    4. Is your network profile set to Private? (check Windows Settings)"
    exit 1
}

# Check models endpoint
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($response.data) { $modelList = @($response.data) }
    $modelCount = $modelList.Count
    if ($modelCount -gt 0) {
        Write-Host ("  [OK] Proxy serving " + $modelCount + " models")
    }
} catch {
    Write-Host "  [WARN] Could not fetch model list (may not affect functionality)" -ForegroundColor Yellow
}

# ============================================================
# Step 3: Configure Codex
# ============================================================
Write-Host "Step 3/4: Configuring Codex..." -ForegroundColor Yellow

$existingConfig = @{}
if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*(.+)$') {
            $existingConfig[$matches[1]] = $matches[2].Trim()
        }
    }
}

# Check if already configured for this proxy
if ($existingConfig.ContainsKey("openai_base_url") -and $existingConfig["openai_base_url"] -match [regex]::Escape($ServerIp)) {
    Write-Host "  [OK] Already configured for this proxy - nothing to change"
} else {
    # Backup existing config
    if (Test-Path $ConfigPath) {
        $backupPath = $ConfigPath + ".backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        if (-not $DryRun) {
            Copy-Item $ConfigPath $backupPath
            Write-Host ("  [OK] Backed up existing config to: " + (Split-Path $backupPath -Leaf))
        } else {
            Write-Host ("  [DRY] Would backup to: " + (Split-Path $backupPath -Leaf))
        }
    }

    # Read current config content
    $lines = @()
    if (Test-Path $ConfigPath) {
        $lines = Get-Content $ConfigPath
    }

    # Changes to make
    $changes = @()

    # Add/update openai_base_url
    $baseUrlFound = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*openai_base_url\s*=') {
            $newLines += ('openai_base_url = "' + $BaseUrl + '/v1"')
            $baseUrlFound = $true
            $changes += "Set openai_base_url = " + $BaseUrl + "/v1"
        } elseif ($line -match '^\s*base_url\s*=') {
            # Replace base_url with openai_base_url
            $newLines += ('openai_base_url = "' + $BaseUrl + '/v1"')
            $baseUrlFound = $true
            $changes += "Replaced base_url with openai_base_url = " + $BaseUrl + "/v1"
        } else {
            $newLines += $line
        }
    }
    if (-not $baseUrlFound) {
        $newLines += ""
        $newLines += "# opencodex LAN Share - Proxy Configuration"
        $newLines += ('openai_base_url = "' + $BaseUrl + '/v1"')
        $changes += "Added openai_base_url = " + $BaseUrl + "/v1"
    }

    # Add model_provider if not present
    $providerFound = $false
    foreach ($line in $newLines) {
        if ($line -match '^\s*model_provider\s*=') {
            $providerFound = $true
            break
        }
    }
    if (-not $providerFound) {
        $newLines += ('model_provider = "opencodex"')
        $changes += "Added model_provider = opencodex"
    }

    if (-not $DryRun) {
        $newLines -join "`r`n" | Set-Content -Path $ConfigPath -Encoding UTF8
        Write-Host "  [OK] Configuration updated:"
        foreach ($c in $changes) {
            Write-Host ("       " + $c)
        }
    } else {
        Write-Host "  [DRY] Would apply changes:"
        foreach ($c in $changes) {
            Write-Host ("       " + $c)
        }
    }
}

# ============================================================
# Step 4: Available models
# ============================================================
Write-Host "Step 4/4: Available models..." -ForegroundColor Yellow

try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($response.data) { $modelList = @($response.data) }

    # Show key model groups
    $qwenModels = ($modelList | Where-Object { $_.id -match "^qwen-cloud/qwen3-coder" } | Select-Object -First 5).id
    $dsModels = ($modelList | Where-Object { $_.id -match "^deepseek/" }).id
    $gptModels = ($modelList | Where-Object { $_.id -match "^gpt-5" } | Select-Object -First 3).id

    Write-Host ""
    Write-Host "  Model groups available through the proxy:" -ForegroundColor Green
    if ($gptModels) {
        Write-Host "    GPT:     " + ($gptModels -join ", ")
    }
    if ($dsModels) {
        Write-Host "    DeepSeek: " + ($dsModels -join ", ")
    }
    if ($qwenModels) {
        Write-Host "    Qwen:    " + ($qwenModels -join ", ")
    }
    Write-Host ("    (+ " + ($modelList.Count - 10) + " more models)")
} catch {
    Write-Host "  [WARN] Could not fetch model list" -ForegroundColor Yellow
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Client Setup Complete!" -ForegroundColor Green
Write-Host "========================================"
Write-Host ""
Write-Host "  Your Codex is now configured to use the LAN proxy at:"
Write-Host ("    " + $BaseUrl + "/v1")
Write-Host ""
Write-Host "  To use: Open Codex Desktop and select a model from the list."
Write-Host "  In the model selector, pick any qwen-cloud/* or deepseek/* model."
Write-Host ""
Write-Host "  To revert: Restore from the backup file in " + $configDir -ForegroundColor Yellow
Write-Host ""
exit 0
