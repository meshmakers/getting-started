# getting-started: Helm-on-kind Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the getting-started repo's Docker Compose deployment with the official OctoMesh Helm charts installed into a local kind cluster (AB#4417), keeping the "success in minutes" quickstart promise.

**Architecture:** A rewritten `om-install.ps1` provisions a kind cluster named `octomesh` (infra manifests adapted from octo-tools, single-node Mongo/RabbitMQ/CrateDB), installs ingress-nginx + cert-manager with a local self-signed root CA (`mm-cloud-issuer`), adds a CoreDNS rewrite so `*.127-0-0-1.nip.io` resolves to ingress from inside pods (JWKS), then installs the published `octo-mesh` chart (all services in-cluster, nip.io publicUris) and the Communication Operator (`autoManagePools=true`). A new `om-bootstrap-tenant.ps1` creates the tenant, enables communication (blueprints seed pool/adapter/chart-repo), and deploys pool + mesh adapter via octo-cli — which requires a small new `DeployPool` command in octo-sdk + octo-cli.

**Tech Stack:** PowerShell 7.4+, kind v0.31+, kubectl, helm v3, openssl, octo-cli, published charts from `https://meshmakers.github.io/charts` (release channel only), images from public Docker Hub `docker.io/meshmakers/*`.

**Spec:** `docs/superpowers/specs/2026-07-20-kind-helm-conversion-design.md` (approved). One deviation agreed during planning: `om-setupIdentityService-local.ps1` is **deleted, not adapted** — the `System.Identity.Bootstrap` blueprint seeds the `octo-data-refinery-studio` OIDC client from `services.studio.publicUri` automatically, so a manual client-registration script is obsolete. `-IncludeSimulation` moves from `om-install.ps1` to `om-bootstrap-tenant.ps1` (the simulation adapter is a tenant-level workload in the operator model).

## Global Constraints

