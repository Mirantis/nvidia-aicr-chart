# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/); versions are the
chart's semver. `appVersion` tracks the pinned [aicr
release](https://github.com/NVIDIA/aicr/releases) independently.

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
