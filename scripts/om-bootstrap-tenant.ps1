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
$SystemTenantId = "octosystem"
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

# All octo-cli calls run against the dedicated 'getting-started_<tenant>'
# context created by ./om-login-local.ps1 — activate it explicitly so other
# contexts the user has configured are never touched.
$OctoContextName = "getting-started_$TenantId"
Invoke-OctoCli -CliArgs @("-c", "UseContext", "-n", $OctoContextName) `
    -FailureHint "Context '$OctoContextName' not found - run ./om-login-local.ps1 first."

# The context carries its own service URIs. `Config` fully replaces the active
# context's options on every call (while keeping the login), so capture the
# URIs once and reuse them whenever we need to flip the tenant, instead of
# hardcoding hostnames here.
# octo-cli prints a version banner before the JSON payload, so only keep
# output from the opening '[' onward.
$listContextsLines = octo-cli -c ListContexts -n $OctoContextName -j
$jsonStart = ($listContextsLines | Select-String -Pattern "^\s*\[" | Select-Object -First 1).LineNumber
if (-not $jsonStart) {
    Write-Error "Could not parse 'octo-cli -c ListContexts -n $OctoContextName -j' output."
    exit 1
}
$listContextsJson = ($listContextsLines | Select-Object -Skip ($jsonStart - 1)) -join "`n"
$octoContext = ($listContextsJson | ConvertFrom-Json) | Select-Object -First 1
if (-not $octoContext) {
    Write-Error "Context '$OctoContextName' not found - run ./om-login-local.ps1 first."
    exit 1
}
$svc = $octoContext.services

function Set-OctoCliTenant {
    # Flips the tenant of the active 'getting-started' context; `Config` only
    # ever mutates the active context, which this script pinned above.
    param([string]$Tid)
    $cfgArgs = @("-c", "Config", "-isu", $svc.identity, "-tid", $Tid)
    if ($svc.asset) { $cfgArgs += @("-asu", $svc.asset) }
    if ($svc.bot) { $cfgArgs += @("-bsu", $svc.bot) }
    if ($svc.communication) { $cfgArgs += @("-csu", $svc.communication) }
    if ($svc.reporting) { $cfgArgs += @("-rsu", $svc.reporting) }
    if ($svc.ai) { $cfgArgs += @("-aisu", $svc.ai) }
    Invoke-OctoCli -CliArgs $cfgArgs -FailureHint "Failed to switch the '$OctoContextName' context to tenant '$Tid'."
}

Write-Host "Creating tenant '$TenantId'..." -ForegroundColor Cyan
# TenantsController's "create child tenant" endpoint is tenant-scoped: the
# active context must point at the PARENT tenant (the system tenant) while
# calling it, not at the tenant being created (which doesn't exist yet and
# would otherwise 400 with "TenantId is required").
Set-OctoCliTenant -Tid $SystemTenantId
& octo-cli -c Create -tid $TenantId -db $TenantId
if ($LASTEXITCODE -ne 0) {
    Write-Host "Tenant creation failed - if it already exists, continuing is safe." -ForegroundColor Yellow
}
# Switch back to the target tenant for all remaining tenant-scoped operations.
Set-OctoCliTenant -Tid $TenantId

Write-Host "Enabling communication (seeds pool, mesh adapter, chart repository)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "EnableCommunication") -FailureHint "Check that you are logged in (./om-login-local.ps1) and the tenant exists."

if (-not $config.adapterChartVersion) {
    Write-Error "local-config.json has no adapterChartVersion - re-run ./om-install.ps1 to resolve it."
    exit 1
}
Write-Host "Pinning the mesh adapter chart version to $($config.adapterChartVersion)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "UpdateWorkloadChartVersion", "-id", $MeshAdapterRtId, "-cv", $config.adapterChartVersion) `
    -FailureHint "The blueprint-seeded mesh adapter was not found - EnableCommunication may have failed."

Write-Host "Deploying the pool (operator creates the CommunicationPool resource)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "DeployPool", "-id", $PoolRtId) -FailureHint "Requires octo-cli with the DeployPool command."

Write-Host "Deploying the mesh adapter..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "DeployWorkload", "-id", $MeshAdapterRtId) -FailureHint "Check 'octo-cli -c GetAdapters' for deployment errors."

if ($IncludeSimulation) {
    if (-not $config.simulationChartVersion) {
        Write-Error "local-config.json has no simulationChartVersion - re-run ./om-install.ps1 to resolve it."
        exit 1
    }
    Write-Host "Importing and deploying the simulation adapter..." -ForegroundColor Cyan
    $template = Get-Content (Join-Path $PSScriptRoot "kubernetes/simulation-adapter.yaml") -Raw
    $importFile = Join-Path $PSScriptRoot "kubernetes/.generated/simulation-adapter.yaml"
    $template -replace "__CHART_VERSION__", $config.simulationChartVersion | Set-Content -Path $importFile -Encoding UTF8
    Invoke-OctoCli -CliArgs @("-c", "ImportRt", "-f", $importFile, "-w") -FailureHint "Simulation adapter import failed."
    Invoke-OctoCli -CliArgs @("-c", "DeployWorkload", "-id", $SimulationAdapterRtId) -FailureHint "Check 'octo-cli -c GetAdapters' for deployment errors."
}

Write-Host "Waiting for adapter pods (up to 5 minutes)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $pods = kubectl --context $KubeContext -n octo get pods --no-headers 2>$null | Out-String
    $adapterLines = $pods -split "`n" | Where-Object { $_ -match "^$TenantId-" }
    if ($adapterLines | Where-Object { $_ -match "Running" }) { break }
    Start-Sleep -Seconds 10
}
kubectl --context $KubeContext -n octo get communicationpool,pods

Write-Host ""
Write-Host "Tenant '$TenantId' is ready." -ForegroundColor Green
Write-Host "Check adapter state with: octo-cli -c GetAdapters"
