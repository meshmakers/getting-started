#!/usr/bin/env pwsh
# Starts a previously stopped OctoMesh kind cluster.
$ErrorActionPreference = "Stop"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found. Run ./om-install.ps1 first." -ForegroundColor Red
    exit 1
}
$coldStart = $false
if ($state -eq "running") {
    Write-Host "OctoMesh cluster is already running." -ForegroundColor Yellow
}
else {
    Write-Host "Starting the OctoMesh kind cluster..." -ForegroundColor Cyan
    docker start $node | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker start $node failed." }
    $coldStart = $true
}

if ($coldStart) {
    # TEMPORARY workaround for platform bug AB#4498: services that boot while the
    # identity service is not yet reachable cache a broken OIDC metadata state
    # and then reject valid tokens with 401 until their pods are restarted.
    # The broken state never self-heals (measured: >2h idle, 35 min under
    # constant traffic). On a cold start every pod boots at once, so this race
    # is hit almost every time. Remedy: wait until identity serves its JWKS
    # through the ingress, then restart the token-validating services once so
    # they fetch a clean OIDC state on boot.
    Write-Host "Waiting for the identity service (OIDC discovery through ingress)..."
    $deadline = (Get-Date).AddMinutes(10)
    $identityReady = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $jwks = Invoke-RestMethod -Uri "https://identity.127-0-0-1.nip.io/.well-known/openid-configuration/jwks" -SkipCertificateCheck -TimeoutSec 5
            if ($jwks.keys -and @($jwks.keys).Count -gt 0) { $identityReady = $true; break }
        }
        catch { }
        Start-Sleep -Seconds 5
    }
    if (-not $identityReady) {
        throw "Identity did not serve its JWKS within 10 minutes - check ./om-status.ps1."
    }

    Write-Host "Restarting token-validating services so they pick up a clean OIDC state..."
    $tokenValidators = @(
        "octo-mesh-asset-rep-services",
        "octo-mesh-bot-services",
        "octo-mesh-communication-controller-services",
        "octo-mesh-platform-services",
        "octo-mesh-reporting"
    )
    $existing = @(kubectl --context kind-octomesh -n octo get deployments -o name 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Could not list deployments in namespace octo." }
    $toRestart = $tokenValidators | Where-Object { $existing -contains "deployment.apps/$_" }
    foreach ($deployment in $toRestart) {
        kubectl --context kind-octomesh -n octo rollout restart deployment $deployment | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "rollout restart of $deployment failed." }
    }
    foreach ($deployment in $toRestart) {
        kubectl --context kind-octomesh -n octo rollout status deployment $deployment --timeout=300s | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "rollout of $deployment did not complete - check ./om-status.ps1." }
    }
}

Write-Host "Waiting for pods to become ready (this can take a few minutes after a cold start)..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    $notReady = kubectl --context kind-octomesh -n octo get pods --no-headers 2>$null | Where-Object { $_ -notmatch "Running|Completed" }
    if ($LASTEXITCODE -eq 0 -and -not $notReady) { break }
    Start-Sleep -Seconds 10
}
Write-Host "Start done. Check details with ./om-status.ps1."
