function Wait-DockerContainer([string]$containerId)
{
    Write-Host "Waiting for docker container $containerId"

    # Loop until the container is running
    while ((docker inspect -f '{{.State.Status}}' $containerId) -ne "running")
    {
        Start-Sleep -Seconds 2
        Write-Host Waiting more...
    }
}

function Create-HttpsCert()
{
    # Install openseel (e. g. winget install -e --id ShiningLight.OpenSSL)
    if ((Get-Command openssl -ErrorAction SilentlyContinue).Length -eq 0)
    {
        Write-Error "Ensure that OpenSSL is installed an available in PATH environment variable."
        return;
    }
    
    # Replace these with the actual paths to your PFX and PEM files
    $location = Get-Location
    $keyFilePath = Join-Path $location "localhost_cert.key"
    $csrFilePath = Join-Path $location "localhost_cert.csr"
    $sourcePfxFilePath = Join-Path $location "localhost_cert.pfx"
    $sourceCrtFilePath = Join-Path $location "localhost_cert.crt"
    $destinationPemFilePath = Join-Path $location "localhost_cert.pem"
    $certPassword = "Secret01"  # Replace "YourPFXPassword" with the password for the PFX file

    Write-Host "Creating HTTPS certificate for localhost"
    openssl genrsa -out $keyFilePath 2048
    Write-Host 1
    openssl req -new -key $keyFilePath -out $csrFilePath -config openssl.cnf 
    # Create developer cert and trust it using PFX format
    Write-Host 2
    openssl x509 -req -days 365 -in $csrFilePath -signkey $keyFilePath -out $sourceCrtFilePath -extensions req_ext -extfile openssl.cnf
    Write-Host 3
    Get-Content $sourceCrtFilePath, $keyFilePath | Set-Content $destinationPemFilePath
    # Erstelle eine PFX-Datei
    Write-Host 4
    openssl pkcs12 -export -out $sourcePfxFilePath -inkey  $keyFilePath -in $sourceCrtFilePath -passout pass:$certPassword
  #  Write-Host 5
    #dotnet dev-certs https -ep $sourcePfxFilePath -p $certPassword -t
    # Create PEM format for trust self signed cert also in container itself
    #openssl pkcs12 -in $sourcePfxFilePath -nokeys -out $destinationPemFilePath -nodes -passin pass:$certPassword  -passout pass:$certPassword
}

function Create-IdentityServerAuthorityCert()
{
    $certPassword = "Secret01"
    openssl req -x509 -newkey rsa:2048 -sha256 -keyout IdentityServer4Auth.key -out IdentityServer4Auth.crt -subj "/CN=localhost" -days 10950 -passout pass:$certPassword
    openssl pkcs12 -export -out IdentityServer4Auth.pfx -inkey IdentityServer4Auth.key -in IdentityServer4Auth.crt -passin pass:$certPassword -passout pass:$certPassword
    openssl pkcs12 -export -out IdentityServer4Auth.pfx -inkey IdentityServer4Auth.key -in IdentityServer4Auth.crt -passin pass:$certPassword -passout pass:$certPassword
}

#$PSStyle.Progress.View = "Classic"

$basedir = $PWD
$infrastructurePath = Join-Path $basedir "infrastructure"
Set-Location $infrastructurePath

# create the key file for mongodb
Write-Progress -Activity 'Install Octo infrastructure' -Status 'Creating keys for mongodb cluster' -PercentComplete 1
if (!(Test-Path -Path "file.key"))
{
    Write-Host "Creating key file and setting access";
    $randBytes = New-Object byte[] 741
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
    $randString = [Convert]::ToBase64String($randBytes)
    $randString > file.key
}
else
{
    Write-Host "Already existing key for mongodb cluster"
}

Write-Progress -Activity 'Install Octo infrastructure' -Status 'Initializing cert for Authority' -PercentComplete 10
if (!(Test-Path -Path "IdentityServer4Auth.pfx"))
{
    Create-IdentityServerAuthorityCert

    if ($LastExitCode -ne 0)
    {
        return;
    }
}
else
{
    Write-Host "Already existing cert for authenication Authority"    
}

Write-Progress -Activity 'Install Octo infrastructure' -Status 'Initializing HTTPS self signed cert' -PercentComplete 20
if (!(Test-Path -Path "localhost_cert.pfx") -or !(Test-Path -Path "localhost_cert.pem"))
{
    Create-HttpsCert

    if ($LastExitCode -ne 0)
    {
        return;
    }
}
else
{
    Write-Host "Already existing cert for HTTPS certificate for localhost"

}

Write-Progress -Activity 'Install Octo infrastructure' -Status 'Docker compose up' -PercentComplete 30

# run ...
docker compose up -d

Write-Progress -Activity 'Install Octo infrastructure' -Status  "Waiting for the containers to be started..." -PercentComplete 40
Wait-DockerContainer mongo-0.mongo
Start-Sleep -s 3

Write-Progress -Activity 'Install Octo infrastructure' -Status 'Setting up mongodb replicaset' -PercentComplete 60

Write-Host "Initializing replica set and waiting for complete initialization";
while ($true)
{
    &{
        docker exec mongo-0.mongo sh -c "mongosh admin /scripts/init-database.js"
    } 2> stderr.txt
    $err = get-content stderr.txt
    Write-Host $err
    if ((-not([string]::IsNullOrWhiteSpace($err))) -And $err.Contains("MongoNetworkError"))
    {
        Write-Progress -Activity 'Install Octo infrastructure' -Status  "Retrying to init replica set..." -PercentComplete 70
        Start-Sleep -s 3
        continue;
    }
    Remove-Item stderr.txt
    break;
}


# init user.
Write-Progress -Activity 'Install Octo infrastructure' -Status 'Creating admin user' -PercentComplete 80
docker exec mongo-0.mongo sh -c "mongosh admin /scripts/create-admin-user.js"

Write-Progress -Activity 'Install Octo infrastructure' -Status 'Complete' -PercentComplete 100

#Clear-Host
Write-Host "Initialization done. Containers are running."
Write-Host "For the stop use 'om-stop-OctoInfrastructure'"
Write-Host "For the next start just 'om-start-OctoInfrastructure'"


Set-Location $basedir

