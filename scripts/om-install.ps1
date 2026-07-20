#!/usr/bin/env pwsh
# Installs OctoMesh into a local kind cluster using the official Helm charts.
# Requires: docker (running), kind, kubectl, helm, openssl, octo-cli, PowerShell 7.4+.
param(
    [Parameter()]
    [ValidateSet("core", "full")]
    [string]$DeploymentProfile = "core",
    [Parameter()]
    [switch]$SkipTrustCa = $false,
    # Non-interactive overrides (prompted when omitted):
    [Parameter()]
    [string]$ChartVersion,
    [Parameter()]
    [string]$IdentityServerLicenseKey,
    [Parameter()]
    [string]$AutoMapperLicenseKey,
    [Parameter()]
    [switch]$NonInteractive = $false
)

$ErrorActionPreference = "Stop"

$ClusterName = "octomesh"
$KubeContext = "kind-$ClusterName"
$ChartRepo = "https://meshmakers.github.io/charts"
$BaseDomain = "127-0-0-1.nip.io"
$KubernetesPath = Join-Path $PSScriptRoot "kubernetes"
$GeneratedPath = Join-Path $KubernetesPath ".generated"
$ConfigPath = Join-Path $KubernetesPath "local-config.json"
$IngressNginxVersion = "4.15.1"
$CertManagerVersion = "v1.20.2"
$RootCaCommonName = "OctoMesh Getting Started Root CA"

function Test-Prerequisites {
    Write-Host ""
    Write-Host "Checking prerequisites..." -ForegroundColor Cyan
    $allPassed = $true

    if ($PSVersionTable.PSVersion -lt [Version]"7.4") {
        Write-Host "PowerShell 7.4+ required (found $($PSVersionTable.PSVersion))." -ForegroundColor Red
        $allPassed = $false
    }

    foreach ($tool in @(
        @{ Name = "docker";   Hint = "Install Docker Desktop: https://www.docker.com/products/docker-desktop/" },
        @{ Name = "kind";     Hint = "Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation (brew install kind / winget install Kubernetes.kind)" },
        @{ Name = "kubectl";  Hint = "Install kubectl: https://kubernetes.io/docs/tasks/tools/" },
        @{ Name = "helm";     Hint = "Install helm v3: https://helm.sh/docs/intro/install/" },
        @{ Name = "openssl";  Hint = "Install openssl (brew install openssl / winget install ShiningLight.OpenSSL.Dev)" },
        @{ Name = "octo-cli"; Hint = "Install octo-cli: choco install octo-cli (see README for other platforms)" }
    )) {
        Write-Host -NoNewline ("  {0,-10} " -f $tool.Name)
        if (Get-Command $tool.Name -ErrorAction SilentlyContinue) {
            Write-Host "OK" -ForegroundColor Green
        }
        else {
            Write-Host "NOT FOUND" -ForegroundColor Red
            Write-Host "    $($tool.Hint)" -ForegroundColor Yellow
            $allPassed = $false
        }
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Docker is installed but not running. Start Docker Desktop first." -ForegroundColor Red
            $allPassed = $false
        }
    }

    # arm64 preflight warning: OctoMesh service images are currently amd64-only, so the
    # platform phase (Task 6) will not start pods on an ARM Docker engine. Infrastructure
    # (mongo/rabbitmq/crate/ingress-nginx/cert-manager) is multi-arch and works fine.
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $dockerArch = (docker info --format '{{.Architecture}}' 2>$null).Trim()
        if ($dockerArch -in @("aarch64", "arm64")) {
            Write-Host ""
            Write-Host "WARNING: Docker engine architecture is $dockerArch (ARM)." -ForegroundColor Yellow
            Write-Host "OctoMesh service images are currently amd64-only, so platform service pods will NOT" -ForegroundColor Yellow
            Write-Host "start on this machine until multi-arch images are published. Infrastructure" -ForegroundColor Yellow
            Write-Host "(MongoDB, RabbitMQ, CrateDB, ingress-nginx, cert-manager) works fine on ARM." -ForegroundColor Yellow
            Write-Host "An amd64 host is required for the full quickstart." -ForegroundColor Yellow
            if ($NonInteractive) {
                Write-Host "Continuing (-NonInteractive)." -ForegroundColor Yellow
            }
            else {
                $continue = Read-Host "Continue anyway? (y/N)"
                if ($continue -ne "y" -and $continue -ne "Y") {
                    Write-Host "Aborted." -ForegroundColor Red
                    $allPassed = $false
                }
            }
        }
    }

    return $allPassed
}

