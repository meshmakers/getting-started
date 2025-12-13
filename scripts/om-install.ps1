param(
    [Parameter()]
    [ValidateSet("core", "full")]
    [string]$DeploymentProfile = "core"
)

function Test-Prerequisites
{
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Checking Prerequisites" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $allPassed = $true

    # Check OpenSSL
    Write-Host -NoNewline "Checking OpenSSL... "
    if (Get-Command openssl -ErrorAction SilentlyContinue)
    {
        $opensslVersion = & openssl version 2>&1
        Write-Host "OK ($opensslVersion)" -ForegroundColor Green
    }
    else
    {
        Write-Host "NOT FOUND" -ForegroundColor Red
        Write-Host "  Please install OpenSSL and ensure it is available in PATH." -ForegroundColor Yellow
        Write-Host "  Windows: winget install -e --id ShiningLight.OpenSSL" -ForegroundColor Yellow
        Write-Host "  macOS: brew install openssl" -ForegroundColor Yellow
        $allPassed = $false
    }

    # Check Docker
    Write-Host -NoNewline "Checking Docker... "
    if (Get-Command docker -ErrorAction SilentlyContinue)
    {
        $dockerRunning = docker info 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            $dockerVersion = & docker --version 2>&1
            Write-Host "OK ($dockerVersion)" -ForegroundColor Green
        }
        else
        {
            Write-Host "NOT RUNNING" -ForegroundColor Red
            Write-Host "  Docker is installed but not running. Please start Docker Desktop." -ForegroundColor Yellow
            $allPassed = $false
        }
    }
    else
    {
        Write-Host "NOT FOUND" -ForegroundColor Red
        Write-Host "  Please install Docker Desktop (4.29+)." -ForegroundColor Yellow
        $allPassed = $false
    }

    # Check octo-cli
    Write-Host -NoNewline "Checking octo-cli... "
    if (Get-Command octo-cli -ErrorAction SilentlyContinue)
    {
        Write-Host "OK" -ForegroundColor Green
    }
    else
    {
        Write-Host "NOT FOUND" -ForegroundColor Red
        Write-Host "  Please install octo-cli: choco install octo-cli" -ForegroundColor Yellow
        $allPassed = $false
    }

    Write-Host ""

    if (-not $allPassed)
    {
        Write-Host "Prerequisites check failed. Please install missing dependencies and try again." -ForegroundColor Red
        return $false
    }

    Write-Host "All prerequisites met!" -ForegroundColor Green
    return $true
}

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

function Get-HelmChartVersions([string]$chartName)
{
    Write-Host "Fetching available versions for $chartName..."
    try
    {
        $response = Invoke-WebRequest -Uri "https://meshmakers.github.io/charts/index.yaml" -UseBasicParsing
        $content = $response.Content

        $versions = [System.Collections.ArrayList]@()

        # Split into individual chart entries (each starts with "- apiVersion:")
        $entries = $content -split "(?=- apiVersion:)"

        foreach ($entry in $entries)
        {
            # Check if this entry is for the exact chart name
            if ($entry -match "name:\s*$chartName\s*$" -or $entry -match "name:\s*$chartName\s*[\r\n]")
            {
                # Ensure it's an exact match (not a substring like octo-mesh matching octo-mesh-reporting)
                if ($entry -match "name:\s*$chartName-")
                {
                    continue
                }

                # Extract appVersion
                if ($entry -match "appVersion:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)")
                {
                    $version = $matches[1]
                    if (-not $versions.Contains($version))
                    {
                        [void]$versions.Add($version)
                    }
                }
            }
        }

        # Sort versions descending (newest first)
        $sortedVersions = $versions | Sort-Object { [Version]$_ } -Descending
        return $sortedVersions
    }
    catch
    {
        Write-Error "Failed to fetch versions for $chartName`: $_"
        return @()
    }
}

function Get-OctoMeshVersions()
{
    return Get-HelmChartVersions -chartName "octo-mesh"
}

function Get-ReportingServicesVersions()
{
    return Get-HelmChartVersions -chartName "octo-mesh-reporting"
}

function Read-LicenseKey([string]$prompt)
{
    Write-Host -NoNewline "$prompt"
    $key = ""
    while ($true)
    {
        $keyInfo = [Console]::ReadKey($true)
        if ($keyInfo.Key -eq 'Enter')
        {
            Write-Host ""
            break
        }
        elseif ($keyInfo.Key -eq 'Backspace')
        {
            if ($key.Length -gt 0)
            {
                $key = $key.Substring(0, $key.Length - 1)
                Write-Host -NoNewline "`b `b"
            }
        }
        else
        {
            $key += $keyInfo.KeyChar
            Write-Host -NoNewline "*"
        }
    }
    return $key
}

