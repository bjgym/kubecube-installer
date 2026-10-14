#!/usr/bin/env bash
#
# Prepares a machine to run build-offline-bundle.sh.
#
# This is the counterpart of cleanup-blank.sh: cleanup removes the build
# toolchain so the snapshot is "blank machine plus bundle", and this puts it
# back when the bundle has to be rebuilt. Neither belongs in the snapshot.
#
# It needs network access, and it is safe to run twice.
#
#   ./prepare-build-host.sh
#
# Deliberately NOT configured here: registry mirrors for the docker daemon.
# build-offline-bundle.sh names the mirror it wants per image
# (docker.1ms.run/library/alpine, hub.rat.dev/...), which is predictable; a
# daemon-wide mirror turns a mirror that happens to be down into a failed pull
# that looks like a missing image.

set -uo pipefail

function log() { echo -e "\033[32m[prepare]\033[0m $*"; }
function warn() { echo -e "\033[33m[prepare]\033[0m $*"; }
function die() {
  echo -e "\033[31m[prepare] $*\033[0m" >&2
  exit 1
}

HELM_VERSION=${HELM_VERSION:-v3.14.4}

function install_packages() {
  log "installing docker, Go and the basics"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "apt-get update failed"
  apt-get install -y -qq docker.io golang-go curl ca-certificates tar gzip python3 \
    || die "apt-get install failed"

  systemctl enable --now docker > /dev/null 2>&1 || warn "could not start docker through systemd"
  docker info > /dev/null 2>&1 || die "docker is installed but not answering"
}

function install_helm() {
  if command -v helm > /dev/null 2>&1; then
    log "helm already present: $(helm version --short)"
    return 0
  fi

  local arch
  arch=$(case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac)

  log "installing helm ${HELM_VERSION}"
  local tmp
  tmp=$(mktemp -d)
  curl -sSLf "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" -o "${tmp}/helm.tgz" \
    || die "could not download helm"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  install -m 0755 "${tmp}/linux-${arch}/helm" /usr/local/bin/helm
  rm -rf "${tmp}"
}

function report() {
  echo
  log "build host ready"
  log "docker : $(docker --version)"
  log "go     : $(go version)"
  log "helm   : $(helm version --short)"
  log "arch   : $(uname -m)"
  echo
  log "next: WORKSPACE=<path to the workspace> ./build-offline-bundle.sh"
}

install_packages
install_helm
report