function Test-PortsFree {
    # Only checked while the octomesh cluster does not exist yet - once it runs,
    # these ports are legitimately taken by the cluster itself.
    $existing = kind get clusters 2>$null
    if ($existing -contains $ClusterName) { return $true }

    $busy = @()
    foreach ($port in @(80, 443, 27017, 5672, 15672, 5432, 4301)) {
        if (Test-Connection -TargetName 127.0.0.1 -TcpPort $port -TimeoutSeconds 1 -Quiet) {
            $busy += $port
        }
    }
    if ($busy.Count -gt 0) {
        Write-Host "Required host ports already in use: $($busy -join ', ')." -ForegroundColor Red
        Write-Host "Likely causes: a leftover getting-started Docker Compose stack, the octo-tools" -ForegroundColor Yellow
        Write-Host "developer kind cluster, or another local database/web server." -ForegroundColor Yellow
        Write-Host "Stop the conflicting services and re-run ./om-install.ps1." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Get-OctoMeshReleases {
    # Returns the octo-mesh chart entries (chart version + appVersion) from the
    # public release index, newest first.
    Write-Host "Fetching available OctoMesh versions..."
    $response = Invoke-WebRequest -Uri "$ChartRepo/index.yaml" -UseBasicParsing
    $releases = [System.Collections.Generic.List[object]]::new()
    $entries = $response.Content -split "(?=- apiVersion:)"
    foreach ($entry in $entries) {
        if ($entry -match "(?m)^\s*name:\s*octo-mesh\s*$" -and
            $entry -match "(?m)^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -and
            $entry -match "(?m)^\s*appVersion:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\s*$") {
            $chartVer = [regex]::Match($entry, "(?m)^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$").Groups[1].Value
            $appVer = [regex]::Match($entry, "(?m)^\s*appVersion:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\s*$").Groups[1].Value
            if (-not ($releases | Where-Object { $_.ChartVersion -eq $chartVer })) {
                $releases.Add([pscustomobject]@{ ChartVersion = $chartVer; AppVersion = $appVer })
            }
        }
    }
    return $releases | Sort-Object { [Version]$_.ChartVersion } -Descending
}

function Read-MaskedInput([string]$prompt) {
    Write-Host -NoNewline $prompt
    $secure = Read-Host -AsSecureString
    return [System.Net.NetworkCredential]::new("", $secure).Password
}

function Initialize-Configuration {
    $config = @{}
    if (Test-Path $ConfigPath) {
        $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $existing.PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value }
        Write-Host "Loaded existing configuration from local-config.json" -ForegroundColor Yellow
    }

    # Version selection
    if ($ChartVersion) {
        $releases = Get-OctoMeshReleases
        $selected = $releases | Where-Object { $_.ChartVersion -eq $ChartVersion } | Select-Object -First 1
        if (-not $selected) { throw "Chart version '$ChartVersion' not found in $ChartRepo" }
    }
    elseif ($config.chartVersion -and $NonInteractive) {
        $selected = [pscustomobject]@{ ChartVersion = $config.chartVersion; AppVersion = $config.appVersion }
    }
    else {
        $releases = Get-OctoMeshReleases
        if ($releases.Count -eq 0) { throw "Could not fetch versions from $ChartRepo. Check your internet connection." }
        if ($NonInteractive) {
            $selected = $releases[0]
        }
        else {
            Write-Host ""
            Write-Host "Available OctoMesh versions (latest 10):" -ForegroundColor Green
            $display = $releases | Select-Object -First 10
            for ($i = 0; $i -lt $display.Count; $i++) {
                $marker = if ($i -eq 0) { " [default]" } else { "" }
                Write-Host "  [$($i + 1)] $($display[$i].AppVersion)$marker"
            }
            $versionInput = Read-Host "Select version (press Enter for default: $($display[0].AppVersion))"
            $selected = if ([string]::IsNullOrWhiteSpace($versionInput)) { $display[0] }
                        else { $display[[int]$versionInput - 1] }
        }
    }
    $config.chartVersion = $selected.ChartVersion
    $config.appVersion = $selected.AppVersion
    Write-Host "Selected OctoMesh $($config.appVersion) (chart $($config.chartVersion))" -ForegroundColor Green

    # License keys
    if ($IdentityServerLicenseKey) { $config.identityServerLicenseKey = $IdentityServerLicenseKey }
    if (-not $config.identityServerLicenseKey) {
        if ($NonInteractive) { throw "IdentityServerLicenseKey is required (parameter or local-config.json)." }
        Write-Host ""
        Write-Host "Duende IdentityServer license key" -ForegroundColor Green
        Write-Host "Get one at https://duendesoftware.com/products/identityserver#pricing (community edition is free for small companies and open source)."
        $config.identityServerLicenseKey = Read-MaskedInput "Enter Identity Server license key: "
    }
    if ($AutoMapperLicenseKey) { $config.autoMapperLicenseKey = $AutoMapperLicenseKey }
    if (-not $config.autoMapperLicenseKey) {
        if ($NonInteractive) { throw "AutoMapperLicenseKey is required (parameter or local-config.json)." }
        Write-Host ""
        Write-Host "AutoMapper license key" -ForegroundColor Green
        Write-Host "Get one at https://www.automapper.io/ (free tier available)."
        $config.autoMapperLicenseKey = Read-MaskedInput "Enter AutoMapper license key: "
    }

    New-Item -ItemType Directory -Path $GeneratedPath -Force | Out-Null
    $config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    return $config
}

function New-KindCluster {
    $existing = kind get clusters 2>$null
    if ($existing -contains $ClusterName) {
        Write-Host "kind cluster '$ClusterName' already exists - reusing it." -ForegroundColor Yellow
        return
    }
    Write-Host "Creating kind cluster '$ClusterName'..." -ForegroundColor Cyan
    kind create cluster --name $ClusterName --config (Join-Path $KubernetesPath "kind-cluster.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kind create cluster failed." }
}

function Install-Infrastructure {
    Write-Host "Installing infrastructure (MongoDB, RabbitMQ, CrateDB)..." -ForegroundColor Cyan
    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "namespaces.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of namespaces.yaml failed." }

    # MongoDB keyfile secret (generated once, reused on re-runs)
    $keyFile = Join-Path $GeneratedPath "file.key"
    if (-not (Test-Path $keyFile)) {
        $randBytes = [byte[]]::new(741)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
        [Convert]::ToBase64String($randBytes) | Set-Content -Path $keyFile -NoNewline -Encoding ascii
    }
    kubectl --context $KubeContext -n octo-infra create secret generic mongodb-keyfile `
        --from-file=file.key=$keyFile --dry-run=client -o yaml | kubectl --context $KubeContext apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Applying the mongodb-keyfile secret failed." }
    $mongoInitPath = Join-Path $KubernetesPath "infra/mongo-init"
    kubectl --context $KubeContext -n octo-infra create configmap mongodb-init `
        --from-file=$mongoInitPath --dry-run=client -o yaml | kubectl --context $KubeContext apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Applying the mongodb-init configmap failed." }

    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/rabbitmq.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of infra/rabbitmq.yaml failed." }
    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/cratedb.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of infra/cratedb.yaml failed." }
    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/mongodb.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of infra/mongodb.yaml failed." }

    kubectl --context $KubeContext -n octo-infra rollout status statefulset/mongodb --timeout=300s
    if ($LASTEXITCODE -ne 0) { throw "MongoDB did not become ready within 300s - check 'kubectl --context kind-octomesh -n octo-infra get pods'." }
    kubectl --context $KubeContext -n octo-infra rollout status deployment/rabbitmq --timeout=300s
    if ($LASTEXITCODE -ne 0) { throw "RabbitMQ did not become ready within 300s - check 'kubectl --context kind-octomesh -n octo-infra get pods'." }
    kubectl --context $KubeContext -n octo-infra rollout status statefulset/cratedb --timeout=300s
    if ($LASTEXITCODE -ne 0) { throw "CrateDB did not become ready within 300s - check 'kubectl --context kind-octomesh -n octo-infra get pods'." }

    # Initialize the replica set and the admin user (both scripts are idempotent).
    Write-Host "Initializing MongoDB replica set..."
    $attempts = 0
    while ($true) {
        $attempts++
        $output = kubectl --context $KubeContext -n octo-infra exec mongodb-0 -- mongosh admin /scripts/init-replicaset.js 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { break }
        if ($output -match "MongoNetworkError" -and $attempts -lt 20) {
            Start-Sleep -Seconds 3
            continue
        }
        throw "MongoDB replica set initialization failed:`n$output"
    }
    kubectl --context $KubeContext -n octo-infra exec mongodb-0 -- mongosh admin /scripts/create-admin-user.js
    if ($LASTEXITCODE -ne 0) { throw "MongoDB admin user creation failed." }
}

