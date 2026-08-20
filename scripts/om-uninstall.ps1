#!/usr/bin/env pwsh
# Deletes the OctoMesh kind cluster and ALL its data, and removes the trusted root CA
# from the OS and browser stores.
param(
    [switch]$Force = $false,
    [switch]$KeepCaTrust = $false,
    [switch]$KeepGeneratedFiles = $false
)

$ErrorActionPreference = "Stop"
$ClusterName = "octomesh"
$KubernetesPath = Join-Path $PSScriptRoot "kubernetes"
$GeneratedPath = Join-Path $KubernetesPath ".generated"

. (Join-Path $KubernetesPath "ca-trust.ps1")

if (-not $KeepCaTrust) { Assert-Elevated }

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
    Write-Host "Removing the root CA from the OS and browser trust stores (may prompt for sudo)..." -ForegroundColor Cyan
    if (-not (Remove-CaFromOsStore)) {
        Write-Host "CA trust removal failed (non-fatal). You may need to remove the 'OctoMesh Getting Started Root CA' from your OS trust store manually." -ForegroundColor Yellow
    }
    Remove-CaFromBrowserStores
    Write-BrowserRestartWarning -Removed
}

if (-not $KeepGeneratedFiles -and (Test-Path $GeneratedPath)) {
    Write-Host "Removing generated local files ($GeneratedPath)..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $GeneratedPath
}

Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "local-config.json (version + license keys) was kept for the next install."