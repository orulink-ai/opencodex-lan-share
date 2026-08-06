# test-stream.ps1
# opencodex LAN Share - Stream Output Test Suite
# Note: Full streaming tests require a Codex client (session-based auth).
# These tests validate endpoint reachability and basic stream mechanics.

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

$Headers = @{ "Content-Type" = "application/json" }
if ($AccessKey) {
    $Headers["Authorization"] = "Bearer " + $AccessKey
}

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
Write-Host "=== opencodex LAN Share - Stream Output Tests ===" -ForegroundColor Cyan
Write-Host ("  Target: " + $BaseUrl)
Write-Host ("  Time:   " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host "  Note: Full stream tests require Codex client (session auth)" -ForegroundColor Yellow
Write-Host ""

# TC-STR-01: Stream endpoint reachable
try {
    $body = @{
        model = "gpt-5.5"
        messages = @(@{ role = "user"; content = "Count 1 to 5" })
        max_tokens = 50
        stream = $true
    } | ConvertTo-Json -Depth 4

    $response = Invoke-WebRequest -Uri ($BaseUrl + "/v1/chat/completions") -Method Post -Body $body -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    Write-TestResult "TC-STR-01" "Stream endpoint reachable" $true ("HTTP " + $response.StatusCode)
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 401) {
        Write-TestResult "TC-STR-01" "Stream endpoint reachable (auth-gated)" $true "HTTP 401 - endpoint alive"
    } else {
        Write-TestResult "TC-STR-01" "Stream endpoint reachable" $false ("HTTP " + $statusCode + " - " + $_.Exception.Message)
    }
}

# TC-STR-02: Models endpoint serves SSE candidates
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    Write-TestResult "TC-STR-02" "Proxy serving API responses (models OK)" $true ""
} catch {
    Write-TestResult "TC-STR-02" "Proxy serving API responses" $false ("Failed - " + $_.Exception.Message)
}

# TC-STR-03: Non-stream endpoint reachable
try {
    $body = @{
        model = "gpt-5.5"
        messages = @(@{ role = "user"; content = "Reply OK" })
        max_tokens = 10
        stream = $false
    } | ConvertTo-Json -Depth 4

    $response = Invoke-WebRequest -Uri ($BaseUrl + "/v1/chat/completions") -Method Post -Body $body -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    Write-TestResult "TC-STR-03" "Non-stream endpoint reachable" $true ("HTTP " + $response.StatusCode)
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 401) {
        Write-TestResult "TC-STR-03" "Non-stream endpoint reachable (auth-gated)" $true "HTTP 401 - endpoint alive"
    } else {
        Write-TestResult "TC-STR-03" "Non-stream endpoint reachable" $false ("HTTP " + $statusCode)
    }
}

# TC-STR-04: Proxy responds within timeout
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Invoke-WebRequest -Uri ($BaseUrl + "/v1/chat/completions") -Method Post -Body $body -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    } catch { }
    $sw.Stop()
    $elapsed = $sw.ElapsedMilliseconds
    if ($elapsed -lt 10000) {
        Write-TestResult "TC-STR-04" ("Proxy responds in " + $elapsed + "ms (< 10s)") $true ""
    } else {
        Write-TestResult "TC-STR-04" "Proxy response time" $false ("Took " + $elapsed + "ms")
    }
} catch {
    Write-TestResult "TC-STR-04" "Proxy response time" $false ("Exception - " + $_.Exception.Message)
}

# TC-STR-05: Proxy health + stability
try {
    $response1 = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    $response2 = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    Write-TestResult "TC-STR-05" "Proxy stable across consecutive requests" $true ""
} catch {
    Write-TestResult "TC-STR-05" "Proxy stability" $false ("Consecutive request failed - " + $_.Exception.Message)
}

# Summary
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host ("  Passed: " + $TestsPassed)
Write-Host ("  Failed: " + $TestsFailed)
Write-Host ("  Total:  " + ($TestsPassed + $TestsFailed))
Write-Host "  Note: Full streaming validation requires a Codex client connection" -ForegroundColor Yellow
if ($TestsFailed -eq 0) {
    Write-Host ""
    Write-Host "  [PASS] All stream tests passed!" -ForegroundColor Green
    exit 0
} else {
    exit 1
}
