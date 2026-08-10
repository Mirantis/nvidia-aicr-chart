#!/usr/bin/env bash
# Customer-shaped kind e2e for the nvidia-aicr chart, in two scenarios.
#
# Shared setup (both scenarios): a throwaway kind cluster with an
# htpasswd-protected plain-HTTP registry:2 standing in for the org registry,
# and hack/e2e/acme-aicr-pack pushed to it with oras (the "CI publish" leg).
#
#   pack      install the stack from the private pack: authenticated pull,
#             pack-named recipe resolution, recipe capture, plus the
#             fail-closed negative test. Validation OFF.
#   validate  assert-only run (deploy.enabled=false) on an IDLE cluster:
#             validation, evidence capture, unsigned publish.
#
# Why two clusters instead of one run: aicr validate schedules a snapshot-agent
# Job and validator Jobs INTO the cluster. Immediately after a --no-wait install
# of the full stack, a small CI node is ~99% CPU-requested and those pods are
# unschedulable — validation then times out no matter how generous --timeout is
# (seen on a 4-vCPU GitHub runner: cpu 3975m/99%, agent pod Pending, exit 8).
# Splitting gives validation room, and the scenarios can run in parallel.
#
# Nothing leaves the machine. Requires: docker, kind, kubectl, helm, curl,
# python3. Each scenario is ~10-15 min.
#
# Usage: hack/e2e/run-kind-e2e.sh [--scenario pack|validate|all] [--keep]
#                                 [--cluster PREFIX]
#   --scenario  which scenario(s) to run (default: all, sequentially)
#   --keep      do not delete the kind cluster(s) at the end
#   --cluster   cluster name prefix (default: aicr-chart-e2e)
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never run on success — safe here.
# shellcheck disable=SC2329  # helpers are invoked indirectly (trap/wait_for).
set -euo pipefail

PREFIX=aicr-chart-e2e
KEEP=false
SCENARIO=all
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)     KEEP=true; shift ;;
    --cluster)  PREFIX="$2"; shift 2 ;;
    --scenario) SCENARIO="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$SCENARIO" in pack|validate|all) ;; *) echo "bad --scenario: $SCENARIO" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$(cd "$HERE/../.." && pwd)"
RC=0
CLUSTER=""   # set per scenario
CTX=""

pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; RC=1; }
K() { kubectl --context "$CTX" "$@"; }

# has <needle> <string>      fixed-string match
# has_re <ERE> <string>      case-insensitive regex match
#
# Assertions match against a CAPTURED string. Never pipe a command into a
# consumer that exits early (`grep -q`, `head`): under `set -o pipefail` the
# consumer closes the pipe on its first match, the producer dies of SIGPIPE, and
# pipefail turns a SUCCESSFUL match into a failed pipeline. It only bites when
# the needle appears early in output large enough that the producer is still
# writing — so it lurks until a log, recipe, or bundle grows, then flakes. It
# did: "Skipping deploy" reported false while "publish exit=0", near the end of
# that same log, reported true. has_re uses a herestring, not a pipe, for the
# same reason.
has()    { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
has_re() { grep -Eiq -- "$1" <<<"$2"; }

# wait_for <timeout-seconds> <description> <command...>
wait_for() {
  local t="$1" desc="$2"; shift 2
  local start="$SECONDS"
  until "$@" >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge "$t" ]; then
      fail "timeout (${t}s) waiting for: $desc"
      return 1
    fi
    sleep 5
  done
}

# Diagnostics for validation failures: the cluster is gone by the time anyone
# reads CI logs, and aicr tears down aicr-validation on failure — so capture
# node pressure, which is what actually decides schedulability.
dump_validation_diag() {
  echo "--- validation diagnostics ---"
  K -n aicr logs "job/nvidia-aicr-install-1" --tail=40 2>/dev/null \
    | grep -aE "validate|Validating|WARN|TIMEOUT|readiness" || true
  K -n aicr-validation get pods -o wide 2>/dev/null || true
  # Full time-ordered event stream, not `describe pods | grep -A8 Events:`.
  # That truncated to the first pod's first 8 lines and once dumped an
  # 88s-old pod beside 38-min-old events with everything between them cut —
  # exactly the window that would have shown the image-pull stall.
  K -n aicr-validation get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
  K describe node 2>/dev/null | sed -n '/Allocated resources:/,/Events:/p' || true
}

