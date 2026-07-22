#!/usr/bin/env pwsh
# Shows the status of the OctoMesh kind installation.
$KubeContext = "kind-octomesh"
$base = "127-0-0-1.nip.io"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found. Run ./om-install.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "Cluster node: $state" -ForegroundColor Cyan
if ($state -ne "running") { Write-Host "Start it with ./om-start.ps1."; exit 0 }

Write-Host ""
Write-Host "=== Pods ===" -ForegroundColor Cyan
foreach ($ns in @("octo-infra", "octo", "octo-operator-system")) {
    Write-Host "--- namespace $ns ---"
    kubectl --context $KubeContext -n $ns get pods 2>$null
}
Write-Host ""
Write-Host "=== Helm releases ===" -ForegroundColor Cyan
helm --kube-context $KubeContext list -A
Write-Host ""
Write-Host "=== Host ports ===" -ForegroundColor Cyan
foreach ($port in @(80, 443, 27017, 5672, 15672, 5432, 4301)) {
    $open = Test-Connection -TargetName 127.0.0.1 -TcpPort $port -TimeoutSeconds 3 -Quiet
    $label = if ($open) { "open" } else { "CLOSED" }
    Write-Host ("  127.0.0.1:{0,-6} {1}" -f $port, $label)
}
Write-Host ""
Write-Host "=== URLs ===" -ForegroundColor Cyan
Write-Host "  Identity:          https://identity.$base/"
Write-Host "  Asset repository:  https://assets.$base/tenants/octosystem/graphql/playground"
Write-Host "  Bot dashboard:     https://bots.$base/ui/jobs"
Write-Host "  Platform services: https://platform.$base/octosystem/_configuration"
Write-Host "  Refinery Studio:   https://studio.$base/          (full profile)"
Write-Host "  Reporting:         https://reporting.$base/       (full profile)"
Write-Host "  RabbitMQ mgmt:     http://localhost:15672/        (guest/guest)"
Write-Host "  CrateDB console:   http://localhost:4301/"
