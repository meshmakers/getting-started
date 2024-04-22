
$basedir = $PWD
$infrastructurePath = Join-Path $basedir "infrastructure"

if (!(Test-Path $infrastructurePath)) {
    Write-Error "Infrastructure path $infrastructurePath does not exist"
    return;
}

Push-Location $infrastructurePath

Write-Host "Starting Octo infrastructure"
docker-compose up -d

Pop-Location

Write-Host "Start done. Containers are running."
Write-Host "For stopping use 'Stop-OctoInfrastructure'"
