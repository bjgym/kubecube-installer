#!/usr/bin/env bash
#
# Strips a build host back to "blank machine plus bundle".
#
# build-offline-bundle.sh needs docker, Go and a source tree. The acceptance run
# needs none of them, and leaving them behind would quietly answer the question
# the acceptance is asking: a bundle install must not depend on a runtime, a
# compiler, or a pre-warmed image store that the machine happens to have.
#
# After this runs, the only thing on the machine that the install did not put
# there is /opt/kubecube-offline.
#
#   ./cleanup-blank.sh            # print what it would do, change nothing
#   ./cleanup-blank.sh --yes      # do it
#
# It is deliberately not idempotent-hostile: running it twice is fine.

set -uo pipefail

OUT=${OUT:-/opt/kubecube-offline}
WORKSPACE=${WORKSPACE:-/root/kubecube-src}
POD_CIDR=${POD_CIDR:-10.244.0.0/16}
DO_IT=false
[ "${1:-}" = "--yes" ] && DO_IT=true

function log() { echo -e "\033[32m[cleanup]\033[0m $*"; }
function warn() { echo -e "\033[33m[cleanup]\033[0m $*"; }

# remove deletes a path if it exists, saying so either way.
function remove() {
  local path=$1
  if [ ! -e "${path}" ]; then
    return 0
  fi
  if [ "${DO_IT}" = "true" ]; then
    rm -rf "${path}"
    log "removed ${path}"
  else
    warn "would remove ${path}"
  fi
}

