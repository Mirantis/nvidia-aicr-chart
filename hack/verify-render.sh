#!/usr/bin/env bash
# Render assertions for the chart's conditional paths.
#
# Shared by the lint and release workflows so that a tag can never publish a
# chart whose conditional branches were never rendered. `helm lint` alone
# renders default values only, which exercises none of them.
#
# Assertions check rendered VALUES, not the presence of a string anywhere in
# the output: strings like "aicr validate" and "ENV_PREINSTALLED_DRIVER" live in the
# always-rendered shell script and env block, so grepping for them passes
# regardless of what --set does.
#
# The chart has no default accelerator (the criteria guard rejects bare
# defaults by design), so every helper appends BASE criteria. Guard tests use
# the *_raw variants, which pass exactly the flags they state.
#
# Usage: hack/verify-render.sh [chart-dir]
set -euo pipefail

# CI uses ubuntu-latest; its system python3 is assumed to carry PyYAML (not
# independently verified from runner image documentation).
python3 -c 'import yaml' 2>/dev/null || { echo "verify-render.sh needs python3 with PyYAML (pip install pyyaml)"; exit 2; }

CHART="${1:-.}"
KUBE_VERSION="${KUBE_VERSION:-1.34.0}"
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
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
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
  if helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" >/dev/null 2>&1; then pass "$desc"
  else fail "$desc — render failed"; fi
}
rejects() {
  local desc="$1"; shift
  if helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" >/dev/null 2>&1; then
    fail "$desc — render succeeded but should have been rejected"
  else pass "$desc"; fi
}

# renders_raw / rejects_raw — NO base criteria; exactly the stated flags
renders_raw() {
  local desc="$1"; shift
  if helm template t "$CHART" --kube-version "$KUBE_VERSION" "$@" >/dev/null 2>&1; then pass "$desc"
  else fail "$desc — render failed"; fi
}
rejects_raw() {
  local desc="$1"; shift
  if helm template t "$CHART" --kube-version "$KUBE_VERSION" "$@" >/dev/null 2>&1; then
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
  if out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>&1); then
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
# helm's exit status is checked first, as in env_is: a failed render yields an
# empty string, which made `omits` pass vacuously (e.g. `--set environment=null`
# errored and still printed ok).
contains() {
  local needle="$1" desc="$2"; shift 2
  local out
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED (contains needs a successful render)"
    return
  fi
  case "$out" in
    *"$needle"*) pass "$desc" ;;
    *)           fail "$desc — expected output to contain '$needle'" ;;
  esac
}

# contains_line <needle> <description> [helm --set args...]
# Exact whole-line match after removing YAML indentation. This anchors template
# text assertions without treating regex metacharacters in shell code specially.
contains_line() {
  local needle="$1" desc="$2"; shift 2
  local out line found=1
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED (contains_line needs a successful render)"
    return
  fi
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [ "$line" = "$needle" ]; then found=0; break; fi
  done <<< "$out"
  if [ "$found" -eq 0 ]; then pass "$desc"
  else fail "$desc — expected an exact rendered line containing '$needle'"; fi
}

