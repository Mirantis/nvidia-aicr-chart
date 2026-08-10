#!/usr/bin/env bash
# Customer-shaped kind e2e for the nvidia-aicr chart.
#
# Exercises the full org-pack path against local infrastructure only:
#   1. htpasswd-protected plain-HTTP registry:2 in-cluster (the "org registry")
#   2. oras push of hack/e2e/acme-aicr-pack (the "CI publish" leg)
#   3. chart install with dataPack + dataPackSecret + dataPackPlainHTTP
#   4. asserts: pack-named recipe resolution, recipe/CTRF/evidence ConfigMaps,
#      unsigned publish with empty signer, artifact present in the registry
#   5. negative test: pull without the secret must fail closed (401)
#
# Nothing leaves the machine. Requires: docker, kind, kubectl, helm, curl,
# python3. Runtime ~20-25 min (dominated by the fresh install).
#
# Usage: hack/e2e/run-kind-e2e.sh [--keep] [--cluster NAME]
#   --keep     do not delete the kind cluster at the end
#   --cluster  cluster name (default: aicr-chart-e2e)
#
# shellcheck disable=SC2015  # `check && pass || fail`: pass always returns 0,
#                            # so fail can never run on success — safe here.
# shellcheck disable=SC2329  # cleanup/neg_failed are invoked via trap/wait_for.
set -euo pipefail

CLUSTER=aicr-chart-e2e
KEEP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)    KEEP=true; shift ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$(cd "$HERE/../.." && pwd)"
CTX="kind-${CLUSTER}"
K() { kubectl --context "$CTX" "$@"; }
RC=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; RC=1; }

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

echo "== preflight =="
for tool in docker kind kubectl helm curl python3; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

echo "== 1. kind cluster (K8s 1.34 — DRA floor) =="
kind create cluster --name "$CLUSTER" --image kindest/node:v1.34.0
K wait --for=condition=Ready node --all --timeout=180s

cleanup() {
  if [ "$KEEP" = false ]; then
    kind delete cluster --name "$CLUSTER" || true
  else
    echo "(--keep: cluster ${CLUSTER} left running)"
  fi
}
trap cleanup EXIT

echo "== 2. org registry (htpasswd, plain HTTP) =="
HTPASSWD=$(docker run --rm httpd:2-alpine htpasswd -Bbn testuser testpassword)
K create namespace registry
K -n registry create secret generic registry-htpasswd --from-literal=htpasswd="$HTPASSWD"
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

echo "== 3. push the pack (the CI leg) =="
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
# Logs can lag pod termination by a few seconds (kubelet log finalization);
# retry the read rather than flaking on the race.
PUSH_OK=false
for _ in 1 2 3 4 5; do
  if K -n registry logs pack-push 2>/dev/null | grep -q "Pushed"; then PUSH_OK=true; break; fi
  sleep 3
done
[ "$PUSH_OK" = true ] && pass "pack pushed" || fail "pack push"

echo "== 4. pull secret + install =="
K create namespace aicr
K -n aicr create secret docker-registry acme-registry-cred \
  --docker-server=registry.registry.svc:5000 \
  --docker-username=testuser --docker-password=testpassword
helm --kube-context "$CTX" install nvidia-aicr "$CHART" -n aicr \
  -f "$HERE/values-kind-e2e.yaml"

echo "== 5. wait for the install Job (Complete OR Failed) =="
JOB=nvidia-aicr-install-1
DEADLINE=$((SECONDS + 1500))
while :; do
  c=$(K -n aicr get job "$JOB" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  case "$c" in
    *Complete*) pass "install Job complete"; break ;;
    *Failed*)
      fail "install Job failed"
      K -n aicr logs "job/$JOB" --tail=100 || true
      exit 1 ;;
  esac
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    fail "install Job did not finish in 25m"
    K -n aicr logs "job/$JOB" --tail=100 || true
    exit 1
  fi
  sleep 15
done

echo "== 6. asserts =="
SUMMARY=$(K -n aicr get cm aicr-recipe -o jsonpath='{.data.summary\.txt}')
echo "$SUMMARY" | grep -q "service=acme" \
  && pass "recipe CM records pack-named criteria (service=acme)" \
  || fail "recipe CM criteria"
echo "$SUMMARY" | grep -q "recipe generation completed" \
  && pass "recipe CM carries resolver summary" || fail "resolver summary"
K -n aicr get cm aicr-recipe -o jsonpath='{.data.recipe\.yaml}' | head -1 | grep -q . \
  && pass "full recipe captured" || fail "recipe.yaml capture"

K -n aicr get cm aicr-validate-result -o jsonpath='{.data.ctrf\.json}' \
  | python3 -c "
import sys, json
s = json.load(sys.stdin)['results']['summary']
print(f'  ctrf: {s[\"tests\"]} tests, {s[\"passed\"]} passed, {s[\"failed\"]} failed')
sys.exit(0 if s['tests'] > 0 else 1)" \
  && pass "CTRF verdict captured" || fail "CTRF verdict"

PTR=$(K -n aicr get cm aicr-evidence-bundle -o jsonpath='{.data.pointer\.yaml}')
echo "$PTR" | grep -q "aicr-evidence" && pass "pointer captured to evidence CM" || fail "pointer capture"
# v0.18.0 --no-sign omits the signer field entirely (observed 2026-08-10).
echo "$PTR" | grep -q "signer" && fail "unsigned pointer unexpectedly carries a signer" \
  || pass "pointer is unsigned (no signer field)"
K -n aicr get cm aicr-evidence-bundle -o jsonpath='{.binaryData.evidence\.tgz}' | grep -q . \
  && pass "evidence bundle captured" || fail "evidence bundle capture"

K -n registry port-forward svc/registry 5001:5000 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true; cleanup' EXIT
wait_for 30 "registry port-forward" curl -sf -u testuser:testpassword http://localhost:5001/v2/_catalog
CAT=$(curl -s -u testuser:testpassword http://localhost:5001/v2/_catalog)
echo "$CAT" | grep -q aicr-evidence && pass "evidence artifact in the registry" || fail "registry catalog: $CAT"
ANON=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/v2/_catalog)
[ "$ANON" = 401 ] && pass "anonymous registry access denied (auth is real)" || fail "expected 401, got $ANON"
kill $PF 2>/dev/null || true
trap cleanup EXIT

echo "== 7. negative test: pull without the secret must fail closed =="
helm --kube-context "$CTX" upgrade nvidia-aicr "$CHART" -n aicr \
  -f "$HERE/values-kind-e2e.yaml" --set dataPackSecret=""
neg_failed() {
  local pod
  pod=$(K -n aicr get pods -o name 2>/dev/null | grep install-2 | head -1) || return 1
  [ -n "$pod" ] || return 1
  K -n aicr get "$pod" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}' 2>/dev/null \
    | grep -q Error
}
wait_for 300 "anonymous pull rejection" neg_failed \
  && pass "initContainer failed without the secret (fail-closed)" \
  || fail "negative test"
POD=$(K -n aicr get pods -o name | grep install-2 | head -1)
K -n aicr logs "$POD" -c data-pack 2>&1 | grep -qiE "credential|unauthorized|401" \
  && pass "failure is an auth error, not something else" || fail "unexpected init error"

echo
if [ "$RC" -eq 0 ]; then echo "KIND E2E PASSED"; else echo "KIND E2E FAILED" >&2; fi
exit "$RC"