# remove_pkgs purges packages the build needed and the install does not.
function remove_pkgs() {
  local pkgs=("$@")
  local installed=()
  local pkg
  for pkg in "${pkgs[@]}"; do
    if dpkg -s "${pkg}" > /dev/null 2>&1; then
      installed+=("${pkg}")
    fi
  done
  if [ ${#installed[@]} -eq 0 ]; then
    return 0
  fi

  if [ "${DO_IT}" = "true" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" > /dev/null 2>&1 || \
      warn "purging ${installed[*]} reported an error, continuing"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y > /dev/null 2>&1 || true
    log "purged packages: ${installed[*]}"
  else
    warn "would purge packages: ${installed[*]}"
  fi
}

function stop_k0s() {
  if command -v k0s > /dev/null 2>&1; then
    if [ "${DO_IT}" = "true" ]; then
      k0s stop > /dev/null 2>&1 || true
      systemctl stop k0scontroller > /dev/null 2>&1 || true
      k0s reset > /dev/null 2>&1 || true
    else
      warn "would stop and reset k0s"
    fi
  fi
  remove /etc/systemd/system/k0scontroller.service
  remove /etc/systemd/system/k0scontroller.service.d
  remove /etc/k0s
  remove /var/lib/k0s
  remove /run/k0s
  remove /usr/local/bin/k0s
  if [ "${DO_IT}" = "true" ]; then
    systemctl daemon-reload > /dev/null 2>&1 || true
  fi
}

function stop_docker() {
  if [ "${DO_IT}" = "true" ]; then
    systemctl stop docker docker.socket containerd > /dev/null 2>&1 || true
  else
    warn "would stop docker and containerd"
  fi

  # a local registry, if the build started one
  if command -v docker > /dev/null 2>&1; then
    local running
    running=$(docker ps -a --format '{{.Names}}' 2> /dev/null | grep -E '^(registry|k0s-member|k0s-stock)' || true)
    if [ -n "${running}" ]; then
      if [ "${DO_IT}" = "true" ]; then
        echo "${running}" | xargs -r docker rm -f > /dev/null 2>&1 || true
        log "removed containers: $(echo "${running}" | tr '\n' ' ')"
      else
        warn "would remove containers: $(echo "${running}" | tr '\n' ' ')"
      fi
    fi
  fi

  remove /etc/docker/daemon.json
  remove /etc/docker
  remove /var/lib/docker
  remove /var/lib/containerd
  remove /etc/containerd
  remove /run/docker.sock

  remove_pkgs docker.io docker-ce docker-ce-cli containerd.io containerd runc
}

function remove_toolchain() {
  remove /usr/local/go
  remove /usr/lib/go-1.22
  remove /usr/lib/go
  remove /root/go
  remove /root/.cache/go-build
  remove /root/.cache/go
  # the apt packages prepare-build-host.sh installed
  remove_pkgs golang-go golang-1.22-go golang-1.22-src golang-src
  # the helm repository cache the bundle build adds
  remove /root/.config/helm
  remove /root/.cache/helm
}

function remove_install_leftovers() {
  # anything a rehearsal install produced
  remove /etc/kubecube
  remove /root/.kube
  remove /usr/local/bin/helm
  remove /usr/local/bin/kubectl
  remove /tmp/cilium-chart
  remove /tmp/k0s-member-ctx
  remove /tmp/kctl
  remove /tmp/cfsslimg
  # empty directories the container runtime packages leave behind: purging the
  # package does not take them, and an empty /etc/cni still looks like a machine
  # that has run a cluster before. /opt/cni is worse than empty — the docker.io
  # package installs the CNI plugin binaries there, and a CNI plugin on the
  # machine is something the install could pick up instead of the bundle's.
  remove /opt/containerd
  remove /opt/cni
  remove /etc/cni
  if [ "${DO_IT}" = "true" ]; then
    find /tmp -maxdepth 1 -name 'tmp.*' -type d -exec rm -rf {} + 2> /dev/null || true
  fi
}

function remove_sources() {
  remove "${WORKSPACE}"
}

# verify_bundle re-checks the bundle, because it is the only thing that survives
# and a corrupted one wastes the whole acceptance run.
function verify_bundle() {
  if [ ! -d "${OUT}" ]; then
    warn "${OUT} does not exist; nothing to verify"
    return 0
  fi
  if [ ! -f "${OUT}/bundle.manifest" ]; then
    warn "${OUT}/bundle.manifest is missing"
    return 1
  fi

  log "verifying the bundle checksums"
  if (cd "${OUT}" && sha256sum -c bundle.manifest --quiet); then
    log "bundle checksums ok"
  else
    warn "bundle checksums FAILED"
    return 1
  fi
}

# assert_blank prints what the machine looks like now. The point is evidence: a
# reviewer should be able to read this and see that nothing the install needs is
# already lying around.
function assert_blank() {
  # bash caches where it found a command, and it does not re-check that the file
  # still exists. stop_k0s runs k0s before deleting it, so without this the
  # check below reports k0s on PATH after it has already been removed.
  hash -r

  echo
  log "blank-state assertions"
  local ok=true
  local path
  for path in /usr/local/bin/k0s /etc/k0s /var/lib/k0s /etc/docker /var/lib/docker \
    /var/lib/containerd /opt/containerd /opt/cni /etc/cni \
    /usr/local/go /root/go /etc/kubecube /root/.kube /usr/local/bin/helm; do
    if [ -e "${path}" ]; then
      warn "still present: ${path}"
      ok=false
    else
      log "absent: ${path}"
    fi
  done

  local cmd
  for cmd in docker k0s helm kubectl go containerd ctr runc dockerd; do
    if command -v "${cmd}" > /dev/null 2>&1; then
      warn "still on PATH: ${cmd} ($(command -v "${cmd}"))"
      ok=false
    else
      log "not on PATH: ${cmd}"
    fi
  done

  local link
  for link in cilium_host cilium_net; do
    if ip link show "${link}" > /dev/null 2>&1; then
      warn "still present: interface ${link}"
      ok=false
    else
      log "no interface ${link}"
    fi
  done

  echo
  log "what remains under /opt:"
  ls -la /opt || true
  echo
  log "bundle size: $(du -sh "${OUT}" 2> /dev/null | awk '{print $1}')"
  echo
  if [ "${ok}" = "true" ]; then
    log "the machine is blank apart from the bundle"
  else
    warn "something above is still present"
  fi
}

# remove_cni_leftovers removes what the CNI put on the *host*.
#
# k0s reset takes the cluster away but not the things the CNI created outside it:
# the cilium_host/cilium_net veth pair stays in the host network namespace with
# its routes, and its iptables chains stay wired into INPUT and FORWARD. A
# machine that keeps them is not blank — the next cluster can inherit stale
# routes for the pod CIDR — and the forwarding rules the installer inserts have
# to go with them, or the next run starts from a state the previous one created.
function remove_cni_leftovers() {
  local link
  for link in cilium_host cilium_net lxc0; do
    if ip link show "${link}" > /dev/null 2>&1; then
      if [ "${DO_IT}" = "true" ]; then
        ip link del "${link}" > /dev/null 2>&1 || true
        log "removed interface ${link}"
      else
        warn "would remove interface ${link}"
      fi
    fi
  done

  local chain
  for chain in CILIUM_FORWARD CILIUM_INPUT CILIUM_OUTPUT CILIUM_POSTROUTING CILIUM_PRE_mangle CILIUM_POST_mangle; do
    if iptables -L "${chain}" > /dev/null 2>&1; then
      if [ "${DO_IT}" = "true" ]; then
        iptables -F "${chain}" > /dev/null 2>&1 || true
        iptables -X "${chain}" > /dev/null 2>&1 || true
        log "removed iptables chain ${chain}"
      else
        warn "would remove iptables chain ${chain}"
      fi
    fi
  done

  # the pod-network rules the provider inserts, and the unit drop-in that
  # reapplies them
  if [ "${DO_IT}" = "true" ]; then
    while iptables -D INPUT -s "${POD_CIDR}" -j ACCEPT > /dev/null 2>&1; do :; done
    while iptables -D FORWARD -s "${POD_CIDR}" -j ACCEPT > /dev/null 2>&1; do :; done
    ip route del "${POD_CIDR}" > /dev/null 2>&1 || true
  fi
  remove /etc/systemd/system/k0scontroller.service.d/forward.conf
  rmdir /etc/systemd/system/k0scontroller.service.d > /dev/null 2>&1 || true

  # back to the policy the machine had: UFW's default is DROP, and leaving it at
  # ACCEPT for the next run would change the condition being tested
  if [ "${DO_IT}" = "true" ]; then
    if command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q "^Status: active"; then
      iptables -P FORWARD DROP
      log "restored the FORWARD policy to DROP (UFW's default)"
    fi
    systemctl daemon-reload > /dev/null 2>&1 || true
  fi
}

function Main() {
  if [ "${DO_IT}" != "true" ]; then
    warn "dry run: nothing will be changed. Re-run with --yes to do it."
    echo
  fi

  stop_k0s
  stop_docker
  remove_cni_leftovers
  remove_toolchain
  remove_install_leftovers
  remove_sources

  if [ "${DO_IT}" = "true" ]; then
    sync
  fi

  verify_bundle
  assert_blank
}

Main
