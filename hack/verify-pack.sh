#!/usr/bin/env bash
# Offline assertions for the k0s/H200 training data pack.
#
# Everything here runs on a laptop: no cluster, no GPU. The pack's whole job
# is to carry environment facts correctly, and every one of those facts is a
# value that must survive resolution — so the assertions check RESOLVED
# values, not the presence of a string in the source YAML (which would pass
# even if aicr ignored the file entirely).
#
# Two aicr versions are exercised on purpose. v1.2.0 is what the chart pins
# and is the primary target: resolution, leaf registration, strictness,
# resolved-override and appliedOverlays assertions all run against it, and its
# bundle (built with --data, as the chart's Job does, including the nvsentinel
# and DRA driver-ownership coherence gates) must succeed and pass `aicr verify`.
# v0.20.0 is the previous pin, kept as a back-compat resolve+bundle check: it
# reads the same `aicr.run/v1beta1` header, so the pack is not tied to one aicr
# release. Verified 2026-11-05: both binaries resolve and bundle this pack.
# The pack is an illustrative worked example layered on upstream's
# `service: k0s` overlays (aicr >= v0.22.0). Upstream's `k0s` overlay sets the
# gpu-operator toolkit.env and the >= 1.34 constraint, so those two checks pass
# on upstream alone (duplicated here on purpose, see the overlay's header). The
# driver-ownership, MIG and nvsentinel facts come upstream only from the
# `os: ubuntu` leaf h200-k0s-ubuntu-training, which this OS-agnostic leaf does
# not apply, so on the recipe resolved here they, and rdma/gds/gdrcopy off,
# depend on the pack. (v1.2.0, verified 2026-11-05.)
#
# Assertions match against a CAPTURED string, never `cmd | grep -q`: under
# `set -o pipefail` grep -q exits on first match, the producer dies of
# SIGPIPE, and a SUCCESSFUL match reports failure.
#
# shellcheck disable=SC2015
# SC2015 (`A && B || C` "isn't if/then/else"): B is always a call to pass()/
# fail(), which only printf and (for fail) set RC=1 — neither can fail, so C
# cannot spuriously run here.
# Mutation-tested per CONTRIBUTING.md house rule 1 (re-run on v1.2.0, 2026-11-05):
# each row below broke the pack one way in a mktemp COPY (never the pack itself)
# and records which assertion caught it. Re-running any of these means repeating
# that same copy-then-break-then-rerun procedure, never editing
# packs/k0s-h200-training. Rows M13-M17 break the binary instead (AICR_120 /
# AICR_020 pointed at a stand-in), since they guard steps that need no pack edit.
#   M1 drop nvidia-dra-driver-gpu's nvidiaDriverRoot override -> "resolved overrides wrong" (nvidiaDriverRoot != /) + v1.2.0 bundle FAIL (exit 2, driver-ownership gate) + v0.20.0 bundle FAIL
#   M2 point CONTAINERD_SOCKET at /run/containerd/containerd.sock -> "resolved overrides wrong" (toolkit.env mismatch)
#   M3 flip gpu-operator toolkit.enabled true->false -> "resolved overrides wrong" (toolkit.enabled != true)
#   M4 set nvidia-dra-driver-gpu's type to an invalid enum -> "resolution failed on v1.2.0 (pinned)"; downstream steps FAIL skipped, never ok
#   M5 flip gpu-operator driver.enabled false->true -> "resolved overrides wrong" (driver.enabled != false) + v1.2.0 bundle FAIL (reverse coherence gate) + v0.20.0 bundle FAIL
#   M6 flip gpu-operator migManager.enabled false->true -> "resolved overrides wrong" (migManager.enabled != false)
#   M7 loosen the K8s.server.version constraint from >= 1.34 to >= 1.30 -> "resolved overrides wrong" (constraint mismatch)
#   M8 rename metadata.name away from k0s-h200-training -> "leaf not listed" / "leaf not marked external" / "leaf status not pass" + "resolved overrides wrong" (appliedOverlays [... 'k0s-h200-renamed'] missing upstream k0s layering)
#   M9 inject a validly-structured nodewright-customizations componentRef (source+chart+version) -> "resolved overrides wrong" (nodewright-customizations present) + both bundle legs "expected 11 component dirs, got 12". A bare `type: Helm` ref is not valid structure and is caught earlier by "resolution failed".
#   M10 flip nvsentinel labeler.assumeDriverInstalled true->false -> "resolved overrides wrong" (assumeDriverInstalled != true) + v1.2.0 bundle FAIL (exit 2, nvsentinel labeler gate) + v0.20.0 bundle FAIL
#   M11 change criteria.service k0s -> k0sfleet -> "resolution failed on v1.2.0 (pinned)" (no recipe covering k0s/h200/training) + downstream FAIL skipped. The appliedOverlays assertion is never reached on this mutation because resolution fails first; it is exercised by M8 and M13.
#   M12 revert the RecipeMetadata document's apiVersion to aicr.run/v1alpha2 -> "resolution failed on v1.2.0 (pinned)" (v1alpha2 was retired in v1.0.0). The ComponentRegistry document (registry.yaml) reverted instead gives the same "resolution failed", error text names the external registry.yaml.
#   M13 AICR_120 pointed at v0.20.0 -> both "--criteria-strict ... k0s" assertions FAIL ("invalid service type: k0s") + appliedOverlays missing upstream k0s layering
#   M14 stand-in binary whose `verify` exits 1 -> "aicr verify failed on the v1.2.0 bundle"
#   M15 stand-in binary whose `bundle` writes 2 entries -> "expected 11 component dirs, got 0"
#   M17 stand-in binary whose `bundle` writes 4 component dirs plus 14 other files (18 top-level entries, as a real v1.2.0 bundle) -> "expected 11 component dirs, got 4" (the old `>= 11 entries` check passed this)
#   M16 AICR_020=/usr/bin/false -> "v0.20.0 resolve+bundle failed"
#
set -euo pipefail

