# License keys of the identity service, per OctoMesh release.
# Dot-sourced by ../om-install.ps1.
#
# Older identity images refuse to start without these keys (InitializationException.EnsureLicenseKey),
# newer ones no longer read them:
#   * Duende IdentityServer - replaced by OpenIddict in 3.4.113.0 (AB#4996).
#   * AutoMapper            - replaced by explicit mappers in 3.5.23.0 (AB#6506).
# The chart passes the identity image tag = chart appVersion, so the selected appVersion decides.

$script:IdentityLicenseKeys = @(
    [pscustomobject]@{
        ConfigKey               = "identityServerLicenseKey"
        ParameterName           = "IdentityServerLicenseKey"
        Product                 = "Duende IdentityServer"
        SignUpHint              = "Get one at https://duendesoftware.com/products/identityserver#pricing (community edition is free for small companies and open source)."
        RequiredBelowAppVersion = [Version]"3.4.113.0"
    },
    [pscustomobject]@{
        ConfigKey               = "autoMapperLicenseKey"
        ParameterName           = "AutoMapperLicenseKey"
        Product                 = "AutoMapper"
        SignUpHint              = "Get one at https://www.automapper.io/ (free tier available)."
        RequiredBelowAppVersion = [Version]"3.5.23.0"
    }
)

function ConvertTo-AppVersion([string]$AppVersion) {
    $parsedVersion = $null
    if (-not [Version]::TryParse($AppVersion, [ref]$parsedVersion)) {
        throw "OctoMesh app version '$AppVersion' is not a version number (expected e.g. 3.5.23.0)."
    }
    return $parsedVersion
}

function Get-RequiredLicenseKeys([string]$AppVersion) {
    $selectedVersion = ConvertTo-AppVersion $AppVersion
    return @($script:IdentityLicenseKeys | Where-Object { $selectedVersion -lt $_.RequiredBelowAppVersion })
}

function Resolve-IdentityLicenseKeys {
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$AppVersion,
        [hashtable]$ProvidedKeys = @{},
        [switch]$NonInteractive,
        [Parameter(Mandatory)] [scriptblock]$ReadKey
    )

    $requiredKeys = Get-RequiredLicenseKeys -AppVersion $AppVersion
    $requiredConfigKeys = @($requiredKeys | ForEach-Object { $_.ConfigKey })

    foreach ($licenseKey in $script:IdentityLicenseKeys) {
        $isRequired = $requiredConfigKeys -contains $licenseKey.ConfigKey
        if (-not $isRequired) {
            $Config.Remove($licenseKey.ConfigKey)
            continue
        }

        $providedValue = $ProvidedKeys[$licenseKey.ConfigKey]
        if (-not [string]::IsNullOrWhiteSpace($providedValue)) {
            $Config[$licenseKey.ConfigKey] = $providedValue
            continue
        }

        $storedValue = $Config[$licenseKey.ConfigKey]
        if (-not [string]::IsNullOrWhiteSpace($storedValue)) { continue }

        if ($NonInteractive) {
            throw "OctoMesh $AppVersion needs the $($licenseKey.Product) license key: pass -$($licenseKey.ParameterName) or set $($licenseKey.ConfigKey) in local-config.json."
        }
        $Config[$licenseKey.ConfigKey] = & $ReadKey $licenseKey
    }
}

function Get-IdentityLicenseKeyValues {
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$AppVersion
    )

    $chartValues = @{}
    foreach ($licenseKey in Get-RequiredLicenseKeys -AppVersion $AppVersion) {
        $chartValues[$licenseKey.ConfigKey] = $Config[$licenseKey.ConfigKey]
    }
    return $chartValues
}