function Install-IngressAndCertManager {
    Write-Host "Installing ingress-nginx and cert-manager..." -ForegroundColor Cyan
    helm upgrade --install ingress-nginx ingress-nginx `
        --repo https://kubernetes.github.io/ingress-nginx --version $IngressNginxVersion `
        --namespace ingress-nginx --create-namespace `
        --values (Join-Path $KubernetesPath "ingress-nginx-values.yaml") `
        --kube-context $KubeContext --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "ingress-nginx install failed." }

    helm upgrade --install cert-manager cert-manager `
        --repo https://charts.jetstack.io --version $CertManagerVersion `
        --namespace cert-manager --create-namespace `
        --values (Join-Path $KubernetesPath "cert-manager-values.yaml") `
        --kube-context $KubeContext --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "cert-manager install failed." }

    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "cluster-issuer.yaml")
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of cluster-issuer.yaml failed." }
    kubectl --context $KubeContext wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "ClusterIssuer mm-cloud-issuer did not become Ready within 120s - check 'kubectl --context kind-octomesh describe clusterissuer mm-cloud-issuer'." }

    # Export the root CA for OS trust and for chart rootCa values.
    $caPath = Join-Path $GeneratedPath "local-root-ca.crt"
    $caB64 = kubectl --context $KubeContext -n cert-manager get secret local-root-ca-tls -o jsonpath='{.data.ca\.crt}'
    if (-not $caB64) { $caB64 = kubectl --context $KubeContext -n cert-manager get secret local-root-ca-tls -o jsonpath='{.data.tls\.crt}' }
    if ([string]::IsNullOrWhiteSpace($caB64)) { throw "Could not read the root CA from secret local-root-ca-tls - is cert-manager healthy?" }
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($caB64)) | Set-Content -Path $caPath -NoNewline -Encoding ascii
    Write-Host "Root CA exported to $caPath"
}

