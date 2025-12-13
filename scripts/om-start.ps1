param(
    [Parameter()]
    [ValidateSet("core", "full")]
    [string]$DeploymentProfile = "core"
)

$basedir = $PWD
$infrastructurePath = Join-Path $basedir "octo-mesh"

if (!(Test-Path $infrastructurePath)) {
    Write-Error "Infrastructure path $infrastructurePath does not exist"
    return;
}

Push-Location $infrastructurePath

Write-Host "Starting Octo infrastructure with profile: $DeploymentProfile" -ForegroundColor Cyan
if ($DeploymentProfile -eq "full")
{
    docker compose --env-file .env --env-file .env.local --profile full up -d
}
else
{
    docker compose --env-file .env --env-file .env.local up -d
}

Pop-Location

Write-Host "Start done. Containers are running."
Write-Host "For stopping use './om-stop.ps1'"