- All artifacts (code, comments, docs, commit messages, CLI output) in **English**.
- Commit message format: `AB#4417 <New/Fix>: <description>`.
- Branches: `feat/reimar/kind-helm-conversion` (getting-started, already exists; octo-documentation: create it), `feat/reimar/ab4417-deploypool` (octo-sdk, octo-cli).
- Git in sub-repos ONLY via `git -C <repo>` from `/Users/reimar/dev/meshmakers/branches/main` — never `cd`.
- .NET builds use `-c DebugL`. After the octo-sdk change, build downstream with `Invoke-BuildAll` (octo-devtools wrapper), never single-repo `Invoke-Build` — single-repo builds do not refresh `../nuget`.
- Release-channel artifacts only: charts from `https://meshmakers.github.io/charts`, image tags = chart appVersion (e.g. `3.4.46.0`), chart versions 3-segment (e.g. `3.4.46`). Never reference `main-latest` or `docker.mm.cloud`.
- Host ports (loopback only): 80, 443, 27017, 5672, 15672, 5432, 4301. kind cluster name `octomesh` (kubectl context `kind-octomesh`).
- Hostname scheme: `https://{identity,assets,bots,communication,platform,studio,reporting}.127-0-0-1.nip.io`. Domain for blueprint URL composition and `{{domain.default}}`: `127-0-0-1.nip.io`.
- Root CA CN: `OctoMesh Getting Started Root CA` (NOT "OctoMesh Local Dev Root CA" — that CN belongs to the octo-tools dev cluster; sharing it would make CA-untrust delete the wrong cert).
- Dev default secrets (same tier as today's compose): Mongo admin `octo-system-admin`/`OctoAdmin1`, Mongo user password `OctoUser1`, RabbitMQ `guest`/`guest`, streamData dummy `OctoStream1`, signing-key PFX password `Secret01`.
- Generated local files go to `scripts/kubernetes/.generated/` (gitignored); user config to `scripts/kubernetes/local-config.json` (gitignored). Never commit certificates, keys, or license keys.
- Well-known blueprint-seeded rtIds (created by `EnableCommunication` with `serviceDefaults.environment=production`): Pool `670000000000000000000001`, MeshAdapter `670000000000000000000002`, HelmRepositoryConfiguration `670000000000000000000004` (→ `https://meshmakers.github.io/charts`).
- Verification runs happen on this machine (Docker Desktop on Apple Silicon). Docker must be running. Do not start the octo-tools kind cluster or compose infra at the same time (port collision).

---

### Task 1: Spike — amd64 service image runs in kind on Apple Silicon

The service images (except the operator) are amd64-only. On Apple Silicon, kind nodes are arm64 containers; amd64 pods only work when Docker Desktop's Rosetta emulation applies inside the node. If this fails, the whole conversion needs a platform-side CI change first — verify before writing any script code.

**Files:** none (throwaway cluster; result recorded in the task report).

**Interfaces:**
- Consumes: nothing.
- Produces: go/no-go decision for all later tasks; the observed pull+start timing for the README's minimum-requirements note.

- [ ] **Step 1: Create a throwaway kind cluster**

Run:
```bash
kind create cluster --name spike-amd64
```
Expected: `Ready` control-plane; `kubectl --context kind-spike-amd64 get nodes` shows the node.

- [ ] **Step 2: Run an amd64-only OctoMesh image**

The identity service needs config to fully start; for the spike it only matters that the binary executes (not `exec format error` / `no match for platform`). Run:
```bash
kubectl --context kind-spike-amd64 run spike --image=meshmakers/octo-mesh-identity-services:3.4.46.0 --restart=Never
sleep 90
kubectl --context kind-spike-amd64 get pod spike
kubectl --context kind-spike-amd64 logs spike --tail=20
```
Expected PASS: pod reaches `Running`, `Error`, or `CrashLoopBackOff` **with .NET startup output or a configuration exception in the logs** (the app executed).
Expected FAIL (abort criterion): image pull error `no matching manifest for linux/arm64`, or logs/events showing `exec format error`. If FAIL: stop, report — the plan is blocked on multi-arch image publishing (platform-side CI change, out of scope).

- [ ] **Step 3: Tear down and record**

Run:
```bash
kind delete cluster --name spike-amd64
```
Record in the task report: PASS/FAIL, pull duration, and whether Rosetta is enabled in Docker Desktop (`Settings → General → Use Rosetta`).

---

### Task 2: octo-sdk — `DeployPoolAsync` on the communication services client

Pool deploy currently has no SDK/CLI surface (Studio calls `POST {tenantId}/v1/pool/deploy?poolRtId=…` directly). The bootstrap script needs it scriptable.

**Files:**
- Modify: `octo-sdk/src/Sdk.ServiceClient/CommunicationControllerServices/ICommunicationServicesClient.cs` (near line 142, next to `GetPoolsAsync`)
- Modify: `octo-sdk/src/Sdk.ServiceClient/CommunicationControllerServices/CommunicationServicesClient.cs` (near line 415, next to `DeployWorkloadAsync`)

**Interfaces:**
- Consumes: existing `RestRequest`/`ValidateResponse` plumbing in `CommunicationServicesClient` (same as `DeployWorkloadAsync`).
- Produces: `Task DeployPoolAsync(string poolRtId)` on `ICommunicationServicesClient` — consumed by Task 3.

- [ ] **Step 1: Create the branch**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-sdk checkout -b feat/reimar/ab4417-deploypool
```

- [ ] **Step 2: Add the interface method**

In `ICommunicationServicesClient.cs`, directly after the `GetPoolsAsync()` declaration, add (match the XML-doc style of the surrounding members):

```csharp
/// <summary>
///     Triggers a deploy of a pool. The central Communication Operator reacts by
///     creating the CommunicationPool custom resource and registering the pool.
///     Workloads are NOT deployed by this call — use <see cref="DeployWorkloadAsync"/>.
/// </summary>
/// <param name="poolRtId">The pool's runtime object ID.</param>
Task DeployPoolAsync(string poolRtId);
```

- [ ] **Step 3: Add the implementation**

In `CommunicationServicesClient.cs`, directly before `DeployWorkloadAsync`, add:

```csharp
/// <inheritdoc />
public async Task DeployPoolAsync(string poolRtId)
{
    ArgumentValidation.ValidateString(nameof(poolRtId), poolRtId);

    var request = new RestRequest("pool/deploy", Method.Post);
    request.AddQueryParameter("poolRtId", poolRtId);

    var response = await Client.ExecuteAsync(request);
    ValidateResponse(response);
}
```

- [ ] **Step 4: Check for existing client tests and mirror them**

Run:
```bash
grep -rn "DeployWorkloadAsync" /Users/reimar/dev/meshmakers/branches/main/octo-sdk/tests --include="*.cs" -l
```
If this finds test files: add an equivalent `DeployPoolAsync` test mirroring the `DeployWorkloadAsync` test in the same file (same mock/assert pattern, path `pool/deploy`, query `poolRtId`). If it finds nothing (no HTTP-level tests exist for this client), compile-level verification in Step 5 is the gate — do not invent a new test harness.

- [ ] **Step 5: Build octo-sdk**

Run:
```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-sdk && dotnet build -c DebugL
```
Expected: Build succeeded, 0 errors (warnings are errors in this codebase — the build fails on any).

- [ ] **Step 6: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-sdk add -A
git -C /Users/reimar/dev/meshmakers/branches/main/octo-sdk commit -m "AB#4417 New: Add DeployPoolAsync to communication services client"
```

---

### Task 3: octo-cli — `DeployPool` command

**Files:**
- Create: `octo-cli/src/ManagementTool/Commands/Implementations/Communication/DeployPoolCommand.cs`
- Modify: `octo-cli/src/ManagementTool/Program.cs` (command registration — one line next to `DeployWorkloadCommand`)
- Modify: `octo-cli/CLAUDE.md` (Pools command table)

**Interfaces:**
- Consumes: `ICommunicationServicesClient.DeployPoolAsync(string)` from Task 2 (via the DebugL NuGet propagated by `Invoke-BuildAll`).
- Produces: CLI verb `DeployPool` with argument `-id <poolRtId>` — consumed by `om-bootstrap-tenant.ps1` (Task 7). Note for the release train: external users get this only with the **next released octo-cli**; the getting-started README (Task 10) states the minimum octo-cli version.

- [ ] **Step 1: Create the branch**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-cli checkout -b feat/reimar/ab4417-deploypool
```

- [ ] **Step 2: Propagate the SDK change**

Build octo-sdk and downstream consumers so `../nuget` has the new 999.0.0 client package. Use the octo-devtools wrapper (do NOT chain manual builds):
```bash
bash "/Users/reimar/.claude/plugins/cache/octo-claude-skills/octo-claude-skills/0.19.2/skills/octo-devtools/scripts/run_pwsh.sh" 'Invoke-BuildAll -configuration DebugL -excludeFrontend $true -excludeAdditional $true'
```
Expected: all core repos green. (This also rebuilds octo-sdk from the branch created in Task 2 — the workspace checkout is shared.)

- [ ] **Step 3: Write the command class**

Create `DeployPoolCommand.cs` with exactly this content (mirrors `DeployWorkloadCommand.cs` in the same folder):

```csharp
using Meshmakers.Common.CommandLineParser;
using Meshmakers.Octo.Frontend.ManagementTool.Services;
using Meshmakers.Octo.Sdk.ServiceClient.CommunicationControllerServices;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Meshmakers.Octo.Frontend.ManagementTool.Commands.Implementations.Communication;

internal class DeployPoolCommand : ServiceClientOctoCommand<ICommunicationServicesClient>
{
    private readonly IArgument _poolRtId;

    public DeployPoolCommand(ILogger<DeployPoolCommand> logger, IOptions<OctoToolOptions> options,
        ICommunicationServicesClient communicationServicesClient, IAuthenticationService authenticationService)
        : base(logger, Constants.CommunicationServicesGroup, "DeployPool",
            "Triggers a deploy of a pool. The Communication Operator creates the pool resources; workloads are deployed separately via DeployWorkload.",
            options, communicationServicesClient, authenticationService)
    {
        _poolRtId = CommandArgumentValue.AddArgument("id", "poolRtId",
            ["The pool's runtime object ID"], true, 1);
    }

    public override async Task Execute()
    {
        var poolRtId = CommandArgumentValue.GetArgumentScalarValue<string>(_poolRtId);

        Logger.LogInformation(
            "Deploying pool '{PoolRtId}' for tenant '{TenantId}' at '{ServiceClientServiceUri}'",
            poolRtId, Options.Value.TenantId, ServiceClient.ServiceUri);

        await ServiceClient.DeployPoolAsync(poolRtId);

        Logger.LogInformation("Pool '{PoolRtId}' deploy triggered", poolRtId);
    }
}
```

- [ ] **Step 4: Register the command**

Run `grep -n "DeployWorkloadCommand" /Users/reimar/dev/meshmakers/branches/main/octo-cli/src/ManagementTool/Program.cs` to find the registration line, and add the identical registration for `DeployPoolCommand` directly next to it (same DI method, same generic pattern — copy the neighboring line and change the type name).

- [ ] **Step 5: Build and smoke-test help output**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-cli && dotnet build Octo.Cli.sln -c DebugL
dotnet run --project src/ManagementTool/ManagementTool.csproj -c DebugL -- -c DeployPool --help
```
Expected: build green; help text shows `DeployPool` with the `-id/--poolRtId` argument. (Command docs are generated from the class itself — no sidecar docs file.)

- [ ] **Step 6: Run octo-cli tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-cli && dotnet test Octo.Cli.sln -c DebugL
```
Expected: all tests pass. If a failure appears, root-cause it — do not dismiss it as pre-existing.

- [ ] **Step 7: Update CLAUDE.md Pools table and commit**

In `octo-cli/CLAUDE.md`, extend the Pools table:
```markdown
| `DeployPool` | `-id <poolRtId>` | Trigger pool deploy (operator creates the CommunicationPool CR); workloads deploy separately |
```

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-cli add -A
git -C /Users/reimar/dev/meshmakers/branches/main/octo-cli commit -m "AB#4417 New: Add DeployPool command"
```

---

### Task 4: getting-started — kubernetes/ static manifests

**Files (all Create, in `getting-started/`):**
- `scripts/kubernetes/kind-cluster.yaml`
- `scripts/kubernetes/namespaces.yaml`
- `scripts/kubernetes/cluster-issuer.yaml`
- `scripts/kubernetes/cert-manager-values.yaml`
- `scripts/kubernetes/ingress-nginx-values.yaml`
- `scripts/kubernetes/infra/mongodb.yaml`
- `scripts/kubernetes/infra/rabbitmq.yaml`
- `scripts/kubernetes/infra/cratedb.yaml`
- `scripts/kubernetes/infra/mongo-init/init-replicaset.js`
- `scripts/kubernetes/infra/mongo-init/create-admin-user.js`
- `scripts/kubernetes/values/octo-mesh-values.yaml`
- `scripts/kubernetes/values/operator-values.yaml`
- `scripts/kubernetes/values/reporting-values.yaml`
- Modify: `.gitignore` (add generated-dir rules)

**Interfaces:**
- Consumes: nothing (static files; adapted from `octo-tools/kubernetes/` with these deltas: cluster name `octomesh`, no containerd registry patches, CA CN `OctoMesh Getting Started Root CA`).
- Produces: file paths + namespace names (`octo-infra`, `octo`, `octo-operator-system`) + in-cluster DNS names (`mongodb-0.mongodb.octo-infra.svc.cluster.local:27017`, `rabbitmq.octo-infra.svc.cluster.local`, `cratedb.octo-infra.svc.cluster.local`) + ClusterIssuer `mm-cloud-issuer` — consumed by Tasks 5–7. Values files consumed by Task 6.

- [ ] **Step 1: Write kind-cluster.yaml**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: octomesh
nodes:
  - role: control-plane
    # listenAddress 127.0.0.1 binds the host ports on loopback only: the platform is
    # reachable from this machine but never exposed to the LAN (dev credentials).
    extraPortMappings:
      - { containerPort: 30017, hostPort: 27017, listenAddress: "127.0.0.1", protocol: TCP }  # mongodb
      - { containerPort: 30672, hostPort: 5672,  listenAddress: "127.0.0.1", protocol: TCP }  # rabbitmq amqp
      - { containerPort: 31672, hostPort: 15672, listenAddress: "127.0.0.1", protocol: TCP }  # rabbitmq mgmt
      - { containerPort: 30543, hostPort: 5432,  listenAddress: "127.0.0.1", protocol: TCP }  # cratedb psql
      - { containerPort: 30420, hostPort: 4301,  listenAddress: "127.0.0.1", protocol: TCP }  # cratedb http
      - { containerPort: 30080, hostPort: 80,   listenAddress: "127.0.0.1", protocol: TCP }  # ingress-nginx http
      - { containerPort: 30443, hostPort: 443,  listenAddress: "127.0.0.1", protocol: TCP }  # ingress-nginx https
```

- [ ] **Step 2: Copy namespaces, cert-manager values, ingress-nginx values, infra manifests, mongo-init scripts**

Copy these files verbatim from `/Users/reimar/dev/meshmakers/octo-tools/kubernetes/` (they are already single-node and reusable — see the spec):
- `namespaces.yaml` → `scripts/kubernetes/namespaces.yaml` (unchanged: octo-infra, octo, octo-operator-system)
- `cert-manager-values.yaml` → unchanged (`crds.enabled: true`, `replicaCount: 1`)
- `ingress-nginx-values.yaml` → unchanged (NodePort 30080/30443, class `nginx`, default class)
- `infra/mongodb.yaml`, `infra/rabbitmq.yaml`, `infra/cratedb.yaml` → unchanged (StatefulSet mongo:8.0.12 1-member RS `rs` with keyFile; rabbitmq:4.0.6-management guest/guest; crate:5.10.10 single-node with sysctl init)
- `infra/mongo-init/init-replicaset.js`, `infra/mongo-init/create-admin-user.js` → unchanged (idempotent; RS member host `mongodb-0.mongodb.octo-infra.svc.cluster.local:27017`; admin `octo-system-admin`/`OctoAdmin1`)

- [ ] **Step 3: Write cluster-issuer.yaml (changed CN!)**

Same structure as octo-tools but with the getting-started CN:

```yaml
# Local self-signed root CA fronted by a CA ClusterIssuer named exactly as the
# managed environments (mm-cloud-issuer), so chart values stay portable.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-root-ca
  namespace: cert-manager
spec:
  isCA: true
  # Distinct CN so trust/untrust never collides with the octo-tools dev cluster CA.
  commonName: OctoMesh Getting Started Root CA
  secretName: local-root-ca-tls
  duration: 87600h          # 10 years
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: mm-cloud-issuer
spec:
  ca:
    secretName: local-root-ca-tls
```

- [ ] **Step 4: Write values/octo-mesh-values.yaml**

Static chart values; dynamic values (license keys, secrets, signing key, rootCa, studio deploy flag) are passed at install time by `om-install.ps1`:

```yaml
# Static values for the published octo-mesh chart (https://meshmakers.github.io/charts).
# Dynamic values (license keys, passwords, signing key, root CA, studio deploy flag)
# are passed by om-install.ps1 at install time.

serviceDefaults:
  # "production" selects the Release variant of the service-managed blueprints:
  # EnableCommunication then seeds the pool, the mesh adapter, and the
  # HelmRepositoryConfiguration pointing at the PUBLIC release chart repo.
  environment: "production"

clusterDependencies:
  mongodbHost: "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017"
  mongodbReplicaSet: "rs"
  rabbitMqHost: "rabbitmq.octo-infra.svc.cluster.local"
  rabbitMqUser: "guest"
  streamDataHost: "cratedb.octo-infra.svc.cluster.local"
  streamDataUser: "crate"
  streamDataEnabled: true

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: mm-cloud-issuer

services:
  identity:
    publicUri: "https://identity.127-0-0-1.nip.io"
  assetRepository:
    publicUri: "https://assets.127-0-0-1.nip.io"
  bot:
    publicUri: "https://bots.127-0-0-1.nip.io"
  communication:
    publicUri: "https://communication.127-0-0-1.nip.io"
    domains:
      # Resolves the {{domain.default}} template in blueprint-seeded workload
      # hostnames (mesh adapter -> adapter.127-0-0-1.nip.io).
      default: "127-0-0-1.nip.io"
  platformServices:
    publicUri: "https://platform.127-0-0-1.nip.io"
  studio:
    # deploy flag is set by om-install.ps1 (-DeploymentProfile full).
    # publicUri is always set: the identity blueprint seeds the Studio OIDC
    # client from it, so the client is correct the moment studio is deployed.
    publicUri: "https://studio.127-0-0-1.nip.io"
```

- [ ] **Step 5: Write values/operator-values.yaml**

```yaml
# Static values for the published octo-mesh-communication-operator chart.
# Webhook certificates and the root CA are passed by om-install.ps1 via --set-file.

# CRDs are installed as a separate chart (octo-mesh-crds) before the platform.
octo-mesh-crds:
  enabled: false

operator:
  # Central mode: the operator owns pool CRs and helm-installs adapter workloads.
  autoManagePools: true
  poolNamespace: octo
  defaultPoolName: default
  # In-cluster route to the controller goes through the public URI: CoreDNS
  # rewrites *.127-0-0-1.nip.io to ingress-nginx, and the root CA (secrets.rootCa)
  # makes the operator trust the local certificate.
  communicationControllerUri: "https://communication.127-0-0-1.nip.io"
  adapterIgnoreCertificateValidation: false
  # Empty registry: workload images are pulled from public Docker Hub.
  imageRegistry: ""
  clusterDependencies:
    mongodbHost: "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017"
    mongodbReplicaSet: "rs"
    rabbitMqHost: "rabbitmq.octo-infra.svc.cluster.local"
    rabbitMqUser: "guest"
    streamDataHost: "cratedb.octo-infra.svc.cluster.local"
    streamDataUser: "crate"
  clusterSecrets:
    mongodbUserPassword: "OctoUser1"
    mongodbAdminPassword: "OctoAdmin1"
    # CrateDB runs auth-less locally, but adapter charts require the secret.
    streamDataPassword: "OctoStream1"
  # Ingress defaults projected into every operator-deployed workload.
  ingress:
    className: nginx
    clusterIssuer: mm-cloud-issuer
    tls: true

broker:
  host: "rabbitmq.octo-infra.svc.cluster.local"
  username: "guest"
  password: "guest"

# The operator forks the helm CLI per workload deploy; the default 128Mi limit OOM-kills.
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 256Mi
```

- [ ] **Step 6: Write values/reporting-values.yaml**

```yaml
# Static values for the published octo-mesh-reporting chart (full profile only).
publicUri: "https://reporting.127-0-0-1.nip.io"
authUri: "https://identity.127-0-0-1.nip.io"

clusterDependencies:
  mongodbHost: "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017"
  rabbitMqHost: "rabbitmq.octo-infra.svc.cluster.local"
  rabbitMqUser: "guest"
  streamDataHost: "cratedb.octo-infra.svc.cluster.local"
  streamDataUser: "crate"
  streamDataEnabled: true

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: mm-cloud-issuer
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
```

- [ ] **Step 7: Extend .gitignore**

Append to `getting-started/.gitignore`:
```
# kind/helm deployment — generated local artifacts (certs, keys, CA, config)
scripts/kubernetes/.generated/
scripts/kubernetes/local-config.json
```

- [ ] **Step 8: Validate YAML and commit**

```bash
kind create cluster --name octomesh --config /Users/reimar/dev/meshmakers/branches/main/getting-started/scripts/kubernetes/kind-cluster.yaml
kubectl --context kind-octomesh apply -f /Users/reimar/dev/meshmakers/branches/main/getting-started/scripts/kubernetes/namespaces.yaml
kubectl --context kind-octomesh get ns octo octo-infra octo-operator-system
kind delete cluster --name octomesh
```
Expected: cluster creates, three namespaces `Active`, cluster deletes cleanly. (The values files are validated in Task 6 when helm consumes them.)

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add scripts/kubernetes .gitignore
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Add kind cluster, infra manifests, and chart values for Helm deployment"
```

---

### Task 5: om-install.ps1 — cluster, infra, ingress, CA, CoreDNS

Full rewrite of `om-install.ps1`. This task delivers the script through the infrastructure phase (everything before the OctoMesh helm installs); Task 6 appends the platform phase. The script is idempotent — re-running repairs/continues.

**Files:**
- Modify (full rewrite): `getting-started/scripts/om-install.ps1`

**Interfaces:**
- Consumes: all static files from Task 4 (paths relative to the script: `$PSScriptRoot/kubernetes/...`).
- Produces:
  - `scripts/kubernetes/local-config.json` schema: `{ "chartVersion": "3.4.46", "appVersion": "3.4.46.0", "identityServerLicenseKey": "…", "autoMapperLicenseKey": "…" }`
  - `scripts/kubernetes/.generated/` contents: `file.key` (Mongo keyfile), `local-root-ca.crt` (exported CA)
  - Functions appended to in Task 6: the script ends with a marked `# ---- platform phase (Task 6) ----` region.
  - Param surface (final, includes Task 6 params): `-DeploymentProfile core|full`, `-SkipTrustCa`, `-ChartVersion`, `-IdentityServerLicenseKey`, `-AutoMapperLicenseKey`, `-NonInteractive`.

- [ ] **Step 1: Write the script (infrastructure phase)**

Replace `scripts/om-install.ps1` with:

```powershell
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

    return $allPassed
}

function Test-PortsFree {
    # Only checked while the octomesh cluster does not exist yet — once it runs,
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
    $corefile = kubectl --context $KubeContext -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
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
    kubectl --context $KubeContext -n kube-system rollout restart deployment coredns
    kubectl --context $KubeContext -n kube-system rollout status deployment coredns --timeout=120s
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
```

- [ ] **Step 2: Run the infrastructure phase**

Run (interactive; enter the license keys from the old compose config — they are in `scripts/octo-mesh/.env.local` on this machine):
```powershell
cd /Users/reimar/dev/meshmakers/branches/main/getting-started/scripts && pwsh ./om-install.ps1
```
Expected: prerequisites OK, cluster created, mongodb/rabbitmq/cratedb Ready, `Replica set fully initialized!`, ingress-nginx + cert-manager installed, `clusterissuer.cert-manager.io/mm-cloud-issuer condition met`, CA exported, CoreDNS restarted, CA trusted.

- [ ] **Step 3: Verify DNS rewrite and CA**

```bash
kubectl --context kind-octomesh run dnstest --image=busybox:1.36 --restart=Never --rm -i -- nslookup identity.127-0-0-1.nip.io
```
Expected: the resolved address is the ingress-nginx-controller service ClusterIP (`kubectl --context kind-octomesh -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'`), NOT 127.0.0.1.

```bash
curl -s -o /dev/null -w "%{http_code}" https://identity.127-0-0-1.nip.io/
```
Expected: an HTTP status (404 from ingress default backend is fine at this point) with **no TLS error** (CA is trusted). If `-SkipTrustCa` was used, add `-k`.

- [ ] **Step 4: Re-run for idempotency**

```powershell
pwsh ./om-install.ps1 -NonInteractive
```
Expected: completes without errors, reusing cluster/config ("already exists" messages).

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add scripts/om-install.ps1
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Rewrite om-install for kind - cluster, infra, ingress, CA, CoreDNS"
```

---

### Task 6: om-install.ps1 — platform, reporting, operator helm installs

**Files:**
- Modify: `getting-started/scripts/om-install.ps1` (replace the `# ---- platform phase (Task 6) ----` marker with the phase below)

**Interfaces:**
- Consumes: `$config` (chartVersion/appVersion/license keys), `$GeneratedPath`, `$ChartRepo`, `$KubeContext`, values files from Task 4.
- Produces: helm releases `octo-mesh-crds` + `communication-operator` (ns `octo-operator-system`), `octo-mesh` (+ `octo-mesh-reporting` on full) in ns `octo`; generated `.generated/IdentityServer4Auth.pfx`, `.generated/operator-webhook/` certs; `communicationInstanceSecretKey` persisted in local-config.json. Service URLs printed. Consumed by Tasks 7/8 and the README.

- [ ] **Step 1: Append the platform phase**

Replace the `# ---- platform phase (Task 6) ----` line with:

```powershell
function New-SigningKey {
    $pfxPath = Join-Path $GeneratedPath "IdentityServer4Auth.pfx"
    if (Test-Path $pfxPath) { return $pfxPath }
    Write-Host "Generating IdentityServer signing key..." -ForegroundColor Cyan
    $keyPath = Join-Path $GeneratedPath "IdentityServer4Auth.key"
    $crtPath = Join-Path $GeneratedPath "IdentityServer4Auth.crt"
    openssl req -x509 -newkey rsa:2048 -sha256 -keyout $keyPath -out $crtPath -subj "/CN=octomesh-signing" -days 10950 -passout pass:Secret01
    if ($LASTEXITCODE -ne 0) { throw "openssl signing-cert generation failed." }
    openssl pkcs12 -export -out $pfxPath -inkey $keyPath -in $crtPath -passin pass:Secret01 -passout pass:Secret01
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
            --set-file services.identity.signingKey.key=$pfxPath `
            --set-file secrets.rootCa=$caPath `
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
            --set-file secrets.rootCa=$caPath `
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
```

- [ ] **Step 2: Run the full install (core profile)**

```powershell
cd /Users/reimar/dev/meshmakers/branches/main/getting-started/scripts && pwsh ./om-install.ps1 -NonInteractive
```
Expected: CRDs + octo-mesh + operator installed; all pods in `octo` and `octo-operator-system` Ready. First image pulls can take 5–15 minutes.

- [ ] **Step 3: Verify OIDC end-to-end plumbing**

```bash
curl -s https://identity.127-0-0-1.nip.io/.well-known/openid-configuration | head -c 300
```
Expected: JSON discovery document with `"issuer":"https://identity.127-0-0-1.nip.io"`.

In-cluster JWKS check (the critical JWKS-from-pod path — `-k` because the test pod lacks the CA; the platform pods get it via the rootCa init container):
```bash
kubectl --context kind-octomesh run jwkstest --image=curlimages/curl --restart=Never --rm -i -- curl -sk https://identity.127-0-0-1.nip.io/.well-known/openid-configuration
```
Expected: the discovery JSON printed from inside the cluster. Additionally check that no service logs the JWKS failure:
```bash
kubectl --context kind-octomesh -n octo logs --all-containers -l "app.kubernetes.io/instance=octo-mesh" --tail=200 2>/dev/null | grep -ci "signature key was not found" || true
```
Expected: `0`.

- [ ] **Step 4: Verify operator**

```bash
kubectl --context kind-octomesh -n octo-operator-system get pods
kubectl --context kind-octomesh -n octo-operator-system logs deploy/communication-operator --tail=20
```
Expected: operator pod Running; logs show a successful connection attempt to `https://communication.127-0-0-1.nip.io` (pool registration happens later, after pool deploy — "no pools" is fine here; connection/TLS errors are not).

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add scripts/om-install.ps1
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Install platform, reporting, and operator charts in om-install"
```

---

### Task 7: om-login-local.ps1 + om-bootstrap-tenant.ps1 (+ simulation adapter)

**Files:**
- Modify (rewrite): `getting-started/scripts/om-login-local.ps1`
- Create: `getting-started/scripts/om-bootstrap-tenant.ps1`
- Create: `getting-started/scripts/kubernetes/simulation-adapter.yaml` (ImportRt template)

**Interfaces:**
- Consumes: octo-cli with `DeployPool` (Task 3 — for verification use the DebugL build: `dotnet run --project /Users/reimar/dev/meshmakers/branches/main/octo-cli/src/ManagementTool/ManagementTool.csproj -c DebugL -- …` or the octo-tools PATH binary after `Invoke-BuildAll`); blueprint-seeded rtIds (Global Constraints); `local-config.json` chartVersion.
- Produces: logged-in octo-cli context; tenant with communication enabled; deployed pool + mesh adapter (+ simulation adapter with `-IncludeSimulation`). The simulation adapter Rt entity uses fixed rtId `671000000000000000000001`.

- [ ] **Step 1: Rewrite om-login-local.ps1**

```powershell
#!/usr/bin/env pwsh
# Configures octo-cli for the local kind installation and logs in interactively.
param(
    $tenantId = "meshtest",
    $includeReporting = $false
)

$ErrorActionPreference = "Stop"
$base = "127-0-0-1.nip.io"

if ($includeReporting) {
    Write-Host "Including reporting"
    octo-cli -c Config -asu "https://assets.$base/" -isu "https://identity.$base/" -bsu "https://bots.$base/" -csu "https://communication.$base/" -rsu "https://reporting.$base/" -tid $tenantId
}
else {
    octo-cli -c Config -asu "https://assets.$base/" -isu "https://identity.$base/" -bsu "https://bots.$base/" -csu "https://communication.$base/" -tid $tenantId
}
octo-cli -c Login -i
```

- [ ] **Step 2: Write kubernetes/simulation-adapter.yaml**

ImportRt template (`__CHART_VERSION__` is replaced by the bootstrap script). Structure mirrors the blueprint-seeded MeshAdapter entity; the two associations MUST be present (Rt export drops exactly these — known platform gotcha):

```yaml
$schema: https://schemas.meshmakers.cloud/runtime-model.schema.json
entities:
  - rtId: '671000000000000000000001'
    ckTypeId: System.Communication/Adapter
    rtWellKnownName: SimulationAdapter
    associations:
      - roleId: System.Communication/Manages
        targetRtId: '670000000000000000000001'
        targetCkTypeId: System.Communication/Pool
      - roleId: System.Communication/HelmRepository
        targetRtId: '670000000000000000000004'
        targetCkTypeId: System.Communication/HelmRepositoryConfiguration
    attributes:
      - id: System/Name
        value: Simulation Adapter
      - id: System/Description
        value: >-
          Simulation adapter for the getting-started quickstart. Deployed by the
          Communication Operator from the public release chart repo.
      - id: System.Communication/ChartName
        value: octo-plug-simulation
      - id: System.Communication/ChartVersion
        value: "__CHART_VERSION__"
      - id: System.Communication/DeploymentState
        value: 0
      - id: System.Communication/CommunicationState
        value: 0
      - id: System.Communication/ConfigurationState
        value: 0
      - id: System.Communication/LastSyncedSequenceNumber
        value: 0
      - id: System.Communication/ReceivesClusterSecrets
        value: false
```

- [ ] **Step 3: Write om-bootstrap-tenant.ps1**

```powershell
#!/usr/bin/env pwsh
# Creates a tenant, enables communication (blueprints seed the pool, the mesh
# adapter, and the public chart repository), and deploys pool + adapters via the
# Communication Operator. Run ./om-login-local.ps1 first.
param(
    [string]$TenantId = "meshtest",
    [switch]$IncludeSimulation = $false
)

$ErrorActionPreference = "Stop"

$KubeContext = "kind-octomesh"
$PoolRtId = "670000000000000000000001"
$MeshAdapterRtId = "670000000000000000000002"
$SimulationAdapterRtId = "671000000000000000000001"

$configPath = Join-Path $PSScriptRoot "kubernetes/local-config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "No local-config.json found - run ./om-install.ps1 first."
    exit 1
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

function Invoke-OctoCli {
    param([string[]]$CliArgs, [string]$FailureHint)
    & octo-cli @CliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "octo-cli $($CliArgs -join ' ') failed. $FailureHint"
        exit 1
    }
}

