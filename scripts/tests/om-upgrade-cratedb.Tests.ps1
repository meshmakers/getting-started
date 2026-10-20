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
        @{ running = "5.10.16"; target = "7.0.0";   action = "Unsupported"; steps = "" }
        @{ running = "4.8.0";   target = "6.4.6";   action = "Unsupported"; steps = "" }
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
        $script:hasPvc = $false
        Mock kubectl {
            $a = $args -join " "
            $global:LASTEXITCODE = 0
            if ($a -match "config get-contexts") { return @("kind-test", "test-2", "kind-fake") }
            if ($a -match "get nodes") { if ($a -match "context kind-fake") { return "k3s://x" } else { return "kind://docker/kind/kind-test-control-plane" } }
            if ($a -match "get pvc") { if ($script:hasPvc) { return "persistentvolumeclaim/data-cratedb-0" } else { return $null } }
            if ($a -match "rollout status") { return "partitioned roll out complete" }
            if ($a -match "get statefulset cratedb") { if ($script:hasSts) { return "statefulset.apps/cratedb" } else { return $null } }
            if ($a -match " apply -f (.+)$") {
                "statefulset.apps/cratedb configured"
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

    It "rejects a context that does not exist" {
        { Update-OctoCrateDb -Context nope -ManifestPath $script:manifest } | Should -Throw "*does not exist*"
    }

    It "refuses a context that is not a kind cluster" -ForEach @("test-2", "kind-fake") {
        $script:hasSts = $false
        { Update-OctoCrateDb -Context $_ -ManifestPath $script:manifest } | Should -Throw "*not a local kind cluster*"
        $script:applied.Count | Should -Be 0
    }

    It "does not apply anything when the running version cannot be read" {
        Mock Get-CrateRunningVersion { throw "pod down" }
        { Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest } | Should -Throw "*Cannot read the running CrateDB version*"
        $script:applied.Count | Should -Be 0
    }

    It "refuses an existing volume without a StatefulSet" {
        $script:hasSts = $false; $script:hasPvc = $true
        { Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest } | Should -Throw "*data-cratedb-0*unknown version*"
        $script:applied.Count | Should -Be 0
    }

    It "-AssumeFreshVolume installs over an existing volume without a StatefulSet" {
        $script:hasSts = $false; $script:hasPvc = $true
        (Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest -AssumeFreshVolume).Action | Should -Be "Install"
    }

    It "refuses an unsupported major jump without applying" {
        $next = Join-Path $TestDrive "next.yaml"; Set-Content $next "image: crate:7.0.0"
        Mock Get-CrateRunningVersion { "5.10.16" }
        { Update-OctoCrateDb -Context kind-test -ManifestPath $next } | Should -Throw "*No tested upgrade path*"
        $script:applied.Count | Should -Be 0
    }

    It "returns exactly one result object" {
        Mock Get-CrateRunningVersion { "5.9.10" }
        $r = @(Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest 6>$null)
        $r.Count | Should -Be 1
        $r[0] | Should -BeOfType [pscustomobject]
    }

    It "warns about lost rows, names the table and still finishes" {
        Mock Get-CrateRunningVersion { "5.10.10" }
        $script:calls = 0
        Mock Get-CrateTableCounts { $script:calls++; if ($script:calls -eq 1) { [ordered]@{ "doc.t" = 10L } } else { [ordered]@{ "doc.t" = 7L } } }
        $r = Update-OctoCrateDb -Context kind-test -ManifestPath $script:manifest -SkipSnapshot -WarningVariable w -WarningAction SilentlyContinue 6>$null
        $r.RowCountWarnings[0] | Should -BeLike "*doc.t has fewer rows (10 -> 7)*"
        "$w" | Should -BeLike "*step to 6.4.6 completed*"
    }
}

Describe "Wait-CrateHealthy" {
    It "names the tables that are not GREEN and suggests number_of_replicas = 0" {
        Mock Start-Sleep {}
        Mock Get-CrateRunningVersion { "6.4.6" }
        Mock Invoke-CrateSql { [pscustomobject]@{ rows = @(, @("doc", "readings", "YELLOW")) } }
        { Wait-CrateHealthy -Context kind-test -Namespace octo-infra -ExpectedVersion 6.4.6 -TimeoutSeconds 1 } |
            Should -Throw "*doc.readings (YELLOW)*number_of_replicas = 0*"
    }
}
