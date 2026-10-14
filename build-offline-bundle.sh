#!/usr/bin/env bash
#
# Builds the offline bundle.
#
# This is a *build* tool: it runs on a host that has network access, docker and
# Go, and it produces a directory that carries everything an install needs, so
# the install itself can run on a machine with no network at all.
#
#   ./build-offline-bundle.sh
#   OUT=/opt/kubecube-offline WORKSPACE=/root/kubecube-src ./build-offline-bundle.sh
#
# What it collects:
#
#   k0s/k0s-<arch>        the k0s binary, extracted from the released image
#   images/*.tar          every image the cluster and the platform need, saved
#                         under the names the manifests will ask for
#   charts/kubecube-chart the platform chart, from the workspace
#   charts/cilium         the Cilium chart, pulled as an OCI artifact
#   bin/helm bin/kubectl  the binaries the offline install cannot download
#   manifests/            the installer scripts
#   bundle.env            the image tag and the versions this bundle carries
#   bundle.manifest       sha256 of every file above
#
# The image tag is the single source for both halves: the images are saved as
# docker.io/<project>/<name>:<tag>, and the installer writes the same tag into
# the chart values. A bundle whose two halves disagree installs nothing but
# ImagePullBackOff.

set -euo pipefail

# ------------------------------------------------------------------ settings

WORKSPACE=${WORKSPACE:-/root/kubecube-src}
OUT=${OUT:-/opt/kubecube-offline}
KUBECUBE_VERSION=${KUBECUBE_VERSION:-v1.9.2}
BUILD_DATE=${BUILD_DATE:-$(date +%Y%m%d)}
IMAGE_REGISTRY=${IMAGE_REGISTRY:-docker.io}
IMAGE_PROJECT=${IMAGE_PROJECT:-kubecube}
HELM_VERSION=${HELM_VERSION:-v3.14.4}
# kubectl tracks the cluster version; keep the two in step with install.conf.
KUBECTL_VERSION=${KUBECTL_VERSION:-v1.28.15}
LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION:-v0.0.28}
CFSSL_VERSION=${CFSSL_VERSION:-v1.6.5}

INSTALLER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Sourced through sed rather than directly. A Windows checkout hands this file
# over with CRLF, and bash then reports every line as "$'\r': command not
# found"; the build host may be either kind of checkout, so read the values
# without depending on which one it is.
# shellcheck source=/dev/null
source <(sed 's/\r$//' "${INSTALLER_DIR}/install.conf")

ARCH=$(case "$(uname -m)" in
  x86_64) echo amd64 ;;
  aarch64 | arm64) echo arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac)

IMAGE_TAG=${IMAGE_TAG:-${KUBECUBE_VERSION}-${BUILD_DATE}-${ARCH}}
K0S_IMAGE="quay.io/k0sproject/k0s:v${K0S_VERSION}-k0s.0"

function log() { echo -e "\033[32m[bundle]\033[0m $*"; }
function warn() { echo -e "\033[33m[bundle]\033[0m $*"; }
function die() {
  echo -e "\033[31m[bundle] $*\033[0m" >&2
  exit 1
}

# normalize_lines strips CR from the text files under a directory.
#
# The build host is often a Windows checkout with core.autocrlf=true, which
# leaves CRLF in the working tree, and a tarball taken from that tree carries
# them. bash on the target refuses such a file outright — "syntax error near
# unexpected token `$'{\r''" — and that is the very first thing the install
# runs, so the bundle has to carry LF.
function normalize_lines() {
  local dir=$1
  local n=0
  local f
  while IFS= read -r -d '' f; do
    if grep -q $'\r' "$f" 2> /dev/null; then
      sed -i 's/\r$//' "$f"
      n=$((n + 1))
    fi
  done < <(find "${dir}" -type f \( -name '*.sh' -o -name 'Dockerfile' -o -name '*.yaml' -o -name '*.yml' \
    -o -name '*.conf' -o -name '*.list' -o -name '*.json' -o -name '*.md' \) -print0)
  if [ "${n}" -gt 0 ]; then
    log "normalized line endings in ${n} file(s) under ${dir}"
  fi
}