function Initialize-EnvLocal([string]$envLocalPath, [string]$deploymentProfile)
{
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  OctoMesh Configuration Setup" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check if .env.local already exists
    $existingConfig = @{}
    if (Test-Path -Path $envLocalPath)
    {
        Write-Host "Found existing .env.local - loading current values..." -ForegroundColor Yellow
        $lines = Get-Content $envLocalPath
        foreach ($line in $lines)
        {
            if ($line -match '^([^#=]+)=(.*)$')
            {
                $existingConfig[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
    }

    # 1. Select OctoMesh Version
    Write-Host ""
    Write-Host "Step 1: Select OctoMesh Version" -ForegroundColor Green
    Write-Host "--------------------------------"

    $versions = Get-OctoMeshVersions
    if ($versions.Count -eq 0)
    {
        Write-Error "Could not fetch versions. Please check your internet connection."
        return $false
    }

    $defaultVersion = $versions[0]
    $currentVersion = if ($existingConfig.ContainsKey("OCTO_VERSION")) { $existingConfig["OCTO_VERSION"] } else { $null }

    Write-Host "Available versions (showing latest 10):"
    $displayVersions = $versions | Select-Object -First 10
    for ($i = 0; $i -lt $displayVersions.Count; $i++)
    {
        $marker = ""
        if ($displayVersions[$i] -eq $currentVersion) { $marker = " (current)" }
        if ($i -eq 0) { $marker += " [default]" }
        Write-Host "  [$($i + 1)] $($displayVersions[$i])$marker"
    }
    Write-Host "  [0] Enter custom version"
    Write-Host ""

    if ($currentVersion)
    {
        Write-Host "Current version: $currentVersion" -ForegroundColor Yellow
    }

    $versionInput = Read-Host "Select version (press Enter for default: $defaultVersion)"

    if ([string]::IsNullOrWhiteSpace($versionInput))
    {
        $selectedVersion = $defaultVersion
    }
    elseif ($versionInput -eq "0")
    {
        $selectedVersion = Read-Host "Enter custom version (e.g., 3.2.218.0)"
    }
    else
    {
        $index = [int]$versionInput - 1
        if ($index -ge 0 -and $index -lt $displayVersions.Count)
        {
            $selectedVersion = $displayVersions[$index]
        }
        else
        {
            Write-Host "Invalid selection, using default." -ForegroundColor Yellow
            $selectedVersion = $defaultVersion
        }
    }

    Write-Host "Selected version: $selectedVersion" -ForegroundColor Green

    # 2. Identity Server License Key
    Write-Host ""
    Write-Host "Step 2: Identity Server License Key" -ForegroundColor Green
    Write-Host "------------------------------------"
    Write-Host "Get your license key at: https://duendesoftware.com/products/identityserver#pricing" -ForegroundColor Cyan
    Write-Host "(Community edition is free for small companies and open source projects)"
    Write-Host ""

    $currentIdentityKey = if ($existingConfig.ContainsKey("IDENTITY_SERVER_LICENSE_KEY")) { $existingConfig["IDENTITY_SERVER_LICENSE_KEY"] } else { $null }

    if ($currentIdentityKey)
    {
        $maskedKey = $currentIdentityKey.Substring(0, [Math]::Min(20, $currentIdentityKey.Length)) + "..."
        Write-Host "Current key: $maskedKey" -ForegroundColor Yellow
        $identityKeyInput = Read-LicenseKey "Enter new license key (press Enter to keep current): "
        if ([string]::IsNullOrWhiteSpace($identityKeyInput))
        {
            $identityServerKey = $currentIdentityKey
        }
        else
        {
            $identityServerKey = $identityKeyInput.Trim()
        }
    }
    else
    {
        $identityServerKey = Read-LicenseKey "Enter Identity Server license key: "
        while ([string]::IsNullOrWhiteSpace($identityServerKey))
        {
            Write-Host "License key is required!" -ForegroundColor Red
            $identityServerKey = Read-LicenseKey "Enter Identity Server license key: "
        }
    }

    # 3. AutoMapper License Key
    Write-Host ""
    Write-Host "Step 3: AutoMapper License Key" -ForegroundColor Green
    Write-Host "-------------------------------"
    Write-Host "Get your license key at: https://www.automapper.org/pricing" -ForegroundColor Cyan
    Write-Host "(Free tier available)"
    Write-Host ""

    $currentAutoMapperKey = if ($existingConfig.ContainsKey("AUTOMAPPER_LICENSE_KEY")) { $existingConfig["AUTOMAPPER_LICENSE_KEY"] } else { $null }

    if ($currentAutoMapperKey)
    {
        $maskedKey = $currentAutoMapperKey.Substring(0, [Math]::Min(20, $currentAutoMapperKey.Length)) + "..."
        Write-Host "Current key: $maskedKey" -ForegroundColor Yellow
        $autoMapperKeyInput = Read-LicenseKey "Enter new license key (press Enter to keep current): "
        if ([string]::IsNullOrWhiteSpace($autoMapperKeyInput))
        {
            $autoMapperKey = $currentAutoMapperKey
        }
        else
        {
            $autoMapperKey = $autoMapperKeyInput.Trim()
        }
    }
    else
    {
        $autoMapperKey = Read-LicenseKey "Enter AutoMapper license key: "
        while ([string]::IsNullOrWhiteSpace($autoMapperKey))
        {
            Write-Host "License key is required!" -ForegroundColor Red
            $autoMapperKey = Read-LicenseKey "Enter AutoMapper license key: "
        }
    }

    # 4. Reporting Services Version (only for full profile)
    $selectedReportingVersion = ""
    if ($deploymentProfile -eq "full")
    {
        Write-Host ""
        Write-Host "Step 4: Select Reporting Services Version" -ForegroundColor Green
        Write-Host "------------------------------------------"

        $reportingVersions = Get-ReportingServicesVersions
        if ($reportingVersions.Count -eq 0)
        {
            Write-Host "Could not fetch Reporting Services versions. Using manual input." -ForegroundColor Yellow
            $selectedReportingVersion = Read-Host "Enter Reporting Services version (e.g., 1.0.0.0)"
        }
        else
        {
            $defaultReportingVersion = $reportingVersions[0]
            $currentReportingVersion = if ($existingConfig.ContainsKey("OCTO_REPORTING_SERVICES_VERSION")) { $existingConfig["OCTO_REPORTING_SERVICES_VERSION"] } else { $null }

            Write-Host "Available versions (showing latest 10):"
            $displayReportingVersions = $reportingVersions | Select-Object -First 10
            for ($i = 0; $i -lt $displayReportingVersions.Count; $i++)
            {
                $marker = ""
                if ($displayReportingVersions[$i] -eq $currentReportingVersion) { $marker = " (current)" }
                if ($i -eq 0) { $marker += " [default]" }
                Write-Host "  [$($i + 1)] $($displayReportingVersions[$i])$marker"
            }
            Write-Host "  [0] Enter custom version"
            Write-Host ""

            if ($currentReportingVersion)
            {
                Write-Host "Current version: $currentReportingVersion" -ForegroundColor Yellow
            }

            $reportingVersionInput = Read-Host "Select version (press Enter for default: $defaultReportingVersion)"

            if ([string]::IsNullOrWhiteSpace($reportingVersionInput))
            {
                $selectedReportingVersion = $defaultReportingVersion
            }
            elseif ($reportingVersionInput -eq "0")
            {
                $selectedReportingVersion = Read-Host "Enter custom version (e.g., 1.0.0.0)"
            }
            else
            {
                $index = [int]$reportingVersionInput - 1
                if ($index -ge 0 -and $index -lt $displayReportingVersions.Count)
                {
                    $selectedReportingVersion = $displayReportingVersions[$index]
                }
                else
                {
                    Write-Host "Invalid selection, using default." -ForegroundColor Yellow
                    $selectedReportingVersion = $defaultReportingVersion
                }
            }

            Write-Host "Selected Reporting Services version: $selectedReportingVersion" -ForegroundColor Green
        }
    }

    # Write .env.local file
    Write-Host ""
    Write-Host "Writing configuration to .env.local..." -ForegroundColor Green

    $envContent = @"
# OctoMesh local configuration
# Generated on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# OctoMesh Version
OCTO_VERSION=$selectedVersion

# License Keys
IDENTITY_SERVER_LICENSE_KEY=$identityServerKey
AUTOMAPPER_LICENSE_KEY=$autoMapperKey
"@

    # Add Reporting Services version if full profile
    if ($deploymentProfile -eq "full" -and -not [string]::IsNullOrWhiteSpace($selectedReportingVersion))
    {
        $envContent += "`n`n# Reporting Services Version`nOCTO_REPORTING_SERVICES_VERSION=$selectedReportingVersion"
    }

    Set-Content -Path $envLocalPath -Value $envContent -Encoding UTF8

    Write-Host ""
    Write-Host "Configuration saved successfully!" -ForegroundColor Green
    Write-Host ""

    return $true
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

# Check prerequisites before proceeding
if (-not (Test-Prerequisites))
{
    return
}

$basedir = $PWD
$infrastructurePath = Join-Path $basedir "octo-mesh"
Push-Location $infrastructurePath

# Check and initialize .env.local if needed
$envLocalPath = Join-Path $infrastructurePath ".env.local"

# Check if .env.local exists and has all required keys
$needsConfig = $false
if (-not (Test-Path -Path $envLocalPath))
{
    Write-Host "No .env.local found - configuration required." -ForegroundColor Yellow
    $needsConfig = $true
}
else
{
    # Check if all required keys are present
    $content = Get-Content $envLocalPath -Raw
    if (-not ($content -match 'OCTO_VERSION=.+') -or
        -not ($content -match 'IDENTITY_SERVER_LICENSE_KEY=.+') -or
        -not ($content -match 'AUTOMAPPER_LICENSE_KEY=.+'))
    {
        Write-Host "Incomplete .env.local found - configuration required." -ForegroundColor Yellow
        $needsConfig = $true
    }
}

if ($needsConfig)
{
    $result = Initialize-EnvLocal -envLocalPath $envLocalPath -deploymentProfile $DeploymentProfile
    if (-not $result)
    {
        Write-Error "Configuration failed. Please try again."
        Pop-Location
        return
    }
}
else
{
    Write-Host "Configuration found in .env.local" -ForegroundColor Green

    # Offer to reconfigure
    $reconfigure = Read-Host "Do you want to reconfigure? (y/N)"
    if ($reconfigure -eq "y" -or $reconfigure -eq "Y")
    {
        $result = Initialize-EnvLocal -envLocalPath $envLocalPath -deploymentProfile $DeploymentProfile
        if (-not $result)
        {
            Write-Error "Configuration failed. Please try again."
            Pop-Location
            return
        }
    }
}

# create backup directory (required for docker volume mount)
if (!(Test-Path -Path "backup" -PathType Container))
{
    Write-Host "Creating backup directory"
    New-Item -Path "backup" -ItemType Directory | Out-Null
}

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

Write-Progress -Activity 'Install OctoMesh' -Status 'Initializing cert for Authority' -PercentComplete 10
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

Write-Progress -Activity 'Install OctoMesh' -Status 'Initializing HTTPS self signed cert' -PercentComplete 20
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
Write-Host "Starting with profile: $DeploymentProfile" -ForegroundColor Cyan
if ($DeploymentProfile -eq "full")
{
    docker compose --env-file .env --env-file .env.local --profile full up -d
}
else
{
    docker compose --env-file .env --env-file .env.local up -d
}

Write-Progress -Activity 'Install OctoMesh' -Status  "Waiting for the containers to be started..." -PercentComplete 40
Wait-DockerContainer octo-mongo-0.mongo
Start-Sleep -s 3

Write-Progress -Activity 'Install OctoMesh' -Status 'Setting up mongodb replicaset' -PercentComplete 60

Write-Host "Initializing replica set and waiting for complete initialization";
while ($true)
{
    &{
        docker exec octo-mongo-0.mongo sh -c "mongosh admin /scripts/init-database.js"
    } 2> stderr.txt
    $err = get-content stderr.txt
    Write-Host $err
    if ((-not([string]::IsNullOrWhiteSpace($err))) -And $err.Contains("MongoNetworkError"))
    {
        Write-Progress -Activity 'Install OctoMesh' -Status  "Retrying to init replica set..." -PercentComplete 70
        Start-Sleep -s 3
        continue;
    }
    Remove-Item stderr.txt
    break;
}


# init user.
Write-Progress -Activity 'Install OctoMesh' -Status 'Creating admin user' -PercentComplete 80
docker exec octo-mongo-0.mongo sh -c "mongosh admin /scripts/create-admin-user.js"

Write-Progress -Activity 'Install Octo infrastructure' -Status 'Complete' -PercentComplete 100

#Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Install the SSL certificate" -ForegroundColor Yellow
Write-Host "   The certificate was created in: octo-mesh/localhost_cert.pfx"
Write-Host "   - Windows: Double-click the .pfx file and import to 'Trusted Root Certification Authorities'"
Write-Host "   - macOS: Double-click the .pfx file and add to Keychain, then trust it"
Write-Host "   Password: Secret01"
Write-Host ""
Write-Host "2. Create the admin user" -ForegroundColor Yellow
Write-Host "   Open https://octo-identity-services:5003/ in your browser"
Write-Host "   and register the admin user with an email and password."

if ($DeploymentProfile -eq "full")
{
    Write-Host ""
    Write-Host "3. Log in to OctoMesh CLI" -ForegroundColor Yellow
    Write-Host "   Run ./om-login-local.ps1 to log in with the admin user."
    Write-Host ""
    Write-Host "4. Setup Identity Service clients" -ForegroundColor Yellow
    Write-Host "   Run ./om-setupIdentityService-local.ps1 to create the client"
    Write-Host "   definitions for Data Refinery Studio."
}

Write-Host ""
Write-Host "Commands:"
Write-Host "  Stop:  ./om-stop.ps1"
Write-Host "  Start: ./om-start.ps1"


Pop-Location

