#!/usr/bin/env bash
#
# Smoke-tests a staged k0s bundle before the build host is wiped.
#
# build-offline-bundle.sh needs docker, Go and a source tree; cleanup-blank.sh
# removes them, and after that a broken tarball can only be found by a failed
# install on a blank machine. Everything here is cheap next to that.
#
# Checks the bundle's record of itself (bundle.manifest, bundle.env), the files
# entry.sh will read, the Cilium values an offline import needs, line endings,
# that every staged script parses, the charts render, the image archives are
# docker archives, and that the tag in bundle.env is the tag inside them.
#
# Needs: a built bundle, and bash, tar and sha256sum. helm is taken from the
# bundle's bin/ when present, otherwise from PATH. --load-images additionally
# needs a running docker and loads the platform archive into its image store.
#
# Run:
#   ./hack/verify-k0s-bundle.sh [/opt/kubecube-offline] [--load-images]
#
# Exit 0 when the bundle looks installable, 1 when a check failed, 2 on bad usage.

set -euo pipefail

OUT=${OUT:-/opt/kubecube-offline}
LOAD_IMAGES=0
fail=0

function ok() { echo "  ok    $*"; }
function bad() {
  echo "  FAIL  $*"
  fail=$((fail + 1))
}

function finish() {
  local rc=$?
  trap - EXIT
  echo
  if [ "${fail}" -eq 0 ] && [ "${rc}" -eq 0 ]; then
    echo "bundle looks installable"
    exit 0
  fi
  if [ "${fail}" -eq 0 ]; then
    echo "BUNDLE CHECK FAILED: aborted (exit ${rc})"
    fail=1
  else
    echo "${fail} check(s) failed"
  fi
  exit "${fail}"
}

function usage() {
  cat <<'USAGE'
verify-k0s-bundle.sh -- smoke-test a staged k0s bundle

  ./hack/verify-k0s-bundle.sh [BUNDLE_DIR] [--load-images]

  BUNDLE_DIR      bundle root, default /opt/kubecube-offline
  --load-images   also load images/platform.tar into this host's docker
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --load-images) LOAD_IMAGES=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "verify-k0s-bundle: unknown option ${arg}" >&2; usage >&2; exit 2 ;;
    *) OUT=${arg} ;;
  esac
done

trap finish EXIT

arch=$(uname -m)
case "${arch}" in
  aarch64|arm64) k0s_bin=k0s-arm64 ;;
  x86_64|amd64) k0s_bin=k0s-amd64 ;;
  *) k0s_bin="k0s-${arch}" ;;
esac

echo "== bundle =="
if [ ! -d "${OUT}" ]; then
  bad "missing: ${OUT}"
  exit 1
fi
ok "exists: ${OUT} ($(du -sh "${OUT}" 2> /dev/null | awk '{print $1}' || true))"

echo "== checksums =="
if (cd "${OUT}" && sha256sum -c bundle.manifest --quiet); then
  ok "bundle.manifest verifies ($(wc -l < "${OUT}/bundle.manifest" 2> /dev/null || echo 0) files)"
else
  bad "bundle.manifest does not verify"
fi

echo "== layout =="
for p in entry.sh install.conf bundle.env bundle.manifest \
  cleanup-blank.sh manifests/install.sh manifests/install_k0s.sh manifests/install_kubecube.sh manifests/install.conf \
  "k0s/${k0s_bin}" charts/kubecube-chart/Chart.yaml charts/cilium/Chart.yaml charts/cilium-values.yaml \
  charts/third-charts.tar.gz bin/helm bin/kubectl images; do
  if [ -e "${OUT}/${p}" ]; then ok "${p}"; else bad "${p} missing"; fi
done
if [ ! -e "${OUT}/k0s/${k0s_bin}" ]; then
  other=$(cd "${OUT}/k0s" 2> /dev/null && ls k0s-* 2> /dev/null | head -1 || true)
  if [ -n "${other}" ]; then
    bad "bundle carries ${other}, this host is ${arch}"
  fi
fi

echo "== the bundle's own install.conf =="
# The appended block has to win over the repository defaults, otherwise an
# offline install tries to download.
for k in 'OFFLINE="true"' 'KUBERNETES_DISTRO="k0s"' 'CNI="cilium"' 'CLOUDSHELL_ENABLE="false"' 'FRONTEND_ENABLE="false"'; do
  if grep -q "${k}" "${OUT}/manifests/install.conf" 2> /dev/null; then ok "${k}"; else bad "${k} not set"; fi
done
tag=$(awk -F= '/^KUBECUBE_IMAGE_TAG=/ {print $2}' "${OUT}/bundle.env" 2> /dev/null | tail -1 || true)
if [ -n "${tag}" ]; then ok "image tag ${tag}"; else bad "no image tag in bundle.env"; fi

