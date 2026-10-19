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
./om-install.ps1 [-DeploymentProfile core|full] [-SkipTrustCa] [-NonInteractive]
                 [-ChartVersion X.Y.Z] [-SkipS3Store]
./om-login-local.ps1 [-tenantId meshtest] [-includeReporting $true]
./om-bootstrap-tenant.ps1 [-TenantId meshtest] [-IncludeSimulation]   # re-runnable (AB#6791)
./om-status.ps1 [-SkipS3Probe]          # pods, releases, host ports, S3 store check (see "S3 store")
./om-stop.ps1 / ./om-start.ps1          # stop/start the kind node container (data preserved);
                                        # om-start waits for Identity's JWKS after a cold start and
                                        # restarts the token-validating services once (AB#4498 workaround)
./om-uninstall.ps1 [-Force] [-KeepCaTrust] [-KeepGeneratedFiles]
                                        # deletes cluster + data, and untrusts the root CA
```

Pester tests of the re-run behaviour (fake octo-cli/kubectl, no stack needed):
`pwsh -c "Invoke-Pester ./scripts/tests"`. Steps that may be "already done" go through
`Invoke-OctoCliIdempotent` in `om-bootstrap-tenant.ps1`; every other failure must stop the script.

## Architecture

* kind cluster `octomesh` (kubectl context `kind-octomesh`), host ports on 127.0.0.1:
  80/443 (ingress), 27017 (Mongo), 5672/15672 (RabbitMQ), 5432/4301 (CrateDB), 8333 (S3 store).
  **This cluster and the octo-tools developer cluster (`kind`) bind the same host ports and never run
  at the same time** (the octo-tools cluster's S3 relay container `octo-kind-s3-relay` also holds 8333).
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
* Host trust lives in `kubernetes/ca-trust.ps1` (161 lines), dot-sourced by both
  scripts: `Assert-Elevated`, `Get-NssCertutil`, `Get-NssDatabasePaths`, the
  `Add-`/`Remove-CaToOsStore` and `…BrowserStores` pairs, and
  `Write-BrowserRestartWarning`. `Assert-Elevated` only *checks* on Windows — no
  elevated relaunch — and exits 1 with instructions when the console is not elevated;
  it is skipped by `-SkipTrustCa` / `-KeepCaTrust` and is a no-op on Unix, where
  individual commands use `sudo`.
* Stores written: the OS store on all three platforms, plus — on Linux only — NSS via
  `certutil` for Chrome (`~/.pki/nssdb`) and every Firefox profile (deb/tarball, snap,
  flatpak), because Linux browsers ignore the OS store. On Windows/macOS nothing
  browser-specific happens: Chrome uses the OS store and Firefox imports it by default
  (`security.enterprise_roots.enabled`, on since FF 68).
* Browser processes are never inspected or stopped. Both scripts end the certificate
  step with a warning that Chrome/Firefox must be closed completely and restarted
  before they see (or stop seeing) the CA.
* Hostnames: `https://{identity,assets,bots,communication,platform,studio,reporting}.127-0-0-1.nip.io`.
  A CoreDNS rewrite resolves `*.127-0-0-1.nip.io` to ingress-nginx inside the cluster
  (pods fetch JWKS from the public identity URI — without the rewrite they would
  resolve 127.0.0.1 = themselves).
* Charts installed: `octo-mesh-crds` and `octo-mesh-communication-operator`
  (`autoManageDeploymentSites=true`) in `octo-operator-system`; `octo-mesh`, `octo-mesh-mcp` (MCP server, `-SkipMcp` skips it; it reads MongoDB directly, in-cluster
  http to the services, public identity URI over the root CA; the identity seed for its clients and
  ApiResource derives `https://mcp.127-0-0-1.nip.io` itself) and, on the full profile,
  `octo-mesh-reporting` in `octo`. `octo-mesh-crds` and
  `octo-mesh-communication-operator` ride the same chart version as `octo-mesh`
  (selected at install time from the public index). The mesh adapter, simulation,
  reporting and MCP charts release independently, so each is resolved separately to
  the newest version at or below the selected platform version.
