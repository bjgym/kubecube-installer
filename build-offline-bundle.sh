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
# The frontend image's two bases. Its Dockerfile pins them too; these are what the
# builder pulls from a mirror this network can reach before building it.
NODE_VERSION=${NODE_VERSION:-12.18.0}
NGINX_VERSION=${NGINX_VERSION:-1.27}
# Flipped to true by build_frontend_image when it actually builds that image, and
# written into the bundle's install.conf. A bundle whose workspace has no
# kubecube-front is still a valid bundle, with the feature off.
FRONTEND_ENABLE=${FRONTEND_ENABLE:-false}

INSTALLER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Sourced through sed rather than directly. A Windows checkout hands this file
# over with CRLF, and bash then reports every line as "$'\r': command not
# found"; the build host may be either kind of checkout, so read the values
# without depending on which one it is.
# shellcheck source=/dev/null
source <(sed 's/\r$//' "${INSTALLER_DIR}/install.conf")

# The repository's install.conf is the default. These two can still be chosen
# per bundle from the environment, which is how one build host produces both a
# k0s bundle and a kubeadm bundle without editing the repository between runs.
# They are read after the file is sourced, so the environment wins over it.
KUBERNETES_DISTRO=${BUNDLE_DISTRO:-${KUBERNETES_DISTRO}}
KUBERNETES_VERSION=${BUNDLE_KUBERNETES_VERSION:-${KUBERNETES_VERSION}}

# The kubeadm path installs calico and only calico: it applies
# manifests/cni/<cni>/v<version>, and the offline package fetches the calico
# manifest. Deciding it here rather than in one of the files written below keeps
# bundle.env and install.conf from disagreeing about which CNI the bundle is for.
if [ "${KUBERNETES_DISTRO}" = "kubeadm" ]; then
  CNI="calico"
fi

# The image repository the kubeadm path tells kubeadm to use. install_k8s.sh
# picks it from ZONE and writes it into the kubeadm config as imageRepository, so
# the bundle has to carry the images under that same name or the install pulls
# from a registry an offline machine cannot reach. Keep the two in step.
if [ "${ZONE}" = "cn" ]; then
  KUBEADM_IMAGE_REPOSITORY="registry.cn-hangzhou.aliyuncs.com/google_containers"
else
  KUBEADM_IMAGE_REPOSITORY="k8s.gcr.io"
fi

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
    -o -name '*.tpl' -o -name '*.conf' -o -name '*.list' -o -name '*.json' -o -name '*.md' \) -print0)
  if [ "${n}" -gt 0 ]; then
    log "normalized line endings in ${n} file(s) under ${dir}"
  fi
}

# --------------------------------------------------------------- preflight

