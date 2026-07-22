# Getting started with OctoMesh

This repository deploys the OctoMesh platform on your machine using the official
OctoMesh Helm charts inside a local [kind](https://kind.sigs.k8s.io/) (Kubernetes
in Docker) cluster — the same deployment model OctoMesh uses in real clusters.

## Prerequisites

* [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine on Linux)
  * **Note:** images are multi-arch (amd64/arm64) as of release 3.4.51; Apple Silicon
    works natively. Releases older than 3.4.51 are amd64-only.
* [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
* [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.31+ (`brew install kind` / `winget install Kubernetes.kind`)
* [kubectl](https://kubernetes.io/docs/tasks/tools/)
* [helm](https://helm.sh/docs/intro/install/) v3
* openssl in PATH (`brew install openssl` / `winget install ShiningLight.OpenSSL.Dev`)
* octo-cli (`choco install octo-cli` on Windows; download the self-contained binary for
  macOS/Linux from the OctoMesh release page) — **minimum version 3.4.51**
* License keys (both prompted during installation):
  * [Duende IdentityServer](https://duendesoftware.com/products/identityserver#pricing) — community edition is free for small companies and open source
  * [AutoMapper](https://www.automapper.io/) — free tier available

No hosts-file entry and no manual certificate import are needed: services are
reached at `*.127-0-0-1.nip.io` hostnames (public DNS that resolves to 127.0.0.1)
and the installer sets up a locally-trusted certificate authority.

## Install

```pwsh
cd scripts
./om-install.ps1                          # core profile
./om-install.ps1 -DeploymentProfile full  # + Refinery Studio and Reporting
```

The installer:
1. creates a kind cluster named `octomesh` (all ports bound to 127.0.0.1 only),
2. installs MongoDB, RabbitMQ, and CrateDB,
3. installs ingress-nginx and cert-manager with a local root CA (you will be asked
   for sudo/admin rights to trust it; skip with `-SkipTrustCa`),
4. installs the OctoMesh platform and the Communication Operator from the public
   Helm chart repository (release versions only — you pick the version, latest is
   the default). Companion chart versions (mesh adapter, simulation, reporting)
   are resolved automatically to the newest release compatible with the chosen
   platform version, since those repos release independently.

## Create the admin user and log in

1. Open <https://identity.127-0-0-1.nip.io/> and register the admin user
   (the email address must be well-formed but does not need to exist).
2. Configure and log in the CLI:

```pwsh
./om-login-local.ps1                          # tenant: meshtest
./om-login-local.ps1 -tenantId "mytenant"     # custom tenant
./om-login-local.ps1 -includeReporting $true  # full profile
```

## Create a tenant and deploy the mesh adapter

```pwsh
./om-bootstrap-tenant.ps1                       # tenant meshtest + mesh adapter
./om-bootstrap-tenant.ps1 -IncludeSimulation    # + simulation adapter
```

This creates the tenant, enables communication (which seeds the default pool, the
mesh adapter, and the public chart repository), and deploys the adapters through
the Communication Operator — exactly the way managed OctoMesh environments work.

## URLs

| Service | URL |
|---|---|
| Identity | https://identity.127-0-0-1.nip.io/ |
| GraphQL playground (system tenant) | https://assets.127-0-0-1.nip.io/tenants/octosystem/graphql/playground |
| Bot dashboard | https://bots.127-0-0-1.nip.io/ui/jobs |
| Platform services (configuration discovery) | https://platform.127-0-0-1.nip.io/octosystem/_configuration |
| Refinery Studio (full profile) | https://studio.127-0-0-1.nip.io/ |
| Reporting (full profile) | https://reporting.127-0-0-1.nip.io/ |
| RabbitMQ management | http://localhost:15672/ (guest/guest) |
| CrateDB console | http://localhost:4301/ |
| MongoDB | mongodb://localhost:27017 |

## Manage the installation

```pwsh
./om-status.ps1      # pods, helm releases, ports, URLs
./om-stop.ps1        # stop the cluster (data preserved)
./om-start.ps1       # start it again
./om-uninstall.ps1   # delete the cluster AND ALL DATA, untrust the CA
```

## Troubleshooting

* **`*.127-0-0-1.nip.io` does not resolve** — some routers/corporate DNS servers
  block DNS answers that point to 127.0.0.1 (rebind protection). Fallback: add
  `127.0.0.1 identity.127-0-0-1.nip.io assets.127-0-0-1.nip.io bots.127-0-0-1.nip.io communication.127-0-0-1.nip.io platform.127-0-0-1.nip.io studio.127-0-0-1.nip.io reporting.127-0-0-1.nip.io`
  to your hosts file.
* **Docker Hub rate limits during install** — anonymous pulls are limited; run
  `docker login` with a free Docker account before installing.
* **Ports already in use** — the installer refuses when 80/443/27017/5672/15672/5432/4301
  are taken (e.g. by another local database). Stop the conflicting service first.
* **Browser warns about the certificate** — the root CA trust step was skipped or
  failed. Re-run `./om-install.ps1` without `-SkipTrustCa`, or trust
  `scripts/kubernetes/.generated/local-root-ca.crt` manually.
* **After `om-start.ps1`, API calls fail with `401` for a while** — when all pods
  cold-start together, some services may cache Identity's OIDC discovery metadata
  before Identity is fully ready, and keep rejecting valid tokens for a long time
  (the refresh interval is measured in hours). Remedy:
  `kubectl --context kind-octomesh -n octo rollout restart deployment <affected-service>`
  (e.g. `octo-mesh-communication-controller-services` or `octo-mesh-asset-rep-services`),
  or simply re-run `./om-stop.ps1` followed by `./om-start.ps1`.
* **Reporting pod `ImagePullBackOff` on Apple Silicon** — the reporting chart
  currently resolves to an older, amd64-only image
  (`octo-mesh-reporting-services:3.4.49.0`) until a newer reporting chart is
  published. Workaround: override the image tag to a multi-arch release:
  `helm upgrade octo-mesh-reporting octo-mesh-reporting --repo https://meshmakers.github.io/charts --version 3.4.49 --reuse-values --set image.tag=3.4.51.0 -n octo --kube-context kind-octomesh`

# Further reading

* [OctoMesh documentation](https://docs.meshmakers.cloud)

