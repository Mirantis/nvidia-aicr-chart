# Publishing the k0s-h200-training Data Pack

Run the following commands from the repo root. Requires: `oras`, and a ghcr PAT with `write:packages` permission.

## Prerequisites

`oras` is not installed on this machine by default. Install it first using your package manager, e.g.:

```bash
brew install oras
```

## Step 1: Authenticate with GHCR

```bash
echo "$GHCR_PAT" | oras login ghcr.io -u ramessesii2 --password-stdin
```

## Step 2: Push the pack to GHCR

Push from inside the pack dir in a SUBSHELL so the cwd is restored — the verification step below uses a repo-root-relative path.

```bash
( cd packs/k0s-h200-training && \
  oras push ghcr.io/ramessesii2/aicr-packs/k0s-h200-training:0.1.0 \
    registry.yaml overlays/ )
```

## Step 3: Make the package public

After the push succeeds, flip the package visibility to public:
https://github.com/users/ramessesii2/packages/container/aicr-packs%2Fk0s-h200-training/settings

## Step 4: Verify anonymous pull works

Anonymous pull must work, or the chart's Job cannot fetch it without a secret.

```bash
oras pull ghcr.io/ramessesii2/aicr-packs/k0s-h200-training:0.1.0 -o /tmp/pullback
diff -r /tmp/pullback packs/k0s-h200-training --exclude README.md --exclude PUBLISH.md
```

The diff should report no differences, confirming the pack was pushed correctly and is publicly accessible.
