# setup-lan.ps1
# opencodex LAN Share - Server Setup Script
# Usage (as Administrator): .\scripts\server\setup-lan.ps1 [-Port <port>] [-SkipFirewall] [-NoService]
#
# This script is IDEMPOTENT - safe to run multiple times.

param(
    [int]$Port = 10100,
    [switch]$SkipFirewall,
    [switch]$NoService
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..\..")

$StepsCompleted = 0
$StepsTotal = 0
$Warnings = @()

function Write-Step {
    param([string]$Message)
    Write-Host ("  [" + (Get-Date -Format "HH:mm:ss") + "] " + $Message)
}

function Write-StepOK {
    param([string]$Message)
    Write-Host ("    [OK] " + $Message) -ForegroundColor Green
    $script:StepsCompleted++
}

function Write-StepWarn {
    param([string]$Message)
    Write-Host ("    [WARN] " + $Message) -ForegroundColor Yellow
    $script:Warnings += $Message
}

function Write-StepFail {
    param([string]$Message)
    Write-Host ("    [FAIL] " + $Message) -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  opencodex LAN Share - Server Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  Port: " + $Port)
Write-Host ("  Time: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host ""

# ============================================================
# Step 1: Prerequisite checks
# ============================================================
$StepsTotal += 4
Write-Step "Step 1/4: Checking prerequisites..."

# Check admin rights
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-StepFail "This script requires Administrator privileges for firewall configuration."
    Write-Host ""
    Write-Host "  Please re-run as Administrator:" -ForegroundColor Yellow
    Write-Host "    Right-click PowerShell -> Run as Administrator"
    Write-Host "    Then: .\scripts\server\setup-lan.ps1"
    exit 1
}
Write-StepOK "Running as Administrator"

# Check opencodex binary
try {
    $ocxVersion = ocx --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-StepOK ("opencodex found: " + $ocxVersion.Trim())
    } else {
        Write-StepFail "opencodex CLI not found. Please install: npm install -g opencodex"
        exit 1
    }
} catch {
    Write-StepFail "opencodex CLI not found. Please install: npm install -g opencodex"
    exit 1
}

# ============================================================
# Step 2: Ensure proxy is running
# ============================================================
Write-Step "Step 2/4: Ensuring proxy is running on port " + $Port + "..."

$proxyRunning = $false
try {
    $healthResponse = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + "/health") -Method Get -TimeoutSec 5 -ErrorAction SilentlyContinue
    Write-StepOK "Proxy is already running on port " + $Port
    $proxyRunning = $true
} catch {
    Write-StepWarn "Proxy not running. Starting..."
    try {
        ocx start 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $healthResponse = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + "/health") -Method Get -TimeoutSec 10 -ErrorAction Stop
        Write-StepOK "Proxy started successfully on port " + $Port
        $proxyRunning = $true
    } catch {
        Write-StepFail "Failed to start proxy. Run 'ocx logs --tail 20' to diagnose."
        exit 1
    }
}

# Check hostname binding
$StepsTotal++
Write-Step "Step 3/4: Checking network binding..."

$hostname = ocx config get hostname 2>&1
if ($hostname -match "0\.0\.0\.0") {
    Write-StepOK "Proxy bound to 0.0.0.0 (accessible from LAN)"
} else {
    Write-StepWarn ("Proxy bound to " + $hostname.Trim() + ". Setting to 0.0.0.0 for LAN access...")
    ocx config set hostname "0.0.0.0" 2>&1 | Out-Null
    ocx restart 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    Write-StepOK "Proxy now bound to 0.0.0.0"
}

# ============================================================
# Step 3: Firewall configuration
# ============================================================
$fwRuleName = "OpenCodex LAN Share (Port " + $Port + ")"
$StepsTotal++
Write-Step "Step 4/5: Configuring Windows Firewall..."