omits() {
  local needle="$1" desc="$2"; shift 2
  local out
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED (omits needs a successful render)"
    return
  fi
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
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
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

# privileged_images_pinned <description> [helm --set args...]
# Both privileged images must be immutable multi-arch index pins. Parse the
# rendered Job rather than hard-coding a digest, so a release-checklist refresh
# does not require a test-only constant change.
privileged_images_pinned() {
  local desc="$1"; shift
  local out images
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED"; return
  fi
  if images=$(printf '%s\n' "$out" | python3 -c '
import sys, yaml
jobs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Job"]
if len(jobs) != 1:
    raise SystemExit(f"expected one Job, got {len(jobs)}")
pod = jobs[0]["spec"]["template"]["spec"]
containers = pod.get("initContainers", []) + pod.get("containers", [])
images = {c.get("name"): c.get("image", "") for c in containers}
names = ("aicr", "data-pack")
missing = "<ABSENT>"
bad = [f"{name}={images.get(name, missing)}"
       for name in names if "@sha256:" not in images.get(name, "")]
if bad:
    raise SystemExit("; ".join(bad))
print(", ".join(f"{name}: digest pinned" for name in names))
' 2>&1); then
    pass "$desc ($images)"
  else
    fail "$desc — $images"
  fi
}

# deploy_args_behavior <description> [helm --set args...]
# Execute the rendered deploy snippet with a fake deploy.sh. This proves the
# array path preserves spaces, apostrophes, newlines and a literal glob, comes
# after the legacy word-split string, and still recognises --best-effort for exit 2.
deploy_args_behavior() {
  local desc="$1"; shift
  local out work rc actual arguments expected
  if ! out=$(helm template t "$CHART" --kube-version "$KUBE_VERSION" "${BASE[@]}" "$@" 2>/dev/null); then
    fail "$desc — render FAILED"; return
  fi
  work=$(mktemp -d)
  printf '%s\n' "$out" > "$work/rendered.yaml"
  sed -n '/^ *echo "=== Running deploy.sh ==="$/,/^ *echo "=== AICR install complete ==="$/p' \
    "$work/rendered.yaml" | sed 's/^              //' > "$work/snippet.sh"
  mkdir "$work/bundles"
  : > "$work/bundles/glob-must-not-expand"
  cat > "$work/bundles/deploy.sh" <<'FAKE'
printf '<%s>\n' "$@" > "${ARG_LOG:?}"
echo "All components installed successfully."
if [ "${FAKE_RETRY:-0}" = 1 ]; then
  echo "DRA kubelet plugin restart blocked, retry needed for: nvidia-dra-driver-gpu"
fi
exit "${FAKE_RC:-0}"
FAKE
  expected=$(cat <<'EXPECTED'
<legacy-one>
<legacy-two>
<--best-effort>
<space value>
<quote'value>
<*>
<line1
line2>
EXPECTED
)
  rc=0
  actual=$(cd "$work" && ARG_LOG="$work/arguments" DEPLOY_FLAGS="legacy-one legacy-two" \
    FAKE_RC=0 bash -c 'set -euo pipefail; source "$1"; echo "=== CONTINUED ==="' \
    _ "$work/snippet.sh" 2>&1) || rc=$?
  arguments=$(cat "$work/arguments" 2>/dev/null || true)
  if [ "$rc" -ne 0 ] || [ "$arguments" != "$expected" ]; then
    fail "$desc — argument run exit=$rc, expected $(printf '%q' "$expected"), got $(printf '%q' "$arguments"); $(printf '%s' "$actual" | tail -1)"
    rm -rf "$work"
    return
  fi
  rc=0
  actual=$(cd "$work" && ARG_LOG="$work/arguments" DEPLOY_FLAGS="legacy-one legacy-two" \
    FAKE_RC=2 FAKE_RETRY=1 bash -c 'set -euo pipefail; source "$1"; echo "=== CONTINUED ==="' \
    _ "$work/snippet.sh" 2>&1) || rc=$?
  case "$actual" in
    *"WARN: deploy.sh deferred the DRA kubelet-plugin restart (exit 2)"*"=== CONTINUED ==="*) ;;
    *) rc=99 ;;
  esac
  rm -rf "$work"
  if [ "$rc" -eq 0 ]; then pass "$desc"
  else fail "$desc — exit-2 run did not continue through deployArgs --best-effort: $(printf '%s' "$actual" | tail -1)"; fi
}

PUBLISH_ON=(--set validate.enabled=true --set validate.emitEvidence=true
            --set validate.publish.enabled=true
            --set validate.publish.ref=ghcr.io/example/aicr-evidence)
SIGNED=("${PUBLISH_ON[@]}" --set validate.publish.identityTokenSecret.name=cosign-token-secret)
UNSIGNED=("${PUBLISH_ON[@]}" --set validate.publish.mode=unsigned)

echo "== Kubernetes floor =="
# Exact Helm error verified with Helm v4.3.0 and v3.19.0 on 2026-11-05.
rejects_with 'chart requires kubeVersion: >= 1.32.0-0 which is incompatible with Kubernetes v1.31.0' \
  "Kubernetes 1.31 is rejected by Helm's kubeVersion check (below the chart floor)" \
  --kube-version 1.31.0
