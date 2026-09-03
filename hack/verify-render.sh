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
# The chart has no default accelerator (the criteria guard rejects bare
# defaults by design), so every helper appends BASE criteria. Guard tests use
# the *_raw variants, which pass exactly the flags they state.
#
# Usage: hack/verify-render.sh [chart-dir]
set -euo pipefail

CHART="${1:-.}"
RC=0
BASE=(--set accelerator=h100)

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; RC=1; }

# env_is <var> <expected-value> <description> [helm --set args...]
# Renders first and asserts helm's exit status BEFORE extracting: without
# that, a failed render yields an empty string and any assertion whose
# expected value is "" would pass vacuously.
# Distinguishes three cases the naive quoted-only parser conflated:
#   value: "x" / value: x  -> got=x        (quoted AND unquoted values)
#   var not rendered       -> got=<ABSENT> (never equal to a wanted value,
#                             so `env_is X ""` can no longer pass vacuously
#                             against a missing var)
#   next line is valueFrom -> got=<NO VALUE LINE> (use contains for those)
env_is() {
  local var="$1" want="$2" desc="$3"; shift 3
  local out line got
  if ! out=$(helm template t "$CHART" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED (env_is needs a successful render)"
    return
  fi
  line=$(printf '%s\n' "$out" \
         | awk -v v="- name: $var\$" '$0 ~ v {found=1; next} found {print; exit}')
  case "$line" in
    "")           got="<ABSENT>" ;;
    *"value: "*)  got=${line#*value: }; got=${got#\"}; got=${got%\"} ;;
    *)            got="<NO VALUE LINE>" ;;
  esac
  if [ "$got" = "$want" ]; then pass "$desc ($var=\"$got\")"
  else fail "$desc — expected $var=\"$want\", got \"$got\""; fi
}

# renders / rejects — BASE criteria included
renders() {
  local desc="$1"; shift
  if helm template t "$CHART" "${BASE[@]}" "$@" >/dev/null 2>&1; then pass "$desc"
  else fail "$desc — render failed"; fi
}
rejects() {
  local desc="$1"; shift
  if helm template t "$CHART" "${BASE[@]}" "$@" >/dev/null 2>&1; then
    fail "$desc — render succeeded but should have been rejected"
  else pass "$desc"; fi
}

# renders_raw / rejects_raw — NO base criteria; exactly the stated flags
renders_raw() {
  local desc="$1"; shift
  if helm template t "$CHART" "$@" >/dev/null 2>&1; then pass "$desc"
  else fail "$desc — render failed"; fi
}
rejects_raw() {
  local desc="$1"; shift
  if helm template t "$CHART" "$@" >/dev/null 2>&1; then
    fail "$desc — render succeeded but should have been rejected"
  else pass "$desc"; fi
}

# rejects_with <needle> <description> [helm --set args...]
#
# For guards whose VALUE is the error message, not the rejection. Some inputs
# fail the render with or without the guard — a malformed value blows up on
# Go's own "can't evaluate field X in type string" the moment a template
# dereferences it. Plain `rejects` passes in both cases, so it asserts nothing
# about the guard and is vacuous by construction (house rule 1). Matching the
# message is what proves the friendly `fail` is the thing that fired.
rejects_with() {
  local needle="$1" desc="$2"; shift 2
  local out
  if out=$(helm template t "$CHART" "${BASE[@]}" "$@" 2>&1); then
    fail "$desc — render succeeded but should have been rejected"
    return
  fi
  case "$out" in
    *"$needle"*) pass "$desc" ;;
    *)           fail "$desc — rejected, but not with '$needle': $(printf '%s' "$out" | tail -1)" ;;
  esac
}

# contains / omits <needle> <description> [helm --set args...]
#
# The render is captured and matched with `case`, never piped into `grep -q`:
# under `set -o pipefail`, grep -q exits on the first match, the producer dies
# of SIGPIPE, and pipefail turns a SUCCESSFUL match into a failed pipeline.
# It only bites when the needle appears early in output large enough that the
# producer is still writing — i.e. it would start flaking silently as the
# chart grows. (Demonstrated in the kind e2e; fixed here pre-emptively.)
contains() {
  local needle="$1" desc="$2"; shift 2
  local out
  out=$(helm template t "$CHART" "${BASE[@]}" "$@" 2>/dev/null || true)
  case "$out" in
    *"$needle"*) pass "$desc" ;;
    *)           fail "$desc — expected output to contain '$needle'" ;;
  esac
}
omits() {
  local needle="$1" desc="$2"; shift 2
  local out
  out=$(helm template t "$CHART" "${BASE[@]}" "$@" 2>/dev/null || true)
  case "$out" in
    *"$needle"*) fail "$desc — output unexpectedly contains '$needle'" ;;
    *)           pass "$desc" ;;
  esac
}

