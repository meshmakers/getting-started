#!/usr/bin/env pwsh
<#
.SYNOPSIS
Applies the CrateDB manifest of the local kind cluster and upgrades an existing CrateDB data volume
safely: never a downgrade, a snapshot first, 5.9 -> 6.x through 5.10.16.

.DESCRIPTION
om-install.ps1 runs this instead of a plain 'kubectl apply' of infra/cratedb.yaml; run it on its own to
upgrade CrateDB without re-running the installation. CrateDB cannot be downgraded: a data directory that
a newer version has opened breaks an older one. 6.x can only be reached from 5.10.1 or later.

  * No CrateDB yet (fresh install): the manifest is applied, nothing else.
  * Running version (sys.nodes) equals the manifest's version: the manifest is applied, no upgrade.
  * Running version is NEWER than the manifest: aborts, the manifest is NOT applied.
  * Otherwise: checks the free disk space, snapshots into the local backup repository (path.repo =
    /data/backup), then upgrades step by step (below 5.10.1 to 6.x: via 5.10.16). After each step it waits
    for the rollout, the version and all tables GREEN and compares the row count of every table.

The kube context is mandatory; the current context is never used.

.PARAMETER Context
kubectl context of the cluster, e.g. kind-octomesh.

.PARAMETER ManifestPath
Path of cratedb.yaml; its 'image: crate:<x.y.z>' line is the target version.

.PARAMETER Namespace
Namespace of the CrateDB StatefulSet (default octo-infra).

.PARAMETER SkipSnapshot
Upgrade without a snapshot. Without it a snapshot is mandatory; if the disk is too small for it the script
asks (interactive) or aborts (-NonInteractive).

.PARAMETER NonInteractive
Never ask; abort where a question would be needed.

.EXAMPLE
./om-upgrade-cratedb.ps1 -Context kind-octomesh
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Context,
    [string]$ManifestPath = (Join-Path $PSScriptRoot "kubernetes/infra/cratedb.yaml"),
    [string]$Namespace = "octo-infra",
    [switch]$SkipSnapshot,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

function ConvertTo-CrateVersion {
    # "6.4.6" or "6.4.6-SNAPSHOT" -> [version]. Throws on anything else.
    param([Parameter(Mandatory)] [string]$Text)
    if ($Text -notmatch '^(\d+\.\d+\.\d+)') { throw "'$Text' is not a CrateDB version (expected x.y.z)." }
    return [version]$Matches[1]
}

function Get-CrateManifestVersion {
    # The CrateDB version the manifest pins: the tag of its 'image: crate:<x.y.z>' line.
    param([Parameter(Mandatory)] [string]$ManifestPath)
    if (-not (Test-Path $ManifestPath)) { throw "CrateDB manifest not found: $ManifestPath" }
    $m = [regex]::Match((Get-Content $ManifestPath -Raw), '(?m)^\s*image:\s*crate:(\d+\.\d+\.\d+)\s*$')
    if (-not $m.Success) { throw "No 'image: crate:<x.y.z>' line found in $ManifestPath." }
    return $m.Groups[1].Value
}

function Get-CrateUpgradePlan {
    # Pure decision: what to do when the data runs $Running and the manifest pins $Target.
    #   NoOp    - equal, nothing to upgrade
    #   Refuse  - running is newer than the target, CrateDB cannot be downgraded
    #   Upgrade - Steps lists every version to run, in order. CrateDB 6.x can only be reached from
    #             5.10.1 or later, so anything older goes through 5.10.16 first.
    param(
        [Parameter(Mandatory)] [string]$Running,
        [Parameter(Mandatory)] [string]$Target
    )
    $r = ConvertTo-CrateVersion $Running
    $t = ConvertTo-CrateVersion $Target
    if ($r -eq $t) { return [pscustomobject]@{ Action = 'NoOp'; Steps = @() } }
    if ($r -gt $t) { return [pscustomobject]@{ Action = 'Refuse'; Steps = @() } }
    $steps = @()
    if ($r -lt [version]'5.10.1' -and $t.Major -ge 6) { $steps += '5.10.16' }
    $steps += "$t"
    return [pscustomobject]@{ Action = 'Upgrade'; Steps = $steps }
}