Write-Host "Creating tenant '$TenantId'..." -ForegroundColor Cyan
& octo-cli -c Create -tid $TenantId -db $TenantId
if ($LASTEXITCODE -ne 0) {
    Write-Host "Tenant creation failed - if it already exists, continuing is safe." -ForegroundColor Yellow
}

Write-Host "Enabling communication (seeds pool, mesh adapter, chart repository)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "EnableCommunication") -FailureHint "Check that you are logged in (./om-login-local.ps1) and the tenant exists."

Write-Host "Pinning the mesh adapter chart version to $($config.chartVersion)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "UpdateWorkloadChartVersion", "-id", $MeshAdapterRtId, "-cv", $config.chartVersion) `
    -FailureHint "The blueprint-seeded mesh adapter was not found - EnableCommunication may have failed."

Write-Host "Deploying the pool (operator creates the CommunicationPool resource)..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "DeployPool", "-id", $PoolRtId) -FailureHint "Requires octo-cli with the DeployPool command."

Write-Host "Deploying the mesh adapter..." -ForegroundColor Cyan
Invoke-OctoCli -CliArgs @("-c", "DeployWorkload", "-id", $MeshAdapterRtId) -FailureHint ""

if ($IncludeSimulation) {
    Write-Host "Importing and deploying the simulation adapter..." -ForegroundColor Cyan
    $template = Get-Content (Join-Path $PSScriptRoot "kubernetes/simulation-adapter.yaml") -Raw
    $importFile = Join-Path $PSScriptRoot "kubernetes/.generated/simulation-adapter.yaml"
    $template -replace "__CHART_VERSION__", $config.chartVersion | Set-Content -Path $importFile -Encoding UTF8
    Invoke-OctoCli -CliArgs @("-c", "ImportRt", "-f", $importFile, "-w") -FailureHint "Simulation adapter import failed."
    Invoke-OctoCli -CliArgs @("-c", "DeployWorkload", "-id", $SimulationAdapterRtId) -FailureHint ""
}

