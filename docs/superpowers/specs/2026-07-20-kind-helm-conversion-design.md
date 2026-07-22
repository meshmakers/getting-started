# getting-started: Docker Compose → Helm charts on kind (AB#4417)

**Date:** 2026-07-20
**Work item:** [AB#4417](https://dev.azure.com/meshmakers/OctoMesh/_workitems/edit/4417) — follow-up of AB#4096 (octo-tools local developer infrastructure on kind)
**Status:** Approved design

## 1. Goal

Convert the public getting-started repository (github.com/meshmakers/getting-started) from the
current Docker Compose deployment to the official OctoMesh Helm charts installed into a local
[kind](https://kind.sigs.k8s.io/) cluster, so the quickstart experience mirrors the real cluster
deployment model. The "success in minutes" promise is kept: one documented entry point provisions
the cluster and installs OctoMesh.

The Docker Compose path is **removed** (not deprecated).

### Audience and constraints

- External developers and prospects with no VPN, no internal registry access, no monorepo checkout.
- Everything comes from public sources: Helm charts from `https://meshmakers.github.io/charts`
  (release channel), images from public Docker Hub (`docker.io/meshmakers/*`).
- **Release versions only.** Rolling tags (`main-latest`) exist only on the internal registry and
  are out of scope by construction. The charts release channel publishes a consistent version set
  (chart version and appVersion per index entry, e.g. 3.4.46 / 3.4.46.0).
- Scripts stay standalone PowerShell (pwsh 7.4+) inside the repo — no octo-tools checkout, no
  `installations.json`, no dev-registry concept.

## 2. Decisions (settled with the work item / repo owner)

| Decision | Choice |
|---|---|
| Deployment model | Full platform in-cluster via the published `octo-mesh` chart; infra and operator installed by the bootstrap script (the chart itself ships neither) |
| Adapter rollout | Via the Communication Operator (`autoManagePools=true`), exactly like managed environments — not via direct `helm install` of adapter charts |
| Docker Compose path | Removed entirely, including checked-in TLS certificates and `.env` machinery |
| Infra topology | Single-node: MongoDB as 1-member replica set (keyFile auth), single RabbitMQ, single-node CrateDB |
| Hostname scheme | nip.io: `https://{identity,assets,bots,communication,platform,studio,reporting}.127-0-0-1.nip.io` — resolves to 127.0.0.1 without hosts-file edits |
| TLS | cert-manager with a self-signed local root CA behind ClusterIssuer `mm-cloud-issuer` (name kept identical to managed environments so values stay portable); OS trust of the CA is a recommended, skippable step |
| Deployment profiles | Kept: `core` \| `full` (full adds Refinery Studio + Reporting), plus `-IncludeSimulation` for the simulation adapter |
| Version selection | Interactive picker in `om-install.ps1`, listing release versions scraped from the public charts index (same UX as today), defaulting to the latest |
| IoT example | Lives in a separate repository; adapting it is a follow-up, out of scope here |

## 3. Architecture

### 3.1 Cluster layout

- kind cluster named `octomesh` (distinct from the octo-tools dev cluster `kind`). The installer
  refuses to proceed with a clear message when the required host ports are already bound (e.g. by
  the octo-tools kind cluster or a leftover compose stack).
- `extraPortMappings` (loopback only): 80/443 → ingress-nginx NodePorts; 27017 (MongoDB),
  5672/15672 (RabbitMQ), 5432/4301 (CrateDB) for direct tool access (mongosh, crash, AMQP tools).
- Namespaces: `octo-infra` (infrastructure), `octo` (platform services and adapter workloads),
  `octo-operator-system` (CRDs + operator), plus the ingress-nginx and cert-manager namespaces.
- Infrastructure manifests (adapted from octo-tools/kubernetes, single-node variants):
  - MongoDB StatefulSet, `mongo:8.x`, 1-member replica set `rs` with keyFile auth (keyfile
    generated at install time into a Kubernetes secret), init scripts create the replica set and
    the admin user (`octo-system-admin` / dev default password).
  - RabbitMQ Deployment with management UI.
  - CrateDB StatefulSet, single node (`discovery.type=single-node`), `vm.max_map_count` init
    container.
- ingress-nginx and cert-manager installed from their public Helm repos at pinned versions
  (matching octo-tools: ingress-nginx 4.15.1, cert-manager v1.20.2).
- Certificate chain: self-signed bootstrap issuer → local root CA certificate → CA ClusterIssuer
  `mm-cloud-issuer`. The CA is exported to a local file; `om-install.ps1` offers to add it to the
  OS trust store (macOS keychain / Windows cert store / Linux ca-certificates), skippable via
  `-SkipTrustCa`. Without trust everything works, browsers just warn.

### 3.2 DNS: the JWKS problem and its fix

Pods validate JWTs against the **public** identity URI (JWKS fetch from inside the pod): the
`octo-mesh` chart hard-wires every service's authority to `services.identity.publicUri`
(`_env.tpl`, no internal override), which is correct — the token issuer URL must be identical
everywhere. On managed environments public DNS resolves that URI to the ingress; on kind, nip.io
names resolve to 127.0.0.1, which inside a pod is the pod itself. Fix: a CoreDNS rewrite rule that
resolves `*.127-0-0-1.nip.io` to the ingress-nginx controller service inside the cluster.

Note: the octo-tools kind setup needs no counterpart mechanism because there identity and all
platform services run as host processes — no pod ever fetches JWKS (adapters authenticate through
the Communication Controller, reached via the Docker host-gateway). The problem only appears once
the platform services move in-cluster, which is exactly this conversion. Combined
with the chart's `secrets.rootCa` init-container mechanism (which splices the local CA into every
pod's trust bundle — the documented pattern used on test-2), in-cluster OIDC/JWKS works against the
same URLs the browser uses.

Known limitation to document: some routers/corporate DNS servers block DNS rebinding (public names
resolving to loopback). Documented fallback: hosts-file entries for the service hostnames.

### 3.3 Helm installs (all charts from https://meshmakers.github.io/charts)

| Order | Chart | Key values |
|---|---|---|
| 1 | `octo-mesh-crds` | — |
| 2 | `octo-mesh` | per-service `publicUri` on nip.io hosts; `secrets.rootCa` = local CA; signing key PFX via `--set-file services.identity.signingKey.key` (generated locally with openssl, never committed); dev-default secrets (databaseUser/databaseAdmin/rabbitmq/streamDataPassword); Duende + AutoMapper license keys (prompted); `services.studio.deploy=true` for `full`; `streamDataEnabled=true`; `clusterDependencies` pointed at the octo-infra service DNS names; ingress annotated with `mm-cloud-issuer` |
| 3 | `octo-mesh-reporting` (`full` profile only) | analogous, own publicUri |
| 4 | `octo-mesh-communication-operator` | `operator.autoManagePools=true`, default pool in namespace `octo`; `communicationControllerUri` pointing at the in-cluster communication-controller service; webhook certificates generated during install; `operator.imageRegistry` empty (workloads pull from Docker Hub); ingress defaults with `mm-cloud-issuer` projected into workloads; dummy `streamDataPassword` because adapter charts require it |

Chart version and image tag (appVersion) come from the same release-index entry, so the installed
set is consistent by construction. The operator's bundled `octo-mesh-crds` dependency is disabled —
CRDs are installed explicitly in step 1.

### 3.4 Adapter rollout (managed-environment fidelity)

Adapters (mesh adapter; simulation adapter when `-IncludeSimulation` is set) are deployed by the
Communication Operator through the default pool — not installed directly by the script. The
post-install tenant bootstrap (octo-cli: create tenant, enable communication, pool/adapter setup)
follows the same sequence as managed environments; the exact CLI steps are verified during
implementation and written into the README. Adapter charts are resolved from the public chart repo
via the tenant's Helm repository configuration.

## 4. Repository layout after conversion

```
getting-started/
  README.md                            # rewritten for the kind flow
  CLAUDE.md                            # rewritten for the kind flow
  LICENSE
  scripts/
    om-install.ps1                     # single entry point: kind + infra + ingress/TLS + helm + operator
    om-start.ps1                       # docker start of the kind node container (data preserved)
    om-stop.ps1                        # docker stop of the kind node container (data preserved)
    om-status.ps1                      # NEW: pods, helm releases, service URLs, host-port checks
    om-uninstall.ps1                   # kind delete cluster + CA untrust; interactive data-loss warning
    om-login-local.ps1                 # octo-cli config/login against the nip.io URLs
    om-setupIdentityService-local.ps1  # Studio OIDC client registration (nip.io redirect URIs)
    kubernetes/
      kind-cluster.yaml
      namespaces.yaml
      cluster-issuer.yaml
      coredns-rewrite.yaml
      cert-manager-values.yaml
      ingress-nginx-values.yaml
      infra/mongodb.yaml
      infra/rabbitmq.yaml
      infra/cratedb.yaml
      infra/mongo-init/init-replicaset.js
      infra/mongo-init/create-admin-user.js
      values/octo-mesh-values.yaml     # static values; dynamic ones passed via --set/--set-file
      values/operator-values.yaml
      values/reporting-values.yaml
```

**Removed:** `scripts/octo-mesh/` entirely — `docker-compose.yml`, `.env`, `.env.local.example`,
all checked-in certificates (`IdentityServer4Auth.*`, `localhost_cert.*`, `file.key`,
`openssl.cnf`), and the compose-mounted mongo scripts. Locally generated artifacts (signing-key
PFX, exported CA, keyfile, prompted license keys) live in a gitignored directory.

### Script behavior details

- `om-install.ps1 [-DeploymentProfile core|full] [-IncludeSimulation] [-SkipTrustCa]`
  - Preflight: pwsh version, docker daemon running, kind/kubectl/helm/openssl/octo-cli on PATH,
    required host ports free (clear refusal message naming the likely occupant).
  - Interactive prompts (only for values without defaults): OctoMesh release version, Duende
    IdentityServer license key (masked), AutoMapper license key (masked).
  - Idempotent where cheap: re-running against an existing `octomesh` cluster re-applies manifests
    and helm upgrades rather than failing; mongo init scripts tolerate already-initialized state.
- `om-start.ps1` / `om-stop.ps1`: start/stop the kind node container. PVC data (local-path inside
  the node container) survives stop/start; only `om-uninstall.ps1` destroys it.
- `om-uninstall.ps1`: interactive "yes" confirmation with an explicit data-loss warning
  (`kind delete cluster` destroys MongoDB/CrateDB volumes), then removes the CA from the OS trust
  store (skippable), and cleans generated local files on request.
- `om-status.ps1`: pod status per namespace, `helm list`, the service URL table, and TCP checks on
  the mapped host ports.
- All scripts: standalone, paths relative to the script location, English output, non-zero exit on
  failure.

## 5. Documentation changes

- `README.md`: rewritten — prerequisites (Docker, kind, kubectl, helm, pwsh, openssl, octo-cli),
  quickstart walkthrough, service URL table (nip.io hosts), profiles, simulation option, update and
  uninstall, troubleshooting (DNS rebind protection, Docker Hub rate limits, Apple Silicon/Rosetta,
  CA trust).
- `CLAUDE.md`: rewritten in lockstep with the README.
- octo-documentation (separate repo, same change set): rewrite
  `docs/technologyGuide/gettingStartedLocally/intro.md` ("Run OctoMesh on a local kind cluster")
  and `prerequisites.md`. The inbound link from `docs/technologyGuide/tools/octo-cli/intro.md`
  stays valid. OctoMesh.wiki needs no changes (verified).

## 6. Error handling

- Preflight failures (missing tools, busy ports, docker down) abort before any mutation, with
  actionable messages including install hints per OS.
- Helm/kubectl steps fail fast (`$ErrorActionPreference = 'Stop'` semantics); the script reports
  which phase failed and that re-running `om-install.ps1` resumes/repairs (idempotent steps).
- Rollout waits with generous timeouts and a pointer to `om-status.ps1` plus
  `kubectl logs`/`kubectl describe` hints on timeout.
- Mongo init handles transient replica-set startup errors with retries and treats
  "already initialized"/"already exists" as success (same error-code allowlist as octo-tools).

## 7. Acceptance criteria (from AB#4417) and how the design meets them

| Criterion | How |
|---|---|
| Documented single entry point provisions kind and installs OctoMesh via Helm | `om-install.ps1` + rewritten README |
| Included examples work against the kind deployment | Simulation adapter flow via operator (`-IncludeSimulation`); the IoT example lives in a separate repo and is fixed in a follow-up (agreed with WI owner) |
| Docker Compose path removed or clearly deprecated | Removed entirely |
| All scripts respect the new deployment model | All `om-*.ps1` rewritten or adapted; no compose remnants |

## 8. Testing / verification plan

Ordered so the riskiest assumptions are verified before script polish:

1. **Spike (before building out scripts):** on Apple Silicon, pull and run the amd64 service images
   in a kind cluster (Rosetta path) — this decides whether the flow works on ARM Macs at all.
2. **TLS/DNS end-to-end:** CoreDNS rewrite + rootCa + nip.io ingress → identity discovery document
   and JWKS reachable from inside a pod; Studio OIDC login round-trip in the browser.
3. **Full `core` install** from a clean machine state: `om-install.ps1` → admin user → login →
   tenant bootstrap → operator deploys the mesh adapter → a trivial dataflow runs.
4. **`full` profile:** Studio + Reporting reachable and licensed; OIDC client registration script.
5. **`-IncludeSimulation`:** simulation adapter deployed by the operator, sample data visible.
6. **Lifecycle:** om-stop/om-start preserves data; om-uninstall destroys and cleans; re-running
   om-install after uninstall works; re-running om-install over a live cluster is idempotent.
7. **License-key question:** verify whether empty keys are viable at runtime (affects whether the
   prompts stay mandatory).
8. Windows 11 and Linux validation of the OS-specific steps (CA trust, prerequisites), reusing the
   documented octo-tools platform notes.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| amd64-only service images on Apple Silicon kind | Spike first (verification step 1); document Docker Desktop Rosetta requirement; multi-arch images are a platform-side follow-up (operator is already multi-arch) |
| DNS rebind protection breaks nip.io on some networks | Documented hosts-file fallback |
| Docker Hub anonymous pull rate limits (~10 images) | Document `docker login` recommendation |
| Operator↔controller in-cluster path untested (octo-tools uses the host-gateway detour) | Verified in verification step 3; in-cluster service URI removes the host-gateway machinery entirely |
| Chart friction on kind (always-emitted TLS block, dead `ingress.tls` value) | Work with annotations + `mm-cloud-issuer`; file platform-side issues if chart changes are needed |
| Resource footprint on small machines | Single-node infra; document minimum Docker resources (CPU/RAM) measured during verification step 3 |

## 10. Out of scope

- The IoT example repository (separate follow-up).
- Changes to octo-tools, the developer-shell docs (`developerGuide/developerShell/*`), or the
  compose-based developer infrastructure there.
- Multi-arch (arm64) image publishing for the platform services (platform-side CI change).
- Staging/production deployment topics; managed-environment installers.
- Chart changes in octo-helm-core (only filed as issues if the kind flow uncovers hard blockers).
