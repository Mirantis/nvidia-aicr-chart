# nvidia-aicr-chart

A Helm chart that installs the NVIDIA AI stack on a Kubernetes cluster by running [NVIDIA AI Cluster Runtime (AICR)](https://github.com/NVIDIA/aicr) in a Job. AICR's version-locked, dependency-ordered recipes become installable by anything that speaks Helm — `helm install`, Argo CD, Flux, or a k0rdent `MultiClusterService`.

**Why this chart:**

- **GitOps-native delivery.** AICR is a CLI; this chart is the declarative envelope that lets fleet managers and reconcilers deliver it.
- **The validated matrix, not hand-picked versions.** One install converges a cluster on NVIDIA's tested combination of driver, operators, scheduler, and monitoring — component versions and ordering come from the pinned AICR release.
- **Recipes become named, versioned artifacts.** An org [data pack](#bring-your-orgs-recipes---data-packs) registers your own criteria value (`service: yourorg`) and carries your environment profile — every cluster installs the same recipe by name, with zero per-cluster flags.
- **Supply chain, end to end.** Checksum-pinned binary with an optional reviewed strict pin, captured CTRF verdicts, and evidence bundles published signed or unsigned-then-sign-later.
- **Operable and tested.** What resolved, what passed, and the proof all land in ConfigMaps; the chart itself ships with a mutation-tested render suite and a reproducible end-to-end test.

The chart is one Kubernetes Job plus its ServiceAccount and RBAC. On the target cluster it:

1. downloads a pinned `aicr` release binary and verifies its checksum,
2. pulls your org's `--data` extension pack when one is configured,
3. runs `aicr recipe` with the criteria supplied through chart values, and captures the resolved recipe to a ConfigMap,
4. runs `aicr bundle` to render the recipe into a Helm bundle,
5. verifies the rendered bundle (`aicr verify`, closed-world checksums) and executes its `deploy.sh` to install the stack,
6. optionally runs `aicr validate`, captures the verdict to a ConfigMap, and publishes the evidence bundle to an OCI registry.

AICR is consumed unmodified — no wrapper logic, no duplicated behavior — so component versions and install ordering always come from the pinned upstream release.

> **v0.3.0 is experimental.** It targets connected clusters. The install path is the proven core; data packs, validation, and evidence publishing are opt-in values, default off.

## Install

There is no default accelerator — state your criteria (see ["Which criteria?"](#which-criteria) below):

```bash
helm install nvidia-aicr oci://ghcr.io/mirantis/charts/nvidia-aicr \
  --version 0.3.0 \
  --namespace nvidia-aicr --create-namespace \
  --set accelerator=h100
```

> **Upgrading from 0.2.0?** Do these in order (details in "k0s clusters" and
> the "Upgrading a cluster converged on an earlier pin" bullet under
> [Scope and limitations](#scope-and-limitations)):
>
> 1. Republish org packs with `apiVersion: aicr.run/v1beta1` first. This is
>    safe while still on chart 0.2.0, because aicr v0.20.0 reads v1beta1
>    (verified 2026-10-22; re-verify with `.tmp/aicr-0.20.0 recipe --data
>    hack/e2e/acme-aicr-pack --service acme --accelerator h100 --intent
>    training -o /dev/null`).
> 2. Replace `environment.k0sContainerd` with `service: k0s` (Kubernetes >= 1.34).
> 3. Replace `service: self-managed`/`self`/`vanilla` with `service: any`.
> 4. Before re-running over a converged cluster, run `aicr upgrade-check
>    --from cluster --to <recipe> --deployer helm`. gpu-operator, nvsentinel
>    and nvidia-dra-driver-gpu currently report blocked.
>
> A k0rdent MCS template bump (`nvidia-aicr-0-3-0`) rolls an install Job to
> every matched cluster, so step 4 applies per cluster.

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

See upstream [Data Extension](https://docs.nvidia.com/aicr/integrator-guide/data-extension/) for pack authoring.

### Private pack registries

`dataPackSecret` names an **existing** Secret of type `kubernetes.io/dockerconfigjson` in the release namespace; the pull initContainer authenticates with it. Empty means anonymous (public artifacts only).

```bash
kubectl create secret docker-registry aicr-pack-pull -n nvidia-aicr \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>
```

A bad or missing credential fails the initContainer visibly — fail-closed, never a silent fallback to anonymous.

If your reconciler can inject secrets as values without putting them in git
— Flux `HelmRelease` `valuesFrom: secretKeyRef`, or k0rdent
`MultiClusterService` `serviceSpec.services[].valuesFrom` — `dataPackAuth.dockerconfigjson`
lets the chart create the Secret instead. The credential then also lives in Helm release
storage on the target cluster: that is the trade-off you accept.
The default remains: the chart never creates the Secret.

### Landing the Secret on fleet children

On a k0rdent fleet, kcm bundles Sveltos: keep **one** wrapper Secret on the management cluster
and a `ClusterProfile` whose selector matches the same labels your
`MultiClusterService` uses — Sveltos applies the wrapped dockerconfigjson
(and its namespace) to every matched child, and rotation is one `kubectl
apply` on the mothership. Worked example with ordering caveats:
[`examples/fleet/fleet-secret-distribution.yaml`](examples/fleet/fleet-secret-distribution.yaml)
The same Secret serves all three credential consumers (pack pull, evidence
publish, validator pulls — see "Private validator images"). Create the
distribution **before** labeling clusters into the fleet, or order two
MultiClusterServices with `dependsOn`. If `validate.publish.registrySecret`
names a Secret that has not landed yet, the Job's pod cannot start (the
Secret is a required volume), so nothing runs until the Secret lands or
`job.activeDeadlineSeconds` expires; the Job is never green. If
publish is enabled with no `registrySecret` at all, the push is anonymous, a
private registry rejects it, and with `validate.publish.failOnError: false`
(the default) the Job still goes green with no published evidence. Enterprise secret
stores: External Secrets Operator on the children fills the same role;
the chart needs nothing special.

### Private validator images

A pack's validator catalog may reference private images. Those are pulled by the **kubelet** in the namespace where `aicr validate` runs its validator Jobs (default `aicr-validation`) — `dataPackSecret` does not cover them. aicr exposes the knobs natively; pass them through `validateArgs`:

```yaml
validateArgs:
  - --namespace
  - nvidia-aicr    # the release namespace
  - --image-pull-secret
  - acme-registry-cred
```

With `--namespace` set to the release namespace, the *same* dockerconfigjson Secret used for `dataPackSecret` can serve as the validator pull secret — one robot token, one Secret object, all three consumers (pack pull, evidence push, validator pull). That `--namespace` is the load-bearing part: without it the validator Jobs run in `aicr-validation`, where the Secret does not exist. The stock validators and the snapshot agent (`ghcr.io/nvidia/aicr`) are public and need none of this. Note that the one-Secret story is about `dataPackSecret`: `dataPackAuth` creates a pack-pull Secret only, and `validate.publish.registrySecret` / `--image-pull-secret` still need a Secret you supply.

## Which criteria?

Recipe selection is criteria assembly against AICR's catalog (`service`, `accelerator`, `intent`, `os`, `platform`). Two failure modes matter:

- **Over-specification fails hard**: naming a dimension the matching overlays don't declare is rejected outright (e.g. `intent: training` with `service: any`: a stated intent needs a service that declares it, and at v1.2.0 those are `aks`, `bcm`, `eks`, `k0s`, `kind`, `lke`, `ocp`, `rke2`, `cks` with `os: ubuntu`, `gke` with `os: cos`, and `oke` with `os: ol`; verified 2026-11-05). The error message lists supported combinations — but you only see it in the Job log, minutes after `helm install` returned.
- **Under-specification degrades silently**: fewer stated dimensions resolve a *thinner* stack with exit 0 and no warning. `accelerator: a100` alone resolves 12 components; a fully-specified EKS training leaf (`--service eks --accelerator h100 --intent training --os ubuntu`) resolves 15 (aicr v1.2.0, verified 2026-11-05).

Defend against both:

```bash
aicr recipe list --gpu h200        # before: which combinations exist for your GPU
kubectl get cm aicr-recipe -n <ns> -o jsonpath='{.data.summary\.txt}'   # after: what resolved
```

The chart refuses to render with no criteria at all: state an `accelerator`, or set `dataPack` (your pack owns criteria), or state a concrete `service` plus `intent` (accelerator-less leaves like `bcm`+`inference` exist; `service: any` does not count). Extra arguments (`--nodes`, `--criteria-strict`) pass through `recipeArgs`.

## Values

| Key | Default | Meaning |
|---|---|---|
| `accelerator` | `""` **(required*)** | Target accelerator: `h100`, `h200`, `gb200`, `gb300`, `b200`, `b300`, `a100`, `l40`, `l40s`, `rtx-pro-6000`, `vr200`. *Render fails unless this, `dataPack`, or concrete `service`+`intent` is set |
| `intent` | `""` | Recipe intent (`training`, `inference`). **Empty omits the flag.** A stated intent must be declared by the matching overlays, so it needs a service that provides it (not `any`) — see "Which criteria?" |
| `os` | `""` | Node OS (`ubuntu`, `rhel`, `rocky`, `cos`, `amazonlinux`, `ol`, `sles`, `talos`). **Empty omits the flag** |
| `platform` | `""` | Workload platform (`kubeflow`, `dynamo`, `kueue`, `nim`, `runai`, `slurm`). **Empty omits the flag** |
| `service` | `any` | Service overlay: `aks`, `bcm`, `cks`, `eks`, `generic`, `gke`, `k0s`, `kind`, `lke`, `metal3`, `mk8s`, `nvke`, `ocp`, `oke`, `rke2`, a pack-registered value (e.g. `acme`), or `any` for self-managed clusters. `generic` and `metal3` are accepted by the CLI but have no recipe for most accelerators (e.g. `--service metal3 --accelerator h100` exits 2 with `no recipe provides service`; v1.2.0, verified 2026-11-05). Use `any`, not `self-managed`/`self`/`vanilla`: at v1.2.0 those names map to `generic`, which has no recipe for most accelerators (see "k0s clusters" and the CHANGELOG). Use `k0s` on k0s clusters |
| `dataPack` | `""` | OCI reference (no scheme) of your org's `--data` extension pack |
| `dataPackSecret` | `""` | Existing dockerconfigjson Secret for private pack registries |
| `dataPackAuth.dockerconfigjson` | `""` | Opt-in: raw dockerconfigjson content; the chart creates `<release>-pack-auth` and uses it for the pack pull. Mutually exclusive with `dataPackSecret`. For reconcilers with native secret-to-values injection (Flux `valuesFrom`, kcm MCS `serviceSpec.services[].valuesFrom`); see "Private pack registries" for the exposure trade-off |
| `dataPackPlainHTTP` / `dataPackInsecureTLS` | `false` | Pack-pull transport for lab registries (plain HTTP / untrusted TLS) — production registries need neither |
| `orasImage` | `ghcr.io/oras-project/oras:v1.2.0@sha256:0087224dd0decc354b5b0689068fbbc40cd5dc3dbf65fcb3868dfbd363dc790b` | initContainer image that pulls `dataPack`; pinned to the multi-arch index covering linux/amd64 and linux/arm64 |
| `recipeConfigMap` | `aicr-recipe` | ConfigMap receiving the resolved recipe + summary; `""` disables |
| `aicrVersion` | `v1.2.0` | Pinned [aicr release](https://github.com/NVIDIA/aicr/releases) tag |
| `aicrArch` | `amd64` | Binary architecture: `amd64` or `arm64` |
| `aicrSha256` | `{amd64: <v1.2.0 hash>, arm64: <v1.2.0 hash>}` | Strict pin keyed by architecture; the entry matching `aicrArch` is used. Update on every `aicrVersion` bump. See "Supply-chain verification" |
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
| `recipeArgs` | `[]` | **Recommended:** arguments passed to `aicr recipe`; one list element is one complete argument, preserving spaces, apostrophes and glob characters. Quote every element, including numbers and booleans. Appended after `recipeFlags` |
| `recipeFlags` | `""` | Legacy extra flags for `aicr recipe`. Split on whitespace; no shell quoting is interpreted, and matching glob patterns expand. Use `recipeArgs` when an argument needs whitespace, quotes or a literal `*` |
| `bundleArgs` | `[]` | **Recommended:** arguments passed to `aicr bundle`, after `bundleFlags`; one list element is one complete argument. Quote every element, including numbers and booleans. Applied after `environment.*`, so operator values win |
| `bundleFlags` | `""` | Legacy extra flags for `aicr bundle` — see "Tainted GPU nodes". Split on whitespace; no shell quoting is interpreted, and matching glob patterns expand |
| `validateArgs` | `[]` | **Recommended:** arguments passed to `aicr validate`, after `validateFlags`; one list element is one complete argument. Quote every element, including numbers and booleans. See "Private validator images" |
| `validateFlags` | `""` | Legacy extra flags for `aicr validate` (`--namespace`, `--image-pull-secret`, `--node-selector`). Split on whitespace; no shell quoting is interpreted, and matching glob patterns expand |
| `job.extraEnv` | `[]` | Extra env for the installer container, verbatim (e.g. `AICR_NCCL_FABRIC`) |
| `environment.preinstalledDriver` | `false` | Nodes already carry an NVIDIA driver — prefer encoding this in your org pack. `service: k0s` does **not** imply it; see "k0s clusters" |
| `deploy.enabled` | `true` | `false` = assert-only run: skip bundle+deploy entirely and validate the cluster against the resolved recipe. Requires `validate.enabled`; see "Validation postures" |
| `deployArgs` | `[]` | **Recommended:** arguments passed to the bundle's `deploy.sh`, after `deployFlags`; one list element is one complete argument, preserving spaces, apostrophes and glob characters. Quote every element, including numbers and booleans. The non-empty legacy default still applies; set `deployFlags: ""` for list-only arguments |
| `deployFlags` | `--best-effort --no-wait` | Legacy flags for `deploy.sh` (accepts `--best-effort`, `--no-wait`, `--retries N`). Split on whitespace; no shell quoting is interpreted, and matching glob patterns expand. Use `deployArgs` for structured arguments |
| `runtimeImage` | `alpine/k8s:1.34.0@sha256:b5f6edfeac5279f3e182d938d1ffecb62f7c980756ac4b6b66d7f0d566782f77` | Job image; pinned to the multi-arch index covering linux/amd64 and linux/arm64. Must include `bash`, `curl`, `kubectl`, and `helm` |
| `job.*` | see `values.yaml` | Job backoff, TTL, deadline, and resource settings |
| `job.tolerations` | `[]` | Tolerations for the **installer pod itself** — required on clusters whose only workers are tainted GPU nodes; see "Tainted GPU nodes" |
| `job.nodeSelector` / `job.affinity` / `job.priorityClassName` | empty | Remaining scheduling controls for the installer pod |

Structured argument rendering, literal space/apostrophe/glob handling, and
placement after each legacy string were exercised by `hack/verify-render.sh`
with Helm v4.3.0 and bash 5.3.20(1)-release, verified 2026-11-05. The image
index digests were resolved with Docker 29.9.2 and curl 8.7.1 on the same date;
CONTRIBUTING's release checklist refreshes them.

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
      version: 0.3.0
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
      - template: nvidia-aicr-0-3-0
        name: nvidia-aicr
        namespace: nvidia-aicr
        values: |
          dataPack: "ghcr.io/acme/acme-aicr-pack:1.0.0"
          dataPackSecret: "aicr-pack-pull"
          service: acme
          accelerator: h200
          intent: training
          bundleArgs:
            - --accelerated-node-toleration
            - nvidia.com/gpu=present:NoSchedule
          deployFlags: ""                 # replace the legacy default with list-only args
          deployArgs: [--retries, "1"]   # strict: wait and gate on the verdict
          validate:
            enabled: true
            phases: [deployment]
            failOnError: true
            emitEvidence: true
            publish: {enabled: true, mode: unsigned, ref: ghcr.io/acme/aicr-evidence, registrySecret: aicr-pack-pull}
```

`dataPackSecret` must exist on each child before the Job runs — see "Landing the Secret on fleet children".

## Tainted GPU nodes

Production clusters commonly taint GPU nodes (e.g. `nvidia.com/gpu=present:NoSchedule`). AICR injects tolerations into the rendered charts when asked; pass the arguments through `bundleArgs`:

```yaml
bundleArgs:
  - --accelerated-node-toleration
  - nvidia.com/gpu=present:NoSchedule
```

Without this, GPU-targeted components stay `Pending` on tainted nodes. Related scheduling flags (`--system-node-selector`, `--system-node-toleration`, `--workload-gate`, `--set component:path=value`) pass through the same way.

**`bundleArgs` covers the components AICR deploys — not the installer Job itself.** On a cluster whose only worker pool is tainted, the Job's own pod will never schedule, and it burns the full `activeDeadlineSeconds` (3 h by default) before failing with `DeadlineExceeded`. Tolerate the taint for the installer too:

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

**On k0s, set `service: k0s`.** Upstream AICR accepts it as a criteria value from v0.22.0 (aicr v0.20.0 rejects it with `invalid service type: k0s`; verified 2026-10-22). On v1.2.0 (verified 2026-11-05, from the overlays at tag v1.2.0, unchanged from v1.1.2, and `aicr recipe`), upstream's `k0s` overlay sets two things and nothing else:

- the GPU operator toolkit's containerd environment (`CONTAINERD_CONFIG=/etc/k0s/containerd.d/nvidia.toml`, `CONTAINERD_SOCKET=/run/k0s/containerd.sock`, `CONTAINERD_RUNTIME_CLASS=nvidia`). Without it the toolkit configures the *default* containerd, reports success, and GPU pods then fail with `no runtime for "nvidia" is configured`;
- the constraint `K8s.server.version >= 1.34`.

The `k0s-training` overlay adds only the `training` intent. **`service: k0s` does not imply a preinstalled driver.** The driver facts (GPU operator `driver.enabled: false` and `migManager.enabled: false`, DRA driver `nvidiaDriverRoot: /`, NVSentinel `labeler.assumeDriverInstalled: true` and the janitor's `hostDriverRootPath: /`) and the `OS.release.ID=ubuntu`, `VERSION_ID=24.04` constraints live only in upstream's `h200-k0s-ubuntu-training` leaf, which resolves for `accelerator: h200`, `intent: training`, `os: ubuntu`:

```yaml
service: k0s
accelerator: h200
intent: training
os: ubuntu          # selects the validated h200-k0s-ubuntu-training leaf
```

Without `os`, `--service k0s --accelerator h200` resolves the generic k0s stack (12 components, no driver facts), and `--service k0s --accelerator h200 --intent training` fails with `specify os (valid: ubuntu)` unless an org pack supplies the leaf. On k0s with a host driver and no such leaf, you still need `environment.preinstalledDriver: true` (or the equivalent in your pack):

```yaml
service: k0s
accelerator: h100
environment:
  preinstalledDriver: true   # nodes already carry an NVIDIA driver
```

**`environment.k0sContainerd` was removed in chart 0.3.0** (breaking). Any value other than `false` (or absent/null) fails the render, including the quoted string `"false"` (verified 2026-10-22 with `--set-string`), and the message says what to do instead (it contains `environment.k0sContainerd was removed in chart 0.3.0`). `service: k0s` is the exact replacement. Two floors apply: `service: k0s` needs aicr >= v0.22.0, so overriding `aicrVersion` below that fails in aicr with `invalid service type: k0s`; and the overlay requires Kubernetes >= 1.34.

**`preinstalledDriver`** stays for every service with a host driver, k0s or not. It turns the GPU operator's driver install off and points the DRA driver at the host root; aicr's driver-ownership coherence check requires both, and `aicr bundle` also fails closed unless the NVSentinel labeler is told the driver is host-provided, so the toggle sets all three together. It is applied before `bundleFlags` and `bundleArgs`, so you can still override any of it. Its structured long form (preferred):

```yaml
bundleArgs:
  - --set
  - gpuoperator:driver.enabled=false
  - --set
  - dradriver:nvidiaDriverRoot=/
  - --set
  - nv-sentinel:labeler.assumeDriverInstalled=true
```

The legacy string equivalent is whitespace-split and does not interpret shell quoting:

```yaml
bundleFlags: '--set gpuoperator:driver.enabled=false --set dradriver:nvidiaDriverRoot=/ --set nv-sentinel:labeler.assumeDriverInstalled=true'
```

**Org pack with its own `service` value.** If your pack registers a private service (so `service: k0s` is not an option), the k0s containerd wiring is yours to carry. The cleaner home is the pack's overlay (the `toolkit.env` override under the `gpu-operator` component). The escape hatch without a pack change is `bundleArgs`; the full structured long form, including the list-valued `toolkit.env` (aicr's `--set` is scalar-only, hence `--set-json`):

```yaml
bundleArgs:
  - --set
  - gpuoperator:driver.enabled=false
  - --set
  - dradriver:nvidiaDriverRoot=/
  - --set
  - nv-sentinel:labeler.assumeDriverInstalled=true
  - --set-json
  - 'gpuoperator:toolkit.env=[{"name": "CONTAINERD_CONFIG", "value": "/etc/k0s/containerd.d/nvidia.toml"}, {"name": "CONTAINERD_SOCKET", "value": "/run/k0s/containerd.sock"}, {"name": "CONTAINERD_RUNTIME_CLASS", "value": "nvidia"}]'
```

Unlike the legacy form, the JSON argument can contain spaces and the inner double quotes are passed through unchanged (the chart's array rendering was checked with Helm v4.3.0 and this exact JSON bundled successfully with aicr v1.2.0, verified 2026-11-05). The legacy string form requires whitespace-free JSON because it is split on whitespace and performs no quote removal:

```yaml
bundleFlags: '--set gpuoperator:driver.enabled=false --set dradriver:nvidiaDriverRoot=/ --set nv-sentinel:labeler.assumeDriverInstalled=true --set-json gpuoperator:toolkit.env=[{"name":"CONTAINERD_CONFIG","value":"/etc/k0s/containerd.d/nvidia.toml"},{"name":"CONTAINERD_SOCKET","value":"/run/k0s/containerd.sock"},{"name":"CONTAINERD_RUNTIME_CLASS","value":"nvidia"}]'
```

[`packs/k0s-h200-training`](packs/k0s-h200-training/) is an illustrative worked example of an org pack: it layers on upstream's `service: k0s` overlays and carries one example fleet's facts as overrides. Copy it and change the facts to match your own fleet; it is not a product service.

**Self-managed clusters: use `service: any`.** Earlier docs recommended the names `self-managed`, `self` and `vanilla`. At v1.2.0 those aliases resolve to `generic`, not `any`, and `generic` has no recipe for most accelerators (`aicr recipe --service self-managed --accelerator h100` exits 2 with `no recipe provides service 'generic'`; verified 2026-11-05). The chart does not guard against this at render time, so the failure shows up in the Job log.

The chart's k0s path was verified end to end on 8× H200 SXM bare metal (k0s v1.36.2, kcm 1.9.0) with aicr v0.20.0 in 2026-08: all components installed under strict flags and aicr's deployment phase passed 4/4. That run used the removed `environment.k0sContainerd` toggle; the `service: k0s` path has been checked offline only (recipe resolution against the v1.1.2 binary on 2026-10-22 and the v1.2.0 binary on 2026-11-05), not on hardware.

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

`aicr validate` installs or upgrades no recipe component. It does create short-lived objects of its own: each validator runs as a Kubernetes Job and, without `--snapshot`, a snapshot agent captures the cluster first (both in `--namespace`, with per-run RBAC that is removed at the end unless `--no-cleanup`; aicr v1.2.0 `validate --help`, 2026-11-05). Performance validators may also start their own benchmark workloads. The chart's `deploy.enabled` toggle and `validate.phases` therefore span four postures (worked values in [`examples/`](examples/)):

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

Before executing `deploy.sh`, the Job runs `aicr verify` on the rendered
bundle — upstream's closed-world gate: every file is checked against the
bundle's `checksums.txt`, and any addition, removal, or modification fails
the Job. In-Job bundles are unattested, so this verifies integrity, not
provenance (and external `--data` packs cap upstream's trust level at
`attested` regardless).

The Job pod runs as nonroot (UID 65532, matching upstream's own image user) with a read-only root filesystem; all work happens in an `emptyDir` mounted at `/tmp`.

## RBAC

The Job's ServiceAccount is bound to `cluster-admin`. AICR bundles install cluster-scoped resources (CRDs for DRA, NVSentinel, and the Prometheus operator, namespaces, and RBAC in those namespaces), so a namespaced role is not sufficient. The binding is scoped to the Job's ServiceAccount and is removed with the release.

## Scope and limitations

- **Kubernetes 1.32 is the chart-wide minimum** (`kubeVersion: ">= 1.32.0-0"`, enforced by Helm at template/lint time; Helm v4.3.0, verified 2026-11-05). The pinned default criteria resolve `K8s.server.version >= 1.32` (`.tmp/aicr-1.2.0 recipe --service any --accelerator h100`; aicr v1.2.0, verified 2026-11-05). Recipe-specific floors can be stricter: `service: k0s` requires **Kubernetes >= 1.34**, as its resolved constraint states. Other recipes may impose their own constraints, so check the recipe rather than treating 1.32 as sufficient for every target.

- Evidence bundles published in `signed` mode place the identity token in the install pod (see "Publishing evidence"); `unsigned` mode exists precisely so identity never has to enter the cluster.

- On clusters without GPUs (kind included), GPU-dependent pods stay Pending and `--best-effort` keeps the install going. That is what the k0rdent catalog's kind e2e exercises: the delivery mechanics, not GPU functionality.

- **Component-failure detection is belt-and-braces.** aicr v1.2.0's
  `deploy.sh` (same logic as v1.1.2's; read from a generated bundle,
  2026-11-05) exits 1 on a component failure when `--best-effort` is absent;
  with `--best-effort` it continues past failed components, prints
  `Deployment completed with failures (--best-effort):` and exits 0; and it
  exits 2 when every component installed but the DRA kubelet-plugin restart
  was deferred because the GPU operator's driver migration had not settled
  (if a component also failed, it exits 1). The Job fails on any non-zero
  deploy exit **and** independently detects the failure report: without
  `--best-effort`, component failures fail the Job; with it, they are logged
  and the Job succeeds. Exit 2 is the exception under `--best-effort`: the Job
  logs `WARN: deploy.sh deferred the DRA kubelet-plugin restart (exit 2)` and
  continues to validation, only when deploy.sh's own line `DRA kubelet plugin
  restart blocked, retry needed for:` is in the log and no failure report is
  (any other exit 2 stays fatal). To finish, let the operator converge and
  re-run the install (`helm upgrade` creates a fresh Job, which re-runs
  `deploy.sh`). Without `--best-effort`, exit 2 fails the Job. Partial
  installs cannot masquerade as silent success either way.

- **Upgrading a cluster converged on an earlier pin is not a plain re-run.** A fresh install is unaffected. Re-running chart 0.3.0 over a cluster that chart 0.2.0 (aicr v0.20.0) converged crosses component boundaries that upstream's `aicr upgrade-check` currently reports as blocked. Indicative result for `service: any` + `h100`, v0.20.0 to v1.2.0 (run 2026-11-05 with the v1.2.0 binary; v1.2.0's `upgrade-check` refuses a v0.20.0-generated recipe file, `aicr.run/v1alpha2 was retired in v1.0.0`, so this used that recipe with its header rewritten to `aicr.run/v1`, which is not an upstream-supported input): gpu-operator v26.3.3 to v26.7.2 **blocked** ("stops at =26.7.1"; "no record describes an upgrade starting from v26.3.3. The earliest recorded starting point is 26.7.0, and no record assesses the move from v26.3.3 to it"); nvsentinel v1.20.0 to v1.28.0 **blocked** ("stops at 1.25.0"; "The earliest recorded starting point is 1.22.0"); nvidia-dra-driver-gpu 0.4.1 to 0.5.1 **blocked** ("stops at 0.5.1"; "The earliest recorded starting point is 0.5.0"); for each of the three upstream says "Read the component's upstream release notes for that move before applying it, then re-run this check". nodewright-operator v0.17.1 to v0.20.0 **manual**, with a namespace relocation `skyhook -> nodewright` that no record assesses; nfd 0.19.0 to 0.20.1 **manual** (3 steps, of which the two RBAC steps, widen-nrt-rbac and narrow-nrt-rbac, apply "only when your nfd override sets topologyUpdater.rbac.create=false"; upgrade-nfd always applies; "chart-managed RBAC (AICR's default) needs nothing"); kai-scheduler v0.14.1 to v0.16.9 **unknown** ("breaking boundary"). A cluster converged on an unreleased v1.1.2 build of this chart sees only nfd 0.19.0 to 0.20.1 **manual** (with chart-managed RBAC, only the upgrade itself, which re-running the chart performs) and nvidia-dra-driver-gpu 0.5.0 to 0.5.1 **safe** (`upgrade-check` from a v1.1.2 recipe to the v1.2.0 one, 2026-11-05). The bundle's `UPGRADING.md` is not enough on its own: it covers only the boundary the bundle's pinned version lands in, not earlier ones you cross. **Required first step:** from a workstation with cluster access, run `aicr upgrade-check --from cluster --to <recipe> --deployer helm` (`--from cluster` is the only supported source for a cluster converged on the old pin) and treat its verdict as authoritative; for a blocked component, first bring it to the earliest recorded starting point the check names, following that component's upstream release notes, then re-run the check, and re-run the chart only once nothing is blocked. The chart does not run `upgrade-check` for you.

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
  only; ~20–25 min.
- The signed publish path has no automated test: public Sigstore does not
  trust local cluster issuers, so it needs a Fulcio-trusted OIDC identity
  (e.g. a GitHub Actions runner). The chart's signed-mode template plumbing
  is covered by the render assertions.

## Relationship to upstream

This chart is not affiliated with NVIDIA. AICR does not currently publish a Helm chart for the install step; if upstream adopts one, this chart is intended to be superseded by it.

## License

Apache 2.0 — see [LICENSE](LICENSE).
