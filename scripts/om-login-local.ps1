#!/usr/bin/env pwsh
# Configures a dedicated octo-cli context for the local kind installation and logs in interactively.
param(
    $tenantId = "meshtest",
    $includeReporting = $false
)

$ErrorActionPreference = "Stop"
$base = "127-0-0-1.nip.io"
$contextName = "getting-started_$tenantId"

# Use a named context (context API) so any other octo-cli contexts the user has
# configured are left untouched.
$contextArgs = @(
    "-c", "AddContext", "-n", $contextName,
    "-isu", "https://identity.$base/",
    "-asu", "https://assets.$base/",
    "-bsu", "https://bots.$base/",
    "-csu", "https://communication.$base/",
    "-tid", $tenantId
)
if ($includeReporting) {
    Write-Host "Including reporting"
    $contextArgs += @("-rsu", "https://reporting.$base/")
}
octo-cli @contextArgs
if ($LASTEXITCODE -ne 0) { throw "Creating the octo-cli context '$contextName' failed." }

octo-cli -c UseContext -n $contextName
if ($LASTEXITCODE -ne 0) { throw "Activating the octo-cli context '$contextName' failed." }

octo-cli -c Login -i
