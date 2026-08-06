# test-connectivity.ps1
# opencodex LAN Share - Connectivity Test Suite
# Usage: .\tests\test-connectivity.ps1 [-ServerIp <ip>] [-Port <port>]

param(
    [string]$ServerIp = "127.0.0.1",
    [int]$Port = 10100,
    [string]$AccessKey = ""
)

$ErrorActionPreference = "Continue"
$BaseUrl = "http://" + $ServerIp + ":" + $Port

$TestsPassed = 0
$TestsFailed = 0
$Results = @()

function Write-TestResult {
    param([string]$Id, [string]$Name, [bool]$Passed, [string]$Detail)
    $status = if ($Passed) { "PASS" } else { "FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    Write-Host ("  [" + $status + "] " + $Id + " - " + $Name) -ForegroundColor $color
    if (-not $Passed -and $Detail) {
        Write-Host ("         " + $Detail) -ForegroundColor "Yellow"
    }
    $script:Results += @{ Id = $Id; Name = $Name; Passed = $Passed; Detail = $Detail }
    if ($Passed) { $script:TestsPassed++ } else { $script:TestsFailed++ }
}

Write-Host ""
Write-Host "=== opencodex LAN Share - Connectivity Tests ===" -ForegroundColor Cyan
Write-Host ("  Target: " + $BaseUrl)
Write-Host ("  Time:   " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host ""

# TC-CONN-01: Health check (any response = proxy alive)
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connected = $tcp.ConnectAsync("127.0.0.1", $Port).Wait(3000)
    if ($connected) {
        $tcp.Close()
        Write-TestResult "TC-CONN-01" ("Proxy reachable on port " + $Port) $true ""
    } else {
        $tcp.Close()
        Write-TestResult "TC-CONN-01" ("Proxy reachable on port " + $Port) $false "TCP connection failed"
    }
} catch {
    Write-TestResult "TC-CONN-01" ("Proxy reachable on port " + $Port) $false ("Cannot connect - " + $_.Exception.Message)
}

# TC-CONN-02: Models endpoint reachable
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -TimeoutSec 10 -ErrorAction Stop
    $modelCount = 0
    if ($response.data) { $modelCount = @($response.data).Count }
    elseif ($response.models) { $modelCount = @($response.models).Count }
    if ($modelCount -gt 0) {
        Write-TestResult "TC-CONN-02" ("Models list /v1/models (" + $modelCount + " models)") $true ""
    } else {
        Write-TestResult "TC-CONN-02" "Models list /v1/models" $false "Returned 0 models"
    }
} catch {
    # 401 means endpoint is reachable but needs auth - still a connectivity pass
    if ($_.Exception.Message -match "401|Unauthorized|unauthorized") {
        Write-TestResult "TC-CONN-02" "Models /v1/models reachable (auth required)" $true "HTTP 401 - endpoint alive, needs access key"
    } else {
        Write-TestResult "TC-CONN-02" "Models list /v1/models" $false ("Request failed - " + $_.Exception.Message)
    }
}

# TC-CONN-03: Port listening
try {
    $netstat = netstat -an 2>$null | Select-String "LISTENING" | Select-String (":" + $Port)
    if ($netstat) {
        $bindingInfo = ($netstat -join " ").Trim()
        Write-TestResult "TC-CONN-03" ("Port " + $Port + " is LISTENING") $true $bindingInfo
    } else {
        Write-TestResult "TC-CONN-03" ("Port " + $Port + " is LISTENING") $false ("Port " + $Port + " not found in LISTENING state")
    }
} catch {
    Write-TestResult "TC-CONN-03" ("Port " + $Port + " is LISTENING") $false ("netstat failed - " + $_.Exception.Message)
}

