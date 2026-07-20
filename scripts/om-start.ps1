#!/usr/bin/env pwsh
# Starts a previously stopped OctoMesh kind cluster.
$ErrorActionPreference = "Stop"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found. Run ./om-install.ps1 first." -ForegroundColor Red
    exit 1
}
if ($state -eq "running") {
    Write-Host "OctoMesh cluster is already running." -ForegroundColor Yellow
}
else {
    Write-Host "Starting the OctoMesh kind cluster..." -ForegroundColor Cyan
    docker start $node | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker start $node failed." }
}
Write-Host "Waiting for pods to become ready (this can take a few minutes after a cold start)..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    $notReady = kubectl --context kind-octomesh -n octo get pods --no-headers 2>$null | Where-Object { $_ -notmatch "Running|Completed" }
    if ($LASTEXITCODE -eq 0 -and -not $notReady) { break }
    Start-Sleep -Seconds 10
}
Write-Host "Start done. Check details with ./om-status.ps1."
