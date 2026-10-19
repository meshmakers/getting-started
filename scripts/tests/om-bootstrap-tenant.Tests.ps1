# Pester tests for om-bootstrap-tenant.ps1 (AB#6791): re-run behaviour.
# They run the real script against a fake octo-cli/kubectl on PATH that keeps
# the tenant state in a temp directory - no stack, no network, no secrets.
# Run: pwsh -c "Invoke-Pester ./scripts/tests"

BeforeDiscovery {
    $script:Unsupported = $IsWindows   # the fakes are POSIX shell-shebang scripts
}

BeforeAll {
    $script:RealScript = Join-Path $PSScriptRoot ".." "om-bootstrap-tenant.ps1"

    function Invoke-Bootstrap {
        param([string]$FailCommand = "", [string]$FailMessage = "")
        $env:FAKE_OCTO_STATE = $script:State
        $env:FAKE_OCTO_FAIL = $FailCommand
        $env:FAKE_OCTO_FAIL_MESSAGE = $FailMessage
        $env:PATH = "$($script:Bin)$([IO.Path]::PathSeparator)$($script:OriginalPath)"
        $output = & pwsh -NoProfile -File (Join-Path $script:Work "om-bootstrap-tenant.ps1") 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function Get-Calls {
        $log = Join-Path $script:State "calls.log"
        if (Test-Path $log) { Get-Content $log } else { @() }
    }
}

Describe "om-bootstrap-tenant.ps1 re-runs" -Skip:$script:Unsupported {
    BeforeEach {
        $script:OriginalPath = $env:PATH
        $root = Join-Path ([IO.Path]::GetTempPath()) ("om-bootstrap-test-" + [guid]::NewGuid().ToString("N"))
        $script:Work = Join-Path $root "scripts"
        $script:Bin = Join-Path $root "bin"
        $script:State = Join-Path $root "state"
        New-Item -ItemType Directory -Path (Join-Path $script:Work "kubernetes"), $script:Bin, $script:State | Out-Null
        Copy-Item $script:RealScript $script:Work
        '{"adapterChartVersion":"1.2.3","simulationChartVersion":"1.2.3"}' |
            Set-Content (Join-Path $script:Work "kubernetes/local-config.json")

        @'
#!/usr/bin/env pwsh
$state = $env:FAKE_OCTO_STATE
$cmd = $null
for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq "-c") { $cmd = $args[$i + 1]; break } }
Add-Content (Join-Path $state "calls.log") $cmd
if ($cmd -eq "ListContexts") {
    "Octo Mesh Management Tool (fake)"
    '[ { "name": "getting-started_meshtest", "services": { "identity": "https://identity.invalid/", "asset": "https://asset.invalid/" } } ]'
    exit 0
}
if ($env:FAKE_OCTO_FAIL -eq $cmd) { [Console]::Error.WriteLine($env:FAKE_OCTO_FAIL_MESSAGE); exit 1 }
if ($cmd -eq "Create") {
    if (Test-Path (Join-Path $state "tenant")) { [Console]::Error.WriteLine("Conflict: Tenant ID 'meshtest' is already in use."); exit 1 }
    New-Item (Join-Path $state "tenant") -ItemType File | Out-Null
}
if ($cmd -eq "EnableCommunication") {
    if (Test-Path (Join-Path $state "comm")) { [Console]::Error.WriteLine("BadRequest: ""Tenant 'meshtest' is already enabled."""); exit 1 }
    New-Item (Join-Path $state "comm") -ItemType File | Out-Null
}
exit 0
'@ | Set-Content (Join-Path $script:Bin "octo-cli")
        "#!/bin/sh`necho 'meshtest-adapter-0 1/1 Running 0 1m'" | Set-Content (Join-Path $script:Bin "kubectl")
        chmod +x (Join-Path $script:Bin "octo-cli") (Join-Path $script:Bin "kubectl")
    }

    AfterEach {
        $env:PATH = $script:OriginalPath
        Remove-Item Env:FAKE_OCTO_STATE, Env:FAKE_OCTO_FAIL, Env:FAKE_OCTO_FAIL_MESSAGE -ErrorAction SilentlyContinue
        Remove-Item (Split-Path $script:Work) -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "completes a clean run" {
        $r = Invoke-Bootstrap
        $r.ExitCode | Should -Be 0
        Get-Calls | Should -Contain "DeployWorkload"
    }

    It "completes the remaining steps after a run that stopped after EnableCommunication" {
        (Invoke-Bootstrap -FailCommand "DeployDeploymentSite" -FailMessage "boom").ExitCode | Should -Not -Be 0
        $r = Invoke-Bootstrap
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "already exists"
        $r.Output | Should -Match "already enabled"
        (Get-Calls | Where-Object { $_ -eq "DeployWorkload" }).Count | Should -Be 1
    }

    It "changes nothing on a third run and exits 0" {
        (Invoke-Bootstrap).ExitCode | Should -Be 0
        (Invoke-Bootstrap).ExitCode | Should -Be 0
        $r = Invoke-Bootstrap
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "already enabled"
    }

    It "still stops on a real EnableCommunication error" {
        $r = Invoke-Bootstrap -FailCommand "EnableCommunication" -FailMessage "Forbidden: not allowed"
        $r.ExitCode | Should -Not -Be 0
        Get-Calls | Should -Not -Contain "DeployWorkload"
    }

    It "still stops on a real tenant creation error" {
        $r = Invoke-Bootstrap -FailCommand "Create" -FailMessage "Forbidden: not allowed"
        $r.ExitCode | Should -Not -Be 0
        Get-Calls | Should -Not -Contain "EnableCommunication"
    }
}
