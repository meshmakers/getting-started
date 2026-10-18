# Helpers for the S3-compatible object store of the getting-started cluster (AB#5967, AB#5490).
# Dot-sourced by om-install.ps1 and om-status.ps1; not a command of its own.
#
# The archive part of a tenant dump uses CrateDB COPY TO / COPY FROM, which address a location that
# every CrateDB node and the bot can reach. Here that is SeaweedFS in the namespace octo-infra:
#   in the cluster (bot and CrateDB):  http://seaweedfs.octo-infra:8333   (protocol = 'http')
#   from the host:                     http://localhost:8333
# The credential is generated at install time into the Secret octo-infra/seaweedfs-s3 (and a copy for the
# bot in octo/octo-artifact-s3). It exists nowhere else: it is never written to a file, printed or logged.

$S3Store = [ordered]@{
    Namespace         = "octo-infra"
    SecretName        = "seaweedfs-s3"
    BotNamespace      = "octo"
    BotSecretName     = "octo-artifact-s3"
    StatefulSetName   = "seaweedfs"
    HostPort          = 8333
    HostEndpoint      = "http://localhost:8333"
    InClusterHostPort = "seaweedfs.octo-infra:8333"
    InClusterEndpoint = "http://seaweedfs.octo-infra:8333"
    Bucket            = "octo-artifacts"
    Region            = "us-east-1"
    CrateHttpUri      = "http://127.0.0.1:4301"
    # Keeps COPY statements (they carry the S3 key) out of sys.jobs_log.
    JobLogFilter      = "stmt NOT ILIKE 'copy %'"
    BotDeployment     = "octo-mesh-bot-services"
    # Name of the setting under which the bot learns how CrateDB reaches the store (the staging location
    # of octo-common-services). The published chart has no value for it, so it is set on the deployment.
    BotCrateEndpointEnv = "OCTO_ARTIFACTSTORAGE__S3__CRATEDBSERVICEURL"
}

function Remove-SecretText([string]$Text, [string[]]$Secrets) {
    foreach ($s in $Secrets) {
        if (-not [string]::IsNullOrEmpty($s)) { $Text = $Text.Replace($s, "***") }
    }
    return $Text
}