cleanup() {
  # On failure, dump the install Job's log BEFORE teardown — otherwise the
  # evidence dies with the cluster and the next debugging round is blind.
  if [ "$RC" -ne 0 ] && [ -n "$CTX" ]; then
    echo "--- install Job log (scenario failed; captured before teardown) ---"
    K -n aicr logs job/nvidia-aicr-install-1 --tail=120 2>/dev/null || true
  fi
  if [ "$KEEP" = false ] && [ -n "$CLUSTER" ]; then
    kind delete cluster --name "$CLUSTER" || true
  elif [ -n "$CLUSTER" ]; then
    echo "(--keep: cluster ${CLUSTER} left running)"
  fi
}
trap cleanup EXIT

setup_cluster() {  # $1 = scenario name
  CLUSTER="${PREFIX}-$1"
  CTX="kind-${CLUSTER}"
  echo "== [$1] kind cluster (K8s 1.34 — DRA floor) =="
  kind create cluster --name "$CLUSTER" --image kindest/node:v1.34.0
  K wait --for=condition=Ready node --all --timeout=180s
}

# aicr validate deploys a snapshot-agent Job (ghcr.io/nvidia/aicr) and one
# Job per validator (ghcr.io/nvidia/aicr-validators/deployment) — every pod
# pulling inside aicr's --timeout window, on a node that is brand-new each
# run (observed: 31 MB agent image stuck ContainerCreating/Pulling for
# 38 min; a fresh anonymous ghcr pull per run is exactly the throttling
# shape). All of them use imagePullPolicy: IfNotPresent (agent verified
# against the v0.18.0 binary; validators observed live, 2026-08-11), so
# images side-loaded into the node are used as-is: pull once on the host —
# cached across runs — and load them. A pull failure here fails fast and
# visibly instead of burning validate's whole timeout.
preload_validation_images() {
  local v plat img tar
  v="$(awk -F'"' '/^appVersion:/ {print $2}' "$CHART/Chart.yaml")"
  plat="linux/$(docker version -f '{{.Server.Arch}}')"
  for img in "ghcr.io/nvidia/aicr:${v}" \
             "ghcr.io/nvidia/aicr-validators/deployment:${v}"; do
    echo "== [validate] preload $img ($plat) =="
    docker pull --platform "$plat" "$img"
    # Not `kind load docker-image`: with docker's containerd image store, a
    # multi-arch tag saves as an index referencing platforms whose blobs
    # were never pulled, and kind's `ctr import --all-platforms --digests`
    # fails on the missing digest. Save the node's platform only
    # (docker >= 25).
    tar=$(mktemp)
    docker save --platform "$plat" "$img" -o "$tar"
    kind load image-archive "$tar" --name "$CLUSTER"
    rm -f "$tar"
  done
}

setup_registry_and_pack() {
  echo "== [$1] org registry (htpasswd, plain HTTP) + pack push =="
  local htpasswd
  htpasswd=$(docker run --rm httpd:2-alpine htpasswd -Bbn testuser testpassword)
  K create namespace registry
  K -n registry create secret generic registry-htpasswd --from-literal=htpasswd="$htpasswd"
  K apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: registry, namespace: registry}
spec:
  replicas: 1
  selector: {matchLabels: {app: registry}}
  template:
    metadata: {labels: {app: registry}}
    spec:
      containers:
        - name: registry
          image: registry:2
          ports: [{containerPort: 5000}]
          env:
            - {name: REGISTRY_AUTH, value: htpasswd}
            - {name: REGISTRY_AUTH_HTPASSWD_REALM, value: e2e-lab}
            - {name: REGISTRY_AUTH_HTPASSWD_PATH, value: /auth/htpasswd}
          volumeMounts: [{name: auth, mountPath: /auth, readOnly: true}]
      volumes:
        - name: auth
          secret: {secretName: registry-htpasswd}
---
apiVersion: v1
kind: Service
metadata: {name: registry, namespace: registry}
spec:
  selector: {app: registry}
  ports: [{port: 5000, targetPort: 5000}]
EOF
  K -n registry rollout status deploy/registry --timeout=180s

  K -n registry create configmap acme-pack-src \
    --from-file=registry.yaml="$HERE/acme-aicr-pack/registry.yaml" \
    --from-file=acme-kind-training.yaml="$HERE/acme-aicr-pack/overlays/acme-kind-training.yaml"
  K apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: pack-push, namespace: registry}
spec:
  restartPolicy: Never
  containers:
    - name: oras
      image: ghcr.io/oras-project/oras:v1.2.0
      workingDir: /pack
      args: ["push", "--plain-http",
             "-u", "testuser", "-p", "testpassword",
             "registry.registry.svc:5000/acme-aicr-pack:1.0.0",
             "registry.yaml", "overlays/"]
      env: [{name: HOME, value: /tmp}]
      volumeMounts:
        - {name: pack, mountPath: /pack/registry.yaml, subPath: registry.yaml}
        - {name: pack, mountPath: /pack/overlays/acme-kind-training.yaml, subPath: acme-kind-training.yaml}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: pack
      configMap: {name: acme-pack-src}
    - {name: tmp, emptyDir: {}}
