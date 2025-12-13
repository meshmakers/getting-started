$basedir = $PWD
$infrastructurePath = Join-Path $basedir "octo-mesh"

if (!(Test-Path $infrastructurePath)) {
    Write-Error "Infrastructure path $infrastructurePath does not exist"
    return
}

Push-Location $infrastructurePath

Write-Host "Uninstalling OctoMesh infrastructure" -ForegroundColor Cyan

if (Test-Path -Path "file.key")
{
    Write-Host "Deleting key file"
    Remove-Item -Force -Path "file.key"
}

Write-Host "Stopping all containers and cleaning up volumes"
# Always use --profile full to ensure all services are removed
docker compose --env-file .env --env-file .env.local --profile full down -v

Pop-Location

Write-Host "Uninstall complete." -ForegroundColor Green
