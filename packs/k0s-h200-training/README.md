# k0s-h200-training

An illustrative AICR [`--data` pack](https://github.com/NVIDIA/aicr/blob/main/docs/integrator/data-extension.md): a worked example of how an org encodes its environment facts as an overlay on top of upstream AICR, here for a **bare-metal Kubernetes cluster running k0s with H200 GPUs**. It registers one named recipe (`k0s-h200-training`) that layers on upstream's `service: k0s` overlays and carries this example fleet's facts (driver present, no InfiniBand, GDS unavailable) as component overrides, so the resolved recipe needs zero per-cluster flags. It is not a product service; copy it and change the facts to match your own fleet.

```
packs/k0s-h200-training/
├── registry.yaml                    # required stub; components: []
└── overlays/
    └── k0s-h200-training.yaml       # leaf: service k0s + h200 + training
```

Criteria chain: `service: k0s`, `accelerator: h200`, `intent: training`. Leaf/recipe name: `k0s-h200-training`.

## What upstream covers now, and what this example still shows

Upstream AICR ships `service: k0s` since aicr v0.22.0. (Verified 2026-10-22 with `gh api`: `recipes/overlays/k0s.yaml` is absent at tag v0.21.1 and present at v0.22.0; the v0.20.0 binary rejects the value with `invalid service type: k0s`.) On v1.2.0 (verified 2026-11-05; upstream's `k0s`, `k0s-training` and `h200-k0s-ubuntu-training` overlay files are unchanged from v1.1.2):

- Upstream's `k0s` overlay sets gpu-operator's `toolkit.env` (the three `CONTAINERD_*` variables that point the toolkit at k0s's own containerd) and the `K8s.server.version >= 1.34` constraint. Nothing else.
- Upstream's `k0s-training` overlay adds no overrides.
- Upstream's `h200-k0s-ubuntu-training` leaf (criteria include `os: ubuntu`) sets the host-driver facts: `driver.enabled: false`, `migManager.enabled: false`, `nvidiaDriverRoot: /`, and `nvsentinel` `labeler.assumeDriverInstalled: true`. This pack's leaf has no `os` in its criteria, so that upstream leaf is **not** applied to it, and those facts depend on this pack here. Both leaves coexist: `aicr recipe list --data ./packs/k0s-h200-training` lists the embedded `h200-k0s-ubuntu-training` and this pack's external `k0s-h200-training`. With this pack loaded, `--os ubuntu` applies **both** leaves (this one first, upstream's last, so upstream's wins on the keys it sets); omitting `os` applies only this one; without the pack, `--os ubuntu` applies only upstream's (appliedOverlays order checked on v1.2.0, 2026-11-05).
- No upstream overlay in the chain this leaf resolves through sets `driver.rdma`, `gds` or `gdrcopy`. The pack explicitly sets all three off. Against aicr's base gpu-operator values (`recipes/components/gpu-operator/values.yaml` at v1.2.0, read 2026-11-05) only `gdrcopy.enabled` changes the effective value (base `true` to `false`); the base already has `driver.rdma.enabled: false`, and does not set `gds`.

So this pack's override set is kept whole as a teaching example. Where an override duplicates something upstream sets, it layers harmlessly, and the overlay's comments say which ones. The duplicates stay so that the example shows every fact in one file and so the pack keeps resolving on the previous pin, v0.20.0.

Resolved on v1.2.0, `metadata.appliedOverlays` is `base, monitoring-hpa, h200-any, k0s, k0s-training, k0s-h200-training`.

### Scope: what is k0s-general vs. what is this fleet

Only `gpu-operator.toolkit.env` is true of k0s generally (any k0s node bundles its own containerd); upstream's `k0s` overlay now carries it. Everything else is a fact about the example fleet:

- Driver ownership (`gpu-operator.driver.enabled: false` + `nvidia-dra-driver-gpu.nvidiaDriverRoot: /`).
- No InfiniBand (`driver.rdma.enabled: false`, `gdrcopy.enabled: false`) and no `nvidia_fs` (`gds.enabled: false`): hardware or host-configuration facts, unrelated to which Kubernetes distribution runs.
- MIG left off (`migManager.enabled: false`): an operational policy choice.

## Environment facts

Each override below is carried in [`overlays/k0s-h200-training.yaml`](overlays/k0s-h200-training.yaml); see that file's comments for the full explanation.

| Override | Value | Why | Upstream (v1.2.0) |
|---|---|---|---|
| `gpu-operator.driver.enabled` | `false` | Host carries the driver (verified 610.57.04). The operator must not install its own. | Also set by upstream's `os: ubuntu` leaf only. |
| `gpu-operator.driver.rdma.enabled` | `false` | No RDMA/InfiniBand on this host — verified 2026-08-26: no `ib_`/`rdma_`/`mlx` kernel modules loaded, `/sys/class/infiniband` empty, `nvidia_peermem` absent. GPUDirect RDMA has nothing to bind to. | Not set by upstream overlays in this chain. |
| `gpu-operator.toolkit.enabled` | `true` | The toolkit is installed by the operator: this host has no `nvidia-container-toolkit`. | Not set by any upstream overlay; `true` is also the value in aicr's base gpu-operator values (v1.2.0) and in an upstream-only bundle, so this is explicit for readability. |
| `gpu-operator.toolkit.env` | `CONTAINERD_CONFIG=/etc/k0s/containerd.d/nvidia.toml`<br>`CONTAINERD_SOCKET=/run/k0s/containerd.sock`<br>`CONTAINERD_RUNTIME_CLASS=nvidia` | Must target k0s's own containerd, not the distro default — otherwise the toolkit configures the wrong containerd, reports success, and GPU pods fail with `no runtime for "nvidia" is configured`. | Also set by upstream `k0s` overlay (aicr >= v0.22.0). |
| `gpu-operator.gds.enabled` | `false` | GPUDirect Storage needs the `nvidia_fs` kernel module, which is not loaded here. | Not set by upstream overlays in this chain. |
| `gpu-operator.gdrcopy.enabled` | `false` | GDRCopy accelerates GPUDirect RDMA transfers specifically; the same verified absence of RDMA/InfiniBand as `driver.rdma.enabled` above means there's no RDMA fabric for it to accelerate. | Not set by upstream overlays in this chain (an upstream-only k0s bundle has it `true`). |
| `gpu-operator.migManager.enabled` | `false` | Off: MIG (re)configuration is disruptive to already-running workloads, so it should be an explicit opt-in rather than a default. | Also set by upstream's `os: ubuntu` leaf only. |
| `nvidia-dra-driver-gpu.nvidiaDriverRoot` | `/` | Host-installed driver userspace lives at the host root. **Required counterpart to `driver.enabled: false` above** — aicr's driver-ownership coherence check exits 2 if only one side is set. | Also set by upstream's `os: ubuntu` leaf only. |
| `nvsentinel.labeler.assumeDriverInstalled` | `true` | With a host-provided driver there is no driver pod for the labeler to observe; without this, several NVSentinel DaemonSets silently come up with 0 desired pods. Verified 2026-11-05: with it `false`, `aicr bundle` exits 2 on v1.2.0 and on v0.20.0. Required counterpart to the driver-ownership pair above. | Also set by upstream's `os: ubuntu` leaf only. |
| constraint `K8s.server.version` | `>= 1.34` | Matches upstream's `k0s` overlay floor. | Also set by upstream `k0s` overlay (aicr >= v0.22.0). |

Two things this pack deliberately does *not* override, both confirmed absent from the resolved recipe's `gpu-operator` overrides:

- **DCGM / dcgmExporter stay enabled** (aicr's base gpu-operator values at v1.2.0 have `dcgm.enabled: true`, verified 2026-11-05; the pack sets no `dcgm` override). On real H200s, DCGM being on is what lets the `accelerator-metrics` validator actually pass.
- **`nodewright-customizations` is not included** — node tuning drains/reboots the node, unacceptable on a shared lab VM.

## Resolving and verifying the pack

Resolve it directly with the `aicr` CLI (v1.2.0, the chart's pin; no cluster, no GPU required):

```bash
aicr recipe --service k0s --accelerator h200 --intent training \
  --data ./packs/k0s-h200-training -o recipe.yaml
```

This succeeds with `components=12` and `overlays=6` (v1.2.0, verified 2026-11-05): `cert-manager, dra-node-labeler, gpu-operator, k8s-ephemeral-storage-metrics, kai-scheduler, kube-prometheus-stack, nfd, nodewright-operator, nvidia-dra-driver-gpu, nvsentinel, prometheus-adapter, prometheus-operator-crds`. (`aicr bundle` skips `dra-node-labeler` unless DRA eviction is opted in, so the bundle holds 11 component directories.)

Run the full offline assertion suite (leaf listed, every override above survives resolution, the pack layers on upstream's `k0s` overlays, and the bundle and `aicr verify` steps) with:

```bash
./hack/verify-pack.sh
```

It asserts, among other things, that `--criteria-strict` **accepts** `service: k0s`. That is the flip from earlier releases: k0s is upstream's value now, so the pack is no longer what registers it. It also asserts that `metadata.appliedOverlays` contains `k0s`, `k0s-training` and `k0s-h200-training` in that order, i.e. the example really sits on top of upstream's overlays.

## Consuming it through the `nvidia-aicr` chart

Once this pack is published as an OCI artifact (see [`PUBLISH.md`](PUBLISH.md) — not yet done as of this writing), point the chart's `dataPack` value at it and set the matching criteria:

```yaml
dataPack: "ghcr.io/ramessesii2/aicr-packs/k0s-h200-training:0.1.0"  # target ref; see PUBLISH.md
service: k0s
accelerator: h200
intent: training
```

Leave `environment.preinstalledDriver` alone (`false`): this pack's `driver.enabled` + `nvidiaDriverRoot` already say the driver is host-owned, and setting it `true` on top would apply the same overrides twice from two places.

## Version compatibility

- **aicr v1.2.0** — the version the chart pins (`aicrVersion` in `values.yaml`) and the primary target — resolves this pack (header `aicr.run/v1beta1`), bundles it with `--data`, and the bundle passes `aicr verify`. Layers on upstream's `k0s` and `k0s-training` overlays.
- **aicr v0.20.0** — the previous pin — still resolves and bundles this pack (verified 2026-11-05; it reads the same `v1beta1` header). Without the pack, v0.20.0 rejects `service: k0s` (`invalid service type: k0s`, verified 2026-11-05); with it, the pack registers the value itself.

`hack/verify-pack.sh` asserts both.
