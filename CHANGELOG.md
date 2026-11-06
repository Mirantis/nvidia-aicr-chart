# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/); versions are the
chart's semver. `appVersion` tracks the pinned [aicr
release](https://github.com/NVIDIA/aicr/releases) independently.

## [0.3.0] — 2026-11-05

- **Structured passthrough arguments**: new `recipeArgs`, `bundleArgs`,
  `validateArgs` and `deployArgs` lists preserve each element as one argument,
  including spaces, apostrophes and literal globs, and run after the legacy
  whitespace-split `*Flags` strings. The legacy keys remain supported (Helm
  v4.3.0 and bash 5.3.20(1)-release, verified 2026-11-05).
- **Kubernetes floor**: the chart now declares `kubeVersion: ">= 1.32.0-0"`,
  the default aicr v1.2.0 recipe's minimum. Recipe-specific constraints can be
  stricter; `service: k0s` still requires Kubernetes >= 1.34 (aicr v1.2.0 and
  Helm v4.3.0, verified 2026-11-05).
- **Privileged images are digest-pinned**: `runtimeImage` and `orasImage` now
  include their multi-arch index SHA-256 digests, covering linux/amd64 and
  linux/arm64; the release checklist refreshes these pins (Docker 29.9.2 and
  curl 8.7.1, verified 2026-11-05).
- **aicr v1.2.0** is the pinned release (was v0.20.0). Strict-pin hashes:
  `aicrSha256.amd64` `3ff6935fd7988373903a2a30f1c24a74a5f8a9052a310615db19fcfec4cfe9a2`,
  `.arm64` `26824146cd0743229239899cb75d3b68e0bc262bcdb357fccc98eca0a5b75976`.
- **BREAKING: `environment.k0sContainerd` is removed.** Setting it to any
  value other than `false` (absent or null is fine) fails the render with a
  migration message, including the quoted string "false". Use `service: k0s`
  (accepted by aicr from v0.22.0, so releases before v0.22.0 (v0.20.0 and
  v0.21.1 verified) reject it with `invalid service type: k0s`; requires
  Kubernetes >= 1.34) in its place. `service: k0s`
  carries only the containerd wiring, not a preinstalled driver: on k0s with a
  host driver keep `environment.preinstalledDriver: true`, unless the recipe
  resolves upstream's `h200-k0s-ubuntu-training` leaf (`accelerator: h200`,
  `intent: training`, `os: ubuntu`). An org pack with its own `service` value
  carries the `toolkit.env` override in its overlay or `bundleFlags`.
- **BREAKING (upstream behaviour change): the service names `self-managed`,
  `self` and `vanilla` now map to `generic`, not `any`.** At v1.2.0 they fail
  for most accelerators (`no recipe provides service 'generic'`; verified
  with `--service self-managed --accelerator h100`). Use `service: any` for
  self-managed clusters. The chart adds no render-time guard: the error
  appears in the Job log.
- **Packs moved to `aicr.run/v1beta1`**: aicr v1.0.0 retired `v1alpha2`, so
  v1.2.0 refuses to load packs that declare it. Both in-repo packs
  (`packs/k0s-h200-training`, `hack/e2e/acme-aicr-pack`) are updated; org
  packs you maintain need the same header change.
- **`packs/k0s-h200-training` re-described as a worked example** that layers
  on upstream's `service: k0s` overlays (v0.22.0+) and carries one example
  fleet's facts as overrides.
- **deploy.sh exit 2 handled**: v1.2.0's `deploy.sh` exits 2 when every
  component installed but the DRA kubelet-plugin restart was deferred. Under
  `--best-effort` the Job logs `WARN: deploy.sh deferred the DRA
  kubelet-plugin restart (exit 2)` and continues; without `--best-effort`,
  or for any other exit 2, the Job fails.
- **Upgrading a converged cluster is not a plain re-run** (fresh installs are
  unaffected). Re-running 0.3.0 over a cluster converged by 0.2.0 (aicr
  v0.20.0) crosses boundaries upstream's `aicr upgrade-check` (v1.2.0) reports
  as **blocked** for gpu-operator (v26.3.3 to v26.7.2: "stops at =26.7.1"),
  nvsentinel (v1.20.0 to v1.28.0: "stops at 1.25.0") and nvidia-dra-driver-gpu
  (0.4.1 to 0.5.1: "stops at 0.5.1"), **manual** for nodewright-operator
  (v0.17.1 to v0.20.0, plus an unassessed namespace relocation skyhook ->
  nodewright) and nfd (0.19.0 to 0.20.1: 3 steps, of which the two RBAC steps
  apply only when topology-updater RBAC is managed outside the chart;
  chart-managed RBAC needs only the upgrade itself), and **unknown** for
  kai-scheduler (v0.14.1 to v0.16.9). Indicative: `service: any` + h100, run
  2026-11-05; v1.2.0 refuses a v0.20.0-generated recipe, so this used one with
  its header rewritten. A cluster converged on an unreleased v1.1.2 build of
  this chart sees only nfd manual (with chart-managed RBAC, only the upgrade
  itself) and nvidia-dra-driver-gpu 0.5.0 to 0.5.1 safe. Required first step:
  `aicr upgrade-check --from cluster --to <recipe> --deployer helm` from a
  workstation; its verdict is authoritative. For a blocked component, first
  bring it to the earliest recorded starting point the check names, following
  that component's upstream release notes, then re-run the check. The bundle's
  `UPGRADING.md` covers only the last boundary. The chart does not run
  `upgrade-check`. New README bullet in "Scope and limitations".
