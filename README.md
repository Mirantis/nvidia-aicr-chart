# nvidia-aicr-chart

A Helm chart that installs the NVIDIA AI stack on a Kubernetes cluster by running [NVIDIA AI Cluster Runtime (AICR)](https://github.com/NVIDIA/aicr) in a Job. AICR's version-locked, dependency-ordered recipes become installable by anything that speaks Helm — `helm install`, Argo CD, Flux, or a k0rdent `MultiClusterService`.

The chart is one Kubernetes Job plus its ServiceAccount and RBAC. On the target cluster it:

1. downloads a pinned `aicr` release binary and verifies its checksum,
2. runs `aicr recipe` with the accelerator / intent / os / platform / service values supplied through chart values,
3. runs `aicr bundle` to render the recipe into a Helm bundle,
4. executes the bundle's `deploy.sh` to install the stack,
5. optionally runs `aicr validate` and captures the verdict to a ConfigMap.

AICR is consumed unmodified — no wrapper logic, no duplicated behavior — so component versions and install ordering always come from the pinned upstream release.

> **v0.1.1 is experimental.** It targets connected clusters. The install path is the proven core;
> `--data` packs and post-install validation are opt-in values, default off.

## Install

```bash
helm install nvidia-aicr oci://ghcr.io/mirantis/charts/nvidia-aicr \
  --version 0.1.1 \
  --namespace nvidia-aicr --create-namespace \
  --set accelerator=h100
```

Watch it converge:

```bash
kubectl logs -n nvidia-aicr -l app.kubernetes.io/name=nvidia-aicr --tail=-1 -f
```

## Values

| Key | Default | Meaning |
|---|---|---|
| `accelerator` | `a100` | Target accelerator: `h100`, `h200`, `gb200`, `gb300`, `b200`, `a100`, `l40`, `l40s`, `rtx-pro-6000` |
| `intent` | `""` | Recipe intent (`training`, `inference`). **Empty omits the flag.** At aicr v0.18.0 a stated intent must be provided by the matching service/os overlays (aks, bcm, eks, lke, ocp, gke+cos, oke) or a service chain like `kind` — with `service: any`, leave intent empty |
| `os` | `""` | Node OS (`ubuntu`, `rhel`, `cos`, `amazonlinux`, `ol`, `talos`). **Empty omits the flag** — aicr uses its detected/`any` value, required when the matching recipe overlays are os-agnostic |
| `platform` | `""` | Workload platform (`kubeflow`, `dynamo`, `nim`, `runai`, `slurm`). **Empty omits the flag**, same semantics as `os` |
| `service` | `any` | AICR service overlay. `any` (upstream aliases: `self-managed`, `self`, `vanilla`) fits self-managed clusters such as k0rdent-provisioned k0s; `kind` applies the kind overlay (GPU driver install disabled, relaxed K8s version constraint) for local testing |
| `aicrVersion` | `v0.18.0` | Pinned [aicr release](https://github.com/NVIDIA/aicr/releases) tag |
| `aicrArch` | `amd64` | Binary architecture: `amd64` or `arm64` |
| `aicrSha256` | `{amd64: <v0.18.0 hash>, arm64: ""}` | Strict pin keyed by architecture; the entry matching `aicrArch` is used. Update on every `aicrVersion` bump. See "Supply-chain verification" |
| `dataPack` | `""` | OCI reference (no scheme) of an AICR `--data` extension pack; see "Data packs" below |
| `orasImage` | `ghcr.io/oras-project/oras:v1.2.0` | initContainer image that pulls `dataPack` |
| `validate.enabled` | `false` | Run `aicr validate` after the install; see "Validation" below |
| `validate.phases` | `[deployment]` | Validation phases to run |
| `validate.failOnError` | `false` | When `true`, a failed validation fails the Job — always after the verdict is captured. Default keeps validation informative |
| `validate.resultConfigMap` | `aicr-validate-result` | ConfigMap receiving the CTRF verdict |
| `validate.emitEvidence` | `false` | Also capture the `--emit-attestation` evidence bundle |
| `validate.evidenceConfigMap` | `aicr-evidence-bundle` | ConfigMap receiving the gzipped evidence bundle |
| `storageClass` | `""` | If non-empty, passed to `aicr bundle --storage-class` |
| `recipeFlags` | `""` | Extra flags passed to `aicr recipe` (e.g. `--criteria-strict`) |
| `bundleFlags` | `""` | Extra flags passed to `aicr bundle` — see "Tainted GPU nodes" below. Applied after `environment.*`, so these win |
| `environment.k0sContainerd` | `false` | Point the container-toolkit at k0s's own containerd — set `true` on k0s clusters; see "k0s clusters" below |
| `environment.preinstalledDriver` | `false` | Nodes already have an NVIDIA driver: disables the operator's driver install and sets the DRA driver root (both required together) |
| `deployFlags` | `--best-effort --no-wait` | Flags passed to the bundle's `deploy.sh` (accepts `--best-effort`, `--no-wait`, `--retries N`) |
| `runtimeImage` | `alpine/k8s:1.34.0` | Job image; must include `bash`, `curl`, `kubectl`, and `helm` |
| `job.*` | see `values.yaml` | Job backoff, TTL, deadline, and resource settings |
| `job.tolerations` | `[]` | Tolerations for the **installer pod itself** — required on clusters whose only workers are tainted GPU nodes; see "Tainted GPU nodes" |
| `job.nodeSelector` / `job.affinity` / `job.priorityClassName` | empty | Remaining scheduling controls for the installer pod |

## Choosing criteria for your fleet

Which criteria you can state depends on the recipe overlays that exist for your
target: a dimension you name must be declared by a matching overlay, or
resolution fails. List what your accelerator supports before writing values
(add `--data <pack>` to include an extension pack's overlays):

```bash
aicr recipe list --gpu h200          # e.g. h200-any (service+accelerator),
                                     #      h200-eks-training (+ intent)
```

At aicr v0.18.0 the fuller sets live on managed services — e.g. `gb200` on EKS
declares service + accelerator + os + intent + platform, while `h200` declares
intent on EKS and accelerator only on `any`. On self-managed clusters, an
extension pack (`dataPack`) is how an org makes its own service/intent
statable.

## Fleet deployment with k0rdent

The chart is published to the [k0rdent catalog](https://catalog.k0rdent.io/) as a
ServiceTemplate. Label the GPU `ClusterDeployment`s you want converged; one
`MultiClusterService` then installs — and validates — the NVIDIA runtime on all
of them:

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
      - template: nvidia-aicr-0-1-1
        name: nvidia-aicr
        namespace: nvidia-aicr
        values: |
          # Every dimension stated (overlay: gb200-eks-ubuntu-training-kubeflow)
          service: eks
          accelerator: gb200
          os: ubuntu
          intent: training
          platform: kubeflow
          # Tolerate tainted GPU nodes (see "Tainted GPU nodes")
          bundleFlags: "--accelerated-node-toleration nvidia.com/gpu=present:NoSchedule"
          # Strict posture: wait for convergence (no --no-wait) and let a
          # component failure fail the Job (no --best-effort)
          deployFlags: "--retries 1"
          validate:
            enabled: true
            phases: [deployment]
            failOnError: true        # gate on the verdict, not just record it
            emitEvidence: true
          # Optional AICR --data extension pack (org catalogs/validators):
          # dataPack: "ghcr.io/<org>/<aicr-data-pack>:<tag>"
```

The same `values` block works on a single cluster via a `ClusterDeployment`'s
`serviceSpec.services` entry, or as a plain `helm install -f values.yaml`.

## Tainted GPU nodes

Production clusters commonly taint GPU nodes (e.g.  `nvidia.com/gpu=present:NoSchedule`). AICR injects tolerations into the rendered charts when asked; pass the flags through `bundleFlags`:

```yaml
bundleFlags: "--accelerated-node-toleration nvidia.com/gpu=present:NoSchedule"
```

Without this, GPU-targeted components stay `Pending` on tainted nodes.  Related scheduling flags (`--system-node-selector`, `--system-node-toleration`, `--workload-gate`, `--set component:path=value`) pass through the same way.

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

Two toggles cover the environments k0rdent most often provisions:

```yaml
environment:
  k0sContainerd: true        # cluster runs k0s (its own containerd)
  preinstalledDriver: true   # nodes already carry an NVIDIA driver
```

- **`k0sContainerd`** points the container-toolkit at k0s's containerd (`/run/k0s/containerd.sock`, drop-ins under `/etc/k0s/containerd.d/`). Without it the toolkit configures the *default* containerd, reports success, and GPU pods then fail with `no runtime for "nvidia" is configured`.

- **`preinstalledDriver`** turns the GPU operator's driver install off and points the DRA driver at the host root. aicr's driver-ownership coherence check requires both, so the toggle sets both together.

The toggles are applied before `bundleFlags`, so you can still override any of it. The equivalent long form, if you prefer to be explicit:

```yaml
bundleFlags: '--set gpuoperator:driver.enabled=false --set dradriver:nvidiaDriverRoot=/ --set-json gpuoperator:toolkit.env=[{"name":"CONTAINERD_CONFIG","value":"/etc/k0s/containerd.d/nvidia.toml"},{"name":"CONTAINERD_SOCKET","value":"/run/k0s/containerd.sock"},{"name":"CONTAINERD_RUNTIME_CLASS","value":"nvidia"}]'
```

Verified end to end on 8× H200 SXM bare metal (k0s v1.36.2, kcm 1.9.0): all components installed
under strict flags and aicr's deployment phase passed 4/4.

## Installing onto a kcm management cluster (selfManagement)

kcm ships its own cert-manager (via its `regional` subchart), and the aicr bundle installs release `cert-manager` in namespace `cert-manager`. Both own the same cluster-scoped CRDs, so on a self-managed mothership one of them must yield. The clean arrangement:

```bash
# 1. cert-manager first, at the version/release/namespace the aicr bundle uses
helm upgrade --install cert-manager jetstack/cert-manager --version v1.20.2 \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --set fullnameOverride=cert-manager

# 2. kcm without its own copy
helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm --version 1.9.0 \
  -n kcm-system --create-namespace --set regional.cert-manager.enabled=false
```

The bundle's own cert-manager step then `helm upgrade --install`s that same release — one owner, no CRD conflict. Deploying to a *managed* cluster (the normal case) needs none of this.

## Data packs (`--data`)

AICR supports runtime extension packs — extra catalog entries, criteria values, and validators layered onto the embedded catalog without forking (upstream `docs/integrator/data-extension.md`). Set `dataPack` to the pack's OCI reference and an initContainer pulls it before the install; every `aicr`
invocation (recipe, bundle, validate) then receives `--data`:

```yaml
dataPack: "ghcr.io/myorg/my-aicr-pack:1.0.0"
```

Only publicly pullable artifacts are supported in this chart version.

## Validation

With `validate.enabled: true`, the Job runs `aicr validate` against the freshly installed stack and publishes the CTRF verdict to `validate.resultConfigMap` — **whether validation passes or fails** (aicr's own per-phase CTRF ConfigMaps are removed at its run cleanup, so the chart owns durable capture; only after capture does `failOnError` apply). Read the
verdict with:

```bash
kubectl get cm aicr-validate-result -n <ns> -o jsonpath='{.data.ctrf\.json}' | jq .results.summary
```

With `validate.emitEvidence: true`, the in-toto attestation bundle is also captured (gzipped, size-guarded) for offline verification:

```bash
kubectl get cm aicr-evidence-bundle -n <ns> -o jsonpath='{.binaryData.evidence\.tgz}' \
  | base64 -d > evidence.tgz && mkdir -p evidence && tar xzf evidence.tgz -C evidence
aicr evidence verify ./evidence
```

Operational notes: when validation is enabled, drop `--no-wait` from
`deployFlags` (so `deploy.sh` waits for convergence before the verdict) and
prefer `--retries 1` — the default retry/backoff schedule can stretch a
single slow component toward an hour, and the Job's
`activeDeadlineSeconds` (default 10800s, sized for real GPU convergence) is
the overall cap. Keep validation off on GPU-less clusters (kind included) —
the deployment phase legitimately fails while GPU pods sit Pending.

## Supply-chain verification

The Job downloads the pinned release tarball and verifies its sha256 against the release's `aicr_checksums.txt` before executing anything (fail-closed). For stricter provenance, set `aicrSha256.<arch>` to the expected tarball hash: that anchors trust in reviewed chart values rather than in release assets fetched at runtime. An empty entry skips only this extra pin — the checksums-file verification always runs.

The Job pod runs as nonroot (UID 65532, matching upstream's own image user) with a read-only root filesystem; all work happens in an `emptyDir` mounted at `/tmp`.

## RBAC

The Job's ServiceAccount is bound to `cluster-admin`. AICR bundles install cluster-scoped resources (CRDs for DRA, NVSentinel, and the Prometheus operator, namespaces, and RBAC in those namespaces), so a namespaced role is not sufficient. The binding is scoped to the Job's ServiceAccount and is removed with the release.

## Scope and limitations

- Evidence bundles are captured unsigned; signing (`aicr evidence publish`) is an identity-bearing act done outside the cluster, after extraction.

- On clusters without GPUs (kind included), GPU-dependent pods stay Pending and `--best-effort` keeps the install going. That is what the k0rdent catalog's kind e2e exercises: the delivery mechanics, not GPU functionality.

- **Component-failure detection is the chart's, not deploy.sh's.** At aicr v0.18.0, `deploy.sh` reports component failures but never exits non-zero for them (with or without `--best-effort`). The Job therefore detects the failure report itself: without `--best-effort`, component failures fail the Job; with `--best-effort`, they are logged and the Job succeeds — partial installs can never masquerade as silent success.

- **Air-gapped clusters are not supported by this chart version.** AICR itself already supports air-gapped delivery — `aicr bundle --vendor-charts` pulls chart bytes into the bundle, and upstream ships an air-gap mirror workflow (`docs/user/air-gap-mirror.md`) plus a CycloneDX SBOM of every deployable image for mirror planning. Exposing this here needs a mirrored binary source and registry overrides in addition to `bundleFlags: "--vendor-charts"`; planned for a future chart version.

- Re-running the Job re-applies the bundle (`helm upgrade` semantics downstream); strict idempotency guarantees are not part of v0.1.1.

- **Do not upgrade while an install is still running.** Each revision renders a new Job (`<release>-install-<revision>`), and Helm deletes the previous revision's Job because it is absent from the new manifest — which SIGKILLs `deploy.sh` mid-run and can leave downstream releases stuck in `pending-install`/`pending-upgrade`. `ttlSecondsAfterFinished` only reaps Jobs that have *finished*, so it does not help here. Let an install converge before changing values.

- No drift detection between runs and no CRD status surface: the Job converges the cluster once per release revision, and its status is the Job exit code plus the ConfigMaps it writes. For continuous reconciliation, run the chart under a GitOps controller.

## Relationship to upstream

This chart is not affiliated with NVIDIA. AICR does not currently publish a Helm chart for the install step; if upstream adopts one, this chart is intended to be superseded by it.

## License

Apache 2.0 — see [LICENSE](LICENSE).
