# manage-users.ps1
# opencodex LAN Share - User Access Key Management
# Usage: .\scripts\server\manage-users.ps1 [-List] [-Create <name>] [-Revoke <id>]

param(
    [switch]$List,
    [string]$Create,
    [string]$Revoke,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help -or (-not $List -and -not $Create -and -not $Revoke)) {
    Write-Host ""
    Write-Host "opencodex LAN Share - User Management" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\scripts\server\manage-users.ps1 -List"
    Write-Host "  .\scripts\server\manage-users.ps1 -Create <name>"
    Write-Host "  .\scripts\server\manage-users.ps1 -Revoke <key-id>"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  manage-users.ps1 -List"
    Write-Host "  manage-users.ps1 -Create 'Zhang San'"
    Write-Host "  manage-users.ps1 -Revoke e644d636-63cf-4ce0-934e-9a35e9ad8a26"
    Write-Host ""
    exit 0
}

# Ensure admin token is set
if (-not $env:OPENCODEX_ADMIN_AUTH_TOKEN) {
    $adminTokenFile = Join-Path $HOME ".opencodex\admin-api-token"
    if (Test-Path $adminTokenFile) {
        $env:OPENCODEX_ADMIN_AUTH_TOKEN = (Get-Content $adminTokenFile -Raw).Trim()
        Write-Host "[INFO] Loaded admin token from " + $adminTokenFile
    } else {
        Write-Host "[ERROR] Admin token not found." -ForegroundColor Red
        Write-Host "  Set OPENCODEX_ADMIN_AUTH_TOKEN env var or ensure ~/.opencodex/admin-api-token exists"
        exit 1
    }
}

if ($List) {
    Write-Host ""
    Write-Host "=== Access Keys ===" -ForegroundColor Cyan
    ocx access key list 2>&1
}

if ($Create) {
    Write-Host ""
    Write-Host ("Creating access key for: " + $Create + "...") -ForegroundColor Yellow
    $result = ocx access key create $Create 2>&1
    Write-Host $result
}

if ($Revoke) {
    Write-Host ""
    Write-Host ("Revoking access key: " + $Revoke + "...") -ForegroundColor Yellow
    $result = ocx access key remove $Revoke --yes 2>&1
    Write-Host $result
}