# --------------------------------------------------------------- preflight

function preflight() {
  local missing=()
  for cmd in docker go helm curl sha256sum python3; do
    command -v "${cmd}" > /dev/null || missing+=("${cmd}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing tools: ${missing[*]}"
  fi

  for dir in KubeCube kubecube-audit kubecube-webconsole kubecube-chart hotplugs; do
    [ -d "${WORKSPACE}/${dir}" ] || die "${WORKSPACE}/${dir} is missing"
  done

  log "workspace   : ${WORKSPACE}"
  log "bundle      : ${OUT}"
  log "arch        : ${ARCH}"
  log "image tag   : ${IMAGE_TAG}"
  log "k0s         : ${K0S_VERSION} (${K0S_IMAGE})"
  log "cilium      : ${CILIUM_VERSION}"
}

# fetch downloads a URL, treating a stalled connection as a failure.
#
# --speed-limit/--speed-time matter here: dl.k8s.io serves at roughly 40KB/s on
# some networks, and without a floor a connection that stops moving leaves the
# build hanging with no output instead of failing.
function fetch() {
  curl -sSLf --retry 5 --retry-delay 5 --retry-all-errors --speed-limit 1024 --speed-time 60 "$@"
}

# pull_with_fallback pulls an image trying each source in turn, and retags it to
# the name the manifests will ask for.
#
# The mirrors here are the ones that answered from this network; a source that
# is unreachable or does not carry the repository is skipped with a warning
# rather than failing the build, so one dead mirror does not stop everything.
function pull_with_fallback() {
  local target=$1
  shift
  local source
  for source in "$@"; do
    log "pulling ${source}"
    if docker pull "${source}" > /dev/null 2>&1; then
      docker tag "${source}" "${target}"
      return 0
    fi
    warn "${source} did not work, trying the next source"
  done
  die "could not pull ${target} from any source: $*"
}

# ------------------------------------------------------------------- k0s

function build_k0s() {
  log "extracting the k0s binary from ${K0S_IMAGE}"
  docker pull --platform "linux/${ARCH}" "${K0S_IMAGE}" > /dev/null

  local tmp="k0s-extract-$$"
  docker rm -f "${tmp}" > /dev/null 2>&1 || true
  docker create --name "${tmp}" --platform "linux/${ARCH}" "${K0S_IMAGE}" > /dev/null
  docker cp "${tmp}:/usr/local/bin/k0s" "${OUT}/k0s/k0s-${ARCH}"
  docker rm "${tmp}" > /dev/null
  chmod 0755 "${OUT}/k0s/k0s-${ARCH}"

  local version
  version=$("${OUT}/k0s/k0s-${ARCH}" version)
  log "k0s binary: ${version}"
  case "${version}" in
    *"${K0S_VERSION}"*) ;;
    *) die "the extracted k0s binary is ${version}, expected ${K0S_VERSION}" ;;
  esac
}

# ------------------------------------------------------------------ charts

