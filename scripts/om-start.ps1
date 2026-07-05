param(
    [Parameter()]
    [ValidateSet("core", "full")]
    [string]$DeploymentProfile = "core",
    [Parameter()]
    [switch]$IncludeSimulation = $false
)

$basedir = $PWD
$infrastructurePath = Join-Path $basedir "octo-mesh"

if (!(Test-Path $infrastructurePath)) {
    Write-Error "Infrastructure path $infrastructurePath does not exist"
    return;
}

Push-Location $infrastructurePath

$profileInfo = $DeploymentProfile
if ($IncludeSimulation) { $profileInfo += " + simulation" }
Write-Host "Starting Octo infrastructure with profile: $profileInfo" -ForegroundColor Cyan

$composeArgs = @("compose", "--env-file", ".env", "--env-file", ".env.local")
if ($DeploymentProfile -eq "full")
{
    $composeArgs += @("--profile", "full")
}
if ($IncludeSimulation)
{
    $composeArgs += @("--profile", "simulation")
}
$composeArgs += @("up", "-d")
& docker @composeArgs

Pop-Location

Write-Host "Start done. Containers are running."
Write-Host "For stopping use './om-stop.ps1'"