function Invoke-CrateSql([string]$Stmt, [string[]]$Secrets = @(), [int]$TimeoutSec = 60) {
    # One statement over the CrateDB HTTP endpoint (host port 4301). Errors are returned sanitized.
    try {
        return Invoke-RestMethod -Method Post -Uri "$($S3Store.CrateHttpUri)/_sql" -ContentType 'application/json' `
            -Body (@{ stmt = $Stmt } | ConvertTo-Json -Compress) -TimeoutSec $TimeoutSec
    }
    catch {
        $msg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { "CrateDB request failed" }
        } else { $_.Exception.Message }
        throw (Remove-SecretText -Text ([string]$msg) -Secrets $Secrets)
    }
}

function Get-JobLogFilter {
    try {
        $r = Invoke-CrateSql "SELECT settings['stats']['jobs_log_filter'] FROM sys.cluster" -TimeoutSec 15
        return [string]$r.rows[0][0]
    }
    catch { return $null }
}

function Test-JobLogFilterActive([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $norm = { param($s) ($s -replace '\s+', ' ').Trim().ToLowerInvariant() }
    return (& $norm $Value) -eq (& $norm $S3Store.JobLogFilter)
}

function Set-JobLogFilter {
    # Persistent cluster setting, no restart. A custom value is left alone and reported.
    $deadline = (Get-Date).AddSeconds(90)
    $current = $null
    while ($true) {
        $current = Get-JobLogFilter
        if ($null -ne $current) { break }
        if ((Get-Date) -gt $deadline) { Write-Host "CrateDB is not reachable on $($S3Store.CrateHttpUri); the job log filter was not set." -ForegroundColor Yellow; return $false }
        Start-Sleep -Seconds 3
    }
    if (Test-JobLogFilterActive $current) { Write-Host "CrateDB job log filter already set." -ForegroundColor DarkGray; return $true }
    if ($current -and $current.Trim().ToLowerInvariant() -ne "true") {
        Write-Host "CrateDB: stats.jobs_log_filter holds a custom value, leaving it untouched. COPY statements may be recorded with the S3 key." -ForegroundColor Yellow
        return $false
    }
    $literal = $S3Store.JobLogFilter.Replace("'", "''")
    try { Invoke-CrateSql "SET GLOBAL PERSISTENT stats.jobs_log_filter = '$literal'" | Out-Null }
    catch { Write-Host "CrateDB: setting stats.jobs_log_filter failed: $_" -ForegroundColor Yellow; return $false }
    Write-Host "CrateDB: persistent job log filter set (COPY statements stay out of sys.jobs_log)." -ForegroundColor Cyan
    return $true
}

function Get-S3StoreCredential([string]$KubeContext) {
    $json = kubectl --context $KubeContext -n $S3Store.Namespace get secret $S3Store.SecretName -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    if (-not $data -or -not $data.accessKey -or -not $data.secretKey) { return $null }
    [pscustomobject]@{
        AccessKeyId     = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data.accessKey))
        SecretAccessKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data.secretKey))
    }
}

function New-S3StoreSecrets([string]$KubeContext) {
    # Creates the credential once (hex only: no ':' or '@', which would break the key:secret@host form of a
    # COPY URI). The manifest goes to kubectl on stdin and uses create, not apply (apply would keep the plain
    # stringData in the last-applied-configuration annotation).
    $credential = Get-S3StoreCredential $KubeContext
    if (-not $credential) {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $newHex = { param([int]$n) $b = [byte[]]::new($n); $rng.GetBytes($b); -join ($b | ForEach-Object { $_.ToString("x2") }) }
        $accessKey = & $newHex 10
        $secretKey = & $newHex 20
        $rng.Dispose()
        $s3Config = [ordered]@{
            identities = @([ordered]@{
                    name = "octo-local"
                    credentials = @([ordered]@{ accessKey = $accessKey; secretKey = $secretKey })
                    actions = @("Admin", "Read", "Write", "List", "Tagging")
                })
        } | ConvertTo-Json -Depth 6 -Compress
        [ordered]@{
            apiVersion = "v1"; kind = "Secret"
            metadata = [ordered]@{ name = $S3Store.SecretName; namespace = $S3Store.Namespace }
            type = "Opaque"
            stringData = [ordered]@{ accessKey = $accessKey; secretKey = $secretKey; "s3.json" = $s3Config }
        } | ConvertTo-Json -Depth 6 -Compress | kubectl --context $KubeContext create -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Creating the S3 store credential Secret failed." }
        Write-Host "Generated the S3 store credential in Secret $($S3Store.Namespace)/$($S3Store.SecretName)." -ForegroundColor Cyan
        $credential = Get-S3StoreCredential $KubeContext
    }

    # The bot needs the pair in its own namespace (the chart references an existing Secret).
    kubectl --context $KubeContext -n $S3Store.BotNamespace get secret $S3Store.BotSecretName 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        [ordered]@{
            apiVersion = "v1"; kind = "Secret"
            metadata = [ordered]@{ name = $S3Store.BotSecretName; namespace = $S3Store.BotNamespace }
            type = "Opaque"
            stringData = [ordered]@{ accessKeyId = $credential.AccessKeyId; secretAccessKey = $credential.SecretAccessKey }
        } | ConvertTo-Json -Depth 6 -Compress | kubectl --context $KubeContext create -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Creating the bot's S3 credential Secret failed." }
    }
}

function Install-S3Store([string]$KubeContext, [string]$KubernetesPath) {
    Write-Host "Installing the S3 store (SeaweedFS) and the CrateDB job log filter..." -ForegroundColor Cyan
    # The filter first: from the moment the store is usable, a COPY with the key may run.
    if (-not (Set-JobLogFilter)) {
        Write-Host "The job log filter is not in place; do not run COPY statements with the S3 key until ./om-status.ps1 shows it active." -ForegroundColor Yellow
    }
    New-S3StoreSecrets $KubeContext
    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/s3-store.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of infra/s3-store.yaml failed." }
    kubectl --context $KubeContext -n $S3Store.Namespace rollout status "statefulset/$($S3Store.StatefulSetName)" --timeout=300s
    if ($LASTEXITCODE -ne 0) { throw "The S3 store did not become ready within 300s - check 'kubectl --context $KubeContext -n octo-infra get pods'." }
}

# TODO: remove Set-BotCrateDbEndpoint and Remove-BotCrateDbEndpoint once a chart release carries services.bot.artifactStorage.s3.crateDbServiceUrl.
function Set-BotCrateDbEndpoint([string]$KubeContext) {
    # The second endpoint of the staging location: how CrateDB reaches the store. Here bot and CrateDB sit in
    # the same cluster, so it equals the bot's own endpoint; it is set anyway so that the bot's setting is
    # complete. Applied on the deployment because the published chart has no value for it; a later
    # `helm upgrade` removes it, om-install.ps1 sets it again after every upgrade.
    kubectl --context $KubeContext -n $S3Store.BotNamespace set env "deployment/$($S3Store.BotDeployment)" "$($S3Store.BotCrateEndpointEnv)=$($S3Store.InClusterEndpoint)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Setting $($S3Store.BotCrateEndpointEnv) on the bot failed." }
    kubectl --context $KubeContext -n $S3Store.BotNamespace rollout status "deployment/$($S3Store.BotDeployment)" --timeout=300s | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "The bot did not become ready after setting $($S3Store.BotCrateEndpointEnv)." }
}

function Remove-BotCrateDbEndpoint([string]$KubeContext) {
    # -SkipS3Store on a cluster that had the store: drop the setting a former run put on the deployment.
    $present = kubectl --context $KubeContext -n $S3Store.BotNamespace get deployment $S3Store.BotDeployment -o "jsonpath={.spec.template.spec.containers[0].env[?(@.name=='$($S3Store.BotCrateEndpointEnv)')].name}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $present) { return }
    kubectl --context $KubeContext -n $S3Store.BotNamespace set env "deployment/$($S3Store.BotDeployment)" "$($S3Store.BotCrateEndpointEnv)-" | Out-Null
    kubectl --context $KubeContext -n $S3Store.BotNamespace rollout status "deployment/$($S3Store.BotDeployment)" --timeout=300s | Out-Null
}

function Test-S3Port([int]$Port) {
    return [bool](Test-Connection -TargetName 127.0.0.1 -TcpPort $Port -TimeoutSeconds 3 -Quiet)
}

function Invoke-S3Request([string]$Method, [string]$Url, $Credential, [switch]$Unsigned) {
    # Signed (or anonymous) S3 request through curl; the credential goes to curl on stdin, not in the argument list.
    $curl = Get-Command curl.exe, curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) { throw "curl is not available." }
    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("om-s3-" + [guid]::NewGuid().ToString("N") + ".out")
    try {
        $curlArgs = @("-s", "-S", "--max-time", "30", "-X", $Method, "-o", $bodyFile, "-w", "%{http_code}")
        if ($Unsigned) { $code = & $curl.Source @curlArgs $Url }
        else {
            $curlArgs += @("--aws-sigv4", "aws:amz:$($S3Store.Region):s3", "-K", "-")
            $code = "user = `"$($Credential.AccessKeyId):$($Credential.SecretAccessKey)`"" | & $curl.Source @curlArgs $Url
        }
        $content = if (Test-Path $bodyFile) { Get-Content $bodyFile -Raw } else { "" }
        [pscustomobject]@{ Status = [int]("$code".Trim()); Body = $content }
    }
    catch { [pscustomobject]@{ Status = 0; Body = "" } }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