function build_charts() {
  log "vendoring kubecube-chart ${KUBECUBE_VERSION}"
  rm -rf "${OUT}/charts/kubecube-chart"
  cp -a "${WORKSPACE}/kubecube-chart" "${OUT}/charts/kubecube-chart"
  rm -rf "${OUT}/charts/kubecube-chart/.git"

  log "packaging the third-party charts (hotplugs)"
  # Everything that runs on the target is built from a normalised copy, so a
  # Windows working tree cannot leak CRLF into the bundle. The copy stays at a
  # fixed path because the warden-init image is built from the same tree.
  rm -rf "${OUT}/.hotplugs-build"
  cp -a "${WORKSPACE}/hotplugs" "${OUT}/.hotplugs-build"
  rm -rf "${OUT}/.hotplugs-build/.git"
  normalize_lines "${OUT}/.hotplugs-build"

  if (cd "${OUT}/.hotplugs-build" && sh compress.sh > /dev/null 2>&1); then
    cp -a "${OUT}/.hotplugs-build/third-charts.tar.gz" "${OUT}/charts/"
  else
    warn "compress.sh failed; the warden-init image carries its own copy, so this is not fatal"
  fi

  log "pulling the cilium chart ${CILIUM_VERSION}"
  rm -rf "${OUT}/charts/cilium" /tmp/cilium-chart
  mkdir -p /tmp/cilium-chart
  # The project's Helm repository is the first choice; the OCI artifact on
  # quay.io is the fallback. quay answers 401 to an anonymous manifest HEAD even
  # for its public repositories, so OCI cannot be the path an offline build
  # depends on.
  if ! helm repo add cilium https://helm.cilium.io/ --force-update > /dev/null 2>&1 \
    || ! helm pull cilium/cilium --version "${CILIUM_VERSION}" -d /tmp/cilium-chart > /dev/null 2>&1; then
    warn "the helm repository did not answer; falling back to the OCI artifact"
    helm pull oci://quay.io/cilium-charts/cilium --version "${CILIUM_VERSION}" -d /tmp/cilium-chart
  fi
  tar -xzf /tmp/cilium-chart/cilium-"${CILIUM_VERSION}".tgz -C "${OUT}/charts"
  [ -f "${OUT}/charts/cilium/Chart.yaml" ] || die "the cilium chart did not unpack"
  log "cilium chart: $(helm show chart "${OUT}/charts/cilium" | awk '/^version:/ {print $2}')"

  cilium_values_write
}

# cilium_values_write records the values the install will use, inside the bundle.
#
# The bundle and the install have to agree on these, because they decide which
# images the chart asks for: an image the bundle did not stage is an install
# that never starts a pod. One file in the bundle is what keeps them in step,
# and the installer layers only the node address on top of it.
#
# image.useDigest=false is deliberate, and it is needed for every image the
# chart can pin that way. Cilium 1.16 pins its images by digest by default, and
# a docker archive does not carry the registry's manifest digest: containerd
# recomputes it on import, so a reference of the form "tag@sha256:..." matches
# nothing and the pod sits in ImagePullBackOff on a machine with no network.
# The agent and the operator were the obvious two; cilium-envoy has its own
# switch, and leaving it on is what broke the first successful install.
function cilium_values_write() {
  cat > "${OUT}/charts/cilium-values.yaml" << EOF
# Written by build-offline-bundle.sh for cilium ${CILIUM_VERSION}.
kubeProxyReplacement: ${CILIUM_KUBE_PROXY_REPLACEMENT}
ipam:
  mode: kubernetes
image:
  useDigest: false
operator:
  replicas: 1
  image:
    useDigest: false
envoy:
  image:
    useDigest: false
hubble:
  enabled: false
EOF
}

# cilium_images renders the chart with the values the installer will use and
# reports the images it references. Rendering beats a hardcoded list: the chart
# decides which images it needs, so a version bump that adds one — 1.16 added
# cilium-envoy — is picked up here instead of failing at install time.
function cilium_images() {
  # The chart writes its images both quoted and unquoted depending on the
  # template, so match either and strip the quotes afterwards.
  #
  # The digest is stripped as well. Cilium's chart renders its envoy image as
  # "tag@sha256:...", and docker pull on a reference that carries a digest
  # leaves the image untagged however clear the tag in it is. An untagged image
  # survives docker save but not containerd's importer, which skips it — and the
  # cilium-envoy DaemonSet then sits in ImagePullBackOff on a machine with no
  # network to fall back on. Pulling by tag keeps the tag, and the content digest
  # is the same either way, so the chart's digest reference still resolves.
  helm template cilium "${OUT}/charts/cilium" --namespace kube-system \
    --values "${OUT}/charts/cilium-values.yaml" \
    | grep -oE 'image: "?[^"[:space:]]+"?' \
    | sed -E 's/image: "?([^"]+)"?/\1/' \
    | sed -E 's/@sha256:.*$//' \
    | sort -u
}

