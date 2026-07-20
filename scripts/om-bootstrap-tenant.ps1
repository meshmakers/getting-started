#!/usr/bin/env pwsh
# Creates a tenant, enables communication (blueprints seed the pool, the mesh
# adapter, and the public chart repository), and deploys pool + adapters via the
# Communication Operator. Run ./om-login-local.ps1 first.
param(
    [string]$TenantId = "meshtest",
    [switch]$IncludeSimulation = $false
)

$ErrorActionPreference = "Stop"

$KubeContext = "kind-octomesh"
$PoolRtId = "670000000000000000000001"
$MeshAdapterRtId = "670000000000000000000002"
$SimulationAdapterRtId = "671000000000000000000001"

$configPath = Join-Path $PSScriptRoot "kubernetes/local-config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "No local-config.json found - run ./om-install.ps1 first."
    exit 1
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

function Invoke-OctoCli {
    param([string[]]$CliArgs, [string]$FailureHint)
    & octo-cli @CliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "octo-cli $($CliArgs -join ' ') failed. $FailureHint"
        exit 1
    }
}

Write-Host "Creating tenant '$TenantId'..." -ForegroundColor Cyan
& octo-cli -c Create -tid $TenantId -db $TenantId
if ($LASTEXITCODE -ne 0) {
    Write-Host "Tenant creation failed - if it already exists, continuing is safe." -ForegroundColor Yellow
}

Write-Host "Enabling communication (seeds pool, mesh adapter, chart repository)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "EnableCommunication") -FailureHint "Check that you are logged in (./om-login-local.ps1) and the tenant exists."

Write-Host "Pinning the mesh adapter chart version to $($config.chartVersion)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "UpdateWorkloadChartVersion", "-id", $MeshAdapterRtId, "-cv", $config.chartVersion) `
    -FailureHint "The blueprint-seeded mesh adapter was not found - EnableCommunication may have failed."

Write-Host "Deploying the pool (operator creates the CommunicationPool resource)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "DeployPool", "-id", $PoolRtId) -FailureHint "Requires octo-cli with the DeployPool command."

Write-Host "Deploying the mesh adapter..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "DeployWorkload", "-id", $MeshAdapterRtId) -FailureHint ""

if ($IncludeSimulation) {
    Write-Host "Importing and deploying the simulation adapter..." -ForegroundColor Cyan
    $template = Get-Content (Join-Path $PSScriptRoot "kubernetes/simulation-adapter.yaml") -Raw
    $importFile = Join-Path $PSScriptRoot "kubernetes/.generated/simulation-adapter.yaml"
    $template -replace "__CHART_VERSION__", $config.chartVersion | Set-Content -Path $importFile -Encoding UTF8
    Invoke-OctoCli -CliArgs @("-c", "ImportRt", "-f", $importFile, "-w") -FailureHint "Simulation adapter import failed."
    Invoke-OctoCli -CliArgs @("-c", "DeployWorkload", "-id", $SimulationAdapterRtId) -FailureHint ""
}

Write-Host "Waiting for adapter pods (up to 5 minutes)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $pods = kubectl --context $KubeContext -n octo get pods --no-headers 2>$null | Out-String
    if ($pods -match "Running") { break }
    Start-Sleep -Seconds 10
}
kubectl --context $KubeContext -n octo get communicationpool,pods

Write-Host ""
Write-Host "Tenant '$TenantId' is ready." -ForegroundColor Green
Write-Host "Check adapter state with: octo-cli -c GetAdapters"