PACK="${1:-packs/k0s-h200-training}"
A120="${AICR_120:-./.tmp/aicr-1.2.0}"
A20="${AICR_020:-./.tmp/aicr-0.20.0}"
PIN="$A120"
RC=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; RC=1; }
# Count component dirs (NNN-<name>) in a bundle; top-level entries would also
# count README.md, deploy.sh, checksums.txt etc. Both v1.2.0 (dra-node-labeler
# skipped at bundle time) and v0.20.0 give 11 for this pack, verified 2026-11-05.
count_components() {
  local d c=0
  for d in "$1"/[0-9][0-9][0-9]-*; do [ -d "$d" ] && c=$((c + 1)); done
  echo "$c"
}
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

for b in "$A120" "$A20"; do
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
  && pass "resolves on v1.2.0 (pinned)" || { fail "resolution failed on v1.2.0 (pinned)"; echo "$out" >&2; resolved=0; }

echo "== the pack leaf is registered (external) =="
lst=$("$PIN" recipe list --data "$PACK" 2>/dev/null || true)
line=$(printf '%s\n' "$lst" | awk '$1=="k0s-h200-training"')
[ -n "$line" ] && pass "leaf k0s-h200-training listed" || fail "leaf not listed"
has external "$line" && pass "leaf reports SOURCE=external" || fail "leaf not marked external"
has pass "$line"     && pass "leaf STATUS=pass"            || fail "leaf status not pass"

# --criteria-strict must ACCEPT service: k0s. This flipped when the pin moved
# off v0.20.0 (chart 0.3.0): upstream ships a `service: k0s` overlay since
# v0.22.0, so k0s is no longer a pack-private value and this pack is not what
# registers it. The old assertion (strict REJECTS k0s) would pass on v1.2.0
# for the wrong reason (verified 2026-11-05) — without --data, `--service k0s
# --intent training` fails with "no recipe covering that combination; specify
# os" — so both checks below are written to succeed only when the value
# itself is accepted.
#   (a) upstream alone, with --os ubuntu (the only os upstream's k0s training
#       leaf covers): proves k0s is an upstream value, no pack involved.
#   (b) with the pack and no --os: the pack leaf passes the strict gate.
if out=$("$PIN" recipe --service k0s --accelerator h200 --intent training --os ubuntu \
     --criteria-strict -o "$STRICT" 2>&1); then
  pass "--criteria-strict accepts service=k0s (upstream value since v0.22.0)"