function build_cilium_images() {
  local images
  images=$(cilium_images)
  [ -n "${images}" ] || die "could not work out which images cilium needs"

  local image
  for image in ${images}; do
    log "pulling cilium image ${image}"
    docker pull --platform "linux/${ARCH}" "${image}" > /dev/null
  done
}

# ------------------------------------------------------------- platform

# go_build compiles one of the Go components statically.
#
# CGO_ENABLED=0 is not an optimisation: the images are alpine, and a binary
# linked against glibc fails there with "required file not found" before it
# prints a single line.
function go_build() {
  local dir=$1
  shift
  log "building $(basename "${dir}")"
  (cd "${dir}" && GO111MODULE=on GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" GOFLAGS=-mod=mod \
    CGO_ENABLED=0 go build "$@")
}

# thin_image writes a Dockerfile that is only a binary and an entry point.
#
# ENTRYPOINT, never CMD: the chart passes the component's flags as container
# args, and args only reach an entry point. With a CMD the flags are taken for
# the executable and the container dies with
#   exec: "-log-file=/etc/logs/cube.log": no such file or directory
function thin_image() {
  local name=$1
  local binary=$2
  local context=$3

  cat > "${context}/Dockerfile.bundle" << EOF
FROM alpine:3.18
COPY ${binary} /
ENTRYPOINT ["/${binary}"]
EOF
  docker build -q -t "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/${name}:${IMAGE_TAG}" -f "${context}/Dockerfile.bundle" "${context}" > /dev/null
}

function build_platform_images() {
  log "building the platform images (tag ${IMAGE_TAG})"

  # alpine is the base of every thin image; pull it once, by a name that works
  # from this network.
  docker pull docker.1ms.run/library/alpine:3.18 > /dev/null
  docker tag docker.1ms.run/library/alpine:3.18 alpine:3.18

  go_build "${WORKSPACE}/KubeCube" -o cube ./cmd/cube
  go_build "${WORKSPACE}/KubeCube" -o warden ./cmd/warden
  # The image is named "kubecube", not "cube", because that is what the chart
  # composes from hub.project + images.kubecube and what the upstream image is
  # called. The binary inside stays "cube".
  thin_image kubecube cube "${WORKSPACE}/KubeCube"
  thin_image warden warden "${WORKSPACE}/KubeCube"

  go_build "${WORKSPACE}/kubecube-audit" -o audit .
  thin_image audit audit "${WORKSPACE}/kubecube-audit"

  go_build "${WORKSPACE}/kubecube-webconsole" -o webconsole .
  thin_image webconsole webconsole "${WORKSPACE}/kubecube-webconsole"

  build_warden_init_image
  build_cfssl_image
  build_kubectl_image

  log "retagging the local path provisioner"
  pull_with_fallback "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/rancher-local-path-provisioner:${IMAGE_TAG}" \
    "docker.1ms.run/rancher/local-path-provisioner:${LOCAL_PATH_VERSION}" \
    "hub.rat.dev/rancher/local-path-provisioner:${LOCAL_PATH_VERSION}" \
    "docker.m.daocloud.io/rancher/local-path-provisioner:${LOCAL_PATH_VERSION}"
}

# build_warden_init_image packages the third-party charts.
#
# The context is the normalised hotplugs copy build_charts prepared. The image
# runs install_hotplug.sh through /bin/sh, and a CRLF script fails there with
# "not found" on its second line.
function build_warden_init_image() {
  log "building warden-init"
  local ctx="${OUT}/.hotplugs-build"
  if [ ! -f "${ctx}/Dockerfile" ]; then
    die "the hotplugs build copy is missing at ${ctx}; build_charts should have made it"
  fi
  docker build -q -t "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/warden-init:${IMAGE_TAG}" "${ctx}" > /dev/null
}

# build_cfssl_image is the pre-install job's certificate image. The job runs
# `bash` and `openssl`, so the image carries both.
function build_cfssl_image() {
  log "building cfssl"
  local ctx
  ctx=$(mktemp -d)
  GOBIN="${ctx}" GO111MODULE=on GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" CGO_ENABLED=0 \
    go install "github.com/cloudflare/cfssl/cmd/cfssl@${CFSSL_VERSION}"
  GOBIN="${ctx}" GO111MODULE=on GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" CGO_ENABLED=0 \
    go install "github.com/cloudflare/cfssl/cmd/cfssljson@${CFSSL_VERSION}"

  cat > "${ctx}/Dockerfile.bundle" << 'EOF'
FROM alpine:3.18
RUN apk add --no-cache bash openssl
COPY cfssl cfssljson /usr/local/bin/
EOF
  docker build -q -t "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/cfssl:${IMAGE_TAG}" -f "${ctx}/Dockerfile.bundle" "${ctx}" > /dev/null
  rm -rf "${ctx}"
}

# build_kubectl_image is the image the chart's post-install job uses to apply the
# warden webhook configuration.
function build_kubectl_image() {
  log "building the kubectl image"
  local ctx
  ctx=$(mktemp -d)

  # Reuse the binary the bundle already carries. Fetching it twice cost twenty
  # minutes on a network where dl.k8s.io serves at about 40KB/s, and the second
  # copy would be byte for byte the first.
  if [ -x "${OUT}/bin/kubectl" ]; then
    cp -a "${OUT}/bin/kubectl" "${ctx}/kubectl"
  else
    fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o "${ctx}/kubectl"
    chmod 0755 "${ctx}/kubectl"
  fi

  cat > "${ctx}/Dockerfile.bundle" << 'EOF'
FROM alpine:3.18
RUN apk add --no-cache bash
COPY kubectl /usr/local/bin/kubectl
EOF
  docker build -q -t "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/bitnami-kubectl:${IMAGE_TAG}" -f "${ctx}/Dockerfile.bundle" "${ctx}" > /dev/null
  rm -rf "${ctx}"
}

# --------------------------------------------------- k0s component images

# k0s_component_images lists the images k0s itself pulls for this configuration.
#
# The list lives in images/k0s/<version>/, beside the CNI-specific files, so it
# is reviewable and versioned with the installer rather than buried in this
# script. Two things are applied on top of the file:
#
#   * ${K0S_VERSION} is expanded, so the file does not pin a patch twice
#   * kube-proxy is dropped when Cilium replaces it: k0s is told not to run
#     kube-proxy at all, and shipping its image would only bloat the bundle
#
# Cilium has no list here on purpose: its images are whatever the chart renders,
# and cilium_images() reads them from the chart.
function k0s_component_images() {
  local dir="${INSTALLER_DIR}/images/k0s/v${K0S_VERSION}"
  [ -f "${dir}/images.list" ] || die "no image list at ${dir}/images.list"

  local files=("${dir}/images.list")
  case "${CNI}" in
    calico)
      [ -f "${dir}/images-cni-calico.list" ] && files+=("${dir}/images-cni-calico.list")
      ;;
    kuberouter)
      [ -f "${dir}/images-cni-kuberouter.list" ] && files+=("${dir}/images-cni-kuberouter.list")
      ;;
  esac

  local lines
  # s/\r$// is not cosmetic: an images.list from a Windows checkout ends every
  # line with CR, which ends up inside the image reference and makes docker pull
  # fail on a name nobody can see.
  lines=$(cat "${files[@]}" \
    | sed -e 's/#.*$//' -e 's/\r$//' -e '/^[[:space:]]*$/d' -e "s/\\\${K0S_VERSION}/${K0S_VERSION}/")

  if [ "${CILIUM_KUBE_PROXY_REPLACEMENT}" = "true" ]; then
    lines=$(echo "${lines}" | grep -v -E '^quay\.io/k0sproject/kube-proxy:' || true)
  fi

  printf '%s\n' "${lines}"
}

