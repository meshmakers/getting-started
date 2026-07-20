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

    # MongoDB keyfile secret (generated once, reused on re-runs)
    $keyFile = Join-Path $GeneratedPath "file.key"
    if (-not (Test-Path $keyFile)) {
        $randBytes = [byte[]]::new(741)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
        [Convert]::ToBase64String($randBytes) | Set-Content -Path $keyFile -NoNewline -Encoding ascii
    }
    kubectl --context $KubeContext -n octo-infra create secret generic mongodb-keyfile `
        --from-file=file.key=$keyFile --dry-run=client -o yaml | kubectl --context $KubeContext apply -f -
    $mongoInitPath = Join-Path $KubernetesPath "infra/mongo-init"
    kubectl --context $KubeContext -n octo-infra create configmap mongodb-init `
        --from-file=$mongoInitPath --dry-run=client -o yaml | kubectl --context $KubeContext apply -f -

    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/rabbitmq.yaml")
    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/cratedb.yaml")
    kubectl --context $KubeContext apply -f (Join-Path $KubernetesPath "infra/mongodb.yaml")

    kubectl --context $KubeContext -n octo-infra rollout status statefulset/mongodb --timeout=300s
    kubectl --context $KubeContext -n octo-infra rollout status deployment/rabbitmq --timeout=300s
    kubectl --context $KubeContext -n octo-infra rollout status statefulset/cratedb --timeout=300s

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
    kubectl --context $KubeContext wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s

    # Export the root CA for OS trust and for chart rootCa values.
    $caPath = Join-Path $GeneratedPath "local-root-ca.crt"
    $caB64 = kubectl --context $KubeContext -n cert-manager get secret local-root-ca-tls -o jsonpath='{.data.ca\.crt}'
    if (-not $caB64) { $caB64 = kubectl --context $KubeContext -n cert-manager get secret local-root-ca-tls -o jsonpath='{.data.tls\.crt}' }
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

# ---- platform phase (Task 6) ----
