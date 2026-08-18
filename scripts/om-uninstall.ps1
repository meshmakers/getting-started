#!/usr/bin/env pwsh
# Deletes the OctoMesh kind cluster and ALL its data.
# The local root CA (and its trust in the OS/browser stores) is KEPT by default so
# the next install reuses it and certificates stay trusted - pass -PurgeCa to drop it.
param(
    [switch]$Force = $false,
    [switch]$PurgeCa = $false,
    [switch]$KeepGeneratedFiles = $false,
    [switch]$NonInteractive = $false
)

$ErrorActionPreference = "Stop"
$ClusterName = "octomesh"
$KubernetesPath = Join-Path $PSScriptRoot "kubernetes"
$GeneratedPath = Join-Path $KubernetesPath ".generated"
$CaPath = Join-Path $KubernetesPath ".ca"

. (Join-Path $KubernetesPath "ca-trust.ps1")

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

if ($PurgeCa) {
    Write-Host "Removing the root CA from the OS and browser trust stores (may prompt for sudo/elevation)..." -ForegroundColor Cyan
    if (-not (Remove-CaFromOsStore)) {
        Write-Host "CA trust removal failed (non-fatal). You may need to remove the 'OctoMesh Getting Started Root CA' from your OS trust store manually." -ForegroundColor Yellow
    }
    Remove-CaFromNssStores -NonInteractive:$NonInteractive
    if (Test-Path $CaPath) {
        Write-Host "Removing the persisted root CA ($CaPath)..." -ForegroundColor Cyan
        Remove-Item -Recurse -Force $CaPath
    }
}

if (-not $KeepGeneratedFiles -and (Test-Path $GeneratedPath)) {
    Write-Host "Removing generated local files ($GeneratedPath)..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $GeneratedPath
}

Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "local-config.json (version + license keys) was kept for the next install."
if ($PurgeCa) {
    Write-Host "The root CA was removed - the next install creates a new one and re-trusts it."
}
else {
    Write-Host "The root CA in kubernetes/.ca was kept, so the next install reuses it and your"
    Write-Host "browsers keep trusting the local certificates (use -PurgeCa to drop it)."
}