# pull_k0s_component tries the upstream name and, for registry.k8s.io images,
# the aliyun mirror that carries the same images on this network.
function pull_k0s_component() {
  local image=$1
  local mirror=""

  case "${image}" in
    registry.k8s.io/*)
      # registry.cn-hangzhou.aliyuncs.com/google_containers mirrors
      # registry.k8s.io under a flat name.
      local flat
      flat=$(echo "${image}" | sed -e 's#registry.k8s.io/##' -e 's#.*/##')
      mirror="registry.cn-hangzhou.aliyuncs.com/google_containers/${flat}"
      ;;
  esac

  if [ -n "${mirror}" ]; then
    pull_with_fallback "${image}" "${mirror}" "${image}"
  else
    pull_with_fallback "${image}" "${image}"
  fi
}

function build_k0s_component_images() {
  log "pulling the k0s component images (cni: ${CNI})"
  local image
  while read -r image; do
    [ -n "${image}" ] || continue
    log "pulling ${image}"
    pull_k0s_component "${image}"
  done < <(k0s_component_images)

  # The sandbox image, under the name the kubelet asks for. k0s composes the
  # reference itself, so overriding it in the config produces "pause:3.8:3.8";
  # importing it under its own name is the way that works.
  log "preparing registry.k8s.io/pause:3.8"
  pull_with_fallback "registry.k8s.io/pause:3.8" \
    "registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.8"
}

