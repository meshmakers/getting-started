# Pester tests for om-upgrade-cratedb.ps1 (AB#7139). No cluster is touched: the script is dot-sourced
# (which only defines its functions) and kubectl plus every CrateDB helper are mocked.
# Run: pwsh -c "Invoke-Pester ./scripts/tests/om-upgrade-cratedb.Tests.ps1"

BeforeAll {
    . (Join-Path $PSScriptRoot ".." "om-upgrade-cratedb.ps1") -Context kind-test
    $script:manifest = Join-Path $TestDrive "cratedb.yaml"
    Set-Content $script:manifest -Value "spec:`n  containers:`n    - name: cratedb`n      image: crate:6.4.6`n      args: [crate]"
}

Describe "Get-CrateUpgradePlan" {
    It "<running> -> <target> is <action> via <steps>" -ForEach @(
        @{ running = "6.4.6";   target = "6.4.6";   action = "NoOp";    steps = "" }
        @{ running = "6.4.6";   target = "5.10.10"; action = "Refuse";  steps = "" }
        @{ running = "6.5.0";   target = "6.4.6";   action = "Refuse";  steps = "" }
        @{ running = "5.9.10";  target = "6.4.6";   action = "Upgrade"; steps = "5.10.16 6.4.6" }
        @{ running = "5.10.0";  target = "6.4.6";   action = "Upgrade"; steps = "5.10.16 6.4.6" }
        @{ running = "5.10.1";  target = "6.4.6";   action = "Upgrade"; steps = "6.4.6" }
        @{ running = "5.10.10"; target = "6.4.6";   action = "Upgrade"; steps = "6.4.6" }
        @{ running = "5.9.10";  target = "5.10.10"; action = "Upgrade"; steps = "5.10.10" }
    ) {
        $plan = Get-CrateUpgradePlan -Running $running -Target $target
        $plan.Action | Should -Be $action
        ($plan.Steps -join " ") | Should -Be $steps
    }
}

Describe "Get-CrateManifestVersion" {
    It "reads the tag of the crate image" {
        Get-CrateManifestVersion -ManifestPath $script:manifest | Should -Be "6.4.6"
    }
    It "pins crate:6.4.6 in the shipped manifest" {
        Get-CrateManifestVersion -ManifestPath (Join-Path $PSScriptRoot ".." "kubernetes" "infra" "cratedb.yaml") | Should -Be "6.4.6"
    }
}

Describe "Update-OctoCrateDb" {
    BeforeEach {
        $script:applied = [System.Collections.Generic.List[string]]::new()
        $script:hasSts = $true
        Mock kubectl {
            $a = $args -join " "
            $global:LASTEXITCODE = 0
            if ($a -match "config get-contexts") { return "kind-test" }
            if ($a -match "get statefulset cratedb") { if ($script:hasSts) { return "statefulset.apps/cratedb" } else { return $null } }
            if ($a -match " apply -f (.+)$") {
                $script:applied.Add(([regex]::Match((Get-Content $Matches[1] -Raw), "crate:(\d+\.\d+\.\d+)").Groups[1].Value))
            }
        }
        Mock Wait-CrateHealthy {}
        Mock Get-CrateTableCounts { [ordered]@{ "doc.t" = 10L } }
        Mock New-CrateUpgradeSnapshot { "snap" }
        Mock Test-CrateSnapshotSpace { $true }
    }

    It "installs on a fresh cluster without reading a version or taking a snapshot" {
        $script:hasSts = $false
        Mock Get-CrateRunningVersion { throw "must not be called" }
        (Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest).Action | Should -Be "Install"
        $script:applied | Should -Be @("6.4.6")
        Should -Invoke New-CrateUpgradeSnapshot -Times 0
    }

    It "is a no-op when the running version equals the target" {
        Mock Get-CrateRunningVersion { "6.4.6" }
        (Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest).Action | Should -Be "NoOp"
        Should -Invoke New-CrateUpgradeSnapshot -Times 0
    }

    It "refuses a downgrade and does not apply the manifest" {
        $old = Join-Path $TestDrive "old.yaml"; Set-Content $old "image: crate:5.10.10"
        Mock Get-CrateRunningVersion { "6.4.6" }
        { Update-OctoCrateDb -Context kind-test -ManifestPath $old } | Should -Throw "*cannot be downgraded*NOT applied*"
        $script:applied.Count | Should -Be 0
        Should -Invoke New-CrateUpgradeSnapshot -Times 0
    }

    It "steps 5.9.10 -> 5.10.16 -> 6.4.6 after one snapshot" {
        Mock Get-CrateRunningVersion { "5.9.10" }
        Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest | Out-Null
        $script:applied | Should -Be @("5.10.16", "6.4.6")
        Should -Invoke New-CrateUpgradeSnapshot -Times 1 -Exactly
    }

    It "aborts before any change when the disk is too small and it may not ask" {
        Mock Get-CrateRunningVersion { "5.10.10" }
        Mock Test-CrateSnapshotSpace { $false }
        { Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest -NonInteractive } | Should -Throw "*Not enough free disk space*-SkipSnapshot*"
        $script:applied.Count | Should -Be 0
    }

    It "-SkipSnapshot upgrades without checking the disk or snapshotting" {
        Mock Get-CrateRunningVersion { "5.10.10" }
        Mock Test-CrateSnapshotSpace { $false }
        Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest -SkipSnapshot | Out-Null
        $script:applied | Should -Be @("6.4.6")
        Should -Invoke New-CrateUpgradeSnapshot -Times 0
    }

    It "fails the step when a table lost rows" {
        Mock Get-CrateRunningVersion { "5.10.10" }
        $script:calls = 0
        Mock Get-CrateTableCounts { $script:calls++; [ordered]@{ "doc.t" = $(if ($script:calls -eq 1) { 10L } else { 7L }) } }
        { Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest -SkipSnapshot } | Should -Throw "*lost rows*10 -> 7*"
    }
}
