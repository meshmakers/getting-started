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
                 [-ChartVersion X.Y.Z] [-IdentityServerLicenseKey …] [-AutoMapperLicenseKey …]
./om-login-local.ps1 [-tenantId meshtest] [-includeReporting $true]
./om-bootstrap-tenant.ps1 [-TenantId meshtest] [-IncludeSimulation]
./om-status.ps1
./om-stop.ps1 / ./om-start.ps1          # stop/start the kind node container (data preserved)
./om-uninstall.ps1 [-Force] [-KeepCaTrust] [-KeepGeneratedFiles]   # deletes cluster + data
```

## Architecture

* kind cluster `octomesh` (kubectl context `kind-octomesh`), host ports on 127.0.0.1:
  80/443 (ingress), 27017 (Mongo), 5672/15672 (RabbitMQ), 5432/4301 (CrateDB).
* Namespaces: `octo-infra` (Mongo 1-member replica set `rs` + keyfile, RabbitMQ,
  CrateDB single node), `octo` (platform services + operator-deployed adapters),
  `octo-operator-system` (CRDs + Communication Operator), plus ingress-nginx and
  cert-manager.
* TLS: cert-manager self-signed root CA (CN "OctoMesh Getting Started Root CA")
  behind ClusterIssuer `mm-cloud-issuer` (same name as managed environments).
* Hostnames: `https://{identity,assets,bots,communication,platform,studio,reporting}.127-0-0-1.nip.io`.
  A CoreDNS rewrite resolves `*.127-0-0-1.nip.io` to ingress-nginx inside the cluster
  (pods fetch JWKS from the public identity URI — without the rewrite they would
  resolve 127.0.0.1 = themselves).
* Charts installed: `octo-mesh-crds` and `octo-mesh-communication-operator`
  (`autoManagePools=true`) in `octo-operator-system`; `octo-mesh` (and
  `octo-mesh-reporting` on the full profile) in `octo`. One consistent chart version
  for everything, selected at install time from the public index.
* `serviceDefaults.environment=production` makes `EnableCommunication` apply the
  Release blueprint variant, which seeds: Pool `670000000000000000000001`,
  MeshAdapter `670000000000000000000002` (chart `octo-mesh-adapter`), and
  HelmRepositoryConfiguration `670000000000000000000004` → https://meshmakers.github.io/charts.
  `om-bootstrap-tenant.ps1` then pins the chart version, deploys the pool
  (`octo-cli -c DeployPool`), and deploys the adapter (`octo-cli -c DeployWorkload`).
  The Studio OIDC client is blueprint-seeded from `services.studio.publicUri` —
  there is no manual client-registration script anymore.
* Generated local state (gitignored): `scripts/kubernetes/.generated/` (signing key
  PFX, root CA, Mongo keyfile, operator webhook certs), `scripts/kubernetes/local-config.json`
  (chart version + license keys).

## Key constraints

* Everything must work for EXTERNAL users: public charts, public Docker Hub images,
  release versions only. Never reference docker.mm.cloud or main-latest tags.
* Scripts are standalone — no octo-tools checkout, no monorepo assumptions.
* Dev-grade default credentials are intentional (quickstart), but nothing generated
  or secret may be committed.
* All artifacts in English. Commit format: `AB#<n> <New/Fix>: <description>`.
