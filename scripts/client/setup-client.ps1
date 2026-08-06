# setup-client.ps1
# opencodex LAN Share - Windows Client Setup (one-liner friendly)
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
# Step 1: Environment check
# ============================================================
Write-Host "[1/4] Checking environment..." -ForegroundColor Yellow

if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}
Write-Host "  [OK] Config directory ready"

Write-Host ""

# ============================================================
# Step 2: Connectivity test
# ============================================================
Write-Host "[2/4] Testing connectivity..." -ForegroundColor Yellow

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
    Write-Host "    3. Is the firewall open for port " + $Port + "?"
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
    Write-Host ("  [WARN] API test: " + $msg) -ForegroundColor Yellow
}

Write-Host ""

# ============================================================
# Step 3: Configure Codex
# ============================================================
Write-Host "[3/4] Configuring Codex..." -ForegroundColor Yellow

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

foreach ($line in $lines) {
    $trimmed = $line.Trim()
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
    $newLines += "# ============================"
}

if (-not $DryRun) {
    $newLines -join "`r`n" | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host ("  [OK] base_url = " + $BaseUrl + "/v1")
    Write-Host "       (no model_provider - uses standard OpenAI protocol)"
} else {
    Write-Host "  [DRY] Would update config"
}

Write-Host ""

# ============================================================
# Step 4: Set API key
# ============================================================
Write-Host "[4/4] Setting API key..." -ForegroundColor Yellow

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
Write-Host "    Your Codex -> OpenAI protocol -> Server proxy"
Write-Host "    -> opencodex -> Alibaba / DeepSeek / OpenAI"
Write-Host ""

if (-not $envSet) {
    Write-Host "  [!] Important: set OPENAI_API_KEY env var, then restart your PC" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  To revert:"
Write-Host "    Restore from backup file in " + $ConfigDir
Write-Host "    Or remove lines between # === opencodex LAN Share === markers"
Write-Host ""

exit 0