# ------------------------------------------------------------- save images

# save_archive exports images and rewrites the archive into the classic docker
# format.
#
# Docker 29 writes an archive that carries both a docker manifest.json and an
# OCI layout. The OCI index names every platform's manifest while the archive
# only carries the pulled platform's blobs, so containerd's importer follows the
# OCI side and fails with "content digest sha256:...: not found" on an archive
# whose docker side is complete. k0s imports these archives on the target, so
# the difference is a failed install.
function save_archive() {
  local out=$1
  shift
  local raw="${out}.raw"
  docker save -o "${raw}" "$@"
  python3 "${INSTALLER_DIR}/normalize-image-tar.py" "${raw}" "${out}"
  rm -f "${raw}"
}

function save_images() {
  log "saving the images into ${OUT}/images"

  local platform_images=(
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/kubecube:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/warden:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/warden-init:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/audit:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/webconsole:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/cfssl:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/bitnami-kubectl:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/rancher-local-path-provisioner:${IMAGE_TAG}"
  )

  local k0s_images=()
  local image
  while read -r image; do
    [ -n "${image}" ] || continue
    k0s_images+=("${image}")
  done < <(k0s_component_images)
  k0s_images+=("registry.k8s.io/pause:3.8")

  local cilium_image_list=()
  while read -r image; do
    [ -n "${image}" ] || continue
    cilium_image_list+=("${image}")
  done < <(cilium_images)

  save_archive "${OUT}/images/platform.tar" "${platform_images[@]}"
  save_archive "${OUT}/images/k0s-components.tar" "${k0s_images[@]}"
  save_archive "${OUT}/images/cilium.tar" "${cilium_image_list[@]}"

  log "images saved:"
  ls -la "${OUT}/images"
}

# -------------------------------------------------------------- binaries

function build_binaries() {
  log "collecting helm ${HELM_VERSION} and kubectl ${KUBECTL_VERSION}"
  local tmp
  tmp=$(mktemp -d)

  fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  install -m 0755 "${tmp}/linux-${ARCH}/helm" "${OUT}/bin/helm"

  fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o "${OUT}/bin/kubectl"
  chmod 0755 "${OUT}/bin/kubectl"

  rm -rf "${tmp}"
  "${OUT}/bin/helm" version --short
  "${OUT}/bin/kubectl" version --client=true --output=yaml 2> /dev/null | grep -m1 gitVersion || true
}

# ----------------------------------------------------------- bundle files

