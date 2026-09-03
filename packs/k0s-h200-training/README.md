# k0s-h200-training

An AICR [`--data` pack](https://github.com/NVIDIA/aicr/blob/main/docs/integrator/data-extension.md) that registers a named recipe, `service: k0s`, resolving NVIDIA's validated training stack for a **bare-metal Kubernetes cluster running k0s with H200 GPUs**. The pack carries this hardware's environment facts (driver present, container toolkit absent, GDS unavailable) as component overrides, so the resolved recipe needs zero per-cluster flags.

```
packs/k0s-h200-training/
├── registry.yaml                    # required stub; components: []
└── overlays/
    └── k0s-h200-training.yaml       # registers service: k0s + h200 + training
```

Criteria chain: `service: k0s`, `accelerator: h200`, `intent: training`. Leaf/recipe name: `k0s-h200-training`.

## The gap this pack fills

Upstream AICR selects recipes by matching criteria against its embedded catalog — there is no "recipe name" flag, and no criteria value describes on-prem / bare-metal Kubernetes:

- The upstream `service` values that actually have registered overlays (confirmed with `aicr recipe list`) are exactly `aks any bcm eks gke kind lke ocp oke`. (`metal3` is accepted by the CLI's flag parser but resolves nothing — `aicr recipe --service metal3 ...` fails with `no recipe provides service 'metal3'`; it is not a working bare-metal path either.)
- `intent: training` is rejected unless `service` is one of `aks`, `bcm`, `eks`, `lke`, `ocp`, or `gke`+`os: cos`, or `oke`+`os: ol` — confirmed by resolving `--accelerator h200 --intent training` with no service, which fails and lists exactly those seven combinations. `service: any` is **not** among them.
- The only non-cloud service overlay upstream is `kind`, and it doesn't even cover this accelerator/intent combination — there is no `h200`+`kind`+`training` leaf, only `h100-kind-training*`. Where it does apply (h100), it sets `gpu-operator.driver.enabled: false` **and** `toolkit.enabled: false`, and disables DCGM (`dcgm.enabled: false`) — correct for `kind`'s `nvkind` fixture, which pre-configures both the driver and the container toolkit on simulated devices. A real bare-metal box is the mirror image: the driver **is** installed, the toolkit is **not**, and DCGM should stay on because the GPUs are real.
- Reusing an existing cloud leaf at h200+training instead doesn't fit either: `bcm` leaves `gpu-operator.driver`/`toolkit` at their unset defaults (so the operator would try to install its own driver over the host's) and sets `gds.enabled: true` (this host has no `nvidia_fs`); `eks` pulls in `aws-ebs-csi-driver` and `aws-efa`, which don't belong on a non-cloud box.

Hence `service: k0s`, registered by this pack's overlay — the value *is* the recipe's name (upstream: "adding a new value to an overlay automatically makes it a valid CLI input").

### Scope: what's k0s-general vs. what's this fleet

Not every override below is a *k0s* fact, and this pack should not be read as a drop-in upstream overlay. Only `gpu-operator.toolkit.env` — the containerd socket/config/runtime-class paths — is true of k0s generally: **any** k0s node bundles its own containerd instead of the distro default, so a general upstream `service: k0s` overlay should carry exactly that override and nothing else. That is the one part of this pack that is a genuine upstream-contribution candidate.

Everything else here is a fact about *this one demo fleet*, riding along under the same `service: k0s` value because this pack is scoped to one host, not because k0s implies any of it:

- Driver ownership (`gpu-operator.driver.enabled: false` + `nvidia-dra-driver-gpu.nvidiaDriverRoot: /`) — plenty of k0s+GPU clusters want gpu-operator to install the driver instead; upstream's own `bcm` leaf does exactly that.
- No InfiniBand (`driver.rdma.enabled: false`, `gdrcopy.enabled: false`) and no `nvidia_fs` (`gds.enabled: false`) — hardware/host-configuration facts, unrelated to which Kubernetes distribution runs.
- MIG left off (`migManager.enabled: false`) — an operational policy choice, not a k0s or hardware fact.

This repo's own chart `values.yaml` keeps these as two independent axes (`environment.k0sContainerd` vs. `environment.preinstalledDriver`) — exactly this distinction. This pack currently collapses both into one `service: k0s` bundle because it targets one demo fleet, not because they belong together.

## Environment facts

Each override below is carried in [`overlays/k0s-h200-training.yaml`](overlays/k0s-h200-training.yaml); see that file's comments for the full explanation.

| Override | Value | Why |
|---|---|---|
| `gpu-operator.driver.enabled` | `false` | Host carries the driver (verified 610.57.04). The operator must not install its own. |
| `gpu-operator.driver.rdma.enabled` | `false` | No RDMA/InfiniBand on this host — verified 2026-08-26: no `ib_`/`rdma_`/`mlx` kernel modules loaded, `/sys/class/infiniband` empty, `nvidia_peermem` absent. GPUDirect RDMA has nothing to bind to. |
| `gpu-operator.toolkit.enabled` | `true` | **Unlike upstream's `kind` overlay**, the toolkit *is* installed here: this host has no `nvidia-container-toolkit`. |
| `gpu-operator.toolkit.env` | `CONTAINERD_CONFIG=/etc/k0s/containerd.d/nvidia.toml`<br>`CONTAINERD_SOCKET=/run/k0s/containerd.sock`<br>`CONTAINERD_RUNTIME_CLASS=nvidia` | Must target k0s's own containerd, not the distro default — otherwise the toolkit configures the wrong containerd, reports success, and GPU pods fail with `no runtime for "nvidia" is configured`. |
| `gpu-operator.gds.enabled` | `false` | GPUDirect Storage needs the `nvidia_fs` kernel module, which is not loaded here. |
| `gpu-operator.gdrcopy.enabled` | `false` | GDRCopy accelerates GPUDirect RDMA transfers specifically; the same verified absence of RDMA/InfiniBand as `driver.rdma.enabled` above means there's no RDMA fabric for it to accelerate. |
| `gpu-operator.migManager.enabled` | `false` | Off: MIG (re)configuration is disruptive to already-running workloads, so it should be an explicit opt-in rather than a default. |
| `nvidia-dra-driver-gpu.nvidiaDriverRoot` | `/` | Host-installed driver userspace lives at the host root. **Required counterpart to `driver.enabled: false` above** — aicr's driver-ownership coherence check exits 2 if only one side is set. |
| `nvsentinel.labeler.assumeDriverInstalled` | `true` | aicr >= v0.19's second driver-ownership coherence check: with a host-provided driver there is no driver pod for the labeler to observe; without this, several NVSentinel DaemonSets silently come up with 0 desired pods. Required counterpart to the driver-ownership pair above on aicr >= v0.19. |
| constraint `K8s.server.version` | `>= 1.34` | k0s ships k8s >= 1.34 on v1.36.x; matches the upstream training leaves. |

Two things this pack deliberately does *not* override, both confirmed absent from the resolved recipe's `gpu-operator` overrides:

- **DCGM / dcgmExporter stay enabled** (chart defaults) — unlike the `kind` overlay, which disables them for simulated devices. On real H200s, DCGM being on is what lets the `accelerator-metrics` validator actually pass.
- **`nodewright-customizations` is not included** — node tuning drains/reboots the node, unacceptable on a shared lab VM.

## Resolving and verifying the pack

Resolve it directly with the `aicr` CLI (v0.20.0, the chart's pin; no cluster, no GPU required):

```bash
aicr recipe --service k0s --accelerator h200 --intent training \
  --data ./packs/k0s-h200-training -o recipe.yaml
```

This succeeds with `components=11`: `cert-manager, gpu-operator, k8s-ephemeral-storage-metrics, kai-scheduler, kube-prometheus-stack, nfd, nodewright-operator, nvidia-dra-driver-gpu, nvsentinel, prometheus-adapter, prometheus-operator-crds`.

Run the full offline assertion suite (the same checks CI runs — leaf listed and pack-private, every override above survives resolution, and the bundle step below) with:

```bash
./hack/verify-pack.sh
```

It asserts, among other things, that `--criteria-strict` **rejects** `service: k0s` — proof the value is pack-private and this pack carries no accidental upstream dependency (the same gate `hack/e2e/acme-aicr-pack` uses).

## Consuming it through the `nvidia-aicr` chart

Once this pack is published as an OCI artifact (see [`PUBLISH.md`](PUBLISH.md) — not yet done as of this writing), point the chart's `dataPack` value at it and set the matching criteria:

```yaml
dataPack: "ghcr.io/ramessesii2/aicr-packs/k0s-h200-training:0.1.0"  # target ref; see PUBLISH.md
service: k0s
accelerator: h200
intent: training
```

Leave the chart's own environment shortcuts alone:

```yaml
environment:
  k0sContainerd: false      # this pack's toolkit.env already targets k0s's containerd
  preinstalledDriver: false # this pack's driver.enabled + nvidiaDriverRoot already say the driver is host-owned
```

`environment.k0sContainerd` and `environment.preinstalledDriver` are chart-level shortcuts for encoding exactly the two facts this pack's overlay collapses together (see ["Scope"](#scope-whats-k0s-general-vs-whats-this-fleet) above). Setting them `true` on top of this pack would apply the same overrides twice, from two different places, for no benefit. More importantly, keeping them `false` keeps this pack **self-contained**: it doesn't lean on this Helm chart's values at all. That self-containment is what would let the k0s-general part — the `toolkit.env` containerd paths, and only that part — be proposed upstream as a `service: k0s` overlay; an upstream overlay cannot depend on this chart's values in the first place. The rest of this pack (driver ownership, RDMA/GDRCopy, MIG) is this-fleet-only and would not travel with such a proposal.

(Verified: rendering the chart's Job template with the values above produces `SERVICE=k0s`, `ACCELERATOR=h200`, `INTENT=training`, the `DATA_PACK` pull argument, and `ENV_K0S_CONTAINERD=false` / `ENV_PREINSTALLED_DRIVER=false` — i.e. the chart passes the criteria straight through and applies none of its own environment profile on top.)

## Version compatibility

- **aicr v0.20.0** — the version the chart pins (`aicrVersion` in `values.yaml`) — resolves and bundles this pack cleanly, including the driver-ownership coherence check added in v0.19 (`nvsentinel` `labeler.assumeDriverInstalled`, carried by this pack since 2026-08-30).
- **aicr v0.18.0** — the previous pin — also resolves and bundles cleanly; it accepts the `nvsentinel` override. `hack/verify-pack.sh` asserts both.
