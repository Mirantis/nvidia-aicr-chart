#!/usr/bin/env bash
# Render assertions for the chart's conditional paths.
#
# Shared by the lint and release workflows so that a tag can never publish a
# chart whose conditional branches were never rendered. `helm lint` alone
# renders default values only, which exercises none of them.
#
# Assertions check rendered VALUES, not the presence of a string anywhere in
# the output: strings like "aicr validate" and "ENV_K0S_CONTAINERD" live in the
# always-rendered shell script and env block, so grepping for them passes
# regardless of what --set does.
#
# Usage: hack/verify-render.sh [chart-dir]
set -euo pipefail

CHART="${1:-.}"
RC=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; RC=1; }

# env_is <var> <expected-value> <description> [helm --set args...]
env_is() {
  local var="$1" want="$2" desc="$3"; shift 3
  local got
  got=$(helm template t "$CHART" "$@" 2>/dev/null \
        | awk -v v="- name: $var" '$0 ~ v {found=1; next} found {print; exit}' \
        | sed -n 's/.*value: "\(.*\)"/\1/p')
  if [ "$got" = "$want" ]; then pass "$desc ($var=\"$got\")"
  else fail "$desc — expected $var=\"$want\", got \"$got\""; fi
}

# renders <description> [helm --set args...]
renders() {
  local desc="$1"; shift
  if helm template t "$CHART" "$@" >/dev/null 2>&1; then pass "$desc"
  else fail "$desc — render failed"; fi
}

# rejects <description> [helm --set args...]  (render MUST fail)
rejects() {
  local desc="$1"; shift
  if helm template t "$CHART" "$@" >/dev/null 2>&1; then
    fail "$desc — render succeeded but should have been rejected"
  else pass "$desc"; fi
}

# contains / omits <needle> <description> [helm --set args...]
contains() {
  local needle="$1" desc="$2"; shift 2
  if helm template t "$CHART" "$@" 2>/dev/null | grep -q -- "$needle"; then pass "$desc"
  else fail "$desc — expected output to contain '$needle'"; fi
}
omits() {
  local needle="$1" desc="$2"; shift 2
  if helm template t "$CHART" "$@" 2>/dev/null | grep -q -- "$needle"; then
    fail "$desc — output unexpectedly contains '$needle'"
  else pass "$desc"; fi
}

echo "== baseline =="
renders "defaults render"

echo "== data pack (initContainer branch) =="
omits   'name: data-pack' "no initContainer by default"
contains 'name: data-pack' "dataPack adds the oras initContainer" \
  --set dataPack=ghcr.io/example/pack:1.0.0

echo "== validation =="
env_is VALIDATE_ENABLED false "validation off by default"
env_is VALIDATE_ENABLED true  "validate.enabled=true is wired through" \
  --set validate.enabled=true
env_is VALIDATE_PHASES "deployment" "default phase list reaches the Job"
rejects "validate.enabled with null phases is rejected" \
  --set validate.enabled=true --set validate.phases=null
# Regression: `{}` yields a single empty-string element — truthy to Helm, but
# produces zero --phase flags, i.e. aicr runs ALL phases including performance.
rejects "validate.enabled with an empty phase list is rejected" \
  --set validate.enabled=true --set 'validate.phases={}'

echo "== environment profile =="
env_is ENV_K0S_CONTAINERD    false "k0s profile off by default"
env_is ENV_PREINSTALLED_DRIVER false "preinstalled-driver profile off by default"
env_is ENV_K0S_CONTAINERD    true  "k0sContainerd=true is wired through" \
  --set environment.k0sContainerd=true
env_is ENV_PREINSTALLED_DRIVER true "preinstalledDriver=true is wired through" \
  --set environment.preinstalledDriver=true
# Regression: a truthy non-"true" value must not be truthy to the template and
# false to the script's `= "true"` test.
env_is ENV_K0S_CONTAINERD true "truthy non-boolean (1) normalises to \"true\"" \
  --set environment.k0sContainerd=1

echo "== aicr binary pin =="
env_is AICR_SHA256 "6a498b8ce0dcb0e28095de35cdae583391ad567f3922aae6657c851cc76275ee" \
  "amd64 strict pin is applied by default"
# Regression: the amd64 hash must never be checked against an arm64 tarball.
env_is AICR_SHA256 "" "arm64 does not inherit the amd64 pin" --set aicrArch=arm64
rejects "legacy scalar aicrSha256 is rejected with a migration error" \
  --set aicrSha256=deadbeef

echo "== installer scheduling =="
omits    'tolerations:' "no tolerations by default"
contains 'nvidia.com/gpu' "job.tolerations reach the installer pod" \
  --set 'job.tolerations[0].key=nvidia.com/gpu' \
  --set 'job.tolerations[0].operator=Exists' \
  --set 'job.tolerations[0].effect=NoSchedule'
contains 'priorityClassName: "system-cluster-critical"' "job.priorityClassName is honoured" \
  --set job.priorityClassName=system-cluster-critical

echo
[ "$RC" -eq 0 ] && echo "All render assertions passed." || echo "Render assertions FAILED." >&2
exit "$RC"