Write-Host "Waiting for adapter pods (up to 5 minutes)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $pods = kubectl --context $KubeContext -n octo get pods --no-headers 2>$null | Out-String
    if ($pods -match "Running") { break }
    Start-Sleep -Seconds 10
}
kubectl --context $KubeContext -n octo get communicationpool,pods

Write-Host ""
Write-Host "Tenant '$TenantId' is ready." -ForegroundColor Green
Write-Host "Check adapter state with: octo-cli -c GetAdapters"
```

- [ ] **Step 4: Run and verify the bootstrap**

Prerequisite once: open `https://identity.127-0-0-1.nip.io/`, register the admin user, then:
```powershell
pwsh ./om-login-local.ps1
pwsh ./om-bootstrap-tenant.ps1
```
Expected: tenant created; EnableCommunication succeeds; chart version pinned; pool deploy triggers the operator (`kubectl --context kind-octomesh -n octo get communicationpool` shows the CR); mesh adapter helm-installed by the operator (`helm --kube-context kind-octomesh -n octo list` shows `meshtest-…` release; adapter pod Running).
```bash
octo-cli -c GetAdapters
```
Expected: MeshAdapter with DeploymentState Deployed and CommunicationState Online (Online can take a minute after pod start).

- [ ] **Step 5: Verify simulation path**