- **Values docs** list the criteria values upstream added: accelerators
  `b300`, `vr200`; os `rocky`, `sles`; platform `kueue`; services `cks`,
  `generic`, `k0s`, `mk8s`, `nvke`, `rke2`. A stated `intent` still needs a
  service that declares it.
- `accelerator: a100` alone now resolves 12 components (was 11):
  `dra-node-labeler` is new.
- Chart version references in the README examples moved to 0.3.0.

## [0.2.0] — 2026-09-02

- **aicr v0.20.0** is the pinned release (was v0.18.0). Both strict-pin
  hashes now ship (`aicrSha256.amd64` and `.arm64`).
- **nvsentinel driver-ownership gate** (aicr >= v0.19): the
  `environment.preinstalledDriver` profile now also sets
  `nv-sentinel:labeler.assumeDriverInstalled=true`, and the
  `k0s-h200-training` pack carries the equivalent override — both verified
  to bundle cleanly on v0.18.0 and v0.20.0.
- **Deploy-failure detection** handles v0.20.0's `deploy.sh`, which exits
  non-zero on component failure without `--best-effort` (v0.18.0 never
  exited non-zero). The Job fails explicitly on any non-zero deploy exit
  and still detects the failure-report line itself.
- **Bundle verification gate**: the Job runs `aicr verify` on the rendered
  bundle before executing `deploy.sh` — upstream's closed-world checksum
  gate; any file added, removed, or modified after bundling fails the Job.
- **Fleet secret delivery documented**: README section + worked example
  (`examples/fleet/fleet-secret-distribution.yaml`) for landing the
  pack/publish/validator dockerconfigjson on k0rdent children via Sveltos.
- **Opt-in `dataPackAuth.dockerconfigjson`**: the chart creates the pack-pull
  Secret from a value, for reconcilers with native secret-to-values
  injection (Flux `valuesFrom`). Mutually exclusive with `dataPackSecret`,
  which remains the default contract (the chart never creates it).

## [0.1.0] — 2026-08-11

Initial release.

- **Install pipeline**: a single Kubernetes Job downloads a pinned,
  checksum-verified `aicr` release (per-architecture strict pins anchored in
  reviewed values), resolves a recipe from chart criteria, renders the Helm
  bundle, and runs its `deploy.sh` — with component-failure detection the
  script itself does not provide.
- **Org data packs**: `dataPack` pulls a `--data` extension pack as an OCI
  artifact; `dataPackSecret` authenticates private registries
  (dockerconfigjson); `dataPackPlainHTTP` / `dataPackInsecureTLS` cover lab
  registries. Packs registering a private `service` value act as named,
  versioned recipes.
- **Criteria guard**: no default accelerator — rendering fails unless an
  `accelerator` is stated, a `dataPack` owns the criteria, or a concrete
  `service` plus `intent` is given. Prevents the silent thin-stack
  resolution that under-specified criteria otherwise produce.
- **Resolved-recipe visibility**: `recipeConfigMap` (default `aicr-recipe`)
  captures the criteria, the resolver's completion summary, and the full
  recipe.
- **Validation**: `aicr validate` with the CTRF verdict captured to a
  ConfigMap whether it passes or fails; optional in-toto evidence bundle
  capture; `validateFlags` passthrough (`--namespace`,
  `--image-pull-secret` for private validator images, `--node-selector`).
- **Assert-only runs**: `deploy.enabled: false` skips bundle+deploy and
  validates an already-converged cluster against the resolved recipe — the
  burn-in / scheduled re-validation / drift-check pattern. Requires
  `validate.enabled`. Worked posture examples ship in `examples/`
  (day-1 install, hardware qualification, drift check).
- **Evidence publishing**: `validate.publish.*` pushes the bundle via
  `aicr evidence publish` — `mode: signed` (Sigstore keyless, short-lived
  OIDC token from a Secret) or `mode: unsigned` (identity never enters the
  cluster; sign later with `aicr evidence sign`). The `pointer.yaml`
  locator is captured alongside the bundle.
- **Installer-pod scheduling**: `job.tolerations` / `nodeSelector` /
  `affinity` / `priorityClassName` (required on clusters whose only workers
  are tainted GPU nodes) and `job.extraEnv`.
- **Testing**: mutation-tested render-assertion suite shared by the lint
  and release workflows; a reproducible kind end-to-end test
  (`hack/e2e/run-kind-e2e.sh`) covering the full private-pack customer
  path.
- **Release safety**: the release workflow verifies tag == chart version,
  re-runs all render assertions, refuses to overwrite a published version,
  and lowercases the registry owner for OCI compliance.