function Set-CoreDnsRewrite {
    # Pods resolve *.127-0-0-1.nip.io to 127.0.0.1 (= the pod itself) via public DNS.
    # Rewrite those names to the ingress controller so in-cluster OIDC/JWKS works.
    # kubectl output with embedded newlines comes back from PowerShell as a string ARRAY
    # (one element per line), not a single multi-line string. -join forces it back into a
    # scalar string so -match/-replace/ConvertTo-Json below operate on the whole Corefile
    # instead of per-line - otherwise ConvertTo-Json emits Corefile as a JSON array and the
    # API server rejects the patch ("cannot unmarshal array into Go struct field ... string").
    $corefile = (kubectl --context $KubeContext -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}') -join "`n"
    if ($corefile -match "127-0-0-1") {
        Write-Host "CoreDNS rewrite already present." -ForegroundColor Yellow
        return
    }
    Write-Host "Adding CoreDNS rewrite for *.$BaseDomain..." -ForegroundColor Cyan
    $rewrite = "    rewrite name regex (.*)\.127-0-0-1\.nip\.io ingress-nginx-controller.ingress-nginx.svc.cluster.local answer auto"
    $patchedCorefile = $corefile -replace "(?m)^(\s*ready\s*)$", "`$1`n$rewrite"
    if ($patchedCorefile -eq $corefile) { throw "Could not locate the 'ready' line in the CoreDNS Corefile to insert the rewrite." }
    $patch = @{ data = @{ Corefile = $patchedCorefile } } | ConvertTo-Json -Depth 5
    $patchFile = Join-Path $GeneratedPath "coredns-patch.json"
    $patch | Set-Content -Path $patchFile -Encoding UTF8
    kubectl --context $KubeContext -n kube-system patch configmap coredns --type merge --patch-file $patchFile
    if ($LASTEXITCODE -ne 0) { throw "CoreDNS Corefile patch failed." }
    kubectl --context $KubeContext -n kube-system rollout restart deployment coredns
    kubectl --context $KubeContext -n kube-system rollout status deployment coredns --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "CoreDNS rollout after Corefile patch failed." }
}