if helm template t "$CHART" --kube-version 1.32.0 --set accelerator=h100 >/dev/null 2>&1; then
  pass "Kubernetes 1.32 is accepted (the chart floor)"
else
  fail "Kubernetes 1.32 is accepted (the chart floor) — render failed"
fi

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
# self-managed/self/vanilla: aliases of any up to aicr v0.20.0, of `generic`
# at v1.2.0 (verified 2026-11-05); without an accelerator aicr rejects them +
# intent either way.
for alias in self-managed self vanilla; do
  rejects_raw "service=$alias (legacy alias of any) + intent does not escape the guard" \
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
privileged_images_pinned "runtime and pack-pull images are digest pinned" \
  --set dataPack=ghcr.io/example/pack:1.0.0

echo "== structured passthrough args =="
contains "RECIPE_VALUE_ARGS=( '--set-json' 'component:path=two words' )" \
  "recipeArgs preserves a space inside one array element" \
  --set 'recipeArgs[0]=--set-json' --set 'recipeArgs[1]=component:path=two words'
contains "BUNDLE_VALUE_ARGS=( '--set-json' 'it'\\''s *' )" \
  "bundleArgs escapes an apostrophe and renders a glob literally" \
  --set 'bundleArgs[0]=--set-json' --set "bundleArgs[1]=it's *"
contains "VALIDATE_VALUE_ARGS=( '--namespace' 'team blue' '--label' '*' )" \
  "validateArgs preserves spaces and a literal glob" \
  --set 'validateArgs[0]=--namespace' --set 'validateArgs[1]=team blue' \
  --set 'validateArgs[2]=--label' --set 'validateArgs[3]=*'
# shellcheck disable=SC2016  # literal rendered bash; must not expand locally
contains './aicr recipe "${RECIPE_ARGS[@]}" "${DATA_ARGS[@]}" ${RECIPE_FLAGS} "${RECIPE_VALUE_ARGS[@]}"' \
  "recipeArgs follow the unchanged legacy recipeFlags"
# shellcheck disable=SC2016  # literal rendered bash; must not expand locally
contains './aicr bundle "${BUNDLE_ARGS[@]}" "${DATA_ARGS[@]}" "${PROFILE_ARGS[@]}" ${BUNDLE_FLAGS} "${BUNDLE_VALUE_ARGS[@]}"' \
  "bundleArgs follow the unchanged legacy bundleFlags"
# shellcheck disable=SC2016  # literal rendered bash; must not expand locally
contains '( cd ./bundles && bash ./deploy.sh ${DEPLOY_FLAGS} "${DEPLOY_VALUE_ARGS[@]}" )' \
  "deployArgs follow the unchanged legacy deployFlags"
# shellcheck disable=SC2016  # literal rendered bash; must not expand locally
contains '--output ./ctrf.json ${VALIDATE_FLAGS} "${VALIDATE_VALUE_ARGS[@]}" || rc=$?' \
  "validateArgs follow the unchanged legacy validateFlags"
env_is RECIPE_FLAGS "--criteria-strict --nodes 8" \
  "legacy recipeFlags reach the Job unchanged" \
  --set recipeFlags="--criteria-strict --nodes 8"
env_is BUNDLE_FLAGS "--vendor-charts --set x=y" \
  "legacy bundleFlags reach the Job unchanged" \
  --set bundleFlags="--vendor-charts --set x=y"
env_is DEPLOY_FLAGS "--best-effort --retries 2" \
  "legacy deployFlags reach the Job unchanged" \
  --set deployFlags="--best-effort --retries 2"
deploy_args_behavior \
  "deployArgs survive execution literally and enable --best-effort" \
  --set 'deployArgs[0]=--best-effort' --set 'deployArgs[1]=space value' \
  --set "deployArgs[2]=quote'value" --set 'deployArgs[3]=*' \
  --set $'deployArgs[4]=line1\nline2'
rejects_with 'recipeArgs must be a YAML list of strings' \
  "scalar recipeArgs is rejected with a friendly type error" \
  --set recipeArgs=--best-effort
rejects_with 'recipeArgs[0] must be a string; quote every element, including numbers' \
  "numeric recipeArgs element is rejected and tells the user to quote numbers" \
  --set 'recipeArgs[0]=100000000'

