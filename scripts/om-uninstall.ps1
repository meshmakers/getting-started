#!/usr/bin/env pwsh
# Deletes the OctoMesh kind cluster and ALL its data, and removes the trusted root CA.
param(
    [switch]$Force = $false,
    [switch]$KeepCaTrust = $false,
    [switch]$KeepGeneratedFiles = $false
)

$ErrorActionPreference = "Stop"
$ClusterName = "octomesh"
$RootCaCommonName = "OctoMesh Getting Started Root CA"
$GeneratedPath = Join-Path $PSScriptRoot "kubernetes/.generated"

if (-not $Force) {
    Write-Host "This deletes the kind cluster '$ClusterName' including ALL DATA (MongoDB, CrateDB volumes)." -ForegroundColor Yellow
    $confirm = Read-Host "Type 'yes' to continue"
    if ($confirm -ne "yes") { Write-Host "Aborted."; exit 0 }
}

$existing = kind get clusters 2>$null
if ($existing -contains $ClusterName) {
    Write-Host "Deleting kind cluster '$ClusterName'..." -ForegroundColor Cyan
    kind delete cluster --name $ClusterName
    if ($LASTEXITCODE -ne 0) { throw "kind delete cluster --name $ClusterName failed." }
}
else {
    Write-Host "No kind cluster '$ClusterName' found." -ForegroundColor Yellow
}

if (-not $KeepCaTrust) {
    Write-Host "Removing the root CA from the OS trust store (may prompt for sudo/elevation)..." -ForegroundColor Cyan
    $caRemovalFailed = $false
    if ($IsMacOS) {
        sudo security delete-certificate -c $RootCaCommonName /Library/Keychains/System.keychain 2>$null
        if ($LASTEXITCODE -ne 0) { $caRemovalFailed = $true }
    }
    elseif ($IsWindows) {
        try {
            Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($RootCaCommonName) } | Remove-Item -ErrorAction Stop
        }
        catch {
            $caRemovalFailed = $true
        }
    }
    else {
        sudo rm -f /usr/local/share/ca-certificates/octomesh-getting-started-root-ca.crt
        if ($LASTEXITCODE -ne 0) { $caRemovalFailed = $true }
        if (-not $caRemovalFailed) {
            sudo update-ca-certificates --fresh | Out-Null
            if ($LASTEXITCODE -ne 0) { $caRemovalFailed = $true }
        }
    }
    if ($caRemovalFailed) {
        Write-Host "CA trust removal failed (non-fatal). You may need to remove '$RootCaCommonName' from your OS trust store manually." -ForegroundColor Yellow
    }
}

if (-not $KeepGeneratedFiles -and (Test-Path $GeneratedPath)) {
    Write-Host "Removing generated local files ($GeneratedPath)..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $GeneratedPath
}

Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "local-config.json (version + license keys) was kept for the next install."
