# diagnostics.ps1
# opencodex LAN Share - Diagnostic Tool
# Usage: .\tools\diagnostics.ps1 [-ServerIp <ip>] [-Port <port>]
# Runs on either server or client side to diagnose connectivity issues.

param(
    [string]$ServerIp = "127.0.0.1",
    [int]$Port = 10100
)

$ErrorActionPreference = "Continue"
$BaseUrl = "http://" + $ServerIp + ":" + $Port

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  opencodex LAN Share - Diagnostics" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  Target:  " + $BaseUrl)
Write-Host ("  Time:    " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host ("  Machine: " + $env:COMPUTERNAME)
Write-Host ""

# === System Info ===
Write-Host "--- System ---" -ForegroundColor Yellow
Write-Host ("  OS:      " + (Get-CimInstance Win32_OperatingSystem).Caption)
Write-Host ("  User:    " + $env:USERNAME)

# Get LAN IPs
$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch "^127\." } | ForEach-Object { $_.IPAddress + " (" + $_.InterfaceAlias + ")" }
Write-Host "  LAN IPs: " + ($ips -join ", ")

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("  Admin:   " + (if ($isAdmin) { "Yes" } else { "No (some checks limited)" }))

# === Node.js ===
Write-Host ""
Write-Host "--- Node.js ---" -ForegroundColor Yellow
$nodeFound = Get-Command node -ErrorAction SilentlyContinue
if ($nodeFound) {
    $nodeVersion = node --version 2>&1
    Write-Host ("  Node.js: " + $nodeVersion.Trim())
} else {
    Write-Host "  Node.js: NOT FOUND" -ForegroundColor Red
    Write-Host "  Fix:     Install Node.js from https://nodejs.org/" -ForegroundColor Yellow
}

# === opencodex Status ===
Write-Host ""
Write-Host "--- opencodex ---" -ForegroundColor Yellow
$ocxFound = Get-Command ocx -ErrorAction SilentlyContinue
if ($ocxFound) {
    Write-Host ("  CLI:     " + $ocxFound.Source)
    $ocxVersion = ocx --version 2>&1
    Write-Host ("  Version: " + $ocxVersion.Trim())
} else {
    Write-Host "  CLI:     NOT FOUND" -ForegroundColor Red
    Write-Host "  Fix:     npm install -g @bitkyc08/opencodex" -ForegroundColor Yellow
}

# === Codex Config ===
Write-Host ""
Write-Host "--- Config ---" -ForegroundColor Yellow
$configPath = Join-Path $HOME ".codex\config.toml"
if (Test-Path $configPath) {
    Write-Host ("  Config:  " + $configPath + " (exists)")
    $configContent = Get-Content $configPath -Raw
    if ($configContent -match 'base_url\s*=\s*"([^"]*)"') {
        Write-Host ("  base_url:" + $matches[1])
    } else {
        Write-Host "  base_url: NOT CONFIGURED" -ForegroundColor Red
    }
    if ($configContent -match 'model_provider\s*=\s*"([^"]*)"') {
        Write-Host ("  Provider:" + $matches[1])
    }
    if ($configContent -match 'openai_base_url\s*=\s*"([^"]*)"') {
        Write-Host ("  WARNING:  openai_base_url found (deprecated - standard Codex Desktop ignores this)" -ForegroundColor Yellow)
    }
} else {
    Write-Host "  Config:  NOT FOUND" -ForegroundColor Red
}

# === Network ===
Write-Host ""
Write-Host "--- Network ---" -ForegroundColor Yellow

# TCP connectivity
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connected = $tcp.ConnectAsync($ServerIp, $Port).Wait(3000)
    if ($connected) {
        Write-Host ("  TCP:     " + $ServerIp + ":" + $Port + " REACHABLE") -ForegroundColor Green
    } else {
        Write-Host ("  TCP:     " + $ServerIp + ":" + $Port + " UNREACHABLE") -ForegroundColor Red
    }
    $tcp.Close()
} catch {
    Write-Host ("  TCP:     " + $ServerIp + ":" + $Port + " ERROR - " + $_.Exception.Message) -ForegroundColor Red
}

# HTTP health
try {
    $response = Invoke-WebRequest -Uri ($BaseUrl + "/health") -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Host ("  HTTP:    " + $BaseUrl + "/health -> " + $response.StatusCode) -ForegroundColor Green
} catch {
    Write-Host ("  HTTP:    " + $BaseUrl + "/health -> FAILED") -ForegroundColor Red
}

# Models endpoint
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($response.data) { $modelList = @($response.data) }
    $count = $modelList.Count
    Write-Host ("  Models:  " + $count + " available") -ForegroundColor $(if ($count -gt 0) { "Green" } else { "Red" })
} catch {
    Write-Host ("  Models:  FAILED - " + $_.Exception.Message) -ForegroundColor Red
}

# DNS/name resolution
try {
    $resolved = [System.Net.Dns]::GetHostEntry($ServerIp)
    Write-Host ("  DNS:     " + $ServerIp + " resolves OK")
} catch {
    Write-Host ("  DNS:     " + $ServerIp + " - " + $_.Exception.Message) -ForegroundColor Yellow
}

# === Firewall (server-side only) ===
if ($ServerIp -eq "127.0.0.1" -and $isAdmin) {
    Write-Host ""
    Write-Host "--- Firewall ---" -ForegroundColor Yellow
    $fwRule = Get-NetFirewallRule -DisplayName "*OpenCodex*" -ErrorAction SilentlyContinue
    if ($fwRule) {
        Write-Host ("  Rule:    " + $fwRule.DisplayName)
        Write-Host ("  Enabled: " + $fwRule.Enabled)
        Write-Host ("  Profile: " + $fwRule.Profile)
        Write-Host ("  Action:  " + $fwRule.Action)
    } else {
        Write-Host "  Rule:    NOT FOUND" -ForegroundColor Red
        Write-Host "  Fix:     Run .\scripts\server\setup-lan.ps1 as Administrator" -ForegroundColor Yellow
    }
}

# === Port listening (server-side only) ===
if ($ServerIp -eq "127.0.0.1") {
    Write-Host ""
    Write-Host "--- Port ---" -ForegroundColor Yellow
    $netstat = netstat -an 2>$null | Select-String (":" + $Port) | Select-String "LISTENING"
    if ($netstat) {
        $info = ($netstat -join " ").Trim()
        Write-Host ("  " + $info)
        if ($info -match "0\.0\.0\.0:" + $Port) {
            Write-Host "  Binding: 0.0.0.0 (LAN accessible)" -ForegroundColor Green
        } elseif ($info -match "127\.0\.0\.1:" + $Port) {
            Write-Host "  Binding: 127.0.0.1 (localhost only - NOT LAN accessible)" -ForegroundColor Red
            Write-Host "  Fix:     ocx config set hostname 0.0.0.0 ; ocx restart" -ForegroundColor Yellow
        }
    } else {
        Write-Host ("  Port " + $Port + ": NOT LISTENING") -ForegroundColor Red
        Write-Host "  Fix:     ocx start" -ForegroundColor Yellow
    }
}

# === Summary ===
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Diagnostics complete." -ForegroundColor Cyan
Write-Host "  If issues found, check the 'Fix:' suggestions above." -ForegroundColor Yellow
Write-Host "========================================"
Write-Host ""
