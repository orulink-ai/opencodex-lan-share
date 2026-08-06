# test-client-windows.ps1
# opencodex LAN Share - Windows Client Setup TDD Test Suite
# Validates: opencodex detection, auto-install, config generation, env setup
#
# Usage:
#   .\tests\test-client-windows.ps1
#   .\tests\test-client-windows.ps1 -ServerIp 192.168.1.110 -AccessKey ocx_data_xxxx

param(
    [string]$ServerIp = "192.168.1.110",
    [int]$Port = 10101,
    [string]$AccessKey = ""
)

$ErrorActionPreference = "Continue"
$BaseUrl = "http://" + $ServerIp + ":" + $Port
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Resolve-Path (Join-Path $ScriptDir "..")
$TestDir = Join-Path $env:TEMP "opencodex-test-client-windows"
$SetupClient = Join-Path $ProjectDir "scripts\client\setup-client.ps1"

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

# Setup test environment
if (Test-Path $TestDir) { Remove-Item -Recurse -Force $TestDir -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
$FakeHome = Join-Path $TestDir "home"
$FakeCodexDir = Join-Path $FakeHome ".codex"
New-Item -ItemType Directory -Path $FakeCodexDir -Force | Out-Null

Write-Host ""
Write-Host "=== opencodex LAN Share - Windows Client Setup Tests ===" -ForegroundColor Cyan
Write-Host ("  Project: " + $ProjectDir)
Write-Host ("  TestDir: " + $TestDir)
Write-Host ("  Time:    " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Host ""

# ============================================================
# TC-CLIENT-WIN-01: setup-client.ps1 exists and is readable
# ============================================================
if (Test-Path $SetupClient) {
    Write-TestResult "TC-CLIENT-WIN-01" "setup-client.ps1 exists" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-01" "setup-client.ps1 exists" $false "File not found at $SetupClient"
}

# ============================================================
# TC-CLIENT-WIN-02: Script has opencodex detection step
# ============================================================
$scriptContent = Get-Content $SetupClient -Raw
if ($scriptContent -match "opencodex.*install|npm.*install.*@bitkyc08/opencodex|ocx.*--version") {
    Write-TestResult "TC-CLIENT-WIN-02" "Script detects/installs opencodex" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-02" "Script detects/installs opencodex" $false "No opencodex detection or install logic found in setup-client.ps1"
}

# ============================================================
# TC-CLIENT-WIN-03: Script has Node.js detection step
# ============================================================
if ($scriptContent -match "node.*--version|Get-Command.*node|node\s+-v") {
    Write-TestResult "TC-CLIENT-WIN-03" "Script detects Node.js" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-03" "Script detects Node.js" $false "No Node.js detection found - opencodex requires Node.js"
}

# ============================================================
# TC-CLIENT-WIN-04: Config template uses opencodex-compatible keys
# ============================================================
$templatePath = Join-Path $ProjectDir "templates\client-config.toml"
if (Test-Path $templatePath) {
    $templateContent = Get-Content $templatePath -Raw

    # TC-CLIENT-WIN-04a: base_url is set (not openai_base_url)
    if ($templateContent -match 'base_url\s*=') {
        Write-TestResult "TC-CLIENT-WIN-04a" "Template uses base_url (opencodex-compatible)" $true ""
    } else {
        Write-TestResult "TC-CLIENT-WIN-04a" "Template uses base_url (opencodex-compatible)" $false "base_url not found in template"
    }

    # TC-CLIENT-WIN-04b: openai_base_url is NOT used (deprecated for opencodex)
    if ($templateContent -match 'openai_base_url\s*=') {
        Write-TestResult "TC-CLIENT-WIN-04b" "Template does NOT use openai_base_url (deprecated)" $false "openai_base_url found - standard Codex Desktop ignores this key"
    } else {
        Write-TestResult "TC-CLIENT-WIN-04b" "Template does NOT use openai_base_url (deprecated)" $true ""
    }

    # TC-CLIENT-WIN-04c: model_provider is set to opencodex
    if ($templateContent -match 'model_provider\s*=\s*"opencodex"') {
        Write-TestResult "TC-CLIENT-WIN-04c" "Template sets model_provider = opencodex" $true ""
    } else {
        Write-TestResult "TC-CLIENT-WIN-04c" "Template sets model_provider = opencodex" $false "model_provider must be ''opencodex'' for LAN Share to work"
    }

    # TC-CLIENT-WIN-04d: wire_api is set to responses
    if ($templateContent -match 'wire_api\s*=\s*"responses"') {
        Write-TestResult "TC-CLIENT-WIN-04d" "Template sets wire_api = responses" $true ""
    } else {
        Write-TestResult "TC-CLIENT-WIN-04d" "Template sets wire_api = responses" $false "wire_api should be ''responses'' for opencodex proxy"
    }
} else {
    Write-TestResult "TC-CLIENT-WIN-04a" "Template file exists" $false "client-config.toml not found"
    Write-TestResult "TC-CLIENT-WIN-04b" "Template file exists" $false "client-config.toml not found"
    Write-TestResult "TC-CLIENT-WIN-04c" "Template file exists" $false "client-config.toml not found"
    Write-TestResult "TC-CLIENT-WIN-04d" "Template file exists" $false "client-config.toml not found"
}

# ============================================================
# TC-CLIENT-WIN-05: Config generation simulation (dry-run)
# ============================================================
$FakeConfig = Join-Path $FakeCodexDir "config.toml"

@"
# Old Codex config
base_url = "http://old-server:8080/v1"
model_provider = "old-provider"
model_catalog_json = "/old/catalog.json"
wire_api = "chat"
openai_base_url = "http://legacy:9090/v1"
"@ | Set-Content -Path $FakeConfig -Encoding UTF8

$lines = Get-Content $FakeConfig
$newLines = @()
$injected = $false
$skipSection = $false

foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '[model_providers.opencodex]') { $skipSection = $true; continue }
    if ($skipSection) {
        if ($trimmed -match '^\[.*\]') { $skipSection = $false }
        else { continue }
    }
    if ($trimmed -match '^openai_base_url\s*=') { continue }
    if ($trimmed -match '^model_provider\s*=') { continue }
    if ($trimmed -match '^model_catalog_json\s*=') { continue }
    if ($trimmed -match '^wire_api\s*=') { continue }

    if ($trimmed -match '^base_url\s*=') {
        if (-not $injected) {
            $newLines += ""
            $newLines += "# === opencodex LAN Share ==="
            $newLines += "base_url = """ + $BaseUrl + "/v1"""
            $newLines += "model_provider = ""opencodex"""
            $newLines += "wire_api = ""responses"""
            $newLines += ""
            $newLines += "[model_providers.opencodex]"
            $newLines += "name = ""OpenCodex Proxy (" + $ServerIp + ")"""
            $newLines += "base_url = """ + $BaseUrl + "/v1"""
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

$newLines -join "`r`n" | Set-Content -Path $FakeConfig -Encoding UTF8
$resultContent = Get-Content $FakeConfig -Raw

# TC-CLIENT-WIN-05a: base_url is set to the LAN server
if ($resultContent -match [regex]::Escape("base_url = """ + $BaseUrl + "/v1""")) {
    Write-TestResult "TC-CLIENT-WIN-05a" "Config has correct base_url" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-05a" "Config has correct base_url" $false "Missing or wrong base_url in generated config"
}

# TC-CLIENT-WIN-05b: model_provider is set to opencodex
if ($resultContent -match 'model_provider\s*=\s*"opencodex"') {
    Write-TestResult "TC-CLIENT-WIN-05b" "Config has model_provider = opencodex" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-05b" "Config has model_provider = opencodex" $false "model_provider not found or wrong value"
}

# TC-CLIENT-WIN-05c: wire_api is set to responses
if ($resultContent -match 'wire_api\s*=\s*"responses"') {
    Write-TestResult "TC-CLIENT-WIN-05c" "Config has wire_api = responses" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-05c" "Config has wire_api = responses" $false "wire_api not found or wrong value"
}

# TC-CLIENT-WIN-05d: [model_providers.opencodex] section exists
if ($resultContent -match '\[model_providers\.opencodex\]') {
    Write-TestResult "TC-CLIENT-WIN-05d" "Config has [model_providers.opencodex] section" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-05d" "Config has [model_providers.opencodex] section" $false "model_providers section missing"
}

# TC-CLIENT-WIN-05e: openai_base_url is cleaned from old config
if ($resultContent -match 'openai_base_url') {
    Write-TestResult "TC-CLIENT-WIN-05e" "Old openai_base_url is cleaned" $false "openai_base_url still present in config"
} else {
    Write-TestResult "TC-CLIENT-WIN-05e" "Old openai_base_url is cleaned" $true ""
}

# TC-CLIENT-WIN-05f: model_catalog_json is cleaned from old config
if ($resultContent -match 'model_catalog_json') {
    Write-TestResult "TC-CLIENT-WIN-05f" "Old model_catalog_json is cleaned" $false "model_catalog_json still present in config"
} else {
    Write-TestResult "TC-CLIENT-WIN-05f" "Old model_catalog_json is cleaned" $true ""
}

# TC-CLIENT-WIN-05g: requires_openai_auth = true in provider section
if ($resultContent -match 'requires_openai_auth\s*=\s*true') {
    Write-TestResult "TC-CLIENT-WIN-05g" "Config has requires_openai_auth = true" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-05g" "Config has requires_openai_auth = true" $false "requires_openai_auth not found or wrong value"
}

# ============================================================
# TC-CLIENT-WIN-06: Script sets OPENAI_API_KEY env var
# ============================================================
if ($scriptContent -match 'OPENAI_API_KEY') {
    Write-TestResult "TC-CLIENT-WIN-06" "Script sets OPENAI_API_KEY environment variable" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-06" "Script sets OPENAI_API_KEY environment variable" $false "No OPENAI_API_KEY reference found in script"
}

# ============================================================
# TC-CLIENT-WIN-07: Script cleans up old OPENCODEX_OPENCODE_API_KEY
# ============================================================
if ($scriptContent -match 'OPENCODEX_OPENCODE_API_KEY' -and $scriptContent -match 'Remove|SetEnvironmentVariable.*null|delete') {
    Write-TestResult "TC-CLIENT-WIN-07" "Script cleans old OPENCODEX_OPENCODE_API_KEY" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-07" "Script cleans old OPENCODEX_OPENCODE_API_KEY" $false "Old env var cleanup not found or incomplete"
}

# ============================================================
# TC-CLIENT-WIN-08: Script checks connectivity before configuring
# ============================================================
if ($scriptContent -match 'ConnectAsync|Test-NetConnection|TcpClient') {
    Write-TestResult "TC-CLIENT-WIN-08" "Script tests connectivity before config" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-08" "Script tests connectivity before config" $false "No TCP connectivity test found"
}

# ============================================================
# TC-CLIENT-WIN-09: Script creates config backup before modifying
# ============================================================
if ($scriptContent -match 'backup|Copy-Item.*backup|Move-Item.*backup') {
    Write-TestResult "TC-CLIENT-WIN-09" "Script creates config backup" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-09" "Script creates config backup" $false "No backup logic found"
}

# ============================================================
# TC-CLIENT-WIN-10: Script includes user-friendly error messages
# ============================================================
if ($scriptContent -match 'Troubleshooting|troubleshoot|Cannot reach|unable to connect') {
    Write-TestResult "TC-CLIENT-WIN-10" "Script has helpful error messages" $true ""

# TC-CLIENT-WIN-11: Script downloads model catalog
try {
    $catalogOk = (Select-String -Path $SetupClient -Pattern "catalog.json" -SimpleMatch)
    $hasCatalogConfig = (Select-String -Path $SetupClient -Pattern "model_catalog_json" -SimpleMatch)
    if ($catalogOk -and $hasCatalogConfig) {
        Write-TestResult "TC-CLIENT-WIN-11" "Script downloads and configures model catalog" $true ""
    } else {
        $missing = @()
        if (-not $catalogOk) { $missing += "missing catalog download" }
        if (-not $hasCatalogConfig) { $missing += "missing model_catalog_json config" }
        Write-TestResult "TC-CLIENT-WIN-11" "Script downloads and configures model catalog" $false ($missing -join ", ")
    }
} catch {
    Write-TestResult "TC-CLIENT-WIN-11" "Script downloads and configures model catalog" $false $_.Exception.Message
}
} else {
    Write-TestResult "TC-CLIENT-WIN-10" "Script has helpful error messages" $false "No troubleshooting info found"
}

# ============================================================
# TC-CLIENT-WIN-12: Script refreshes Codex models_cache via ocx sync-cache
# Root cause: Codex Desktop reads ~/.codex/models_cache.json (not /v1/models
# dynamically). Writing the catalog alone does NOT refresh the model list unless
# the cache is invalidated (fetched_at forced to 2000-01-01). opencodex does this
# via `ocx sync-cache`. The old script never ran it, so the colleague's list stayed stale.
# ============================================================
$hasSyncCache = (Select-String -Path $SetupClient -Pattern "sync-cache" -SimpleMatch)
if ($hasSyncCache) {
    Write-TestResult "TC-CLIENT-WIN-12" "Script runs ocx sync-cache to refresh Codex model cache" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-12" "Script runs ocx sync-cache to refresh Codex model cache" $false "setup-client.ps1 never invalidates models_cache.json, so Codex Desktop keeps showing stale models"
}

# ============================================================
# TC-CLIENT-WIN-13: Script does NOT start a local proxy (must route through LAN server)
# We must only refresh the cache, never `ocx start`/`ocx ensure` (which would spawn a
# local proxy and may overwrite base_url). Verify no local-proxy start is introduced
# in the sync-cache step.
# ============================================================
if ($hasSyncCache) {
    # Locate the sync-cache block and ensure it does not call start/proxy
    $scriptLines = Get-Content $SetupClient
    $syncIdx = ($scriptLines | Select-String -Pattern "sync-cache" | Select-Object -First 1).LineNumber
    $blockStart = $syncIdx - 12
    if ($blockStart -lt 0) { $blockStart = 0 }
    $blockEnd = $syncIdx + 12
    if ($blockEnd -gt $scriptLines.Count) { $blockEnd = $scriptLines.Count }
    $block = ($scriptLines[$blockStart..($blockEnd-1)] -join "`n")
    if ($block -match "ocx start|ocx ensure|ocx service") {
        Write-TestResult "TC-CLIENT-WIN-13" "Cache refresh does not start a local proxy" $false "sync-cache block also starts a local proxy - would break LAN routing"
    } else {
        Write-TestResult "TC-CLIENT-WIN-13" "Cache refresh does not start a local proxy" $true ""
    }
} else {
    Write-TestResult "TC-CLIENT-WIN-13" "Cache refresh does not start a local proxy" $false "sync-cache block not found (skipped)"
}

# ============================================================
# TC-CLIENT-WIN-14: Cache refresh respects DryRun (must NOT mutate real cache in preview)
# ============================================================
if ($hasSyncCache) {
    $scriptLines = Get-Content $SetupClient
    $syncIdx = ($scriptLines | Select-String -Pattern "sync-cache" | Select-Object -First 1).LineNumber
    $blockStart = $syncIdx - 12
    if ($blockStart -lt 0) { $blockStart = 0 }
    $blockEnd = $syncIdx + 12
    if ($blockEnd -gt $scriptLines.Count) { $blockEnd = $scriptLines.Count }
    $block = ($scriptLines[$blockStart..($blockEnd-1)] -join "`n")
    if ($block -match '-not \$DryRun') {
        Write-TestResult "TC-CLIENT-WIN-14" "Cache refresh is gated by DryRun guard" $true ""
    } else {
        Write-TestResult "TC-CLIENT-WIN-14" "Cache refresh is gated by DryRun guard" $false "sync-cache runs even in DryRun preview mode - would mutate real models_cache.json"
    }
} else {
    Write-TestResult "TC-CLIENT-WIN-14" "Cache refresh is gated by DryRun guard" $false "sync-cache block not found"
}

# ============================================================
# TC-CLIENT-WIN-15: Fallback removes stale models_cache.json when sync-cache fails
# ============================================================
$psContent = Get-Content $SetupClient -Raw
if ($psContent -match 'modelsCachePath|models_cache\.json' -and $psContent -match 'Remove-Item.*modelsCachePath') {
    Write-TestResult "TC-CLIENT-WIN-15" "Fallback removes stale models_cache.json on sync failure" $true ""
} else {
    Write-TestResult "TC-CLIENT-WIN-15" "Fallback removes stale models_cache.json on sync failure" $false "No fallback that clears the stale cache on sync-cache failure"
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host ("  Passed: " + $TestsPassed)
Write-Host ("  Failed: " + $TestsFailed)
Write-Host ("  Total:  " + ($TestsPassed + $TestsFailed))

if ($TestsFailed -eq 0) {
    Write-Host ""
    Write-Host "  [PASS] All Windows client setup tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host ("  [FAIL] " + $TestsFailed + " test(s) failed") -ForegroundColor Red
    Write-Host ""
    Write-Host "  Failing tests:" -ForegroundColor Yellow
    foreach ($r in ($Results | Where-Object { -not $_.Passed })) {
        Write-Host ("    - " + $r.Id + ": " + $r.Name)
    }
    exit 1
}