* `serviceDefaults.environment=production` makes `EnableCommunication` apply the
  Release blueprint variant, which seeds: Pool `670000000000000000000001`,
  MeshAdapter `670000000000000000000002` (chart `octo-mesh-adapter`), and
  HelmRepositoryConfiguration `670000000000000000000004` → https://meshmakers.github.io/charts.
  `om-bootstrap-tenant.ps1` then pins the chart version, deploys the pool
  (`octo-cli -c DeployDeploymentSite`, called `DeployPool` before octo-cli 3.5.0), and deploys the adapter (`octo-cli -c DeployWorkload`).
  The Studio OIDC client is blueprint-seeded from `services.studio.publicUri` —
  there is no manual client-registration script anymore.
* **S3 store (AB#5967, AB#5490).** The archive part of a tenant dump uses CrateDB `COPY TO` /
  `COPY FROM`, which need a location that CrateDB and the bot can both reach. `om-install.ps1` adds
  SeaweedFS 4.48 (`weed mini`) to `octo-infra` (`kubernetes/infra/s3-store.yaml`, StatefulSet
  `seaweedfs`, 20 Gi PVC, bucket `octo-artifacts`, memory limit 4 Gi with
  `-s3.readerCacheSizeMB=256` and `GOMEMLIMIT=2560MiB`: a multi-GB read otherwise grows the Go heap
  past 1 GiB). Two endpoints: in the cluster `http://seaweedfs.octo-infra:8333` (bot and CrateDB; in a
  statement `s3://<key>:<secret>@seaweedfs.octo-infra:8333/octo-artifacts/<prefix>/` with
  `WITH (protocol = 'http')`), from the host `http://localhost:8333` (kind mapping 30333 -> 8333).
  The credential (hex, no `:`) is generated at install time into the Secret `octo-infra/seaweedfs-s3`
  and copied for the bot into `octo/octo-artifact-s3`; it is never written to a file or printed.
  Anonymous requests are refused. The bot gets the S3 provider through
  `kubernetes/values/bot-s3-values.yaml` (chart `services.bot.artifactStorage`), plus
  `OCTO_ARTIFACTSTORAGE__S3__CRATEDBSERVICEURL` (the endpoint under which CrateDB reaches the store;
  `om-install.ps1` sets it on the bot deployment). **Job log filter:** CrateDB records every statement with its text in
  `sys.jobs_log`, which for a `COPY` includes the S3 key; `om-install.ps1` sets the persistent cluster
  setting `stats.jobs_log_filter = 'stmt NOT ILIKE ''copy %'''` before the store is usable. `om-status.ps1`
  checks, without printing a key: pod ready; host answers (anonymous refused, signed list works); the
  CrateDB pod reaches the cluster name; the filter is active; a `COPY TO` of a three-row probe table
  (schema `octo_check`, dropped again) runs on the CrateDB node into the store, its objects are visible
  through the host port, and neither it nor a canary-key `COPY` appears in `sys.jobs_log` while an ordinary
  statement does (`-SkipS3Probe` leaves out the probe). The helpers live in `scripts/om-s3-lib.ps1`.
  Objects and the filter survive `om-stop.ps1` / `om-start.ps1`; they die with `om-uninstall.ps1`.
  `-SkipS3Store` leaves the whole thing out (the bot then keeps its built-in storage, the archive dump
  uses the row path). Garage is the second candidate for the store and is not built.
* Generated local state (gitignored): `scripts/kubernetes/.generated/` (signing key
  PFX, root CA certificate, Mongo keyfile, operator webhook certs),
  `scripts/kubernetes/local-config.json` (chart version).

## Key constraints

* Everything must work for EXTERNAL users: public charts, public Docker Hub images,
  release versions only. Never reference docker.mm.cloud or main-latest tags.
* Scripts are standalone — no octo-tools checkout, no monorepo assumptions.
* Service images are multi-arch (amd64/arm64) as of release 3.4.51; releases older
  than 3.4.51 are amd64-only. octo-cli minimum version is 3.5.0.
* Dev-grade default credentials are intentional (quickstart), but nothing generated
  or secret may be committed.
* All artifacts in English. Commit format: `AB#<n> <New/Fix>: <description>`.
