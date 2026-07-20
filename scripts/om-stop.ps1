#!/usr/bin/env pwsh
# Stops the OctoMesh kind cluster. Data is preserved; restart with ./om-start.ps1.
$ErrorActionPreference = "Stop"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found (container '$node' does not exist)." -ForegroundColor Yellow
    exit 0
}
if ($state -ne "running") {
    Write-Host "OctoMesh cluster is already stopped." -ForegroundColor Yellow
    exit 0
}
Write-Host "Stopping the OctoMesh kind cluster..." -ForegroundColor Cyan
docker stop $node | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker stop $node failed." }
Write-Host "Stopped. Data is preserved - start again with ./om-start.ps1."