echo "== recipe visibility =="
env_is RECIPE_CM "aicr-recipe" "recipe capture on by default"
env_is RECIPE_CM "" "recipeConfigMap=\"\" disables capture" --set recipeConfigMap=""
contains_line "[ \${#RECIPE_VALUE_ARGS[@]} -gt 0 ] && printf 'recipeArgs:%s\\n' \"\$(printf ' %q' \"\${RECIPE_VALUE_ARGS[@]}\")\"" \
  "non-empty recipeArgs are recorded in the advisory recipe summary"

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
# environment.k0sContainerd was removed in chart 0.3.0 (upstream ships
# `service: k0s` from aicr v0.22.0, verified 2026-10-22). A truthy value must
# fail the render with the migration message, never be silently ignored;
# rejects_with matches the message so the assertion proves the guard fired,
# not some other failure.
rejects_with 'environment.k0sContainerd was removed in chart 0.3.0' \
  "environment.k0sContainerd=true is rejected with a migration error" \
  --set environment.k0sContainerd=true
rejects_with 'or pass it with bundleArgs: ["--set-json", "gpuoperator:toolkit.env=[...]"] (each list element is one argument, so the JSON may contain spaces). The legacy bundleFlags' \
  "truthy non-boolean k0sContainerd (1) is rejected with structured and legacy migration paths" \
  --set environment.k0sContainerd=1
renders "environment.k0sContainerd=false is tolerated (means not using it)" \
  --set environment.k0sContainerd=false
omits 'ENV_K0S_CONTAINERD' "the k0s env var is gone"
omits '/run/k0s/containerd.sock' "the chart no longer injects k0s containerd paths"
env_is ENV_PREINSTALLED_DRIVER false "preinstalled-driver profile off by default"
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

echo "== aicr binary pin =="
env_is AICR_SHA256 "3ff6935fd7988373903a2a30f1c24a74a5f8a9052a310615db19fcfec4cfe9a2" \
  "amd64 strict pin is applied by default"   # v1.2.0 linux_amd64
env_is AICR_SHA256 "26824146cd0743229239899cb75d3b68e0bc262bcdb357fccc98eca0a5b75976" \
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
# gate being dropped. v1.2.0, verified 2026-11-05: an unattested bundle
# passes at trust level "unverified" (checksums only, offline); a tampered
# deploy.sh fails with exit 4.
contains './aicr verify ./bundles' \
  "bundle passes the aicr verify gate before deploy.sh runs"
# deploy.sh exit 2 (v1.2.0, verified 2026-11-05; same logic as v1.1.2's):
# every component installed, DRA kubelet-plugin restart deferred. Under
# --best-effort the Job warns and continues; the branch must key on
# deploy.sh's own retry line, not on the exit code alone, so an unrelated
# exit 2 still fails the Job. Template-text assertions, like
# the verify gate above: they catch the key or the log line being dropped.
# Branch behaviour itself is proven by a scratch harness (task-2 report).
contains 'DRA kubelet plugin restart blocked, retry needed for:' \
  "exit-2 warn branch keys on deploy.sh's own retry line"
contains 'WARN: deploy.sh deferred the DRA kubelet-plugin restart (exit 2)' \
  "exit-2 warn branch logs the deferred restart"
# The other two terms of the warn condition, anchored on text that only the
# condition contains (a bare 'Deployment completed with failures' would also
# match the later report-line check, so it would be vacuous):
# shellcheck disable=SC2016  # literal template text; must not expand
contains '[ "${rc}" -eq 2 ] && [ "${DEPLOY_BEST_EFFORT}" = "true" ]' \
  "exit-2 warn branch requires --best-effort"
contains '&& ! grep -q "Deployment completed with failures" ./deploy.log; then' \
  "exit-2 warn branch is refused when deploy.sh reported component failures"
# Fail branch: any exit 2 that does not meet all three terms fails the Job
# and says why.
contains 'exit 2 continues only as a deferred DRA kubelet-plugin restart' \
  "exit-2 fail branch explains why an exit 2 was not let through"

echo "== example values files =="
for ex in "$CHART"/examples/*.yaml; do
  if helm template t "$CHART" --kube-version "$KUBE_VERSION" -f "$ex" >/dev/null 2>&1; then
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
