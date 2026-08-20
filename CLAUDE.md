# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides PowerShell scripts that deploy the OctoMesh platform into a
local kind (Kubernetes in Docker) cluster using the official OctoMesh Helm charts from
the public release repository (https://meshmakers.github.io/charts). Release versions
only — rolling/dev tags are not publicly available.

## Common Commands

All commands run from `scripts/` with PowerShell 7.4+.

```pwsh
./om-install.ps1 [-DeploymentProfile core|full] [-SkipTrustCa]
                 [-ChartVersion X.Y.Z] [-IdentityServerLicenseKey …] [-AutoMapperLicenseKey …]
                 # unattended runs are detected from a redirected stdin, not a flag:
                 # version defaults to latest, missing license keys throw
./om-login-local.ps1 [-tenantId meshtest] [-includeReporting $true]
./om-bootstrap-tenant.ps1 [-TenantId meshtest] [-IncludeSimulation]
./om-status.ps1
./om-stop.ps1 / ./om-start.ps1          # stop/start the kind node container (data preserved);
                                        # om-start waits for Identity's JWKS after a cold start and
                                        # restarts the token-validating services once (AB#4498 workaround)
./om-uninstall.ps1 [-Force] [-KeepCaTrust] [-KeepGeneratedFiles]
                                        # deletes cluster + data, and untrusts the root CA
```

## Architecture

* kind cluster `octomesh` (kubectl context `kind-octomesh`), host ports on 127.0.0.1:
  80/443 (ingress), 27017 (Mongo), 5672/15672 (RabbitMQ), 5432/4301 (CrateDB).
* Namespaces: `octo-infra` (Mongo 1-member replica set `rs` + keyfile, RabbitMQ,
  CrateDB single node), `octo` (platform services + operator-deployed adapters),
  `octo-operator-system` (CRDs + Communication Operator), plus ingress-nginx and
  cert-manager.
* TLS: cert-manager self-signed root CA (CN "OctoMesh Getting Started Root CA")
  behind ClusterIssuer `mm-cloud-issuer` (same name as managed environments). Only
  the CA *certificate* is exported (`.generated/local-root-ca.crt`) — the private key
  stays in the `local-root-ca-tls` secret and dies with the cluster, deliberately:
  a root CA trusted by the OS and browsers can sign for any host, so it must not
  outlive the cluster on disk. Consequence: every install mints a new CA and re-trusts
  it (sudo/admin prompt each time), replacing the stale entry.
* On Windows both scripts call `Assert-Elevated` before doing any work: the certificate
  store needs an elevated process, PowerShell cannot elevate in place, so the script
  re-launches itself with `-Verb RunAs`, waits, and exits with the child's code. Bound
  parameters are rebuilt for the child except `*LicenseKey`, which would otherwise land
  in a machine-visible command line. Skipped with `-SkipTrustCa` / `-KeepCaTrust`, and
  a no-op on Unix (per-command `sudo` there).
* Trust plumbing lives in `kubernetes/ca-trust.ps1`, shared by install/uninstall:
  the OS store on all three platforms, plus — on Linux only — NSS via `certutil` for
  Chrome (`~/.pki/nssdb`) and for every Firefox profile (deb/tarball, snap, flatpak),
  because Linux browsers ignore the OS store. On Windows/macOS nothing browser-specific
  is done: Chrome uses the OS store and Firefox imports it by default
  (`security.enterprise_roots.enabled`, on since FF 68). The sqlite `cert9.db` backend
  accepts writes from a running browser (verified against a live headless Firefox), so
  nothing is closed to install the CA — the browser just has to restart to read it.
  `Add-CaTrust` ends with `Invoke-BrowserRestartOffer`, a `yes`-confirmed convenience
  that closes running browsers; declining costs nothing. Process matching uses a
  normalized executable name, since on Linux `ProcessName` is Chrome's whole command
  line.
* Hostnames: `https://{identity,assets,bots,communication,platform,studio,reporting}.127-0-0-1.nip.io`.
  A CoreDNS rewrite resolves `*.127-0-0-1.nip.io` to ingress-nginx inside the cluster
  (pods fetch JWKS from the public identity URI — without the rewrite they would
  resolve 127.0.0.1 = themselves).
* Charts installed: `octo-mesh-crds` and `octo-mesh-communication-operator`
  (`autoManagePools=true`) in `octo-operator-system`; `octo-mesh` (and
  `octo-mesh-reporting` on the full profile) in `octo`. `octo-mesh-crds` and
  `octo-mesh-communication-operator` ride the same chart version as `octo-mesh`
  (selected at install time from the public index). The mesh adapter, simulation,
  and reporting charts release independently, so each is resolved separately to
  the newest version at or below the selected platform version.
* `serviceDefaults.environment=production` makes `EnableCommunication` apply the
  Release blueprint variant, which seeds: Pool `670000000000000000000001`,
  MeshAdapter `670000000000000000000002` (chart `octo-mesh-adapter`), and
  HelmRepositoryConfiguration `670000000000000000000004` → https://meshmakers.github.io/charts.
  `om-bootstrap-tenant.ps1` then pins the chart version, deploys the pool
  (`octo-cli -c DeployPool`), and deploys the adapter (`octo-cli -c DeployWorkload`).
  The Studio OIDC client is blueprint-seeded from `services.studio.publicUri` —
  there is no manual client-registration script anymore.
* Generated local state (gitignored): `scripts/kubernetes/.generated/` (signing key
  PFX, root CA certificate, Mongo keyfile, operator webhook certs),
  `scripts/kubernetes/local-config.json` (chart version + license keys).

## Key constraints

* Everything must work for EXTERNAL users: public charts, public Docker Hub images,
  release versions only. Never reference docker.mm.cloud or main-latest tags.
* Scripts are standalone — no octo-tools checkout, no monorepo assumptions.
* Service images are multi-arch (amd64/arm64) as of release 3.4.51; releases older
  than 3.4.51 are amd64-only. octo-cli minimum version is 3.4.51.
* Dev-grade default credentials are intentional (quickstart), but nothing generated
  or secret may be committed.
* All artifacts in English. Commit format: `AB#<n> <New/Fix>: <description>`.