# pack_auth_name_matches <description> [helm --set args...]
#
# The chart-managed Secret's own metadata.name and the name the Job's volume
# mounts must be the same string. Both come from nvidia-aicr.packSecretName so
# they cannot drift — this asserts they in fact don't. Nothing else in the
# suite would: `contains 'secretName: "t-pack-auth"'` reads only the mount
# side, so spelling the Secret's name out separately renders perfectly valid
# YAML and ships a Job mounting a Secret that does not exist — no render-time
# signal, just a pod wedged in ContainerCreating on the target cluster.
pack_auth_name_matches() {
  local desc="$1"; shift
  local out created mounted
  if ! out=$(helm template t "$CHART" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED"; return
  fi
  created=$(printf '%s\n' "$out" | awk '/^kind: Secret$/{s=1} s && /^  name: /{print $2; exit}')
  mounted=$(printf '%s\n' "$out" | awk -F'"' '/secretName: /{print $2; exit}')
  if [ -n "$created" ] && [ "$created" = "$mounted" ]; then
    pass "$desc (both \"$created\")"
  else
    fail "$desc — Secret created as \"$created\" but Job mounts \"$mounted\""
  fi
}

PUBLISH_ON=(--set validate.enabled=true --set validate.emitEvidence=true
            --set validate.publish.enabled=true
            --set validate.publish.ref=ghcr.io/example/aicr-evidence)
SIGNED=("${PUBLISH_ON[@]}" --set validate.publish.identityTokenSecret.name=cosign-token-secret)
UNSIGNED=("${PUBLISH_ON[@]}" --set validate.publish.mode=unsigned)

echo "== criteria guard =="
rejects_raw "bare defaults are rejected (no accelerator, no pack)"
renders_raw "stated accelerator escapes the guard" --set accelerator=h100
renders_raw "dataPack escapes the guard" --set dataPack=ghcr.io/example/pack:1.0.0
renders_raw "concrete service + intent escapes the guard (bcm-inference shape)" \
  --set service=bcm --set intent=inference
# service defaults to "any", which aicr rejects in combination with intent —
# so intent alone must NOT slip through.
rejects_raw "intent with service=any does not escape the guard" --set intent=training
# "any" is the absence of a value: aicr rejects --accelerator any outright.
rejects_raw "accelerator=any is rejected (aicr treats it as no criteria)" \
  --set accelerator=any
# values.yaml documents self-managed/self/vanilla as aliases of any.
for alias in self-managed self vanilla; do
  rejects_raw "service=$alias (alias of any) + intent does not escape the guard" \
    --set service="$alias" --set intent=training
done

echo "== baseline =="
renders "defaults render (with base criteria)"

echo "== data pack (initContainer branch) =="
omits   'name: data-pack' "no initContainer by default"
contains 'name: data-pack' "dataPack adds the oras initContainer" \
  --set dataPack=ghcr.io/example/pack:1.0.0
omits   'registry-config' "anonymous pull has no --registry-config" \
  --set dataPack=ghcr.io/example/pack:1.0.0
contains 'registry-config' "dataPackSecret wires --registry-config into oras" \
  --set dataPack=ghcr.io/example/pack:1.0.0 --set dataPackSecret=pack-pull
contains 'secretName: "pack-pull"' "dataPackSecret mounts the named Secret" \
  --set dataPack=ghcr.io/example/pack:1.0.0 --set dataPackSecret=pack-pull
contains 'type: kubernetes.io/dockerconfigjson' \
  "dataPackAuth renders the chart-managed pull Secret" \
  --set dataPack=ghcr.io/acme/pack:1 --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
contains 'secretName: "t-pack-auth"' \
  "dataPackAuth mounts the chart-managed Secret" \
  --set dataPack=ghcr.io/acme/pack:1 --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
# Mounting the Secret is not the same as USING it: --registry-config is what
# makes oras authenticate. dataPackSecret has this assertion above; without the
# twin, the dataPackAuth branch of the same shared `if $packSecret` could
# regress to an anonymous pull with the Secret sitting mounted and unread.
contains 'registry-config' \
  "dataPackAuth wires --registry-config into oras" \
  --set dataPack=ghcr.io/acme/pack:1 --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
contains 'mountPath: /pack-auth' \
  "dataPackAuth mounts /pack-auth into the oras initContainer" \
  --set dataPack=ghcr.io/acme/pack:1 --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
pack_auth_name_matches \
  "the chart-managed Secret's name is the name the Job mounts" \
  --set dataPack=ghcr.io/acme/pack:1 --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
rejects_with 'dataPackAuth must be a map' \
  "a scalar dataPackAuth is rejected with a shape error, not a raw Go field error" \
  --set dataPack=ghcr.io/acme/pack:1 --set dataPackAuth=oops
omits 'type: kubernetes.io/dockerconfigjson' \
  "no chart-managed Secret by default" \
  --set dataPack=ghcr.io/acme/pack:1
rejects "dataPackSecret and dataPackAuth are mutually exclusive" \
  --set dataPack=ghcr.io/acme/pack:1 --set dataPackSecret=pack-pull \
  --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
rejects "dataPackAuth without dataPack is rejected (no consumer for the Secret)" \
  --set-json 'dataPackAuth={"dockerconfigjson":"{\"auths\":{}}"}'
omits   '"--plain-http"' "pack pull is HTTPS by default" \
  --set dataPack=ghcr.io/example/pack:1.0.0
contains '"--plain-http"' "dataPackPlainHTTP adds --plain-http to oras" \
  --set dataPack=ghcr.io/example/pack:1.0.0 --set dataPackPlainHTTP=true
contains '"--insecure"' "dataPackInsecureTLS adds --insecure to oras" \
  --set dataPack=ghcr.io/example/pack:1.0.0 --set dataPackInsecureTLS=true
contains 'name: pack-tmp' "oras initContainer gets a writable /tmp (blob staging)" \
  --set dataPack=ghcr.io/example/pack:1.0.0

echo "== recipe visibility =="
env_is RECIPE_CM "aicr-recipe" "recipe capture on by default"
env_is RECIPE_CM "" "recipeConfigMap=\"\" disables capture" --set recipeConfigMap=""

echo "== validation =="
env_is VALIDATE_ENABLED false "validation off by default"
env_is VALIDATE_ENABLED true  "validate.enabled=true is wired through" \
  --set validate.enabled=true
env_is VALIDATE_PHASES "deployment" "default phase list reaches the Job"
rejects "validate.enabled with null phases is rejected" \
  --set validate.enabled=true --set validate.phases=null
rejects "validate.enabled with an empty phase list is rejected" \
  --set validate.enabled=true --set 'validate.phases={}'
env_is DEPLOY_ENABLED true "deploy leg on by default"
env_is DEPLOY_ENABLED false "deploy.enabled=false (assert-only) is wired through" \
  --set deploy.enabled=false --set validate.enabled=true
rejects "assert-only without validate.enabled is rejected (no-op Job)" \
  --set deploy.enabled=false
env_is VALIDATE_FLAGS "" "no validate flags by default"
env_is VALIDATE_FLAGS "--namespace aicr --image-pull-secret cred" \
  "validateFlags passthrough reaches the Job" \
  --set validateFlags="--namespace aicr --image-pull-secret cred"
omits 'AICR_NCCL_FABRIC' "no extra env by default"
env_is AICR_NCCL_FABRIC "roce" "job.extraEnv renders verbatim (unquoted toYaml value)" \
  --set 'job.extraEnv[0].name=AICR_NCCL_FABRIC' --set 'job.extraEnv[0].value=roce'

echo "== evidence publish =="
env_is PUBLISH_ENABLED false "publish off by default"
env_is PUBLISH_ENABLED true "publish enabled is wired through" "${SIGNED[@]}"
env_is PUBLISH_REF "ghcr.io/example/aicr-evidence" "publish.ref reaches the Job" "${SIGNED[@]}"
contains 'name: COSIGN_IDENTITY_TOKEN' "signed mode injects the identity token env" "${SIGNED[@]}"
contains 'name: "cosign-token-secret"' "identity token comes from the named Secret" "${SIGNED[@]}"
env_is PUBLISH_MODE "unsigned" "unsigned mode is wired through" "${UNSIGNED[@]}"
omits 'COSIGN_IDENTITY_TOKEN' "unsigned mode has NO identity token env (absent, not empty)" "${UNSIGNED[@]}"
contains 'secretName: "evidence-push"' "publish.registrySecret mounts the named Secret" \
  "${SIGNED[@]}" --set validate.publish.registrySecret=evidence-push
omits 'name: publish-auth' "no publish-auth mount without registrySecret" "${SIGNED[@]}"

echo "== publish guards =="
rejects "publish without validate.enabled is rejected" \
  --set validate.publish.enabled=true --set validate.publish.ref=r \
  --set validate.publish.identityTokenSecret.name=t
rejects "publish without emitEvidence is rejected" \
  --set validate.enabled=true \
  --set validate.publish.enabled=true --set validate.publish.ref=r \
  --set validate.publish.identityTokenSecret.name=t
rejects "publish with empty ref is rejected" \
  --set validate.enabled=true --set validate.emitEvidence=true \
  --set validate.publish.enabled=true \
  --set validate.publish.identityTokenSecret.name=t
rejects "invalid publish.mode is rejected" \
  "${SIGNED[@]}" --set validate.publish.mode=maybe
rejects "signed mode without identityTokenSecret.name is rejected" \
  "${PUBLISH_ON[@]}"

echo "== environment profile =="
env_is ENV_K0S_CONTAINERD    false "k0s profile off by default"
env_is ENV_PREINSTALLED_DRIVER false "preinstalled-driver profile off by default"
env_is ENV_K0S_CONTAINERD    true  "k0sContainerd=true is wired through" \
  --set environment.k0sContainerd=true
env_is ENV_PREINSTALLED_DRIVER true "preinstalledDriver=true is wired through" \
  --set environment.preinstalledDriver=true
# Template-text assertion, deliberately with NO --set: the PROFILE_ARGS block
# is shell inside the always-rendered command script, so this needle is present
# whatever environment.preinstalledDriver is — passing `--set
# environment.preinstalledDriver=true` here would imply a conditionality this
# assertion does not test (see the file header: strings in the always-rendered
# script pass regardless of --set). The value wiring is covered by the
# ENV_PREINSTALLED_DRIVER pair above; what THIS catches is the aicr >= v0.19
# coherence flag being dropped from the profile.
contains 'nv-sentinel:labeler.assumeDriverInstalled=true' \
  "preinstalled-driver profile carries the nvsentinel labeler flag"
env_is ENV_K0S_CONTAINERD true "truthy non-boolean (1) normalises to \"true\"" \
  --set environment.k0sContainerd=1

echo "== aicr binary pin =="
env_is AICR_SHA256 "a80a7ed1ad7474434c929efbea77223b0eb156f901569319698e9bdb9e1126f9" \
  "amd64 strict pin is applied by default"   # v0.20.0 linux_amd64
env_is AICR_SHA256 "f8353a56ff430714818879c8b4c4de057c0e3cea11beb34f45e4753db8f300f5" \
  "aicrArch=arm64 selects the arm64 strict pin" --set aicrArch=arm64
# Now that BOTH arches ship a pin, the "no entry for this arch" path has no
# other coverage — and that is the path where a `get`/lookup regression would
# silently check a tarball against another architecture's hash instead of
# skipping the optional pin. Empty the selected entry explicitly.
env_is AICR_SHA256 "" \
  "an arch with an empty pin entry gets no strict pin (never inherits another arch's)" \
  --set aicrArch=arm64 --set aicrSha256.arm64=""
rejects "legacy scalar aicrSha256 is rejected with a migration error" \
  --set aicrSha256=deadbeef

echo "== bundle -> deploy gate =="
# Closed-world gate between bundle and deploy — upstream's canonical flow
# (`aicr verify . && ./deploy.sh`). Template-text assertion: catches the
# gate being dropped. Verified 2026-09-01 on v0.20.0: unattested bundle
# passes at trust level "unverified" (checksums only, offline); a tampered
# deploy.sh fails with exit 4. Command exists on v0.18.0 too.
contains './aicr verify ./bundles' \
  "bundle passes the aicr verify gate before deploy.sh runs"

echo "== example values files =="
for ex in "$CHART"/examples/*.yaml; do
  if helm template t "$CHART" -f "$ex" >/dev/null 2>&1; then
    pass "example renders: $(basename "$ex")"
  else
    fail "example does not render: $(basename "$ex")"
  fi
done

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