# TC-CONN-04: Response latency
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($AccessKey) {
        $headers = @{"Authorization" = "Bearer " + $AccessKey}
        $null = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $headers -TimeoutSec 10 -ErrorAction Stop
    } else {
        # No AccessKey: use TCP round-trip as proxy for latency
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($ServerIp, $Port)
        $tcp.Close()
    }
    $sw.Stop()
    $latency = $sw.ElapsedMilliseconds
    if ($latency -lt 5000) {
        Write-TestResult "TC-CONN-04" ("Response latency (" + $latency + "ms < 5000ms)") $true ""
    } else {
        Write-TestResult "TC-CONN-04" "Response latency" $false ("Latency " + $latency + "ms exceeds 5000ms threshold")
    }
} catch {
    Write-TestResult "TC-CONN-04" "Response latency" $false ("Request failed - " + $_.Exception.Message)
}

# TC-CONN-05: Firewall rule check (server-side only)
if ($ServerIp -eq "127.0.0.1") {
    try {
        $fwRule = Get-NetFirewallRule -DisplayName "*OpenCodex*" -ErrorAction SilentlyContinue 2>$null
        if ($fwRule) {
            $enabled = if ($fwRule.Enabled) { "Enabled" } else { "Disabled" }
            Write-TestResult "TC-CONN-05" ("Windows Firewall rule (" + $enabled + ")") $true $fwRule.DisplayName
        } else {
            Write-TestResult "TC-CONN-05" "Windows Firewall rule" $false "No firewall rule with 'OpenCodex' found"
        }
    } catch {
        Write-TestResult "TC-CONN-05" "Windows Firewall rule" $false "Cannot query firewall (admin rights needed?)"
    }
} else {
    Write-TestResult "TC-CONN-05" "Firewall rule (server-side only)" $true "Client mode, skipped"
}

# TC-CONN-06: Binding address check
if ($ServerIp -eq "127.0.0.1") {
    try {
        $bindInfo = netstat -an 2>$null | Select-String (":" + $Port) | Select-String "LISTENING"
        $bindPattern = "0.0.0.0:" + $Port
        $localPattern = "127.0.0.1:" + $Port
        if ($bindInfo -match [regex]::Escape($bindPattern)) {
            Write-TestResult "TC-CONN-06" ("Proxy bound to 0.0.0.0:" + $Port + " (external OK)") $true ""
        } elseif ($bindInfo -match [regex]::Escape($localPattern)) {
            Write-TestResult "TC-CONN-06" "Proxy binding address" $false "Only bound to 127.0.0.1 - external machines cannot connect"
        } else {
            Write-TestResult "TC-CONN-06" "Proxy binding address" $false ("Binding: " + ($bindInfo -join " "))
        }
    } catch {
        Write-TestResult "TC-CONN-06" "Proxy binding address" $false "Cannot determine binding address"
    }
} else {
    Write-TestResult "TC-CONN-06" "Binding check (server-side only)" $true "Client mode, skipped"
}

# Summary
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host ("  Passed: " + $TestsPassed)
Write-Host ("  Failed: " + $TestsFailed)
Write-Host ("  Total:  " + ($TestsPassed + $TestsFailed))

if ($TestsFailed -eq 0) {
    Write-Host ""
    Write-Host "  [PASS] All connectivity tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host ("  [FAIL] " + $TestsFailed + " test(s) failed") -ForegroundColor Red

    Write-Host ""
    Write-Host "  Fix Suggestions:" -ForegroundColor Yellow
    $failedIds = ($Results | Where-Object { -not $_.Passed }).Id
    if ($failedIds -contains "TC-CONN-01") {
        Write-Host "  1. Proxy not running? Run: ocx start"
    }
    if ($failedIds -contains "TC-CONN-03") {
        Write-Host "  2. Port not listening? Run: ocx start --port " + $Port
    }
    if ($failedIds -contains "TC-CONN-05") {
        Write-Host "  3. Firewall not configured? Run as admin: .\scripts\server\setup-lan.ps1"
    }
    if ($failedIds -contains "TC-CONN-06") {
        Write-Host "  4. Wrong binding? Run: ocx config set hostname 0.0.0.0 ; ocx restart"
    }
    exit 1
}