function write_bundle_files() {
  log "writing bundle.env, install.conf and bundle.manifest"

  cat > "${OUT}/bundle.env" << EOF
# Written by build-offline-bundle.sh. Sourced by the installer scripts.
KUBECUBE_IMAGE_TAG=${IMAGE_TAG}
KUBECUBE_IMAGE_REGISTRY=${IMAGE_REGISTRY}
KUBECUBE_IMAGE_PROJECT=${IMAGE_PROJECT}
KUBECUBE_VERSION=${KUBECUBE_VERSION}
K0S_VERSION=${K0S_VERSION}
CILIUM_VERSION=${CILIUM_VERSION}
CNI=${CNI}
ARCH=${ARCH}
BUILT_AT=$(date -Iseconds)
EOF

  # The bundle's install.conf is the repository's, plus the assignments that
  # describe this bundle. Appending works because bash lets the last assignment
  # win, so the file stays readable next to the original.
  cp -a "${INSTALLER_DIR}/install.conf" "${OUT}/manifests/install.conf"
  cat >> "${OUT}/manifests/install.conf" << EOF

#######################################################################
# written by build-offline-bundle.sh -- these win over the values above
#######################################################################
OFFLINE="true"
OFFLINE_BUNDLE_DIR="${OUT}"
KUBERNETES_DISTRO="k0s"
CNI="${CNI}"
KUBECUBE_IMAGE_TAG="${IMAGE_TAG}"
KUBECUBE_IMAGE_REGISTRY="${IMAGE_REGISTRY}"
KUBECUBE_IMAGE_PROJECT="${IMAGE_PROJECT}"
# the arm64 bundle cannot build these two yet; see install.conf
CLOUDSHELL_ENABLE="false"
FRONTEND_ENABLE="false"

# The bundle carries no arm64 ingress-controller image, so the chart must not
# install its subchart: it would sit in ImagePullBackOff and take the whole
# helm release down with it. Ingress is a separate concern an operator turns
# back on where they can get the image.
INGRESS_CONTROLLER_ENABLE="false"
EOF
  cp -a "${OUT}/manifests/install.conf" "${OUT}/install.conf"

  # checksums over everything that is not the manifest itself
  (cd "${OUT}" && find . -type f ! -name bundle.manifest -printf '%P\n' \
    | sort \
    | xargs -I{} sha256sum {} > bundle.manifest)
  log "bundle.manifest: $(wc -l < "${OUT}/bundle.manifest") files"
}

# ------------------------------------------------------------------- main

function Main() {
  preflight

  rm -rf "${OUT}"
  mkdir -p "${OUT}"/{manifests,charts,k0s,images,bin}

  # the installer scripts travel in the bundle: the target machine has no copy
  for f in entry.sh install.sh install_k8s.sh install_k0s.sh install_kubecube.sh utils.sh cleanup.sh; do
    if [ -f "${INSTALLER_DIR}/${f}" ]; then
      cp -a "${INSTALLER_DIR}/${f}" "${OUT}/manifests/"
    else
      warn "${f} is missing from ${INSTALLER_DIR}"
    fi
  done

  # entry.sh also belongs at the bundle root: that path is the one command the
  # operator runs, and it is what finds bundle.env next to itself.
  if [ -f "${INSTALLER_DIR}/entry.sh" ]; then
    cp -a "${INSTALLER_DIR}/entry.sh" "${OUT}/entry.sh"
  else
    die "entry.sh is missing from ${INSTALLER_DIR}"
  fi

  build_k0s
  build_charts
  build_binaries
  build_platform_images
  build_cilium_images
  build_k0s_component_images
  save_images
  # the normalised hotplugs copy is a build input, not part of the bundle
  rm -rf "${OUT}/.hotplugs-build"
  write_bundle_files

  log "bundle ready: ${OUT}"
  log "size: $(du -sh "${OUT}" | awk '{print $1}')"
  cat << EOF

Install it on a blank machine with:

  bash ${OUT}/entry.sh

EOF
}

Main
