#!/usr/bin/env pwsh
# Configures octo-cli for the local kind installation and logs in interactively.
param(
    $tenantId = "meshtest",
    $includeReporting = $false
)

$ErrorActionPreference = "Stop"
$base = "127-0-0-1.nip.io"

if ($includeReporting) {
    Write-Host "Including reporting"
    octo-cli -c Config -asu "https://assets.$base/" -isu "https://identity.$base/" -bsu "https://bots.$base/" -csu "https://communication.$base/" -rsu "https://reporting.$base/" -tid $tenantId
}
else {
    octo-cli -c Config -asu "https://assets.$base/" -isu "https://identity.$base/" -bsu "https://bots.$base/" -csu "https://communication.$base/" -tid $tenantId
}
octo-cli -c Login -i