echo "== the cilium values the bundle carries =="
# Every image the chart can pin by digest has to be switched off: a docker
# archive has no manifest digest, so "tag@sha256:..." matches nothing after the
# import and the pod sits in ImagePullBackOff offline.
n=$(grep -c 'useDigest: false' "${OUT}/charts/cilium-values.yaml" 2> /dev/null || true)
if [ "${n}" -ge 3 ]; then
  ok "${n} useDigest switches are off (agent, operator, envoy)"
else
  bad "only ${n} useDigest switch(es) off; the agent, the operator and envoy all need it"
fi

echo "== line endings =="
# A CRLF script fails on the target with "syntax error near unexpected token",
# which is the first thing an install does.
if grep -rlU $'\r' "${OUT}/manifests" "${OUT}/entry.sh" 2> /dev/null | grep -q .; then
  bad "CRLF found in the staged scripts"
else
  ok "staged scripts are LF"
fi

echo "== scripts parse =="
parsed=0
for f in "${OUT}"/manifests/*.sh "${OUT}/entry.sh"; do
  [ -f "${f}" ] || continue
  parsed=$((parsed + 1))
  if bash -n "${f}" 2> /dev/null; then ok "bash -n $(basename "${f}")"; else bad "bash -n $(basename "${f}")"; fi
done
[ "${parsed}" -gt 0 ] || bad "no staged scripts found to parse"

echo "== k0s binary =="
if [ -x "${OUT}/k0s/${k0s_bin}" ]; then
  if "${OUT}/k0s/${k0s_bin}" version > /dev/null 2>&1; then
    ok "${k0s_bin} runs"
  else
    bad "${k0s_bin} does not run on this host"
  fi
else
  bad "k0s/${k0s_bin} is missing or not executable"
fi

echo "== charts =="
HELM=${HELM:-}
if [ -z "${HELM}" ]; then
  if [ -x "${OUT}/bin/helm" ]; then HELM="${OUT}/bin/helm"; else HELM=helm; fi
fi
if command -v "${HELM}" > /dev/null 2>&1; then
  if "${HELM}" lint "${OUT}/charts/kubecube-chart" > /dev/null 2>&1; then
    ok "kubecube chart lints"
  else
    bad "kubecube chart does not lint"
  fi
  "${HELM}" show chart "${OUT}/charts/cilium" 2> /dev/null | awk '/^(name|version):/ {printf "  %s\n", $0}' || true
  if "${HELM}" template cilium "${OUT}/charts/cilium" --namespace kube-system > /dev/null 2>&1; then
    ok "cilium chart renders"
  else
    bad "cilium chart does not render"
  fi
else
  bad "helm not available (looked for ${HELM})"
fi

echo "== images =="
images=0
for t in "${OUT}"/images/*.tar; do
  [ -e "${t}" ] || continue
  images=$((images + 1))
  n=$(tar -tf "${t}" 2> /dev/null | wc -l || true)
  if [ "${n}" -gt 0 ] && tar -tf "${t}" 2> /dev/null | grep -q 'manifest.json'; then
    ok "$(basename "${t}"): $(du -h "${t}" | cut -f1), ${n} entries"
  else
    bad "$(basename "${t}") is not a docker archive"
  fi
done
[ "${images}" -gt 0 ] || bad "no image archives under ${OUT}/images"

# The tag in bundle.env and the tags inside the archives have to be the same
# string: the installer writes the first into the chart values and the cluster
# pulls the second.
echo "== tag agreement =="
if [ -f "${OUT}/images/platform.tar" ]; then
  in_archive=$(tar -xOf "${OUT}/images/platform.tar" manifest.json 2> /dev/null | grep -oE 'kubecube/[a-z-]+:[^"]+' | sort -u | head -3 || true)
  while read -r i; do [ -n "${i}" ] && echo "  ${i}"; done <<< "${in_archive}"
  if [ -n "${tag}" ] && [ -n "${in_archive}" ] && echo "${in_archive}" | grep -q "${tag}"; then
    ok "archives carry the tag bundle.env records"
  else
    bad "archives do not carry ${tag}"
  fi
else
  bad "images/platform.tar is missing"
fi

if [ "${LOAD_IMAGES}" -eq 1 ]; then
  echo "== docker can read the archives =="
  if ! command -v docker > /dev/null 2>&1; then
    bad "docker is not installed; rerun without --load-images"
  elif docker load -i "${OUT}/images/platform.tar" > /dev/null 2>&1; then
    ok "platform.tar loads"
  else
    bad "platform.tar does not load"
  fi
fi

# The EXIT trap prints the summary and exits with the number of failed checks.