EOF
  K -n registry wait --for=jsonpath='{.status.phase}'=Succeeded pod/pack-push --timeout=180s
  # Logs can lag pod termination (kubelet log finalization); retry the read
  # rather than flaking on the race.
  local ok=false
  for _ in 1 2 3 4 5; do
    if has "Pushed" "$(K -n registry logs pack-push 2>/dev/null || true)"; then ok=true; break; fi
    sleep 3
  done
  [ "$ok" = true ] && pass "pack pushed" || fail "pack push"

  K create namespace aicr
  K -n aicr create secret docker-registry acme-registry-cred \
    --docker-server=registry.registry.svc:5000 \
    --docker-username=testuser --docker-password=testpassword
}

# wait_install_job — Complete OR Failed; never burns the whole timeout on a
# failure, and dumps logs when it does fail.
wait_install_job() {
  local job="$1" budget="${2:-1500}"
  local deadline=$((SECONDS + budget)) c
  while :; do
    c=$(K -n aicr get job "$job" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
    case "$c" in
      *Complete*) pass "$job complete"; return 0 ;;
      *Failed*)
        fail "$job failed"
        K -n aicr logs "job/$job" --tail=100 || true
        return 1 ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "$job did not finish within ${budget}s"
      K -n aicr logs "job/$job" --tail=100 || true
      return 1
    fi
    sleep 15
  done
}