function Invoke-CrateSql {
    # One SQL statement, sent through the pod's own HTTP endpoint (no port-forward, no host port needed).
    param(
        [Parameter(Mandatory)] [string]$Context,
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$Stmt,
        [string]$Pod = 'cratedb-0'
    )
    $body = @{ stmt = $Stmt } | ConvertTo-Json -Compress
    $raw = ($body | & kubectl --context $Context -n $Namespace exec -i $Pod -c cratedb -- `
            curl -sS -XPOST 'localhost:4200/_sql' -H 'Content-Type: application/json' --data-binary '@-' 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "CrateDB SQL call failed: $($raw.Trim())" }
    try { $result = $raw | ConvertFrom-Json } catch { throw "CrateDB returned a non-JSON answer: $($raw.Trim())" }
    if ($result.PSObject.Properties.Name -contains 'error') { throw "CrateDB: $($result.error.message)" }
    return $result
}

function Get-CrateRunningVersion {
    # Lowest version among the nodes, as reported by sys.nodes.
    param([string]$Context, [string]$Namespace)
    $r = Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "SELECT version['number'] FROM sys.nodes"
    $versions = @($r.rows | ForEach-Object { ConvertTo-CrateVersion $_[0] })
    if ($versions.Count -eq 0) { throw "sys.nodes returned no node." }
    return (($versions | Sort-Object | Select-Object -First 1).ToString())
}

function Get-CrateTableCounts {
    # Row count per user table (refreshed first), as a hashtable "schema.table" -> count.
    param([string]$Context, [string]$Namespace)
    $tables = Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt (
        "SELECT table_schema, table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE' " +
        "AND table_schema NOT IN ('sys', 'information_schema', 'pg_catalog', 'blob') ORDER BY 1, 2")
    $counts = [ordered]@{}
    foreach ($t in $tables.rows) {
        $q = '"{0}"."{1}"' -f ($t[0] -replace '"', '""'), ($t[1] -replace '"', '""')
        $null = Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "REFRESH TABLE $q"
        $counts["$($t[0]).$($t[1])"] = [long](Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "SELECT count(*) FROM $q").rows[0][0]
    }
    return $counts
}

function Wait-CrateHealthy {
    # Waits until the node answers with the expected version and every table is GREEN.
    param([string]$Context, [string]$Namespace, [string]$ExpectedVersion, [int]$TimeoutSeconds = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        try {
            $v = Get-CrateRunningVersion -Context $Context -Namespace $Namespace
            $notGreen = [long](Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "SELECT count(*) FROM sys.health WHERE health <> 'GREEN'").rows[0][0]
            $last = "version $v, $notGreen table(s) not GREEN"
            if ($v -eq $ExpectedVersion -and $notGreen -eq 0) { return }
        }
        catch { $last = $_.Exception.Message }
        Start-Sleep -Seconds 5
    }
    throw "CrateDB did not become healthy on $ExpectedVersion within $TimeoutSeconds s ($last)."
}

function Test-CrateSnapshotSpace {
    # $true when the volume under /data has room for a snapshot of all primary shards (+10 % and 512 MiB).
    param([string]$Context, [string]$Namespace, [ref]$Detail)
    $dataBytes = [long](Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt 'SELECT coalesce(sum(size), 0) FROM sys.shards WHERE "primary"').rows[0][0]
    $df = & kubectl --context $Context -n $Namespace exec cratedb-0 -c cratedb -- df -Pk /data 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read the free disk space of /data: $df" }
    $availBytes = [long](($df | Select-Object -Last 1) -split '\s+')[3] * 1024
    $needBytes = [long]($dataBytes * 1.1) + 512MB
    $Detail.Value = "data {0:N0} MiB, free {1:N0} MiB, needed {2:N0} MiB" -f ($dataBytes / 1MB), ($availBytes / 1MB), ($needBytes / 1MB)
    return ($availBytes -ge $needBytes)
}

function New-CrateUpgradeSnapshot {
    # Full snapshot of the running version into a new fs repository under path.repo (/data/backup).
    param([string]$Context, [string]$Namespace, [string]$FromVersion)
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $repo = "upgrade_$stamp"
    $location = "/data/backup/upgrade-$stamp-from-$FromVersion"
    try {
        $null = Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "CREATE REPOSITORY `"$repo`" TYPE fs WITH (location = '$location', compress = true)"
    }
    catch {
        throw "Could not create the snapshot repository ($($_.Exception.Message)). The running CrateDB needs -Cpath.repo=/data/backup. Pass -SkipSnapshot to upgrade without a snapshot."
    }
    $null = Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "CREATE SNAPSHOT `"$repo`".`"pre_upgrade`" ALL WITH (wait_for_completion = true)"
    $state = (Invoke-CrateSql -Context $Context -Namespace $Namespace -Stmt "SELECT state FROM sys.snapshots WHERE repository = '$repo' AND name = 'pre_upgrade'").rows[0][0]
    if ($state -ne 'SUCCESS') { throw "Snapshot $repo.pre_upgrade ended in state '$state'. Nothing was upgraded." }
    return "$repo.pre_upgrade ($location, CrateDB $FromVersion)"
}

