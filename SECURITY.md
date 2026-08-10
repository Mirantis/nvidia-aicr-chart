# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub Security
Advisories on this repository ("Report a vulnerability"). Do not open a
public issue for security reports.

## Supported versions

The latest released chart version receives fixes. Older versions are not
patched; upgrade to the latest release.

## Security posture, for reviewers

The install Job's ServiceAccount is bound to `cluster-admin` (AICR bundles
install CRDs, namespaces, and RBAC); the pod itself runs nonroot with a
read-only root filesystem and dropped capabilities. The `aicr` binary is
downloaded pinned and checksum-verified, fail-closed, with an optional
reviewed strict pin per architecture. In `validate.publish.mode: signed`,
a short-lived OIDC identity token is exposed inside that pod — the README's
"Publishing evidence" section states the trade-off plainly, and
`mode: unsigned` exists so identity never has to enter the cluster.