function Show-S3StoreStatus([string]$KubeContext, [switch]$SkipCopyProbe) {
    # Prints one result per check and never a key. Returns $true when every check passed.
    $lines = New-Object System.Collections.Generic.List[object]
    $add = { param([string]$Name, [bool]$Ok, [string]$Detail) $lines.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail }) }

    kubectl --context $KubeContext -n $S3Store.Namespace get statefulset $S3Store.StatefulSetName 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  not installed: the archive dump uses the row path (re-run ./om-install.ps1 without -SkipS3Store to add it)" -ForegroundColor DarkGray
        return $true
    }
    $credential = Get-S3StoreCredential $KubeContext
    $secrets = @(); if ($credential) { $secrets = @($credential.AccessKeyId, $credential.SecretAccessKey) }

    $ready = kubectl --context $KubeContext -n $S3Store.Namespace get pod "$($S3Store.StatefulSetName)-0" -o 'jsonpath={.status.containerStatuses[0].ready}' 2>$null
    $podOk = ($LASTEXITCODE -eq 0 -and $ready -eq "true")
    & $add "pod" $podOk $(if ($podOk) { "$($S3Store.StatefulSetName)-0 ready" } else { "$($S3Store.StatefulSetName)-0 is not ready" })

    $hostOk = $false; $hostDetail = "no answer on $($S3Store.HostEndpoint)"
    if (Test-S3Port $S3Store.HostPort) {
        $anon = Invoke-S3Request -Method GET -Url "$($S3Store.HostEndpoint)/" -Unsigned
        if ($anon.Status -in 401, 403) {
            if ($credential) {
                $signed = Invoke-S3Request -Method GET -Url "$($S3Store.HostEndpoint)/$($S3Store.Bucket)/?list-type=2&max-keys=1" -Credential $credential
                $hostOk = ($signed.Status -eq 200)
                $hostDetail = if ($hostOk) { "answers on $($S3Store.HostEndpoint); anonymous requests are refused; bucket '$($S3Store.Bucket)' listable with the credential" } else { "answers, but the signed bucket list returned HTTP $($signed.Status)" }
            }
            else { $hostDetail = "answers, but the credential Secret is missing" }
        }
        else { $hostDetail = "port open, unexpected answer HTTP $($anon.Status) to an anonymous request" }
    }
    & $add "host" $hostOk $hostDetail

    $probe = 'exec 3<>/dev/tcp/seaweedfs.octo-infra/8333 && printf "GET / HTTP/1.0\r\n\r\n" >&3 && head -n 1 <&3'
    $answer = kubectl --context $KubeContext -n $S3Store.Namespace exec cratedb-0 -- bash -c $probe 2>$null
    $inOk = ($LASTEXITCODE -eq 0 -and "$answer" -match 'HTTP/1\.[01] \d{3}')
    & $add "inCluster" $inOk $(if ($inOk) { "answers from the CrateDB pod as $($S3Store.InClusterHostPort) ($("$answer".Trim()))" } else { "no answer from the CrateDB pod to $($S3Store.InClusterHostPort)" })

    $filterValue = Get-JobLogFilter
    $filterOk = Test-JobLogFilterActive $filterValue
    & $add "jobLogFilter" $filterOk $(if ($filterOk) { "stats.jobs_log_filter is active" } elseif ($null -eq $filterValue) { "CrateDB not reachable on $($S3Store.CrateHttpUri)" } else { "stats.jobs_log_filter is not the expected filter" })

    if (-not $SkipCopyProbe) {
        if (-not ($filterOk -and $credential -and $hostOk)) {
            & $add "copy" $false "skipped: needs the filter, the credential and the host check to pass first"
        }
        else {
            $runId = [guid]::NewGuid().ToString("N").Substring(0, 12)
            $prefix = "_status/$runId"
            $uriBase = "$($S3Store.InClusterHostPort)/$($S3Store.Bucket)/$prefix"
            $table = "octo_check.s3_probe"
            try {
                # COPY TO does not accept system tables: a three-row probe table in its own schema, dropped again.
                Invoke-CrateSql "DROP TABLE IF EXISTS $table" | Out-Null
                Invoke-CrateSql "CREATE TABLE $table (id INTEGER, v TEXT) CLUSTERED INTO 1 SHARDS WITH (number_of_replicas = 0)" | Out-Null
                Invoke-CrateSql "INSERT INTO $table (id, v) VALUES (1, 'a'), (2, 'b'), (3, 'c')" | Out-Null
                Invoke-CrateSql "REFRESH TABLE $table" | Out-Null
                $marker = "octo-s3-check-$runId"
                Invoke-CrateSql "SELECT '$marker' AS marker" | Out-Null
                try { Invoke-CrateSql "COPY $table TO DIRECTORY 's3://canaryaccesskey:canarysecretkey@$uriBase-canary/' WITH (protocol = 'http', compression = 'gzip')" | Out-Null } catch { }
                Start-Sleep -Milliseconds 800
                $canaryRows = (Invoke-CrateSql "SELECT count(*) FROM sys.jobs_log WHERE stmt ILIKE 'copy %canaryaccesskey%'").rows[0][0]
                $markerRows = (Invoke-CrateSql "SELECT count(*) FROM sys.jobs_log WHERE stmt LIKE 'SELECT ''$marker''%'").rows[0][0]
                if ($canaryRows -ne 0 -or $markerRows -lt 1) {
                    & $add "copy" $false "skipped the COPY with the real key: the canary COPY left $canaryRows entries in sys.jobs_log (expected 0), the ordinary statement $markerRows (expected 1)"
                }
                else {
                    $r = Invoke-CrateSql "COPY $table TO DIRECTORY 's3://$($credential.AccessKeyId):$($credential.SecretAccessKey)@$uriBase/' WITH (protocol = 'http', compression = 'gzip')" -Secrets $secrets
                    & $add "copy" ($r.rowcount -gt 0) "COPY TO from the CrateDB node into $($S3Store.InClusterHostPort)/$($S3Store.Bucket)/$prefix/ exported $($r.rowcount) rows"
                    $list = Invoke-S3Request -Method GET -Url "$($S3Store.HostEndpoint)/$($S3Store.Bucket)/?list-type=2&prefix=$prefix/" -Credential $credential
                    $keys = @([regex]::Matches($list.Body, '<Key>([^<]+)</Key>') | ForEach-Object { $_.Groups[1].Value })
                    & $add "objects" ($list.Status -eq 200 -and $keys.Count -gt 0) "$($keys.Count) object(s) under $prefix/ visible through the host port"
                    Start-Sleep -Milliseconds 800
                    $copyRows = (Invoke-CrateSql "SELECT count(*) FROM sys.jobs_log WHERE stmt ILIKE 'copy %$runId%'").rows[0][0]
                    & $add "jobsLog" ($copyRows -eq 0) $(if ($copyRows -eq 0) { "no COPY entry in sys.jobs_log (real key and canary); the ordinary statement is recorded" } else { "sys.jobs_log holds $copyRows COPY entries with the real key" })
                    foreach ($k in $keys) { Invoke-S3Request -Method DELETE -Url "$($S3Store.HostEndpoint)/$($S3Store.Bucket)/$k" -Credential $credential | Out-Null }
                }
            }
            catch { & $add "copy" $false ("COPY probe failed: " + (Remove-SecretText -Text ([string]$_) -Secrets $secrets)) }
            finally { try { Invoke-CrateSql "DROP TABLE IF EXISTS $table" | Out-Null } catch { } }
        }
    }

    foreach ($l in $lines) {
        $tag = if ($l.Ok) { "OK  " } else { "FAIL" }
        Write-Host ("  {0} {1,-13} {2}" -f $tag, $l.Name, $l.Detail) -ForegroundColor $(if ($l.Ok) { "Green" } else { "Red" })
    }
    return -not ($lines | Where-Object { -not $_.Ok })
}
