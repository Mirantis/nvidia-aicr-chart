# Contributing

Contributions welcome — bug reports, docs, values, template changes, and
e2e improvements alike. Licensed under Apache-2.0; submitting a PR implies
you have the right to contribute the code under that license.

## Dev loop

```bash
helm lint . --strict --set accelerator=h100
./hack/verify-render.sh .          # ~60 render assertions, seconds
```

Both run in CI on every push (`lint` workflow) and again at release time —
a tag cannot publish a chart whose conditional paths never rendered.

## House rules

Two rules exist because their violations each shipped bugs before the rules:

1. **New render assertions must be mutation-tested.** Revert the template
   change your assertion guards, run the suite, and watch that exact
   assertion fail. An assertion that passes against the broken template is
   worse than none — this suite has caught three vacuous assertions to date.
2. **Upstream behaviour claims must be verified against the pinned `aicr`
   binary** (`Chart.yaml` `appVersion`), not inferred from docs. Run
   `aicr <cmd> --help` or the command itself; the docs and the binary have
   disagreed before (e.g. `--no-sign` writes no signer field at all, not an
   "empty signer block"). Note the verified version next to the claim.

## End-to-end test

```bash
./hack/e2e/run-kind-e2e.sh          # ~20-25 min, local only
```

Creates a throwaway kind cluster with a private (htpasswd) registry, pushes
the synthetic org pack (`hack/e2e/acme-aicr-pack/`), and exercises the full
customer path: authenticated pack pull, pack-named recipe resolution,
install, validation, unsigned evidence publish, and a fail-closed negative
test. Requires docker, kind, kubectl, helm, curl, python3. `--keep`
preserves the cluster for debugging. Runs in CI via the `kind-e2e` workflow
on chart-affecting PRs.

The signed publish path cannot run locally (public Sigstore does not trust
local issuers); the release-gated `signed-evidence-e2e` workflow covers it
with GitHub's OIDC identity.

## Releasing

1. Bump `version` in `Chart.yaml` (semver; breaking values changes bump the
   minor pre-1.0). Update `CHANGELOG.md`.
2. If bumping `appVersion`: update `aicrSha256.amd64` from the release's
   `aicr_checksums.txt`, and re-verify any behaviour claims against the new
   binary (see house rule 2).
3. Tag `vX.Y.Z` and push the tag. The release workflow verifies
   tag == `Chart.yaml` version, re-runs lint + render assertions, refuses to
   overwrite an already-published version, and pushes to
   `oci://ghcr.io/<owner>/charts`.

## Design records

Dated design documents with as-run test evidence live in `docs/design/`.
Significant behaviour changes should update or add one.
