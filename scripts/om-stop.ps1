
$basedir = $PWD
$infrastructurePath = Join-Path $basedir "infrastructure"

if (!(Test-Path $infrastructurePath)) {
    Write-Error "Infrastructure path $infrastructurePath does not exist"
    return;
}

Push-Location $infrastructurePath

docker-compose down

Pop-Location