scenario_pack() {
  setup_cluster pack
  setup_registry_and_pack pack

  echo "== [pack] install from the private pack (validation off) =="
  helm --kube-context "$CTX" install nvidia-aicr "$CHART" -n aicr \
    -f "$HERE/values-kind-e2e.yaml"
  wait_install_job nvidia-aicr-install-1 || return 0

  echo "== [pack] asserts =="
  local summary recipe
  summary=$(K -n aicr get cm aicr-recipe -o jsonpath='{.data.summary\.txt}')
  has "service=acme" "$summary" \
    && pass "recipe CM records pack-named criteria (service=acme)" \
    || fail "recipe CM criteria"
  has "recipe generation completed" "$summary" \
    && pass "recipe CM carries resolver summary" || fail "resolver summary"
  recipe=$(K -n aicr get cm aicr-recipe -o jsonpath='{.data.recipe\.yaml}' 2>/dev/null || true)
  [ -n "$recipe" ] && pass "full recipe captured" || fail "recipe.yaml capture"
  has "nvidia-aicr-install-" "$(K -n aicr get pods -o name)" \
    && pass "pod name matches the catalog e2e prefix" || fail "pod prefix"
  local n
  n=$(helm --kube-context "$CTX" list -A -q | wc -l | tr -d ' ')
  [ "$n" -ge 10 ] && pass "stack installed ($n helm releases)" \
    || fail "expected >=10 releases, got $n"

  echo "== [pack] negative test: pull without the secret must fail closed =="
  helm --kube-context "$CTX" upgrade nvidia-aicr "$CHART" -n aicr \
    -f "$HERE/values-kind-e2e.yaml" --set dataPackSecret=""
  neg_failed() {
    local pod reason
    pod=$(grep -m1 install-2 <<<"$(K -n aicr get pods -o name 2>/dev/null || true)" || true)
    [ -n "$pod" ] || return 1
    reason=$(K -n aicr get "$pod" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
    has Error "$reason"
  }
  if wait_for 300 "anonymous pull rejection" neg_failed; then
    pass "initContainer failed without the secret (fail-closed)"
    local pod
    pod=$(grep -m1 install-2 <<<"$(K -n aicr get pods -o name)" || true)
    has_re "credential|unauthorized|401" "$(K -n aicr logs "$pod" -c data-pack 2>&1 || true)" \
      && pass "failure is an auth error, not something else" || fail "unexpected init error"
  else
    fail "negative test"
    K -n aicr get pods -o wide || true
  fi
  cleanup; CLUSTER=""
}

scenario_validate() {
  setup_cluster validate
  preload_validation_images
  setup_registry_and_pack validate

  echo "== [validate] assert-only run on an idle cluster =="
  K describe node 2>/dev/null | sed -n '/Allocated resources:/,/Events:/p' \
    | grep -E "cpu|memory" | sed 's/^/  idle: /'
  helm --kube-context "$CTX" install nvidia-aicr "$CHART" -n aicr \
    -f "$HERE/values-assert-only.yaml"
  wait_install_job nvidia-aicr-install-1 || { dump_validation_diag; return 0; }

  echo "== [validate] asserts =="
  # Job logs can lag the Complete condition (kubelet log finalization), so
  # retry rather than flaking — same race as the pack push.
  job_log_has() {
    local needle="$1" log
    for _ in 1 2 3 4 5; do
      log=$(K -n aicr logs job/nvidia-aicr-install-1 2>/dev/null || true)
      has "$needle" "$log" && return 0
      sleep 3
    done
    return 1
  }
  job_log_has "Skipping deploy" \
    && pass "deploy leg skipped (assert-only)" || fail "deploy leg was not skipped"
  job_log_has "evidence publish exit=0" \
    && pass "evidence publish reported success" || fail "evidence publish did not report exit=0"
  local n
  n=$(helm --kube-context "$CTX" list -A -q | grep -cv nvidia-aicr || true)
  [ "$n" -eq 0 ] && pass "no component releases installed (nothing but the chart)" \
    || fail "assert-only installed $n component releases"

  if K -n aicr get cm aicr-validate-result >/dev/null 2>&1; then
    # Validators legitimately FAIL here (no components to find) — that is the
    # assertion working. What matters is that a verdict was produced+captured.
    K -n aicr get cm aicr-validate-result -o jsonpath='{.data.ctrf\.json}' \
      | python3 -c "
import sys, json
s = json.load(sys.stdin)['results']['summary']
print(f'  ctrf: {s[\"tests\"]} tests, {s[\"passed\"]} passed, {s[\"failed\"]} failed, {s[\"skipped\"]} skipped')
sys.exit(0 if s['tests'] > 0 else 1)" \
      && pass "CTRF verdict captured" || fail "CTRF verdict empty"
  else
    fail "CTRF verdict ConfigMap missing (validation produced no report)"
    dump_validation_diag
  fi

  if K -n aicr get cm aicr-evidence-bundle >/dev/null 2>&1; then
    local ptr tgz
    ptr=$(K -n aicr get cm aicr-evidence-bundle -o jsonpath='{.data.pointer\.yaml}' 2>/dev/null || true)
    has "schemaVersion" "$ptr" && pass "pointer captured to evidence CM" \
      || fail "pointer capture"
    # `--emit-attestation` alone writes a pointer with empty digest/oci
    # (verified on v0.18.0), so presence proves nothing about publishing —
    # a populated oci field is the real signal that the push happened.
    has_re 'oci:[[:space:]]*[^"[:space:]]' "$ptr" && pass "pointer records a published OCI ref" \
      || fail "pointer has no OCI ref — publish did not push"
    # v0.18.0 --no-sign omits the signer field entirely (observed 2026-08-10).
    has "signer" "$ptr" && fail "unsigned pointer unexpectedly carries a signer" \
      || pass "pointer is unsigned (no signer field)"
    tgz=$(K -n aicr get cm aicr-evidence-bundle -o jsonpath='{.binaryData.evidence\.tgz}' 2>/dev/null || true)
    [ -n "$tgz" ] && pass "evidence bundle captured" || fail "evidence bundle capture"
  else
    fail "evidence ConfigMap missing (validation/publish produced nothing)"
    dump_validation_diag
  fi

  K -n registry port-forward svc/registry 5001:5000 >/dev/null 2>&1 &
  local pf=$!
  # shellcheck disable=SC2064
  trap "kill $pf 2>/dev/null || true; cleanup" EXIT
  if wait_for 30 "registry port-forward" curl -sf -u testuser:testpassword http://localhost:5001/v2/_catalog; then
    local cat anon
    cat=$(curl -s -u testuser:testpassword http://localhost:5001/v2/_catalog)
    has aicr-evidence "$cat" && pass "evidence artifact in the registry" \
      || fail "registry catalog: $cat"
    anon=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/v2/_catalog)
    [ "$anon" = 401 ] && pass "anonymous registry access denied (auth is real)" \
      || fail "expected 401, got $anon"
  fi
  kill "$pf" 2>/dev/null || true
  trap cleanup EXIT
  cleanup; CLUSTER=""
}

echo "== preflight =="
for tool in docker kind kubectl helm curl python3; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

case "$SCENARIO" in
  pack)     scenario_pack ;;
  validate) scenario_validate ;;
  all)      scenario_pack; scenario_validate ;;
esac

echo
if [ "$RC" -eq 0 ]; then echo "KIND E2E PASSED ($SCENARIO)"; else echo "KIND E2E FAILED ($SCENARIO)" >&2; fi
exit "$RC"