function Add-CaTrust {
    if ($SkipTrustCa) {
        Write-Host "Skipping OS trust of the root CA (-SkipTrustCa). Browsers will warn about the certificate." -ForegroundColor Yellow
        return
    }
    $caPath = Join-Path $GeneratedPath "local-root-ca.crt"
    Write-Host "Trusting the local root CA in the OS store (may prompt for sudo/elevation)..." -ForegroundColor Cyan
    if ($IsMacOS) {
        sudo security delete-certificate -c $RootCaCommonName /Library/Keychains/System.keychain 2>$null
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $caPath
    }
    elseif ($IsWindows) {
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($RootCaCommonName) } | Remove-Item -ErrorAction SilentlyContinue
        Import-Certificate -FilePath $caPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    }
    else {
        sudo cp $caPath /usr/local/share/ca-certificates/octomesh-getting-started-root-ca.crt
        sudo update-ca-certificates
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CA trust failed (non-fatal). You can trust $caPath manually or continue with browser warnings." -ForegroundColor Yellow
    }
}

# ── Main flow ────────────────────────────────────────────────────────────────
if (-not (Test-Prerequisites)) { exit 1 }
if (-not (Test-PortsFree)) { exit 1 }
$config = Initialize-Configuration
New-KindCluster
Install-Infrastructure
Install-IngressAndCertManager
Set-CoreDnsRewrite
Add-CaTrust

function New-SigningKey {
    $pfxPath = Join-Path $GeneratedPath "IdentityServer4Auth.pfx"
    if (Test-Path $pfxPath) { return $pfxPath }
    Write-Host "Generating IdentityServer signing key..." -ForegroundColor Cyan
    $keyPath = Join-Path $GeneratedPath "IdentityServer4Auth.key"
    $crtPath = Join-Path $GeneratedPath "IdentityServer4Auth.crt"
    openssl req -x509 -newkey rsa:2048 -sha256 -keyout $keyPath -out $crtPath -subj "/CN=octomesh-signing" -days 10950 -passout pass:Secret01 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl signing-cert generation failed." }
    openssl pkcs12 -export -out $pfxPath -inkey $keyPath -in $crtPath -passin pass:Secret01 -passout pass:Secret01 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl pkcs12 export failed." }
    return $pfxPath
}

function Get-InstanceSecretKey {
    # AES-256-GCM master key for workload secret encryption. Generated once and
    # persisted - rotating it would orphan encrypted workload secrets.
    if (-not $config.communicationInstanceSecretKey) {
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $config.communicationInstanceSecretKey = [Convert]::ToBase64String($bytes)
        $config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    }
    return $config.communicationInstanceSecretKey
}