function preflight() {
  # What the build needs depends on which build it is. A minimal build produces the
  # distribution's own artefacts and skips build_k0s, build_charts and save_images, so
  # go, helm and docker are never invoked and the component sources are never read.
  # Requiring them anyway made minimal mode unreachable on the one kind of host it
  # exists for - a build host without the component sources.
  local tools="curl sha256sum python3"
  local dirs=""
  if [ "${BUNDLE_MINIMAL}" = "true" ]; then
    log "minimal build: go, helm, docker and the component sources are not required"
  else
    tools="${tools} docker go helm"
    dirs="KubeCube kubecube-audit kubecube-webconsole kubecube-chart hotplugs"
  fi

  local missing=()
  for cmd in ${tools}; do
    command -v "${cmd}" > /dev/null || missing+=("${cmd}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing tools: ${missing[*]}"
  fi

  for dir in ${dirs}; do
    [ -d "${WORKSPACE}/${dir}" ] || die "${WORKSPACE}/${dir} is missing"
  done

  log "workspace   : ${WORKSPACE}"
  log "bundle      : ${OUT}"
  log "arch        : ${ARCH}"
  log "image tag   : ${IMAGE_TAG}"
  if [ "${BUNDLE_MINIMAL}" = "true" ]; then
    log "mode        : minimal, distribution artefacts only"
  else
    log "k0s         : ${K0S_VERSION} (${K0S_IMAGE})"
    log "cilium      : ${CILIUM_VERSION}"
  fi
}

# fetch downloads a URL, treating a stalled connection as a failure.
#
# --speed-limit/--speed-time matter here: dl.k8s.io serves at roughly 40KB/s on
# some networks, and without a floor a connection that stops moving leaves the
# build hanging with no output instead of failing.
function fetch() {
  # Two things this network taught this function.
  #
  # A single connection to the Kubernetes release bucket runs at tens of KB/s,
  # while the same host over eight connections runs at several MB/s: the
  # bottleneck is the connection, not the server. aria2c is used when it is
  # installed, and curl remains the fallback.
  #
  # And a file that is already there is not fetched again, so a build that was
  # interrupted resumes instead of starting its downloads from zero. That matters
  # most for the three kubeadm binaries, which are the largest things fetched
  # here.
  local out="" url="" a
  while [ $# -gt 0 ]; do
    a="$1"
    shift
    case "${a}" in
      -o)
        out="$1"
        shift
        ;;
      -L | -s | -S | -f) ;;
      *) url="${a}" ;;
    esac
  done

  if [ -n "${out}" ] && [ -s "${out}" ]; then
    log "have $(basename "${out}"), not fetching it again"
    return 0
  fi

  if command -v aria2c > /dev/null 2>&1; then
    # aria2c's -o is relative to --dir and it drops a leading slash, so an
    # absolute destination has to be split into the two arguments it understands.
    # Passing -o /tmp/x/helm.tgz made aria2 write to $PWD/tmp/x/helm.tgz, and the
    # tar that follows failed on a file that was never where it was asked for.
    if [ -n "${out}" ]; then
      aria2c -x8 -s8 -k1M --file-allocation=none --summary-interval=0 \
        --allow-overwrite=true --retry-wait=5 -m 5 \
        --dir "$(dirname "${out}")" -o "$(basename "${out}")" "${url}"
    else
      aria2c -x8 -s8 -k1M --file-allocation=none --summary-interval=0 \
        --allow-overwrite=true --retry-wait=5 -m 5 "${url}"
    fi
    return $?
  fi

  curl -sSLf --retry 5 --retry-delay 5 --retry-all-errors --speed-limit 1024 --speed-time 60 \
    ${out:+-o "${out}"} "${url}"
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
  # The chart travels as it is written, and a Windows checkout hands it over
  # with CRLF. YAML survives that; a template that emits a value into a base64
  # field does not — the carriage return lands inside the base64 — so the chart
  # is normalised like everything else that runs on the target.
  normalize_lines "${OUT}/charts/kubecube-chart"

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
  build_cloudshell_image
  build_frontend_image

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

# build_cloudshell_image builds the terminal image the CloudShell feature runs.
#
# Two stages, because the repository builds it that way: cloudshell/base/Dockerfile
# produces the base, and cloudshell/<arch>/Dockerfile takes it as BASE_IMG and
# adds the kubectl the chroot copies. Both are built here rather than pulled — the
# tag the arch Dockerfiles default to is local on purpose, and the base the
# project used to publish sits on a registry that no longer answers, built from an
# Ubuntu release whose archive is gone.
#
# The kubectl download inside the second stage is the slow part: dl.k8s.io serves
# at roughly 40KB/s on this network, and the image wants its own copy for the
# chroot rather than the one in ${OUT}/bin, which is a different architecture's
# file in a cross build.
function build_cloudshell_image() {
  log "building the cloudshell image (base + ${ARCH})"

  local base_tag="kubecube/cloudshell-base:24.04"
  local ctx="${WORKSPACE}/kubecube-webconsole/cloudshell"

  [ -f "${ctx}/base/Dockerfile" ] || die "no cloudshell base Dockerfile at ${ctx}/base/Dockerfile"
  [ -f "${ctx}/${ARCH}/Dockerfile" ] || die "no cloudshell Dockerfile for ${ARCH}"

  docker build -q -t "${base_tag}" -f "${ctx}/base/Dockerfile" "${ctx}" > /dev/null \
    || die "could not build the cloudshell base image"

  docker build -q -t "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/cloudshell:${IMAGE_TAG}" \
    --build-arg "BASE_IMG=${base_tag}" \
    -f "${ctx}/${ARCH}/Dockerfile" "${ctx}" > /dev/null \
    || die "could not build the cloudshell image for ${ARCH}"
}