```powershell
pwsh ./om-bootstrap-tenant.ps1 -IncludeSimulation
```
Expected: idempotent for the already-deployed parts; simulation adapter imported and deployed; second adapter pod Running. If the ImportRt YAML is rejected, run `octo-cli -c GetAdapter --identifier 670000000000000000000002 --json`, compare the entity shape, adjust `simulation-adapter.yaml` accordingly, and note the correction in the task report.

- [ ] **Step 6: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add scripts/om-login-local.ps1 scripts/om-bootstrap-tenant.ps1 scripts/kubernetes/simulation-adapter.yaml
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Add tenant bootstrap with operator-deployed adapters"
```

---

### Task 8: Lifecycle scripts — om-start, om-stop, om-status, om-uninstall

**Files:**
- Modify (rewrite): `getting-started/scripts/om-start.ps1`, `getting-started/scripts/om-stop.ps1`, `getting-started/scripts/om-uninstall.ps1`
- Create: `getting-started/scripts/om-status.ps1`

**Interfaces:**
- Consumes: cluster name `octomesh` (node container `octomesh-control-plane`), CA CN `OctoMesh Getting Started Root CA`, `.generated/` path.
- Produces: user-facing lifecycle commands documented in the README (Task 10).

- [ ] **Step 1: Write om-stop.ps1**

```powershell
#!/usr/bin/env pwsh
# Stops the OctoMesh kind cluster. Data is preserved; restart with ./om-start.ps1.
$ErrorActionPreference = "Stop"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found (container '$node' does not exist)." -ForegroundColor Yellow
    exit 0
}
if ($state -ne "running") {
    Write-Host "OctoMesh cluster is already stopped." -ForegroundColor Yellow
    exit 0
}
Write-Host "Stopping the OctoMesh kind cluster..." -ForegroundColor Cyan
docker stop $node | Out-Null
Write-Host "Stopped. Data is preserved - start again with ./om-start.ps1."
```

- [ ] **Step 2: Write om-start.ps1**

```powershell
#!/usr/bin/env pwsh
# Starts a previously stopped OctoMesh kind cluster.
$ErrorActionPreference = "Stop"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found. Run ./om-install.ps1 first." -ForegroundColor Red
    exit 1
}
if ($state -eq "running") {
    Write-Host "OctoMesh cluster is already running." -ForegroundColor Yellow
}
else {
    Write-Host "Starting the OctoMesh kind cluster..." -ForegroundColor Cyan
    docker start $node | Out-Null
}
Write-Host "Waiting for pods to become ready (this can take a few minutes after a cold start)..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    $notReady = kubectl --context kind-octomesh -n octo get pods --no-headers 2>$null | Where-Object { $_ -notmatch "Running|Completed" }
    if ($LASTEXITCODE -eq 0 -and -not $notReady) { break }
    Start-Sleep -Seconds 10
}
Write-Host "Start done. Check details with ./om-status.ps1."
```

- [ ] **Step 3: Write om-status.ps1**

```powershell
#!/usr/bin/env pwsh
# Shows the status of the OctoMesh kind installation.
$KubeContext = "kind-octomesh"
$base = "127-0-0-1.nip.io"