function Install-OctoMesh {
    Write-Host "Installing OctoMesh platform chart (octo-mesh $($config.chartVersion))..." -ForegroundColor Cyan

    helm upgrade --install octo-mesh-crds octo-mesh-crds `
        --repo $ChartRepo --version $config.chartVersion `
        --namespace octo-operator-system `
        --kube-context $KubeContext --wait --timeout 2m
    if ($LASTEXITCODE -ne 0) { throw "octo-mesh-crds install failed." }

    $pfxPath = New-SigningKey
    $caPath = Join-Path $GeneratedPath "local-root-ca.crt"

    # Forward slashes in --set-file paths (helm on Windows chokes on backslashes) -
    # see Install-Operator's comment for details.
    $pfxArg = $pfxPath -replace '\\', '/'
    $caArg = $caPath -replace '\\', '/'

    # Secrets via a temporary JSON values file (avoids --set escaping issues) -
    # the same pattern the managed-environment deployment uses.
    $secretsFile = Join-Path $GeneratedPath "octo-mesh-secrets.json"
    @{
        secrets = @{
            databaseUser = "OctoUser1"
            databaseAdmin = "OctoAdmin1"
            rabbitmq = "guest"
            streamDataPassword = "OctoStream1"
            communicationInstanceSecretKey = Get-InstanceSecretKey
        }
        services = @{
            identity = @{
                signingKey = @{ password = "Secret01" }
                identityServerLicenseKey = $config.identityServerLicenseKey
                autoMapperLicenseKey = $config.autoMapperLicenseKey
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $secretsFile -Encoding UTF8

    $studioDeploy = if ($DeploymentProfile -eq "full") { "true" } else { "false" }

    try {
        helm upgrade --install octo-mesh octo-mesh `
            --repo $ChartRepo --version $config.chartVersion `
            --namespace octo `
            --values (Join-Path $KubernetesPath "values/octo-mesh-values.yaml") `
            --values $secretsFile `
            --set-file services.identity.signingKey.key=$pfxArg `
            --set-file secrets.rootCa=$caArg `
            --set services.studio.deploy=$studioDeploy `
            --kube-context $KubeContext --timeout 10m
        if ($LASTEXITCODE -ne 0) { throw "octo-mesh install failed." }
    }
    finally {
        Remove-Item $secretsFile -ErrorAction SilentlyContinue
    }

    Write-Host "Waiting for platform services to become ready (image pulls may take several minutes)..."
    foreach ($deploy in @("identity-services", "asset-rep-services", "bot-services", "communication-controller-services", "platform-services")) {
        kubectl --context $KubeContext -n octo rollout status deployment -l "app.kubernetes.io/name=$deploy" --timeout=600s 2>$null
    }
    # Fallback wait that does not depend on label naming: all pods in ns octo ready.
    kubectl --context $KubeContext -n octo wait --for=condition=Ready pods --all --timeout=600s
}

function Install-Reporting {
    if ($DeploymentProfile -ne "full") { return }
    Write-Host "Installing reporting chart (octo-mesh-reporting $($config.chartVersion))..." -ForegroundColor Cyan
    $caPath = Join-Path $GeneratedPath "local-root-ca.crt"
    # Forward slashes in --set-file paths (helm on Windows chokes on backslashes) -
    # see Install-Operator's comment for details.
    $caArg = $caPath -replace '\\', '/'
    $secretsFile = Join-Path $GeneratedPath "reporting-secrets.json"
    @{
        secrets = @{
            databaseUser = "OctoUser1"
            databaseAdmin = "OctoAdmin1"
            rabbitmq = "guest"
            streamDataPassword = "OctoStream1"
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $secretsFile -Encoding UTF8
    try {
        helm upgrade --install octo-mesh-reporting octo-mesh-reporting `
            --repo $ChartRepo --version $config.chartVersion `
            --namespace octo `
            --values (Join-Path $KubernetesPath "values/reporting-values.yaml") `
            --values $secretsFile `
            --set-file secrets.rootCa=$caArg `
            --kube-context $KubeContext --timeout 10m
        if ($LASTEXITCODE -ne 0) { throw "octo-mesh-reporting install failed." }
    }
    finally {
        Remove-Item $secretsFile -ErrorAction SilentlyContinue
    }
}

function Install-Operator {
    Write-Host "Installing Communication Operator ($($config.chartVersion))..." -ForegroundColor Cyan

    # Admission webhook certificates (CA + server cert for the in-cluster service).
    $webhookPath = Join-Path $GeneratedPath "operator-webhook"
    New-Item -ItemType Directory -Path $webhookPath -Force | Out-Null
    $caKey = Join-Path $webhookPath "ca.key"; $caCrt = Join-Path $webhookPath "ca.crt"
    $svcKey = Join-Path $webhookPath "svc.key"; $svcCrt = Join-Path $webhookPath "svc.crt"
    if (-not (Test-Path $svcCrt)) {
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -keyout $caKey -out $caCrt -subj "/CN=communication-operator-ca" -days 3650
        if ($LASTEXITCODE -ne 0) { throw "openssl webhook CA generation failed." }
        openssl req -newkey rsa:2048 -nodes -keyout $svcKey -out (Join-Path $webhookPath "svc.csr") -subj "/CN=communication-operator.octo-operator-system.svc"
        if ($LASTEXITCODE -ne 0) { throw "openssl webhook CSR generation failed." }
        $extFile = Join-Path $webhookPath "san.cnf"
        "subjectAltName=DNS:communication-operator.octo-operator-system.svc,DNS:communication-operator.octo-operator-system.svc.cluster.local" | Set-Content -Path $extFile -Encoding ascii
        openssl x509 -req -in (Join-Path $webhookPath "svc.csr") -CA $caCrt -CAkey $caKey -CAcreateserial -out $svcCrt -days 3650 -extfile $extFile
        if ($LASTEXITCODE -ne 0) { throw "openssl webhook cert signing failed." }
    }

    # Forward slashes in --set-file paths (helm on Windows chokes on backslashes),
    # precomputed into plain variables (subexpressions inside kubectl/helm argument
    # tokens do not parse reliably in PowerShell).
    $caKeyArg = $caKey -replace '\\', '/'
    $caCrtArg = $caCrt -replace '\\', '/'
    $svcKeyArg = $svcKey -replace '\\', '/'
    $svcCrtArg = $svcCrt -replace '\\', '/'
    $rootCaArg = (Join-Path $GeneratedPath "local-root-ca.crt") -replace '\\', '/'
    $operatorValues = Join-Path $KubernetesPath "values/operator-values.yaml"
    helm upgrade --install communication-operator octo-mesh-communication-operator `
        --repo $ChartRepo --version $config.chartVersion `
        --namespace octo-operator-system `
        --values $operatorValues `
        --set-file serviceHooks.caKey=$caKeyArg `
        --set-file serviceHooks.caCrt=$caCrtArg `
        --set-file serviceHooks.svcKey=$svcKeyArg `
        --set-file serviceHooks.svcCrt=$svcCrtArg `
        --set-file secrets.rootCa=$rootCaArg `
        --kube-context $KubeContext --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "communication-operator install failed." }
}

Install-OctoMesh
Install-Reporting
Install-Operator

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Service URLs:" -ForegroundColor Cyan
Write-Host "  Identity:            https://identity.$BaseDomain/"
Write-Host "  Asset repository:    https://assets.$BaseDomain/tenants/octosystem/graphql/playground"
Write-Host "  Bot dashboard:       https://bots.$BaseDomain/ui/jobs"
Write-Host "  Platform services:   https://platform.$BaseDomain/octosystem/_configuration"
if ($DeploymentProfile -eq "full") {
    Write-Host "  Refinery Studio:     https://studio.$BaseDomain/"
    Write-Host "  Reporting:           https://reporting.$BaseDomain/"
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open https://identity.$BaseDomain/ and register the admin user."
Write-Host "  2. Run ./om-login-local.ps1 to configure and log in octo-cli."
Write-Host "  3. Run ./om-bootstrap-tenant.ps1 to create a tenant and deploy the mesh adapter."
Write-Host ""
Write-Host "Manage the installation with ./om-status.ps1, ./om-stop.ps1, ./om-start.ps1, ./om-uninstall.ps1."