function Update-OctoCrateDb {
    <#
.SYNOPSIS
Applies the CrateDB manifest of the local kind cluster and upgrades an existing CrateDB data volume
safely: never a downgrade, a snapshot first, 5.9 -> 6.x through 5.10.16.

.DESCRIPTION
Replaces the plain 'kubectl apply' of cratedb.yaml. CrateDB cannot be downgraded - a node data
directory that a newer version has opened breaks an older one - and 6.x can only be reached from
5.10.1 or later.

  * No CrateDB StatefulSet yet (fresh install): the manifest is applied, nothing else.
  * The running version (sys.nodes) equals the version pinned by the manifest: the manifest is applied
    (the image does not change), no upgrade.
  * The running version is NEWER than the manifest: aborts with an error and does NOT apply the manifest.
  * Otherwise: checks the free disk space, takes a snapshot into the local backup repository
    (path.repo = /data/backup), then runs every step (from below 5.10.1 to 6.x: 5.10.16 first). After
    each step it waits for the rollout, the expected version and all tables GREEN, and compares the row
    count of every table with the count before the upgrade (fewer rows = error).

The kube context is a mandatory parameter; the current context is never used.

.PARAMETER Context
kubectl context of the cluster, e.g. kind-kind. Mandatory.

.PARAMETER ManifestPath
Path of cratedb.yaml. Its 'image: crate:<x.y.z>' line is the target version.

.PARAMETER Namespace
Namespace of the CrateDB StatefulSet. Defaults to octo-infra.

.PARAMETER SkipSnapshot
Upgrade without the snapshot. Without this switch a snapshot is mandatory; if the disk is too small
for it, the function asks (interactive) or aborts (-NonInteractive).

.PARAMETER NonInteractive
Never ask; abort where a question would be needed.

.EXAMPLE
Update-OctoCrateDb -Context kind-kind -ManifestPath ./kubernetes/infra/cratedb.yaml
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Context,
        [Parameter(Mandatory)] [string]$ManifestPath,
        [string]$Namespace = 'octo-infra',
        [switch]$SkipSnapshot,
        [switch]$NonInteractive
    )

    $contexts = @(& kubectl config get-contexts -o name 2>$null)
    if ($contexts -notcontains $Context) { throw "kubectl context '$Context' does not exist." }

    $target = Get-CrateManifestVersion -ManifestPath $ManifestPath
    $apply = {
        param([string]$Path)
        & kubectl --context $Context apply -f $Path
        if ($LASTEXITCODE -ne 0) { throw "kubectl apply of $Path failed." }
    }

    $existing = & kubectl --context $Context -n $Namespace get statefulset cratedb -o name --ignore-not-found 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read the CrateDB StatefulSet in context '$Context': $existing" }
    if (-not $existing) {
        Write-Host "CrateDB: no existing installation in '$Context', installing $target." -ForegroundColor Cyan
        & $apply $ManifestPath
        return [pscustomobject]@{ Action = 'Install'; From = $null; To = $target; Steps = @($target); Snapshot = $null }
    }

    # The data decides, not the image of the StatefulSet: read the version from the running node.
    try { $running = Get-CrateRunningVersion -Context $Context -Namespace $Namespace }
    catch {
        Write-Host "CrateDB: not answering, waiting for the existing pod..." -ForegroundColor Yellow
        & kubectl --context $Context -n $Namespace rollout status statefulset/cratedb --timeout=180s | Out-Null
        try { $running = Get-CrateRunningVersion -Context $Context -Namespace $Namespace }
        catch { throw "Cannot read the running CrateDB version in '$Context' ($($_.Exception.Message)). The manifest was NOT applied." }
    }

    $plan = Get-CrateUpgradePlan -Running $running -Target $target
    switch ($plan.Action) {
        'Refuse' {
            throw ("CrateDB in '$Context' runs $running, the manifest pins the older $target. CrateDB cannot be downgraded, " +
                "the manifest was NOT applied. Update this repository (git pull) so that the manifest pins $running or newer.")
        }
        'NoOp' {
            Write-Host "CrateDB: already on $running, no upgrade needed." -ForegroundColor Green
            & $apply $ManifestPath
            return [pscustomobject]@{ Action = 'NoOp'; From = $running; To = $target; Steps = @(); Snapshot = $null }
        }
    }

    Write-Host "CrateDB: upgrading $running -> $($plan.Steps -join ' -> ')" -ForegroundColor Cyan
    Wait-CrateHealthy -Context $Context -Namespace $Namespace -ExpectedVersion $running -TimeoutSeconds 300
    $before = Get-CrateTableCounts -Context $Context -Namespace $Namespace
    Write-Host "CrateDB: $($before.Count) table(s), $(($before.Values | Measure-Object -Sum).Sum) row(s) before the upgrade."

    $snapshot = $null
    if ($SkipSnapshot) {
        Write-Host "CrateDB: snapshot skipped (-SkipSnapshot)." -ForegroundColor Yellow
    }
    else {
        $detail = ''
        if (Test-CrateSnapshotSpace -Context $Context -Namespace $Namespace -Detail ([ref]$detail)) {
            Write-Host "CrateDB: disk space for the snapshot is sufficient ($detail)."
            $snapshot = New-CrateUpgradeSnapshot -Context $Context -Namespace $Namespace -FromVersion $running
            Write-Host "CrateDB: snapshot $snapshot" -ForegroundColor Green
        }
        else {
            $msg = "Not enough free disk space for the pre-upgrade snapshot ($detail)."
            if ($NonInteractive -or [Console]::IsInputRedirected) {
                throw "$msg Free up space or pass -SkipSnapshot to upgrade without a snapshot. Nothing was upgraded."
            }
            Write-Host $msg -ForegroundColor Yellow
            if ((Read-Host "Upgrade WITHOUT a snapshot? There is no way back from a CrateDB upgrade (y/N)") -notmatch '^(y|yes)$') {
                throw "Upgrade cancelled, nothing was changed."
            }
        }
    }

    $manifestText = Get-Content $ManifestPath -Raw
    foreach ($step in $plan.Steps) {
        Write-Host "CrateDB: step to $step..." -ForegroundColor Cyan
        if ($step -eq $target) {
            & $apply $ManifestPath
        }
        else {
            $stepText = [regex]::Replace($manifestText, '(?m)^(\s*image:\s*crate:)\d+\.\d+\.\d+', "`${1}$step")
            $stepFile = Join-Path ([System.IO.Path]::GetTempPath()) "cratedb-step-$step-$([guid]::NewGuid().ToString('N')).yaml"
            try {
                Set-Content -Path $stepFile -Value $stepText -Encoding utf8
                & $apply $stepFile
            }
            finally { Remove-Item $stepFile -Force -ErrorAction SilentlyContinue }
        }
        & kubectl --context $Context -n $Namespace rollout status statefulset/cratedb --timeout=600s
        if ($LASTEXITCODE -ne 0) { throw ("CrateDB did not roll out $step. The data may already be opened by $step - do not apply an older manifest." + $(if ($snapshot) { " Snapshot: $snapshot" })) }
        Wait-CrateHealthy -Context $Context -Namespace $Namespace -ExpectedVersion $step
        $after = Get-CrateTableCounts -Context $Context -Namespace $Namespace
        foreach ($table in $before.Keys) {
            if (-not $after.Contains($table)) { throw "Table $table is missing after the step to $step." }
            if ($after[$table] -lt $before[$table]) { throw "Table $table lost rows in the step to $step ($($before[$table]) -> $($after[$table]))." }
            if ($after[$table] -gt $before[$table]) { Write-Warning "Table ${table}: $($after[$table] - $before[$table]) row(s) more than before (written during the upgrade)." }
        }
        Write-Host "CrateDB: $step is up, all tables GREEN, row counts match ($($after.Count) table(s))." -ForegroundColor Green
    }
    return [pscustomobject]@{ Action = 'Upgrade'; From = $running; To = $target; Steps = $plan.Steps; Snapshot = $snapshot }
}

# Dot-sourcing (tests) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $null = Update-OctoCrateDb -Context $Context -ManifestPath $ManifestPath -Namespace $Namespace `
        -SkipSnapshot:$SkipSnapshot -NonInteractive:$NonInteractive
}