if ($SkipFirewall) {
    Write-StepWarn "Firewall configuration skipped (--SkipFirewall flag)"
} else {
    $existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        if ($existingRule.Enabled -eq "True") {
            Write-StepOK "Firewall rule already exists and is enabled: " + $fwRuleName
        } else {
            Write-StepWarn "Firewall rule exists but is disabled. Enabling..."
            Set-NetFirewallRule -DisplayName $fwRuleName -Enabled True
            Write-StepOK "Firewall rule enabled"
        }
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName $fwRuleName `
                -Description "Allow LAN access to opencodex proxy on port " + $Port `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $Port `
                -Action Allow `
                -Profile Private `
                -ErrorAction Stop | Out-Null
            Write-StepOK ("Firewall rule created: " + $fwRuleName + " (Private profile only)")
        } catch {
            Write-StepFail ("Failed to create firewall rule: " + $_.Exception.Message)
            exit 1
        }
    }
}

# ============================================================
# Step 4: Auth Proxy (port 10101)
# ============================================================
$StepsTotal++
Write-Step "Step 5/6: Auth Proxy (port 10101)..."

$authProxyScript = Join-Path $PSScriptRoot "auth-proxy.py"
$authProxyPort = 10101

# Firewall for auth proxy
$fwRuleName2 = "OpenCodex Auth Proxy (Port " + $authProxyPort + ")"
if (-not $SkipFirewall) {
    $existingRule2 = Get-NetFirewallRule -DisplayName $fwRuleName2 -ErrorAction SilentlyContinue
    if (-not $existingRule2) {
        try {
            New-NetFirewallRule `
                -DisplayName $fwRuleName2 `
                -Description "Allow LAN access to opencodex auth proxy on port " + $authProxyPort `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $authProxyPort `
                -Action Allow `
                -Profile Private `
                -ErrorAction Stop | Out-Null
            Write-StepOK ("Firewall rule created for auth proxy port " + $authProxyPort)
        } catch {
            Write-StepWarn ("Failed to create auth proxy firewall rule: " + $_.Exception.Message)
        }
    }
}

# Check if auth proxy already running
$proxyRunning = $false
try {
    $testResult = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $authProxyPort + "/v1/models") -Method Get `
        -Headers @{"Authorization"="Bearer test"} -TimeoutSec 3 -ErrorAction SilentlyContinue
    Write-StepOK "Auth proxy already running on port " + $authProxyPort
    $proxyRunning = $true
} catch {}

if (-not $proxyRunning) {
    if (Test-Path $authProxyScript) {
        Write-StepWarn "Starting auth proxy..."
        Start-Process python3 -ArgumentList $authProxyScript, "--port", $authProxyPort `
            -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-StepOK ("Auth proxy started on port " + $authProxyPort)
    } else {
        Write-StepWarn ("auth-proxy.py not found at " + $authProxyScript)
    }
}

# ============================================================
# Step 5: Service installation (optional)
# ============================================================
$StepsTotal++
Write-Step "Step 6/6: Windows Service..."

if ($NoService) {
    Write-StepWarn "Service installation skipped (--NoService flag)"
} else {
    try {
        $serviceStatus = ocx service status 2>&1
        if ($serviceStatus -match "running|installed") {
            Write-StepOK "opencodex service is installed and running"
        } else {
            Write-StepWarn "Service not installed. Installing..."
            ocx service install 2>&1 | Out-Null
            Write-StepOK "Service installed (auto-starts on boot)"
        }
    } catch {
        Write-StepWarn ("Service setup skipped: " + $_.Exception.Message)
    }
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setup Complete" -ForegroundColor Green
Write-Host "========================================"
Write-Host ""

# Detect LAN IP
$lanIp = "unknown"
try {
    $ipInfo = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -match "^192\.168\." -or $_.IPAddress -match "^10\." -or $_.IPAddress -match "^172\.(1[6-9]|2[0-9]|3[0-1])\." } |
        Select-Object -First 1
    if ($ipInfo) { $lanIp = $ipInfo.IPAddress }
} catch { }

Write-Host "  Proxy endpoint:  http://" + $lanIp + ":" + $Port + "/v1"
Write-Host "  Local endpoint:  http://127.0.0.1:" + $Port + "/v1"
Write-Host ""

# Check/create access keys
Write-Host "  Access Keys:" -ForegroundColor Yellow
try {
    $keysOutput = ocx access key list 2>&1
    if ($keysOutput -match "No keys|no access keys|empty") {
        Write-Host "    No access keys found. Create one for each colleague:"
        Write-Host "      ocx access key create <colleague-name>"
    } else {
        Write-Host $keysOutput
    }
} catch {
    Write-Host "    Run 'ocx access key create <name>' to generate a key for a colleague"
}

Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Yellow
Write-Host "    1. Create access keys for colleagues:"
Write-Host "       .\scripts\server\manage-users.ps1 -Create"
Write-Host ""
Write-Host "    2. Send each colleague:"
Write-Host "       - Their access key (keep it secret!)"
Write-Host "       - The proxy address: http://" + $lanIp + ":" + $Port + "/v1"
Write-Host "       - The client setup script: .\scripts\client\setup-client.ps1"
Write-Host ""
Write-Host "    3. Colleague runs:"
Write-Host "       .\scripts\client\setup-client.ps1 -ServerIp " + $lanIp + " -AccessKey <their-key>"
Write-Host ""

if ($Warnings.Count -gt 0) {
    Write-Host "  Warnings (" + $Warnings.Count + "):" -ForegroundColor Yellow
    foreach ($w in $Warnings) {
        Write-Host "    - " + $w
    }
}

Write-Host "  Run tests to verify: .\tests\test-connectivity.ps1" -ForegroundColor Cyan
Write-Host ""

exit 0