# build_frontend_image builds the web UI image: a node stage that produces static
# files, then nginx serving them. It is architecture-independent by construction —
# the output is a directory of files, and only nginx has to match the node — but
# the build itself is not, and two things about it are not obvious from the
# Dockerfile:
#
#   * the builder stage is pinned with --platform=$BUILDPLATFORM so that a buildx
#     release on an amd64 host does not emulate node. That pin needs the variable
#     to be declared as a Dockerfile-level ARG to resolve at all; without the
#     declaration it is empty and the build dies before its first layer with
#     `failed to parse platform : "" is an invalid OS component`. buildx fills it
#     in by itself, the plain builder does not, so it is passed here.
#
#   * node-sass v4.14.1 publishes no prebuilt binding for linux/arm64, so npm
#     compiles it from source there: about four minutes of g++ in node:12.18.0 on
#     a four-core VM, before webpack starts. This step is slow, and that is the
#     reason rather than a hang.
#
# The source has to be in the workspace. Without it this skips, warns, and leaves
# the feature off, so a bundle built from a workspace that has no kubecube-front
# is still a bundle.
function build_frontend_image() {
  local ctx="${WORKSPACE}/kubecube-front"

  if [ ! -f "${ctx}/Dockerfile" ]; then
    warn "no ${ctx}/Dockerfile: skipping the frontend image, FRONTEND_ENABLE stays false"
    return 0
  fi

  log "building the frontend image (node ${NODE_VERSION}, nginx ${NGINX_VERSION}, ${ARCH})"

  # docker.io is not reachable from this network; the mirror is, so both bases are
  # pulled from it and then tagged under the names the Dockerfile asks for.
  docker pull "docker.1ms.run/library/node:${NODE_VERSION}" > /dev/null
  docker tag "docker.1ms.run/library/node:${NODE_VERSION}" "node:${NODE_VERSION}"
  docker pull "docker.1ms.run/library/nginx:${NGINX_VERSION}" > /dev/null
  docker tag "docker.1ms.run/library/nginx:${NGINX_VERSION}" "nginx:${NGINX_VERSION}"

  if docker build -t "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/frontend:${IMAGE_TAG}" \
    --build-arg "BUILDPLATFORM=linux/${ARCH}" \
    -f "${ctx}/Dockerfile" "${ctx}"; then
    FRONTEND_ENABLE="true"
  else
    warn "could not build the frontend image: FRONTEND_ENABLE stays false"
  fi
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
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/cloudshell:${IMAGE_TAG}"
    "${IMAGE_REGISTRY}/${IMAGE_PROJECT}/rancher-local-path-provisioner:${IMAGE_TAG}"
  )

  # Only when it was built: build_frontend_image leaves the flag false on a
  # workspace without the source, and saving an image that is not there fails the
  # archive.
  if [ "${FRONTEND_ENABLE}" = "true" ]; then
    platform_images+=("${IMAGE_REGISTRY}/${IMAGE_PROJECT}/frontend:${IMAGE_TAG}")
  fi

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
KUBERNETES_DISTRO="${KUBERNETES_DISTRO}"
KUBERNETES_VERSION="${KUBERNETES_VERSION}"
CNI="${CNI}"
KUBECUBE_IMAGE_TAG="${IMAGE_TAG}"
KUBECUBE_IMAGE_REGISTRY="${IMAGE_REGISTRY}"
KUBECUBE_IMAGE_PROJECT="${IMAGE_PROJECT}"

# The kubeadm path reads its distribution binary, its images and its container
# runtime from a directory of loose files rather than from the network; the two
# variables that switch it on were referenced in install_k8s.sh and defined
# nowhere, which is what made that branch dead code.
OFFLINE_INSTALL="true"
OFFLINE_PKG_PATH="${OUT}/offline"
EOF

  # A minimal bundle carries the distribution's own artefacts only: no platform
  # images and no chart. Two consequences have to be written down with it, or the
  # install walks into a wall:
  #   - the pivot cannot be installed from it (its images are not here), and
  #   - the kubeadm offline path takes its container runtime from the bundle's
  #     packages, where docker would need cri-dockerd, which no reachable source
  #     provides on this network.
  if [ "${BUNDLE_MINIMAL}" = "true" ]; then
    cat >> "${OUT}/manifests/install.conf" << EOF
