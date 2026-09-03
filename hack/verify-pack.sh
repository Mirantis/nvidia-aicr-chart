#!/usr/bin/env bash
# Offline assertions for the k0s/H200 training data pack.
#
# Everything here runs on a laptop: no cluster, no GPU. The pack's whole job
# is to carry environment facts correctly, and every one of those facts is a
# value that must survive resolution — so the assertions check RESOLVED
# values, not the presence of a string in the source YAML (which would pass
# even if aicr ignored the file entirely).
#
# Two aicr versions are exercised on purpose: v0.20.0 is what the chart pins
# and is the primary target — resolution, leaf registration, strictness and
# resolved-override assertions all run against it, and its bundle (which
# includes the nvsentinel driver-ownership coherence gate added in v0.19)
# must succeed. v0.18.0 is the previous pin, kept as a back-compat bundle
# check because the pack's overrides are accepted by both.
#
# Assertions match against a CAPTURED string, never `cmd | grep -q`: under
# `set -o pipefail` grep -q exits on first match, the producer dies of
# SIGPIPE, and a SUCCESSFUL match reports failure.
#
# shellcheck disable=SC2015,SC2012
# SC2015 (`A && B || C` "isn't if/then/else"): B is always a call to pass()/
# fail(), which only printf and (for fail) set RC=1 — neither can fail, so C
# cannot spuriously run here. SC2012 (`ls | wc -l`): counting entries in a
# bundle output directory that aicr itself just populated with chart names;
# no attacker-controlled or newline-bearing filenames are possible there.
# Mutation-tested per CONTRIBUTING.md house rule 1 (2026-08-25): each row below
# broke the pack one way in a mktemp COPY (never the pack itself) and records
# which assertion caught it. Re-running any of these means repeating that same
# copy-then-break-then-rerun procedure, never editing packs/k0s-h200-training.
#   M1 drop nvidia-dra-driver-gpu's nvidiaDriverRoot override -> "resolved overrides wrong" (nvidiaDriverRoot != /) + BOTH bundle steps FAIL (the driver-ownership coherence gate predates v0.19, so v0.20.0 rejects it too — re-confirmed 2026-09-03, exit 2)
#   M2 point CONTAINERD_SOCKET at /run/containerd/containerd.sock -> "resolved overrides wrong" (toolkit.env mismatch)
#   M3 flip gpu-operator toolkit.enabled true->false -> "resolved overrides wrong" (toolkit.enabled != true)
#   M4 set nvidia-dra-driver-gpu's type to an invalid enum -> "resolution failed on v0.20.0 (pinned)"; downstream steps FAIL skipped, never ok
#   M5 flip gpu-operator driver.enabled false->true -> "resolved overrides wrong" (driver.enabled != false) + BOTH bundle steps FAIL (reverse coherence gate; same pre-v0.19 check, so v0.20.0 rejects it too)
#   M6 flip gpu-operator migManager.enabled false->true -> "resolved overrides wrong" (migManager.enabled != false)
#   M7 loosen the K8s.server.version constraint from >= 1.34 to >= 1.30 -> "resolved overrides wrong" (constraint mismatch)
#   M8 rename metadata.name away from k0s-h200-training -> "leaf not listed" / "leaf not marked external" / "leaf status not pass"
#   M9 inject a validly-structured nodewright-customizations componentRef -> "resolved overrides wrong" (nodewright-customizations present)
#   M10 flip nvsentinel labeler.assumeDriverInstalled true->false -> "resolved overrides wrong" (assumeDriverInstalled != true) + v0.20.0 bundle FAIL
#
set -euo pipefail

PACK="${1:-packs/k0s-h200-training}"
A18="${AICR_018:-./.tmp/aicr-0.18.0}"
A20="${AICR_020:-./.tmp/aicr-0.20.0}"
PIN="$A20"
RC=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; RC=1; }
has()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# One tmpdir for every artifact this run generates (recipes + bundle dirs),
# removed on exit whether we pass, fail, or abort early. Fixed /tmp paths
# reused across runs would let a later run silently read a PREVIOUS run's
# leftover file when this run's own producer step failed — printing `ok`
# about a pack that was never actually resolved. A fresh mktemp -d per run
# makes that class of stale-read impossible: there is nothing to be stale.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RECIPE="$WORK/vp-recipe.yaml"
STRICT="$WORK/vp-strict.yaml"

for b in "$A18" "$A20"; do
  [ -x "$b" ] || { echo "missing aicr binary: $b (see plan Task 1 Step 1)" >&2; exit 2; }
done

echo "== resolution =="
# `resolved` gates every later step that reads $RECIPE: if resolution itself
# failed, those steps must FAIL outright, never silently skip-as-ok and
# never read whatever (nonexistent, now that paths are per-run) file happens
# to be there.
resolved=1
out=$("$PIN" recipe --data "$PACK" --service k0s --accelerator h200 \
        --intent training -o "$RECIPE" 2>&1) \
  && pass "resolves on v0.20.0 (pinned)" || { fail "resolution failed on v0.20.0 (pinned)"; echo "$out" >&2; resolved=0; }