else
  fail "--criteria-strict rejects service=k0s (expected upstream value on v1.2.0)"; printf '%s\n' "$out" | tail -3 >&2
fi
if out=$("$PIN" recipe --data "$PACK" --service k0s --accelerator h200 --intent training \
     --criteria-strict -o "$STRICT" 2>&1); then
  pass "--criteria-strict accepts the pack's service=k0s recipe"
else
  fail "--criteria-strict rejects the pack's service=k0s recipe"; printf '%s\n' "$out" | tail -3 >&2
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
# The order assertion holds because this script never passes --os: with --os
# ubuntu and the pack loaded, appliedOverlays puts k0s-h200-training BEFORE k0s,
# k0s-training (v1.2.0, verified 2026-11-05), and the subsequence would fail.
# The pack leaf must layer on upstream's k0s overlays (proves the example sits
# on top of upstream; a renamed `service` or an overlay-name collision breaks
# it). Ordered subsequence, not equality, so unrelated upstream layers added
# in a later aicr do not break it.
applied = d.get('metadata', {}).get('appliedOverlays', [])
it = iter(applied)
if not all(n in it for n in ('k0s', 'k0s-training', 'k0s-h200-training')):
    errs.append(f'appliedOverlays {applied} missing upstream k0s layering')
if errs:
    print('  ' + '; '.join(errs), file=sys.stderr); sys.exit(1)
EOF
else
  fail "skipped: v1.2.0 (pinned) did not resolve, cannot check resolved overrides"
fi

echo "== bundles cleanly on v1.2.0 (pinned; --data mirrors the chart Job) =="
# The pack is passed to bundle too, as the chart's Job does. The bundle output
# goes under $WORK, never inside $PACK: bundling into a --data directory
# recurses until "file name too long".
b2="$WORK/bundle120"
mkdir -p "$b2"
if [ "$resolved" -eq 1 ]; then
  if out=$("$PIN" bundle --data "$PACK" --recipe "$RECIPE" --deployer helm -o "$b2" 2>&1); then
    n=$(count_components "$b2")
    [ "$n" -eq 11 ] && pass "v1.2.0 bundle wrote $n component dirs" || fail "expected 11 component dirs, got $n"
    if out=$("$PIN" verify "$b2" 2>&1); then
      pass "aicr verify passes on the v1.2.0 bundle"
    else
      fail "aicr verify failed on the v1.2.0 bundle"; printf '%s\n' "$out" | tail -3 >&2
    fi
  else
    fail "v1.2.0 bundle failed"; printf '%s\n' "$out" | tail -3 >&2
  fi
else
  fail "skipped: v1.2.0 bundle not attempted, resolution failed"
fi

echo "== back-compat: still resolves and bundles cleanly on v0.20.0 (previous pin) =="
RECIPE20="$WORK/vp20.yaml"
b="$WORK/bundle20"
mkdir -p "$b"
if out=$("$A20" recipe --data "$PACK" --service k0s --accelerator h200 \
     --intent training -o "$RECIPE20" 2>&1) \
   && out=$("$A20" bundle --recipe "$RECIPE20" --deployer helm -o "$b" 2>&1); then
  n=$(count_components "$b")
  [ "$n" -eq 11 ] && pass "v0.20.0 bundle wrote $n component dirs" || fail "expected 11 component dirs, got $n"
else
  fail "v0.20.0 resolve+bundle failed"; printf '%s\n' "$out" | tail -3 >&2
fi

echo
[ "$RC" -eq 0 ] && echo "PACK ASSERTIONS PASSED" || echo "PACK ASSERTIONS FAILED" >&2
exit "$RC"