INSTALL_KUBECUBE_PIVOT="false"
CONTAINER_RUNTIME="containerd"
EOF
  fi

  # The kubeadm path installs calico and only calico: it applies
  # manifests/cni/<cni>/v<version> and the offline package fetches the calico
  # manifest. Writing the repository default (cilium) into a kubeadm bundle sends
  # the install looking for a manifest the bundle does not carry.
  if [ "${KUBERNETES_DISTRO}" = "kubeadm" ]; then
    cat >> "${OUT}/manifests/install.conf" << EOF
CNI="calico"
EOF
  fi

  cat >> "${OUT}/manifests/install.conf" << EOF
# The terminal image is built by build_cloudshell_image and carried in
# platform.tar, so that feature can be on.
#
# The front end follows its own build: build_frontend_image sets FRONTEND_ENABLE
# when the source is in the workspace, and warns and leaves it false when it is
# not, so a bundle built without kubecube-front is still a valid bundle rather
# than a failed build.
CLOUDSHELL_ENABLE="true"
FRONTEND_ENABLE="${FRONTEND_ENABLE}"

# The bundle carries no arm64 ingress-controller image, so the chart must not
# install its subchart: it would sit in ImagePullBackOff and take the whole
# helm release down with it. Ingress is a separate concern an operator turns
# back on where they can get the image.
#
# The search, recorded so it is not repeated. The project's own images are amd64
# only: kubecube/ingress-nginx-controller:v1.2.0 and
# kubecube/ingress-nginx-kube-webhook-certgen:v1.1.1 both report
# "architecture": "amd64". The arm64 builds live on registry.k8s.io, whose
# backing host is unreachable from this network — a pull resolves to
# *.pkg.dev and times out, even though /v2/ on registry.k8s.io answers. And none
# of the mirrors this host can reach carries the image; every reference below was
# tried and answers "does not exist":
#
#   registry.cn-hangzhou.aliyuncs.com/google_containers/ingress-nginx-controller
#   registry.cn-hangzhou.aliyuncs.com/google_containers/ingress-nginx-kube-webhook-certgen
#   docker.1ms.run/kubernetes-ingress-controller/ingress-nginx-controller
#   hub.rat.dev/kubernetes-ingress-controller/ingress-nginx-controller
#   quay.io/kubernetes-ingress-controller/ingress-nginx-controller
#
# What unblocks it: publish those two images as multi-arch in the project's own
# registry, or run the controller on an amd64 node.
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

# ------------------------------------------------- kubeadm offline package