$node = "octomesh-control-plane"
$state = docker inspect -f '{{.State.Status}}' $node 2>$null
if (-not $state) {
    Write-Host "No OctoMesh kind cluster found. Run ./om-install.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "Cluster node: $state" -ForegroundColor Cyan
if ($state -ne "running") { Write-Host "Start it with ./om-start.ps1."; exit 0 }

Write-Host ""
Write-Host "=== Pods ===" -ForegroundColor Cyan
foreach ($ns in @("octo-infra", "octo", "octo-operator-system")) {
    Write-Host "--- namespace $ns ---"
    kubectl --context $KubeContext -n $ns get pods 2>$null
}
Write-Host ""
Write-Host "=== Helm releases ===" -ForegroundColor Cyan
helm --kube-context $KubeContext list -A
Write-Host ""
Write-Host "=== Host ports ===" -ForegroundColor Cyan
foreach ($port in @(80, 443, 27017, 5672, 15672, 5432, 4301)) {
    $open = Test-Connection -TargetName 127.0.0.1 -TcpPort $port -TimeoutSeconds 3 -Quiet
    $label = if ($open) { "open" } else { "CLOSED" }
    Write-Host ("  127.0.0.1:{0,-6} {1}" -f $port, $label)
}
Write-Host ""
Write-Host "=== URLs ===" -ForegroundColor Cyan
Write-Host "  Identity:          https://identity.$base/"
Write-Host "  Asset repository:  https://assets.$base/tenants/octosystem/graphql/playground"
Write-Host "  Bot dashboard:     https://bots.$base/ui/jobs"
Write-Host "  Platform services: https://platform.$base/octosystem/_configuration"
Write-Host "  Refinery Studio:   https://studio.$base/          (full profile)"
Write-Host "  Reporting:         https://reporting.$base/       (full profile)"
Write-Host "  RabbitMQ mgmt:     http://localhost:15672/        (guest/guest)"
Write-Host "  CrateDB console:   http://localhost:4301/"
```

- [ ] **Step 4: Write om-uninstall.ps1**

```powershell
#!/usr/bin/env pwsh
# Deletes the OctoMesh kind cluster and ALL its data, and removes the trusted root CA.
param(
    [switch]$Force = $false,
    [switch]$KeepCaTrust = $false,
    [switch]$KeepGeneratedFiles = $false
)

$ErrorActionPreference = "Stop"
$ClusterName = "octomesh"
$RootCaCommonName = "OctoMesh Getting Started Root CA"
$GeneratedPath = Join-Path $PSScriptRoot "kubernetes/.generated"

if (-not $Force) {
    Write-Host "This deletes the kind cluster '$ClusterName' including ALL DATA (MongoDB, CrateDB volumes)." -ForegroundColor Yellow
    $confirm = Read-Host "Type 'yes' to continue"
    if ($confirm -ne "yes") { Write-Host "Aborted."; exit 0 }
}

$existing = kind get clusters 2>$null
if ($existing -contains $ClusterName) {
    Write-Host "Deleting kind cluster '$ClusterName'..." -ForegroundColor Cyan
    kind delete cluster --name $ClusterName
}
else {
    Write-Host "No kind cluster '$ClusterName' found." -ForegroundColor Yellow
}

if (-not $KeepCaTrust) {
    Write-Host "Removing the root CA from the OS trust store (may prompt for sudo/elevation)..." -ForegroundColor Cyan
    if ($IsMacOS) {
        sudo security delete-certificate -c $RootCaCommonName /Library/Keychains/System.keychain 2>$null
    }
    elseif ($IsWindows) {
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match [regex]::Escape($RootCaCommonName) } | Remove-Item -ErrorAction SilentlyContinue
    }
    else {
        sudo rm -f /usr/local/share/ca-certificates/octomesh-getting-started-root-ca.crt
        sudo update-ca-certificates --fresh | Out-Null
    }
}

