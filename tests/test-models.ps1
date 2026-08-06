# test-models.ps1
# opencodex LAN Share - Model Availability Test Suite
# Tests what can be tested: models listing + endpoint reachability
# Full chat testing requires a Codex client (uses session-based auth forwarding)

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

function Test-EndpointExists {
    param([string]$Endpoint, [string]$Label)
    try {
        $body = @{
            model = "gpt-5.5"
            messages = @(@{ role = "user"; content = "Hi" })
            max_tokens = 5
        } | ConvertTo-Json -Depth 4

        $response = Invoke-WebRequest -Uri ($BaseUrl + $Endpoint) -Method Post -Body $body -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
        return @{ Reachable = $true; Status = $response.StatusCode; Msg = "" }
    } catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -eq 401) {
            return @{ Reachable = $true; Status = 401; Msg = "(auth-gated - routes via Codex session)" }
        } elseif ($sc -eq 404) {
            return @{ Reachable = $false; Status = 404; Msg = "Endpoint not found" }
        } else {
            return @{ Reachable = $false; Status = $sc; Msg = $_.Exception.Message }
        }
    }
}

Write-Host ""
Write-Host "=== opencodex LAN Share - Model Availability Tests ===" -ForegroundColor Cyan
Write-Host ("  Target: " + $BaseUrl)
Write-Host ("  Time:   " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host ""

# TC-MOD-01: Models list non-empty
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($response.data) { $modelList = @($response.data) }
    elseif ($response.models) { $modelList = @($response.models) }
    $modelCount = $modelList.Count
    if ($modelCount -gt 0) {
        Write-TestResult "TC-MOD-01" ("Models list (" + $modelCount + " models)") $true ""
    } else {
        Write-TestResult "TC-MOD-01" "Models list" $false "Returned 0 models"
    }
} catch {
    Write-TestResult "TC-MOD-01" "Models list" $false ("Request failed - " + $_.Exception.Message)
}

# TC-MOD-02: /v1/chat/completions endpoint exists
$result = Test-EndpointExists "/v1/chat/completions" "Chat"
if ($result.Reachable) {
    Write-TestResult "TC-MOD-02" ("Chat endpoint " + $result.Status + " " + $result.Msg) $true ""
} else {
    Write-TestResult "TC-MOD-02" "Chat endpoint" $false ("HTTP " + $result.Status + " " + $result.Msg)
}

# TC-MOD-03: /v1/responses endpoint exists
$result = Test-EndpointExists "/v1/responses" "Responses"
if ($result.Reachable) {
    Write-TestResult "TC-MOD-03" ("Responses endpoint " + $result.Status + " " + $result.Msg) $true ""
} else {
    Write-TestResult "TC-MOD-03" "Responses endpoint" $false ("HTTP " + $result.Status + " " + $result.Msg)
}

# TC-MOD-04: Invalid model returns error
try {
    $body = @{
        model = "nonexistent-model-xyz-12345"
        messages = @(@{ role = "user"; content = "test" })
        max_tokens = 10
    } | ConvertTo-Json -Depth 4

    try {
        $null = Invoke-RestMethod -Uri ($BaseUrl + "/v1/chat/completions") -Method Post -Body $body -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
        Write-TestResult "TC-MOD-04" "Invalid model returns error" $false "Expected 4xx but got 200"
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -ge 400 -and $statusCode -lt 500) {
            Write-TestResult "TC-MOD-04" "Invalid model returns error" $true ("HTTP " + $statusCode)
        } else {
            Write-TestResult "TC-MOD-04" "Invalid model returns error" $false ("HTTP " + $statusCode)
        }
    }
} catch {
    Write-TestResult "TC-MOD-04" "Invalid model returns error" $false ("Exception - " + $_.Exception.Message)
}

# TC-MOD-05: qwen-cloud models in listing
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($response.data) { $modelList = @($response.data) }
    $qwenModels = $modelList | Where-Object { $_.id -match "qwen-cloud" }
    $qwenCount = @($qwenModels).Count
    if ($qwenCount -gt 0) {
        Write-TestResult "TC-MOD-05" ("qwen-cloud models available (" + $qwenCount + ")") $true ""
    } else {
        Write-TestResult "TC-MOD-05" "qwen-cloud models" $false "No qwen-cloud models found"
    }
} catch {
    Write-TestResult "TC-MOD-05" "qwen-cloud models" $false ("Request failed - " + $_.Exception.Message)
}

# TC-MOD-06: deepseek models in listing
try {
    $response = Invoke-RestMethod -Uri ($BaseUrl + "/v1/models") -Method Get -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
    $modelList = @()
    if ($response.data) { $modelList = @($response.data) }
    $dsModels = $modelList | Where-Object { $_.id -match "^deepseek/" }
    $dsCount = @($dsModels).Count
    if ($dsCount -gt 0) {
        Write-TestResult "TC-MOD-06" ("deepseek models available (" + $dsCount + ")") $true ""
    } else {
        Write-TestResult "TC-MOD-06" "deepseek models" $false "No deepseek models found"
    }
} catch {
    Write-TestResult "TC-MOD-06" "deepseek models" $false ("Request failed - " + $_.Exception.Message)
}

# Summary
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host ("  Passed: " + $TestsPassed)
Write-Host ("  Failed: " + $TestsFailed)
Write-Host ("  Total:  " + ($TestsPassed + $TestsFailed))

if ($TestsFailed -eq 0) {
    Write-Host ""
    Write-Host "  [PASS] All model availability tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host ("  [FAIL] " + $TestsFailed + " test(s) failed") -ForegroundColor Red
    exit 1
}