# build_kubeadm_offline writes the directory install_k8s.sh reads when
# OFFLINE_INSTALL is true.
#
# Every name below is that script's contract: it moves or untars each one by
# name. That path had never been reachable — OFFLINE_INSTALL and OFFLINE_PKG_PATH
# are referenced in install_k8s.sh and defined nowhere — so the names had never
# been exercised by anything.
#
# Only sources that answer on this network are used: dl.k8s.io for the binaries,
# the Ubuntu archive for the CNI plugins and the container runtime (GitHub, the
# distribution host and registry.k8s.io do not), and the calico project's docs
# host for the CNI manifest.
function build_kubeadm_offline() {
  local dir="${OUT}/offline"
  local release="v${KUBERNETES_VERSION}"
  local cni_version="v0.8.2"
  local tmp
  tmp=$(mktemp -d)

  # Deliberately not cleaned first: fetch skips files that are already there, so
  # an interrupted build picks up where it stopped instead of re-downloading the
  # three binaries, which are the largest things this function fetches.
  mkdir -p "${dir}"

  log "kubeadm offline package for kubernetes ${KUBERNETES_VERSION} (${ARCH})"

  # 1. the three binaries, each checked against the checksum the release bucket
  # publishes beside it.
  #
  # The check is not decoration: these are the largest downloads here, a fetch
  # that fails leaves a truncated file behind, and a truncated kubelet produces a
  # bundle that installs a cluster that will not come up — a failure that would
  # otherwise only appear at the far end of an acceptance run. The .sha256 files
  # hold the bare hash with no filename, so sha256sum -c cannot read them; the two
  # hashes are compared directly.
  local b want got
  for b in kubeadm kubelet kubectl; do
    fetch "https://dl.k8s.io/release/${release}/bin/linux/${ARCH}/${b}" -o "${dir}/${b}" \
      || die "could not fetch ${b}"
    # curl rather than fetch: this one has to arrive on stdout, and fetch without
    # an output file hands the download to aria2, which writes a file named after
    # the URL instead of printing it.
    want=$(curl -sSLf "https://dl.k8s.io/release/${release}/bin/linux/${ARCH}/${b}.sha256" \
      | tr -d '[:space:]' | cut -c1-64)
    got=$(sha256sum "${dir}/${b}" | cut -d' ' -f1)
    if [ -z "${want}" ] || [ "${want}" != "${got}" ]; then
      # Removed before failing: fetch skips a file that is already there, so
      # leaving a truncated one behind would make every later run reuse it and
      # fail the same way, with no way back except deleting it by hand.
      rm -f "${dir}/${b}" "${dir}/${b}.aria2"
      die "${b} does not match its published checksum (want ${want:-none}, got ${got})"
    fi
    log "${b} verified: ${got}"
    chmod 0755 "${dir}/${b}"
  done

  # 2. the kubelet units. Their usual source is raw.githubusercontent, which is
  # blocked here, so the repository carries them.
  cp -a "${INSTALLER_DIR}/kubeadm/kubelet.service" "${dir}/kubelet.service"
  cp -a "${INSTALLER_DIR}/kubeadm/10-kubeadm.conf" "${dir}/10-kubeadm.conf"

  # 3. the CNI plugins, out of the Ubuntu package that carries them: GitHub,
  # where they are normally published, is not reachable.
  (cd "${tmp}" && apt-get download containernetworking-plugins > /dev/null 2>&1) \
    || die "could not download containernetworking-plugins, the only reachable source of the CNI plugins"
  dpkg-deb -x "${tmp}"/containernetworking-plugins_*.deb "${tmp}/cni"

  # Ubuntu 24.04 ships these under /usr/lib/cni and older releases shipped them
  # under /opt/cni/bin, so take whichever this release has rather than assuming
  # one: assuming /opt/cni/bin is what failed this step on every attempt. The
  # tarball lays them out flat either way, because install_k8s.sh extracts it
  # into /opt/cni/bin on the target.
  local cni_bin=""
  local candidate
  for candidate in "${tmp}/cni/opt/cni/bin" "${tmp}/cni/usr/lib/cni"; do
    if [ -d "${candidate}" ]; then
      cni_bin="${candidate}"
      break
    fi
  done
  [ -n "${cni_bin}" ] || die "the CNI plugin package carried no CNI plugin directory"
  log "CNI plugins from ${cni_bin#"${tmp}/cni"}"
  tar -czf "${dir}/cni-plugins-linux-${ARCH}-${cni_version}.tgz" -C "${cni_bin}" .
  rm -rf "${tmp}/cni"

  # 3b. crictl, which kubeadm's preflight refuses to run without: "crictl not
  # found in system path" is a fatal error, not a warning. It is published on
  # GitHub releases, which is blocked here, so the mirrors that carry GitHub
  # content are tried. The version follows the Kubernetes minor version because
  # install_k8s.sh derives it the same way — crictl up to 1.25 speaks CRI
  # v1alpha2, containerd 2.x serves only v1, and the older client makes a working
  # runtime look broken.
  local crictl_version="v1.17.0"
  if [ "$(echo "${KUBERNETES_VERSION}" | cut -d. -f2)" -ge 22 ]; then
    crictl_version="v1.$(echo "${KUBERNETES_VERSION}" | cut -d. -f2).0"
  fi
  local crictl_tar="${dir}/crictl-${crictl_version}-linux-${ARCH}.tar.gz"
  if [ -s "${crictl_tar}" ]; then
    log "have crictl ${crictl_version}, not fetching it again"
  else
    local crictl_src
    for crictl_src in \
      "https://ghfast.top/https://github.com/kubernetes-sigs/cri-tools/releases/download/${crictl_version}" \
      "https://gh-proxy.com/https://github.com/kubernetes-sigs/cri-tools/releases/download/${crictl_version}"; do
      if curl -sSLf -m 300 -o "${crictl_tar}" "${crictl_src}/crictl-${crictl_version}-linux-${ARCH}.tar.gz"; then
        log "crictl ${crictl_version} from ${crictl_src%%/https*}"
        break
      fi
      warn "${crictl_src} did not work"
    done
  fi
  # A truncated download installs a crictl that kubeadm then fails to run, so
  # check the archive really carries the binary.
  tar -tzf "${crictl_tar}" 2> /dev/null | grep -qx crictl \
    || die "crictl-${crictl_version}-linux-${ARCH}.tar.gz does not contain crictl"

  # 4. the container runtime, as packages rather than the tarball the online path
  # downloads from the distribution host, plus the two tools kubeadm's preflight
  # insists on.
  #
  # Every package is named and fetched with "apt-get download" rather than
  # "install --download-only": the latter resolves dependencies against what the
  # build host already has, and a host with docker already has containerd and
  # runc, so it downloaded neither — the bundle shipped without runc and dpkg on
  # the target refused to configure containerd at all. conntrack is here because
  # kubeadm refuses to run without the binary, and libnetfilter-conntrack3 is its
  # library, which the same reasoning would otherwise leave behind.
  (cd "${dir}" && apt-get download containerd runc conntrack libnetfilter-conntrack3 > /dev/null 2>&1) \
    || die "could not download the runtime and conntrack packages"
  local pkg
  for pkg in containerd runc conntrack libnetfilter-conntrack3; do
    ls "${dir}"/"${pkg}"_*.deb > /dev/null 2>&1 || die "no ${pkg} package landed in ${dir}"
  done

  # 5. the CNI manifest, and a check that the images it names are the ones this
  # bundle carries. install_k8s.sh applies manifests/cni/<cni>/v<version>, so it
  # has to live in the bundle's manifests tree.
  #
  # The calico version comes from images.list rather than from "latest". Two
  # things make "latest" wrong here: docs.tigera.io redirects to
  # raw.githubusercontent, which is blocked on this network, and its latest is a
  # different calico release from the images this bundle stages, so the
  # cross-check below would fail on the mismatch it exists to catch. The mirrors
  # are tried in turn; the first two are reachable where GitHub is not.
  local calico_version
  calico_version=$(grep -oE 'calico/node:v[0-9.]+' "${INSTALLER_DIR}/images/k8s/v${KUBERNETES_VERSION}/images.list" \
    | head -1 | sed 's#.*:##')
  [ -n "${calico_version}" ] || die "images/k8s/v${KUBERNETES_VERSION}/images.list names no calico/node image to take a version from"
  log "calico manifest for ${calico_version}"

  local calico_manifest="${dir}/calico.yaml"
  local calico_src
  for calico_src in \
    "https://gitee.com/mirrors/calico/raw/${calico_version}/manifests/calico.yaml" \
    "https://gh-proxy.com/https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml" \
    "https://ghfast.top/https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/calico.yaml"; do
    # curl rather than fetch: fetch hands the download to aria2, which reported
    # zero bytes on the redirecting URL and left an empty file behind.
    if curl -sSLf -m 120 -o "${calico_manifest}" "${calico_src}"; then
      log "calico manifest from ${calico_src%%/manifests*}"
      break
    fi
    warn "${calico_src} did not work"
  done
  [ -s "${calico_manifest}" ] || die "could not fetch the calico manifest for ${calico_version}"

  mkdir -p "${OUT}/manifests/cni/calico/${release}"
  cp -a "${calico_manifest}" "${OUT}/manifests/cni/calico/${release}/calico.yaml"

  # 6. the images: the control-plane set comes from kubeadm itself, the CNI images
  # from images.list, and the manifest above has to agree with the second.
  #
  # Asking kubeadm rather than reading a hand-written list is what keeps this
  # right: "kubeadm config images list" prints exactly what "kubeadm init" will
  # pull, tags included. A hand-written list is correct until a patch release
  # moves a tag — 1.28.15 wants etcd 3.5.15-0, not the 3.5.9-0 the file used to
  # name — and the failure then lands on an offline machine as an ImagePull error
  # from a registry it cannot reach.
  local images=()
  local image
  while read -r image; do
    [ -n "${image}" ] || continue
    images+=("${image}")
  done < <("${dir}/kubeadm" config images list --kubernetes-version "v${KUBERNETES_VERSION}" \
    --image-repository "${KUBEADM_IMAGE_REPOSITORY}" 2> /dev/null)
  [ ${#images[@]} -gt 0 ] || die "kubeadm config images list named no images"

  # the CNI images, which kubeadm knows nothing about
  while read -r image; do
    [ -n "${image}" ] || continue
    images+=("${image}")
  done < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "${INSTALLER_DIR}/images/k8s/v${KUBERNETES_VERSION}/images.list" \
    | grep '^docker\.io/calico/')
  [ ${#images[@]} -gt 0 ] || die "images/k8s/v${KUBERNETES_VERSION}/images.list names no calico images"

  local from_manifest
  from_manifest=$(grep -oE 'image: *"?[^"[:space:]]+"?' "${dir}/calico.yaml" \
    | sed -E 's/image: *"?([^"]+)"?/\1/' | sort -u)
  local missing=0
  for image in ${from_manifest}; do
    case " ${images[*]} " in
      *" ${image} "*) ;;
      *) warn "the calico manifest names ${image}, which images.list does not"; missing=$((missing + 1)) ;;
    esac
  done
  if [ "${missing}" -gt 0 ]; then
    die "the calico manifest and images/k8s/v${KUBERNETES_VERSION}/images.list disagree"
  fi

  for image in "${images[@]}"; do
    # Mirrors that answer where docker.io and registry.k8s.io do not. The target
    # name is always the one images.list and the calico manifest agree on, so a
    # mirror is pulled from and then retagged.
    local sources=()
    case "${image}" in
      docker.io/*) sources+=("$(echo "${image}" | sed 's#^docker\.io/#docker.1ms.run/#')") ;;
      registry.k8s.io/*) sources+=("$(echo "${image}" | sed 's#^registry\.k8s\.io/#registry.cn-hangzhou.aliyuncs.com/google_containers/#')") ;;
    esac
    # calico publishes the same images on quay.io, which answered for the ones
    # the docker.io mirrors did not carry
    case "${image}" in
      docker.io/calico/*)
        sources+=("quay.io/$(echo "${image}" | sed 's#^docker\.io/##')")
        sources+=("hub.rat.dev/$(echo "${image}" | sed 's#^docker\.io/##')")
        ;;
    esac
    sources+=("${image}")
    pull_with_fallback "${image}" "${sources[@]}"
  done

  save_archive "${dir}/offline_images.tar" "${images[@]}"

  log "kubeadm offline package: $(du -sh "${dir}" | awk '{print $1}')"
}

function Main() {
  preflight

  # offline/ is deliberately kept. It holds the three Kubernetes binaries, the
  # largest downloads in a kubeadm bundle, and fetch skips a file that is already
  # there. Wiping the whole bundle made every retry re-download 200MB, which is
  # how one failing step turned into four attempts. Everything else is rebuilt
  # from scratch, so nothing stale can reach the manifest.
  rm -rf "${OUT}/bin" "${OUT}/charts" "${OUT}/k0s" "${OUT}/images" "${OUT}/manifests"
  mkdir -p "${OUT}"/{manifests,charts,k0s,images,bin}

  # the installer scripts travel in the bundle: the target machine has no copy.
  # The build and ops tools travel too, so the bundle can rebuild itself and be
  # returned to a blank host without the repository.
  for f in entry.sh install.sh install_k8s.sh install_k0s.sh install_kubecube.sh install_member.sh utils.sh cleanup.sh \
    cleanup-blank.sh prepare-build-host.sh build-offline-bundle.sh normalize-image-tar.py; do
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

  # BUNDLE_MINIMAL builds a bundle for a cluster only: the distribution's own
  # artefacts, no platform images and no charts. It exists so a kubeadm bundle
  # can be produced on a host that does not have the component sources: the
  # platform images are the same images under the same tag as the k0s bundle's,
  # so a member install takes them from there.
  if [ "${BUNDLE_MINIMAL}" != "true" ]; then
    build_k0s
    build_charts
    build_platform_images
    build_cilium_images
    build_k0s_component_images
  fi
  build_binaries
  if [ "${KUBERNETES_DISTRO}" = "kubeadm" ]; then
    build_kubeadm_offline
  fi
  # a minimal bundle carries the kubeadm images inside offline/ instead
  if [ "${BUNDLE_MINIMAL}" != "true" ]; then
    save_images
  fi
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