if (-not $KeepGeneratedFiles -and (Test-Path $GeneratedPath)) {
    Write-Host "Removing generated local files ($GeneratedPath)..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $GeneratedPath
}

Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "local-config.json (version + license keys) was kept for the next install."
```

- [ ] **Step 5: Verify the lifecycle**

```powershell
pwsh ./om-status.ps1     # expected: node running, pods listed, ports open, URLs printed
pwsh ./om-stop.ps1       # expected: "Stopped."
pwsh ./om-status.ps1     # expected: node exited + hint to start
pwsh ./om-start.ps1      # expected: starts, waits, "Start done."
curl -s -o /dev/null -w "%{http_code}\n" https://identity.127-0-0-1.nip.io/.well-known/openid-configuration   # expected: 200
```
Do NOT run om-uninstall here — it is verified in Task 12 (E2E) where the full reinstall is part of the matrix.

- [ ] **Step 6: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add scripts/om-start.ps1 scripts/om-stop.ps1 scripts/om-status.ps1 scripts/om-uninstall.ps1
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Rewrite lifecycle scripts for the kind cluster"
```

---

### Task 9: Remove the Docker Compose tree

**Files:**
- Delete: `getting-started/scripts/octo-mesh/` (entire directory: docker-compose.yml, .env, .env.local.example, all checked-in certificates and keys, openssl.cnf, scripts/)
- Delete: `getting-started/scripts/om-setupIdentityService-local.ps1` (obsolete — the identity blueprint seeds the Studio client)
- Delete: `getting-started/scripts/om-removeIdentityService.ps1` (compose-era counterpart)
- Modify: `getting-started/.gitignore` (drop the `scripts/octo-mesh/*` and `/scripts/infrastructure/*` rules)

**Interfaces:**
- Consumes: nothing.
- Produces: a repo without any compose remnants (WI acceptance criterion "Docker Compose path removed").