echo "== the leaf is registered and pack-private =="
lst=$("$PIN" recipe list --data "$PACK" 2>/dev/null || true)
line=$(printf '%s\n' "$lst" | awk '$1=="k0s-h200-training"')
[ -n "$line" ] && pass "leaf k0s-h200-training listed" || fail "leaf not listed"
has external "$line" && pass "leaf reports SOURCE=external" || fail "leaf not marked external"
has pass "$line"     && pass "leaf STATUS=pass"            || fail "leaf status not pass"

# --criteria-strict must REJECT service: k0s — proof the value is pack-private
# and the pack carries no accidental upstream dependency (same gate the
# acme-aicr-pack fixture uses).
if "$PIN" recipe --service k0s --accelerator h200 --intent training \
     --criteria-strict -o "$STRICT" >/dev/null 2>&1; then
  fail "--criteria-strict accepted service=k0s (should be pack-private)"
else
  pass "--criteria-strict rejects service=k0s (pack-private)"
fi

echo "== environment facts survive resolution =="
if [ "$resolved" -eq 1 ]; then
python3 - "$RECIPE" <<'EOF' && pass "resolved overrides match the pack's intent" || fail "resolved overrides wrong"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# Keyed by the componentRef's `name` (the pack/registry-facing identifier the
# overlay's `componentRefs[].name` targets), NOT `chart` (the resolved
# upstream Helm chart id). They coincide for e.g. gpu-operator but diverge
# for this pack's own leaf: chart=dra-driver-nvidia-gpu, name=nvidia-dra-driver-gpu
# (same split as upstream node-feature-discovery/nfd, nodewright/nodewright-operator).
# Keying by `chart` silently drops this lookup and never fires the assertion.
refs = {c.get('name'): c for c in d.get('componentRefs', [])}
errs = []
go = (refs.get('gpu-operator') or {}).get('overrides', {})
if go.get('driver', {}).get('enabled') is not False: errs.append('driver.enabled != false')
if go.get('toolkit', {}).get('enabled') is not True: errs.append('toolkit.enabled != true')
env = {e['name']: e['value'] for e in go.get('toolkit', {}).get('env', [])}
want = {'CONTAINERD_CONFIG': '/etc/k0s/containerd.d/nvidia.toml',
        'CONTAINERD_SOCKET': '/run/k0s/containerd.sock',
        'CONTAINERD_RUNTIME_CLASS': 'nvidia'}
if env != want: errs.append(f'toolkit.env {env} != {want}')
for k in ('gds', 'gdrcopy', 'migManager'):
    if go.get(k, {}).get('enabled') is not False: errs.append(f'{k}.enabled != false')
dra = (refs.get('nvidia-dra-driver-gpu') or {}).get('overrides', {})
if dra.get('nvidiaDriverRoot') != '/': errs.append('nvidiaDriverRoot != /')
nvs = (refs.get('nvsentinel') or {}).get('overrides', {})
if nvs.get('labeler', {}).get('assumeDriverInstalled') is not True: errs.append('labeler.assumeDriverInstalled != true')
if 'nodewright-customizations' in refs: errs.append('nodewright-customizations present (reboots nodes)')
cons = {c['name']: c['value'] for c in d.get('constraints', [])}
if cons.get('K8s.server.version') != '>= 1.34': errs.append(f"constraint {cons.get('K8s.server.version')}")
if errs:
    print('  ' + '; '.join(errs), file=sys.stderr); sys.exit(1)
EOF
else
  fail "skipped: v0.20.0 (pinned) did not resolve, cannot check resolved overrides"
fi

echo "== back-compat: still bundles cleanly on v0.18.0 (previous pin) =="
RECIPE18="$WORK/vp18.yaml"
b="$WORK/bundle18"
mkdir -p "$b"
if out=$("$A18" recipe --data "$PACK" --service k0s --accelerator h200 \
     --intent training -o "$RECIPE18" 2>&1) \
   && out=$("$A18" bundle --recipe "$RECIPE18" --deployer helm -o "$b" 2>&1); then
  n=$(ls "$b" | wc -l | tr -d ' ')
  [ "$n" -ge 11 ] && pass "v0.18.0 bundle wrote $n entries" || fail "expected >=11 entries, got $n"
else
  fail "v0.18.0 resolve+bundle failed"; printf '%s\n' "$out" | tail -3 >&2
fi

echo "== bundles cleanly on v0.20.0 (the chart's pin; nvsentinel gate satisfied) =="
b2="$WORK/bundle20"
mkdir -p "$b2"
if [ "$resolved" -eq 1 ]; then
  if out=$("$PIN" bundle --recipe "$RECIPE" --deployer helm -o "$b2" 2>&1); then
    n=$(ls "$b2" | wc -l | tr -d ' ')
    [ "$n" -ge 11 ] && pass "v0.20.0 bundle wrote $n entries" || fail "expected >=11 entries, got $n"
  else
    fail "v0.20.0 bundle failed"; printf '%s\n' "$out" | tail -3 >&2
  fi
else
  fail "skipped: v0.20.0 bundle not attempted, resolution failed"
fi

echo
[ "$RC" -eq 0 ] && echo "PACK ASSERTIONS PASSED" || echo "PACK ASSERTIONS FAILED" >&2
exit "$RC"
