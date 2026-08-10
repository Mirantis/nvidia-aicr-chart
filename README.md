# nvidia-aicr-chart

A Helm chart that installs the NVIDIA AI stack on a Kubernetes cluster by running [NVIDIA AI Cluster Runtime (AICR)](https://github.com/NVIDIA/aicr) in a Job. AICR's version-locked, dependency-ordered recipes become installable by anything that speaks Helm — `helm install`, Argo CD, Flux, or a k0rdent `MultiClusterService`.

**Why this chart:**

- **The validated matrix, not hand-picked versions.** One install converges a cluster on NVIDIA's tested combination of driver, operators, scheduler, and monitoring — component versions and ordering come from the pinned AICR release, never from this chart.
- **Recipes become named, versioned artifacts.** An org [data pack](#bring-your-orgs-recipes---data-packs) registers your own criteria value (`service: yourorg`) and carries your environment profile — every cluster installs the same recipe by name, with zero per-cluster flags.
- **GitOps-native delivery.** AICR is a CLI; this chart is the declarative envelope that lets fleet managers and reconcilers deliver it.
- **Supply chain, end to end.** Checksum-pinned binary with an optional reviewed strict pin, captured CTRF verdicts, and evidence bundles published signed (Sigstore keyless) or unsigned-then-sign-later.
- **Operable and tested.** What resolved, what passed, and the proof all land in ConfigMaps; the chart itself ships with a mutation-tested render suite and a reproducible end-to-end test.

The chart is one Kubernetes Job plus its ServiceAccount and RBAC. On the target cluster it:

1. downloads a pinned `aicr` release binary and verifies its checksum,
2. pulls your org's `--data` extension pack when one is configured,
3. runs `aicr recipe` with the criteria supplied through chart values, and captures the resolved recipe to a ConfigMap,
4. runs `aicr bundle` to render the recipe into a Helm bundle,
5. executes the bundle's `deploy.sh` to install the stack,
6. optionally runs `aicr validate`, captures the verdict to a ConfigMap, and publishes the evidence bundle to an OCI registry.

AICR is consumed unmodified — no wrapper logic, no duplicated behavior — so component versions and install ordering always come from the pinned upstream release.

> **v0.1.0 is experimental.** It targets connected clusters. The install path is the proven core; data packs, validation, and evidence publishing are opt-in values, default off.

## Install

There is no default accelerator — state your criteria (see ["Which criteria?"](#which-criteria) below):

```bash
helm install nvidia-aicr oci://ghcr.io/mirantis/charts/nvidia-aicr \
  --version 0.1.0 \
  --namespace nvidia-aicr --create-namespace \
  --set accelerator=h100
```

Watch it converge, then check what actually resolved:

```bash
kubectl logs -n nvidia-aicr -l app.kubernetes.io/name=nvidia-aicr --tail=-1 -f
kubectl get cm aicr-recipe -n nvidia-aicr -o jsonpath='{.data.summary\.txt}'
```

## Bring your org's recipes (`--data` packs)

This is the intended production path. AICR selects recipes by matching criteria against its catalog — there is no "recipe name" flag. An org pack closes that gap: registering a private `service` value in an overlay makes it a valid CLI input (upstream: *"adding a new value to an overlay automatically makes it a valid CLI input"*), so the value **is** the recipe's name. The same overlay carries your environment facts (containerd socket, driver posture, fleet constraints) and your calibrated validators, so a resolved bundle needs zero per-cluster flags.

A minimal pack, for a fictional org "acme":

```
acme-aicr-pack/
├── registry.yaml                 # required stub even with no component additions
├── overlays/
│   └── acme-h200-training.yaml   # registers service=acme; bakes in env profile
└── validators/
    └── catalog.yaml              # org validators, pinned by image digest
```

Package the directory as an OCI artifact (`oras push`), then point the chart at it:

```yaml
dataPack: "ghcr.io/acme/acme-aicr-pack:1.0.0"
dataPackSecret: "aicr-pack-pull"    # for private registries; see below
service: acme
accelerator: h200
intent: training
```

See upstream `docs/integrator/data-extension.md` for pack authoring.

### Private pack registries

`dataPackSecret` names an **existing** Secret of type `kubernetes.io/dockerconfigjson` in the release namespace; the pull initContainer authenticates with it. Empty means anonymous (public artifacts only). The chart never creates the Secret:

```bash
kubectl create secret docker-registry aicr-pack-pull -n nvidia-aicr \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>
```

A bad or missing credential fails the initContainer visibly — fail-closed, never a silent fallback to anonymous.

### Private validator images

A pack's validator catalog may reference private images. Those are pulled by the **kubelet** in the namespace where `aicr validate` runs its validator Jobs (default `aicr-validation`) — `dataPackSecret` does not cover them. aicr exposes the knobs natively; pass them through `validateFlags`:

```yaml
validateFlags: "--namespace aicr --image-pull-secret acme-registry-cred"
```

With `--namespace` set to the release namespace, the *same* dockerconfigjson Secret used for `dataPackSecret` can serve as the validator pull secret — one robot token, one Secret object, all three consumers (pack pull, evidence push, validator pull). The stock validators and the snapshot agent (`ghcr.io/nvidia/aicr`) are public and need none of this.

## Which criteria?

Recipe selection is criteria assembly against AICR's catalog (`service`, `accelerator`, `intent`, `os`, `platform`). Two failure modes matter:

- **Over-specification fails hard**: naming a dimension the matching overlays don't declare is rejected outright (e.g. `intent: training` with `service: any`). The error message lists supported combinations — but you only see it in the Job log, minutes after `helm install` returned.
- **Under-specification degrades silently**: fewer stated dimensions resolve a *thinner* stack with exit 0 and no warning. `accelerator: a100` alone resolves 11 components; a fully-specified EKS training leaf resolves 15.

Defend against both:

```bash
aicr recipe list --gpu h200        # before: which combinations exist for your GPU
kubectl get cm aicr-recipe -n <ns> -o jsonpath='{.data.summary\.txt}'   # after: what resolved
```

The chart refuses to render with no criteria at all: state an `accelerator`, or set `dataPack` (your pack owns criteria), or state a concrete `service` plus `intent` (accelerator-less leaves like `bcm`+`inference` exist; `service: any` does not count). Extra flags (`--nodes`, `--criteria-strict`) pass through `recipeFlags`.

## Values

| Key | Default | Meaning |
|---|---|---|
| `accelerator` | `""` **(required*)** | Target accelerator: `h100`, `h200`, `gb200`, `gb300`, `b200`, `a100`, `l40`, `l40s`, `rtx-pro-6000`. *Render fails unless this, `dataPack`, or concrete `service`+`intent` is set |
| `intent` | `""` | Recipe intent (`training`, `inference`). **Empty omits the flag.** A stated intent must be declared by the matching overlays — see "Which criteria?" |
| `os` | `""` | Node OS (`ubuntu`, `rhel`, `cos`, `amazonlinux`, `ol`, `talos`). **Empty omits the flag** |
| `platform` | `""` | Workload platform (`kubeflow`, `dynamo`, `nim`, `runai`, `slurm`). **Empty omits the flag** |
| `service` | `any` | Service overlay: `aks`, `bcm`, `eks`, `gke`, `kind`, `lke`, `metal3`, `ocp`, `oke`, a pack-registered value (e.g. `acme`), or `any` for self-managed clusters |
| `dataPack` | `""` | OCI reference (no scheme) of your org's `--data` extension pack |
| `dataPackSecret` | `""` | Existing dockerconfigjson Secret for private pack registries |
| `dataPackPlainHTTP` / `dataPackInsecureTLS` | `false` | Pack-pull transport for lab registries (plain HTTP / untrusted TLS) — production registries need neither |
| `orasImage` | `ghcr.io/oras-project/oras:v1.2.0` | initContainer image that pulls `dataPack` |
| `recipeConfigMap` | `aicr-recipe` | ConfigMap receiving the resolved recipe + summary; `""` disables |
| `aicrVersion` | `v0.18.0` | Pinned [aicr release](https://github.com/NVIDIA/aicr/releases) tag |
| `aicrArch` | `amd64` | Binary architecture: `amd64` or `arm64` |
| `aicrSha256` | `{amd64: <v0.18.0 hash>, arm64: ""}` | Strict pin keyed by architecture; the entry matching `aicrArch` is used. Update on every `aicrVersion` bump. See "Supply-chain verification" |
| `validate.enabled` | `false` | Run `aicr validate` after the install; see "Validation" |
| `validate.phases` | `[deployment]` | Validation phases to run |
| `validate.failOnError` | `false` | When `true`, a failed validation fails the Job — always after the verdict is captured |
| `validate.resultConfigMap` | `aicr-validate-result` | ConfigMap receiving the CTRF verdict |
| `validate.emitEvidence` | `false` | Also capture the `--emit-attestation` evidence bundle |
| `validate.evidenceConfigMap` | `aicr-evidence-bundle` | ConfigMap receiving the gzipped bundle (+ `pointer.yaml` once published) |
| `validate.publish.enabled` | `false` | Push the evidence bundle to an OCI registry; requires `emitEvidence`. See "Publishing evidence" |
| `validate.publish.mode` | `signed` | `signed` (in-cluster keyless signing) or `unsigned` (sign later, identity never enters the cluster) |
| `validate.publish.ref` | `""` | OCI push reference, e.g. `ghcr.io/myorg/aicr-evidence`. Required when enabled |
| `validate.publish.identityTokenSecret` | `{name: "", key: token}` | signed mode: existing Secret holding a **short-lived** OIDC token, exposed as `COSIGN_IDENTITY_TOKEN` |
| `validate.publish.registrySecret` | `""` | Existing dockerconfigjson Secret for the evidence registry push |
| `validate.publish.failOnError` | `false` | A publish failure fails the Job only when `true` |
| `validate.publish.insecureTLS` / `.plainHTTP` | `false` | Self-signed / plain-HTTP registries (local testing) |
| `storageClass` | `""` | If non-empty, passed to `aicr bundle --storage-class` |
| `recipeFlags` | `""` | Extra flags passed to `aicr recipe` (e.g. `--criteria-strict`, `--nodes 8`) |
| `bundleFlags` | `""` | Extra flags passed to `aicr bundle` — see "Tainted GPU nodes". Applied after `environment.*`, so these win |
| `validateFlags` | `""` | Extra flags passed to `aicr validate` (`--namespace`, `--image-pull-secret`, `--node-selector`); see "Private validator images" |
| `job.extraEnv` | `[]` | Extra env for the installer container, verbatim (e.g. `AICR_NCCL_FABRIC`) |
| `environment.k0sContainerd` | `false` | Point the container-toolkit at k0s's own containerd — prefer encoding this in your org pack; see "k0s clusters" |
| `environment.preinstalledDriver` | `false` | Nodes already carry an NVIDIA driver — prefer encoding this in your org pack |
| `deploy.enabled` | `true` | `false` = assert-only run: skip bundle+deploy entirely and validate the cluster against the resolved recipe. Requires `validate.enabled`; see "Validation postures" |
| `deployFlags` | `--best-effort --no-wait` | Flags passed to the bundle's `deploy.sh` (accepts `--best-effort`, `--no-wait`, `--retries N`) |
| `runtimeImage` | `alpine/k8s:1.34.0` | Job image; must include `bash`, `curl`, `kubectl`, and `helm` |
| `job.*` | see `values.yaml` | Job backoff, TTL, deadline, and resource settings |
| `job.tolerations` | `[]` | Tolerations for the **installer pod itself** — required on clusters whose only workers are tainted GPU nodes; see "Tainted GPU nodes" |
| `job.nodeSelector` / `job.affinity` / `job.priorityClassName` | empty | Remaining scheduling controls for the installer pod |

## Publishing evidence

With `validate.publish.enabled: true`, the Job pushes the emitted evidence bundle to `publish.ref` via `aicr evidence publish` after the verdict is captured. The `pointer.yaml` locator lands on the evidence ConfigMap either way. Two trust modes:

**`mode: signed`** — keyless Sigstore signing in-cluster. The identity token from `identityTokenSecret` is exposed as `COSIGN_IDENTITY_TOKEN`. Understand what this means: the token lives inside a pod whose ServiceAccount is bound to `cluster-admin`, and anyone who can read pods in that namespace during the run can sign as that identity until it expires. Use only short-lived, per-run tokens — and note the token must still be **valid when the publish step runs**, which is after `deploy.sh` and validation, potentially tens of minutes after install. Public Sigstore does not trust self-managed cluster issuers, so the token is BYO (mint → write Secret → install):

```bash
kubectl create secret generic cosign-token -n nvidia-aicr --from-literal=token="$OIDC_TOKEN"
```

**`mode: unsigned`** — the bundle is pushed with an empty signer block; identity never enters the cluster. Sign later from a trusted host with Sigstore egress:

```bash
aicr evidence sign <pointer.yaml> --relocate
```

This is upstream's own fork-based CI flow, and the recommended posture for regulated environments and scheduled runs.

The registry must support the OCI 1.1 Referrers API for signature attachment (GHCR, GitLab, Harbor ≥ 2.8, ECR, Google Artifact Registry, ACR, Artifactory); upstream falls back to a tag schema otherwise. The push itself authenticates via `registrySecret` (dockerconfigjson), scoped to the publish invocation only.

## Fleet and GitOps deployment

The chart is a normal OCI Helm chart: any reconciler that speaks Helm delivers it. Two worked examples; the same values block works everywhere, including plain `helm install -f values.yaml`.

One caveat applies to every reconciler: **do not reconcile new values while an install is still running** — see "Scope and limitations".

### Flux

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata: {name: nvidia-aicr, namespace: flux-system}
spec:
  type: oci
  url: oci://ghcr.io/mirantis/charts
  interval: 1h
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: {name: nvidia-aicr, namespace: nvidia-aicr}
spec:
  interval: 1h
  chart:
    spec:
      chart: nvidia-aicr
      version: 0.1.0
      sourceRef: {kind: HelmRepository, name: nvidia-aicr, namespace: flux-system}
  values:
    service: acme
    accelerator: h200
    intent: training
    dataPack: "ghcr.io/acme/acme-aicr-pack:1.0.0"
    dataPackSecret: "aicr-pack-pull"
```

Argo CD users: the same chart/values as an `Application` with an OCI repo source.

### k0rdent

The chart is published to the [k0rdent catalog](https://catalog.k0rdent.io/) as a ServiceTemplate. Label the GPU `ClusterDeployment`s you want converged; one `MultiClusterService` installs — and validates — the NVIDIA runtime on all of them:

```yaml
apiVersion: k0rdent.mirantis.com/v1beta1
kind: MultiClusterService
metadata:
  name: nvidia-runtime-training
  namespace: kcm-system
spec:
  clusterSelector:
    matchLabels:
      gpu-fleet: training            # your label on GPU ClusterDeployments
  serviceSpec:
    services:
      - template: nvidia-aicr-0-1-0
        name: nvidia-aicr
        namespace: nvidia-aicr
        values: |
          dataPack: "ghcr.io/acme/acme-aicr-pack:1.0.0"
          dataPackSecret: "aicr-pack-pull"
          service: acme
          accelerator: h200
          intent: training
          bundleFlags: "--accelerated-node-toleration nvidia.com/gpu=present:NoSchedule"
          deployFlags: "--retries 1"     # strict: wait and gate on the verdict
          validate:
            enabled: true
            phases: [deployment]
            failOnError: true
            emitEvidence: true
            publish: {enabled: true, mode: unsigned, ref: ghcr.io/acme/aicr-evidence}
```

## Tainted GPU nodes

Production clusters commonly taint GPU nodes (e.g. `nvidia.com/gpu=present:NoSchedule`). AICR injects tolerations into the rendered charts when asked; pass the flags through `bundleFlags`:

```yaml
bundleFlags: "--accelerated-node-toleration nvidia.com/gpu=present:NoSchedule"
```

Without this, GPU-targeted components stay `Pending` on tainted nodes. Related scheduling flags (`--system-node-selector`, `--system-node-toleration`, `--workload-gate`, `--set component:path=value`) pass through the same way.

**`bundleFlags` covers the components AICR deploys — not the installer Job itself.** On a cluster whose only worker pool is tainted, the Job's own pod will never schedule, and it burns the full `activeDeadlineSeconds` (3 h by default) before failing with `DeadlineExceeded`. Tolerate the taint for the installer too:

```yaml
job:
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: NoSchedule
```

Note that aicr's `--set` is **scalar-only**; list or object values need `--set-json` (or `--set-file`). That matters for the k0s example below, whose `toolkit.env` is a list.

## k0s clusters and hosts with a preinstalled driver

These two toggles encode environment facts. If you run an org pack, encode them in the pack's overlay instead — that is what packs are for, and it keeps per-cluster values empty:

```yaml
environment:
  k0sContainerd: true        # cluster runs k0s (its own containerd)
  preinstalledDriver: true   # nodes already carry an NVIDIA driver
```

- **`k0sContainerd`** points the container-toolkit at k0s's containerd (`/run/k0s/containerd.sock`, drop-ins under `/etc/k0s/containerd.d/`). Without it the toolkit configures the *default* containerd, reports success, and GPU pods then fail with `no runtime for "nvidia" is configured`.

- **`preinstalledDriver`** turns the GPU operator's driver install off and points the DRA driver at the host root. aicr's driver-ownership coherence check requires both, so the toggle sets both together.

The toggles are applied before `bundleFlags`, so you can still override any of it. The equivalent long form:

```yaml
bundleFlags: '--set gpuoperator:driver.enabled=false --set dradriver:nvidiaDriverRoot=/ --set-json gpuoperator:toolkit.env=[{"name":"CONTAINERD_CONFIG","value":"/etc/k0s/containerd.d/nvidia.toml"},{"name":"CONTAINERD_SOCKET","value":"/run/k0s/containerd.sock"},{"name":"CONTAINERD_RUNTIME_CLASS","value":"nvidia"}]'
```

Verified end to end on 8× H200 SXM bare metal (k0s v1.36.2, kcm 1.9.0): all components installed under strict flags and aicr's deployment phase passed 4/4.

## Validation

With `validate.enabled: true`, the Job runs `aicr validate` against the freshly installed stack and publishes the CTRF verdict to `validate.resultConfigMap` — **whether validation passes or fails** (aicr's own per-phase CTRF ConfigMaps are removed at its run cleanup, so the chart owns durable capture; only after capture does `failOnError` apply). Read the verdict with:

```bash
kubectl get cm aicr-validate-result -n <ns> -o jsonpath='{.data.ctrf\.json}' | jq .results.summary
```

With `validate.emitEvidence: true`, the in-toto attestation bundle is also captured (gzipped, size-guarded):

```bash
kubectl get cm aicr-evidence-bundle -n <ns> -o jsonpath='{.binaryData.evidence\.tgz}' \
  | base64 -d > evidence.tgz && mkdir -p evidence && tar xzf evidence.tgz -C evidence
aicr evidence verify ./evidence
```

Operational notes: when validation is enabled, drop `--no-wait` from `deployFlags` (so `deploy.sh` waits for convergence before the verdict) and prefer `--retries 1` — the default retry/backoff schedule can stretch a single slow component toward an hour, and the Job's `activeDeadlineSeconds` (default 10800s) is the overall cap. Keep validation off on GPU-less clusters (kind included) — the deployment phase legitimately fails while GPU pods sit Pending.

## Validation postures

Two different things get verified with the same machinery. **Rollout verification** (the `deployment` phase, validators shipped in aicr) asks *"is the cluster running what the recipe says?"*. **Capability qualification** (the `performance`/`conformance` phases, validators mostly from your org pack) asks *"does this hardware actually deliver?"* — burn-in, NCCL floors, storage thresholds. Qualification consumes what rollout installed (DCGM, device plugin, drivers); it never provides it.

`aicr validate` itself never deploys anything — it is purely assertive. The chart's `deploy.enabled` toggle and `validate.phases` therefore span four postures (worked values in [`examples/`](examples/)):

| Posture | `deploy.enabled` | `phases` | When |
|---|---|---|---|
| **Install & prove** | `true` | `[deployment]` | day-1, fleet converge — [`examples/day1-install.yaml`](examples/day1-install.yaml) |
| **Qualify hardware** | `false` | `[performance]` + org pack | commissioning burn-in, benchmarks — [`examples/qualify-hardware.yaml`](examples/qualify-hardware.yaml) |
| **Re-certify / drift check** | `false` | `[deployment]` | scheduled, pre-upgrade — [`examples/drift-check.yaml`](examples/drift-check.yaml) |
| **Full acceptance** | `true` | `[deployment, performance]` | new fleet, one shot |

With `deploy.enabled: false` the Job still pulls the pack and resolves + captures the recipe (the contract being asserted), then skips bundle+deploy entirely. Rendering fails if combined with `validate.enabled: false` — a Job that neither deploys nor validates would be a no-op.

**What the verdicts mean when something is missing** (upstream semantics): validation *fails closed*. A cluster that flunks the readiness pre-flight exits `2` and deploys no validators; a recipe component that is absent or unhealthy **fails** the deployment phase (exit `8`) — on an assert-only run, that is the drift check working; an *optional* prerequisite (GPU nodes, an operator CRD a check needs) triggers an explicit **skip guard** — CTRF `skipped`, named reason, exit `0`, not a failure. Inconclusive checks (`other`) fail closed like failures. `validate.failOnError` decides whether a non-zero verdict fails the Job.

## Supply-chain verification

The Job downloads the pinned release tarball and verifies its sha256 against the release's `aicr_checksums.txt` before executing anything (fail-closed). For stricter provenance, set `aicrSha256.<arch>` to the expected tarball hash: that anchors trust in reviewed chart values rather than in release assets fetched at runtime. An empty entry skips only this extra pin — the checksums-file verification always runs.

The Job pod runs as nonroot (UID 65532, matching upstream's own image user) with a read-only root filesystem; all work happens in an `emptyDir` mounted at `/tmp`.

## RBAC

The Job's ServiceAccount is bound to `cluster-admin`. AICR bundles install cluster-scoped resources (CRDs for DRA, NVSentinel, and the Prometheus operator, namespaces, and RBAC in those namespaces), so a namespaced role is not sufficient. The binding is scoped to the Job's ServiceAccount and is removed with the release.

## Scope and limitations

- Evidence bundles published in `signed` mode place the identity token in the install pod (see "Publishing evidence"); `unsigned` mode exists precisely so identity never has to enter the cluster.

- On clusters without GPUs (kind included), GPU-dependent pods stay Pending and `--best-effort` keeps the install going. That is what the k0rdent catalog's kind e2e exercises: the delivery mechanics, not GPU functionality.

- **Component-failure detection is the chart's, not deploy.sh's.** At aicr v0.18.0, `deploy.sh` reports component failures but never exits non-zero for them (with or without `--best-effort`). The Job therefore detects the failure report itself: without `--best-effort`, component failures fail the Job; with `--best-effort`, they are logged and the Job succeeds — partial installs can never masquerade as silent success.

- **Air-gapped clusters are not supported by this chart version.** The Job downloads the `aicr` binary from GitHub releases and the bundle pulls charts from upstream registries. AICR itself supports air-gapped delivery (`aicr bundle --vendor-charts`, the air-gap mirror workflow, a CycloneDX SBOM per deployable image); exposing it here needs a mirrored binary source and registry overrides. Planned for a future chart version.

- Re-running the Job re-applies the bundle (`helm upgrade` semantics downstream); strict idempotency guarantees are not part of this version. Observed on re-runs: transient webhook/cert-rotation failures recovered by deploy.sh's retries, and orphaned-CRD warnings.

- **Do not upgrade while an install is still running.** Each revision renders a new Job (`<release>-install-<revision>`), and Helm deletes the previous revision's Job because it is absent from the new manifest — which SIGKILLs `deploy.sh` mid-run and can leave downstream releases stuck in `pending-install`/`pending-upgrade`. `ttlSecondsAfterFinished` only reaps Jobs that have *finished*. Let an install converge before changing values.

- The bundle installs the Nodewright/Skyhook **operator**, but no `Skyhook` custom resources — nothing reboots on install alone. If you later define tuning policies, node reboots happen asynchronously; on a self-managed management cluster that restarts the management plane too.

- No drift detection between runs and no CRD status surface: the Job converges the cluster once per release revision, and its status is the Job exit code plus the ConfigMaps it writes (`aicr-recipe`, the CTRF verdict, the evidence bundle). For continuous reconciliation, run the chart under a GitOps controller.

## Testing

- `hack/verify-render.sh` — render assertions for every conditional path
  (mutation-tested; run by the lint and release workflows).
- `hack/e2e/run-kind-e2e.sh` — customer-shaped end-to-end on a throwaway kind
  cluster: private org data pack from an htpasswd registry, pack-named recipe
  resolution (`hack/e2e/acme-aicr-pack/`), full install, validation, unsigned
  evidence publish, and a fail-closed negative test. Local infrastructure
  only; ~20–25 min. Also runs in CI (`kind-e2e` workflow).
- `.github/workflows/signed-evidence-e2e.yml` — the signed publish path,
  release-gated (needs GitHub's Fulcio-trusted OIDC).

## Relationship to upstream

This chart is not affiliated with NVIDIA. AICR does not currently publish a Helm chart for the install step; if upstream adopts one, this chart is intended to be superseded by it.

## License

Apache 2.0 — see [LICENSE](LICENSE).