- [ ] **Step 1: Delete files**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started rm -r scripts/octo-mesh scripts/om-setupIdentityService-local.ps1 scripts/om-removeIdentityService.ps1
```
Note: `scripts/octo-mesh/.env.local` is gitignored and untracked — it stays on disk (it holds the user's license keys); that is intentional, do not delete it from the working tree.

- [ ] **Step 2: Clean .gitignore**

Remove these lines from `.gitignore` (compose-era rules):
```
scripts/octo-mesh/*.crt
scripts/octo-mesh/*.key
scripts/octo-mesh/*.csr
scripts/octo-mesh/*.pem
scripts/octo-mesh/.env.local
/scripts/infrastructure/*.crt
/scripts/infrastructure/*.csr
/scripts/infrastructure/*.key
/scripts/infrastructure/*.pem
```

- [ ] **Step 3: Verify no compose references remain**

```bash
grep -rni "docker-compose\|docker compose\|octo-identity-services:5003\|localhost:5011\|localhost:5001" /Users/reimar/dev/meshmakers/branches/main/getting-started --include="*.ps1" --include="*.yaml" --include="*.yml" --exclude-dir=.git --exclude-dir=docs
```
Expected: no hits (docs/ is excluded — the spec/plan legitimately mention compose history).

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add -A
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Remove the Docker Compose deployment path"
```

---

### Task 10: Rewrite README.md and CLAUDE.md

**Files:**
- Modify (rewrite): `getting-started/README.md`
- Modify (rewrite): `getting-started/CLAUDE.md`

**Interfaces:**
- Consumes: everything built in Tasks 4–9 (script names, parameters, URLs, flow).
- Produces: the public quickstart documentation (GitHub landing page).

- [ ] **Step 1: Write README.md**

Replace the full content with:

````markdown
# Getting started with OctoMesh

This repository deploys the OctoMesh platform on your machine using the official
OctoMesh Helm charts inside a local [kind](https://kind.sigs.k8s.io/) (Kubernetes
in Docker) cluster — the same deployment model OctoMesh uses in real clusters.

## Prerequisites

* [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine on Linux)
  * Apple Silicon Macs: enable *Settings → General → Use Rosetta for x86_64/amd64 emulation*
    (the OctoMesh service images are amd64)
* [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
* [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.31+ (`brew install kind` / `winget install Kubernetes.kind`)
* [kubectl](https://kubernetes.io/docs/tasks/tools/)
* [helm](https://helm.sh/docs/intro/install/) v3
* openssl in PATH (`brew install openssl` / `winget install ShiningLight.OpenSSL.Dev`)
* octo-cli (`choco install octo-cli` on Windows; download the self-contained binary for
  macOS/Linux from the OctoMesh release page) — **minimum version: the first release
  that includes the `DeployPool` command**
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
   the default).

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

# Further reading

* [OctoMesh documentation](https://docs.meshmakers.cloud)
````

- [ ] **Step 2: Write CLAUDE.md**

Replace the full content with:

````markdown
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
````

- [ ] **Step 3: Verify docs match reality**

Cross-check every script name, parameter, URL, and port mentioned in both files against the actual scripts from Tasks 5–8 (`grep -c` the parameter names in the scripts). Expected: no mismatches.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started add README.md CLAUDE.md
git -C /Users/reimar/dev/meshmakers/branches/main/getting-started commit -m "AB#4417 New: Rewrite README and CLAUDE.md for the Helm-on-kind deployment"
```

---

### Task 11: octo-documentation — rewrite the local getting-started guide

**Files (in `/Users/reimar/dev/meshmakers/branches/main/octo-documentation`):**
- Modify (rewrite): `src/octo-mesh-documentation/docs/technologyGuide/gettingStartedLocally/prerequisites.md`
- Modify (rewrite): `src/octo-mesh-documentation/docs/technologyGuide/gettingStartedLocally/intro.md`

**Interfaces:**
- Consumes: the final README content (Task 10) — the doc pages are the same flow in Docusaurus form.
- Produces: updated public docs. The inbound link from `docs/technologyGuide/tools/octo-cli/intro.md` → `../../gettingStartedLocally/prerequisites.md` must stay valid (file keeps its path).

- [ ] **Step 1: Create the branch**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-documentation checkout -b feat/reimar/kind-helm-conversion
```

- [ ] **Step 2: Rewrite prerequisites.md**

Keep the existing frontmatter (sidebar position etc.) and replace the body with the prerequisites section from the new README (Docker + Rosetta note, pwsh 7.4+, kind, kubectl, helm, openssl, octo-cli incl. minimum-version note, license keys). Replace the sentence "These docs describe a possibility to run OctoMesh on a local docker environment." with: "OctoMesh is operated using Kubernetes in production. This guide runs the same Helm-chart deployment on a local kind (Kubernetes in Docker) cluster." Remove the hosts-file section entirely.

- [ ] **Step 3: Rewrite intro.md**

Keep frontmatter; retitle to "Run OctoMesh on a local kind cluster"; body = the new README flow (clone → om-install with profiles → admin user → om-login-local → om-bootstrap-tenant incl. `-IncludeSimulation` → URL table → lifecycle scripts → troubleshooting), adapted to Docusaurus (relative links, no HTML). Content must match Task 10's README semantically — copy from it, do not invent.

- [ ] **Step 4: Build the docs site**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-documentation && npm run build 2>&1 | tail -20
```
Expected: build completes. Known caveat: pre-existing broken-link errors come from apiReference pages, NOT from guide pages — a red build is only a failure for this task if the errors mention `gettingStartedLocally` or `octo-cli/intro`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-documentation add src/octo-mesh-documentation/docs/technologyGuide/gettingStartedLocally
git -C /Users/reimar/dev/meshmakers/branches/main/octo-documentation commit -m "AB#4417 New: Rewrite local getting-started guide for Helm on kind"
```

---

### Task 12: End-to-end verification matrix

Full fresh-machine simulation. This is the acceptance gate for AB#4417.

**Files:** none (verification only; fixes discovered here are committed to the owning task's files with `AB#4417 Fix:` messages).

**Interfaces:**
- Consumes: everything.
- Produces: the verification report (pass/fail per row) for the PR description.

- [ ] **Step 1: Full uninstall + fresh core install**

```powershell
cd /Users/reimar/dev/meshmakers/branches/main/getting-started/scripts
pwsh ./om-uninstall.ps1 -Force
pwsh ./om-install.ps1        # interactive: version prompt + license keys
```
Expected: complete without errors; all pods Ready.

- [ ] **Step 2: Admin + login + tenant bootstrap**

Browser: register admin at `https://identity.127-0-0-1.nip.io/` (no certificate warning). Then:
```powershell
pwsh ./om-login-local.ps1
pwsh ./om-bootstrap-tenant.ps1 -IncludeSimulation
octo-cli -c GetAdapters
```
Expected: MeshAdapter + SimulationAdapter both Deployed; adapter pods Running in ns `octo`.

- [ ] **Step 3: Functional smoke test**

```bash
octo-cli -c GetPools
octo-cli -c GetAdapterNodes
```
Expected: pool Online; adapter nodes listed (proves adapter ↔ controller SignalR connectivity through the in-cluster route).

- [ ] **Step 4: Full profile upgrade + Studio login**

```powershell
pwsh ./om-install.ps1 -DeploymentProfile full -NonInteractive
```
Browser: open `https://studio.127-0-0-1.nip.io/`, log in with the admin user (OIDC round-trip via the blueprint-seeded client), open the meshtest tenant.
Expected: Studio loads, login succeeds, no certificate warnings.

- [ ] **Step 5: Lifecycle + data survival**

```powershell
pwsh ./om-stop.ps1
pwsh ./om-start.ps1
octo-cli -c GetAdapters
```
Expected: adapters return to Online after restart; tenant data intact.

- [ ] **Step 6: Record the matrix**

Report the result of each step (1–5) plus: install wall-clock time, Docker resource settings used, and any fix commits made. This goes into the PR description.

---

## Execution notes

- Tasks 2→3 are sequential (SDK before CLI). Task 1 must run before Tasks 5–7 (abort criterion). Tasks 4→5→6→7→8→9→10 are sequential within getting-started. Task 11 can run any time after Task 10. Task 12 is last.
- If a verification step fails, fix within the owning task (commit `AB#4417 Fix: …`) before moving on — do not defer breakage to Task 12.
- Windows 11 and Linux validation (spec §8, item 8) cannot run on this machine — it is deferred to a manual pass by Reimar (or a colleague) before the release announcement; the scripts already contain the OS branches (CA trust) and the README documents the per-OS install hints.
- The spec's open license-key question (are empty keys viable at runtime?) is intentionally NOT tested — the prompts stay mandatory, which is the safe spec-compliant default.
- Push and PR creation are NOT part of this plan — Reimar decides per repo when the branch is ready.
