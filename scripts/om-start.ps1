
$basedir = $PWD
$infrastructurePath = Join-Path $basedir "octo-mesh"

if (!(Test-Path $infrastructurePath)) {
    Write-Error "Infrastructure path $infrastructurePath does not exist"
    return;
}

Push-Location $infrastructurePath

Write-Host "Starting Octo infrastructure"
docker-compose --env-file .env --env-file .env.local up -d

Pop-Location

Write-Host "Start done. Containers are running."
Write-Host "For stopping use 'Stop-OctoInfrastructure'"
