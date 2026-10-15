BeforeAll {
    . (Join-Path $PSScriptRoot "license-keys.ps1")

    function Get-RequiredConfigKeys([string]$AppVersion) {
        return @(Get-RequiredLicenseKeys -AppVersion $AppVersion | ForEach-Object { $_.ConfigKey })
    }

    $script:unexpectedPrompt = { param($licenseKey) throw "Unexpected prompt for $($licenseKey.Product)" }
}

Describe "Get-RequiredLicenseKeys" {
    It "requires both keys for releases that still ship Duende IdentityServer" {
        Get-RequiredConfigKeys "3.4.112.0" | Should -Be @("identityServerLicenseKey", "autoMapperLicenseKey")
    }

    It "requires only the AutoMapper key from the OpenIddict release on" {
        Get-RequiredConfigKeys "3.4.113.0" | Should -Be @("autoMapperLicenseKey")
    }

    It "still requires the AutoMapper key on the last release that uses AutoMapper" {
        Get-RequiredConfigKeys "3.5.22.0" | Should -Be @("autoMapperLicenseKey")
    }

    It "requires no key from the release without AutoMapper on" {
        Get-RequiredConfigKeys "3.5.23.0" | Should -BeNullOrEmpty
        Get-RequiredConfigKeys "3.6.0.0" | Should -BeNullOrEmpty
    }

    It "compares version parts as numbers, not as text" {
        Get-RequiredConfigKeys "3.5.3.0" | Should -Be @("autoMapperLicenseKey")
        Get-RequiredConfigKeys "3.4.99.0" | Should -Be @("identityServerLicenseKey", "autoMapperLicenseKey")
    }

    It "rejects an app version that is not a version number" {
        { Get-RequiredLicenseKeys -AppVersion "latest" } | Should -Throw "*latest*"
    }
}

Describe "Resolve-IdentityLicenseKeys" {
    It "takes a key passed as parameter over the stored one" {
        $config = @{ autoMapperLicenseKey = "stored" }

        Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.20.0" `
            -ProvidedKeys @{ autoMapperLicenseKey = "from-parameter" } -ReadKey $script:unexpectedPrompt

        $config.autoMapperLicenseKey | Should -Be "from-parameter"
    }

    It "reuses a stored key without prompting" {
        $config = @{ autoMapperLicenseKey = "stored" }

        Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.20.0" -ReadKey $script:unexpectedPrompt

        $config.autoMapperLicenseKey | Should -Be "stored"
    }

    It "prompts for every missing required key" {
        $config = @{}
        $promptedProducts = [System.Collections.Generic.List[string]]::new()
        $readKey = { param($licenseKey) $promptedProducts.Add($licenseKey.Product); "typed-$($licenseKey.ConfigKey)" }

        Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.4.100.0" -ReadKey $readKey

        $promptedProducts | Should -Be @("Duende IdentityServer", "AutoMapper")
        $config.identityServerLicenseKey | Should -Be "typed-identityServerLicenseKey"
        $config.autoMapperLicenseKey | Should -Be "typed-autoMapperLicenseKey"
    }

    It "prompts again while the typed key is blank" {
        $config = @{}
        $typedAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@("", "   ", "typed-key"))
        $readKey = { param($licenseKey) $typedAnswers.Dequeue() }

        Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.20.0" -ReadKey $readKey

        $typedAnswers.Count | Should -Be 0
        $config.autoMapperLicenseKey | Should -Be "typed-key"
    }

    It "fails in non-interactive mode and names the parameter of the missing key" {
        $config = @{}

        { Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.20.0" -NonInteractive -ReadKey $script:unexpectedPrompt } |
            Should -Throw "*3.5.20.0*-AutoMapperLicenseKey*"
    }

    It "treats a blank key as missing" {
        $config = @{ autoMapperLicenseKey = "   " }

        { Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.20.0" -NonInteractive -ReadKey $script:unexpectedPrompt } |
            Should -Throw "*-AutoMapperLicenseKey*"
    }

    It "does not prompt and drops stored keys the selected release no longer reads" {
        $config = @{ identityServerLicenseKey = "old-duende"; autoMapperLicenseKey = "old-automapper"; chartVersion = "3.5.23" }

        Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.23.0" -NonInteractive -ReadKey $script:unexpectedPrompt

        $config.ContainsKey("identityServerLicenseKey") | Should -BeFalse
        $config.ContainsKey("autoMapperLicenseKey") | Should -BeFalse
        $config.chartVersion | Should -Be "3.5.23"
    }

    It "keeps only the AutoMapper key for a release between the two thresholds" {
        $config = @{ identityServerLicenseKey = "old-duende"; autoMapperLicenseKey = "stored" }

        Resolve-IdentityLicenseKeys -Config $config -AppVersion "3.5.0.0" -ReadKey $script:unexpectedPrompt

        $config.ContainsKey("identityServerLicenseKey") | Should -BeFalse
        $config.autoMapperLicenseKey | Should -Be "stored"
    }
}

Describe "Get-IdentityLicenseKeyValues" {
    It "returns the keys the selected release reads, under their chart value names" {
        $config = @{ identityServerLicenseKey = "duende"; autoMapperLicenseKey = "automapper" }

        $values = Get-IdentityLicenseKeyValues -Config $config -AppVersion "3.4.112.0"

        $values.identityServerLicenseKey | Should -Be "duende"
        $values.autoMapperLicenseKey | Should -Be "automapper"
    }

    It "returns nothing for a release that reads no key" {
        $config = @{ autoMapperLicenseKey = "leftover" }

        $values = Get-IdentityLicenseKeyValues -Config $config -AppVersion "3.5.23.0"

        $values.Count | Should -Be 0
    }
}
