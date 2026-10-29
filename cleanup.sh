#!/usr/bin/env bash

set -o nounset
set -o pipefail

OPT=$1

function kubecube_uninstall() {
  clog info "uninstalling kubecube"

  clog debug "uninstall kubecueb helm chart release"
  kubectl delete validatingwebhookconfigurations kubecube-validating-webhook-configuration warden-validating-webhook-configuration kubecube-monitoring-admission || true
  kubectl delete cluster --all || true
  helm uninstall kubecube -n kubecube-system || true

  # Wait for the namespaces instead of deleting them and moving on. One that is
  # still terminating keeps its CRs, and the next install then refuses objects it
  # did not create.
  clog debug "wait for the release namespaces to terminate"
  kubectl delete ns kubecube-system kubecube-monitoring hnc-system kubecube --ignore-not-found --wait=true --timeout=300s \
    || clog warn "a namespace did not terminate in 300s; check with: kubectl get ns"

  # CRDs outlive the release — helm only deletes what it installed — and a leftover
  # CRD is what makes a fresh install fail on an object it did not create.
  clog debug "delete the platform's CRDs"
  kubectl get crd -o name 2>/dev/null | grep -e kubecube.io | xargs -r kubectl delete --ignore-not-found --wait=false || true

  # /etc/kubecube is deleted in main(), after kubernetes_uninstall has read the
  # cluster's networks from it. Deleting it here meant a second teardown found no
  # conf, fell back to the defaults, and left the previous cluster's firewall rules
  # in place — which is exactly what a teardown of a custom-network cluster hit.

  clog info "kubecube uninstall success"
}

function kubernetes_uninstall() {
  clog info "uninstalling kubernetes"

  # -f, because kubeadm asks for a confirmation and a script has nobody to answer
  # it. Without the flag the reset did nothing at all, and this function then
  # deleted /etc/kubernetes and the binaries and reported success over a cluster
  # that was still running.
  #
  # A second run finds no kubeadm — the first run deleted it — and that is a cluster
  # already reset, not a failure.
  clog debug "kubernetes reset"
  if command -v kubeadm > /dev/null 2>&1; then
    if ! kubeadm reset -f; then
      clog error "kubeadm reset failed; stopping rather than leaving a half-uninstalled node"
      exit 1
    fi
  else
    clog warn "kubeadm is not installed; there is no cluster left to reset"
  fi

  # The kubelet outlives the reset: it stays enabled and keeps restarting against a
  # control plane that is gone.
  clog debug "stop and disable the kubelet"
  systemctl disable --now kubelet > /dev/null 2>&1 || true
  rm -f /etc/systemd/system/kubelet.service.d/forward.conf
  systemctl daemon-reload

  # The CNI leaves interfaces, routes and the firewall rules the installer added.
  #
  # The interfaces print as "cali1234@if3": the peer suffix is not part of the name,
  # and passing it to `ip link delete` fails, which is why thirteen of them survived
  # the first version of this. Both networks are cleared because the installer allows
  # the pod CIDR on INPUT and FORWARD and the service CIDR on FORWARD.
  clog debug "remove cni leftovers"
  local dev
  ip link show 2>/dev/null | awk -F': ' '/cali|cilium|tunl0|cni0|lxc/ {print $2}' | while read -r dev; do
    dev=${dev%%@*}
    ip link set "${dev}" down > /dev/null 2>&1 || true
    ip link delete "${dev}" > /dev/null 2>&1 || true
  done

  # tunl0 is the ipip module's default device: `ip link delete tunl0` returns 0 and
  # it is back the moment anything loads the module again, so the module goes.
  modprobe -r ipip > /dev/null 2>&1 || true
  # Both the networks this cluster was configured with and the distribution defaults:
  # a cluster that was installed with a custom pod network and then had its config
  # replaced still has rules for the old one, and a leftover rule is exactly what
  # this cleanup exists to remove.
  #
  # The snapshot is taken first, then deleted line by line. Piping `iptables -S` into
  # `grep -q` looked fine and never worked: grep exits on the first match, iptables
  # dies of SIGPIPE, and with `set -o pipefail` the pipeline reports 141 — so the
  # condition was false for a rule that was plainly there.
  local cidr rules rule
  for cidr in "${NET_POD_CIDR}" "${NET_SERVICE_CIDR}" 10.244.0.0/16 10.96.0.0/12; do
    [ -n "${cidr}" ] || continue
    rules=$(iptables -S 2> /dev/null | grep -- "-s ${cidr} " || true)
    [ -n "${rules}" ] || continue
    while IFS= read -r rule; do
      # -A INPUT ... -> -D INPUT ... (replace the prefix, do not just strip it)
      iptables ${rule/#-A /-D } > /dev/null 2>&1 || true
    done <<< "${rules}"
    ip route del "${cidr}" > /dev/null 2>&1 || true
  done

  clog debug "delete residual files of kubernetes"
  rm -rf /etc/kubernetes/
  rm -rf /var/lib/etcd
  rm -rf /var/lib/cni/
  rm -rf /var/lib/kubelet

  clog debug "delete binaries of kubernetes"
  rm -f /usr/local/bin/crictl /usr/local/bin/kubeadm /usr/local/bin/kubectl /usr/local/bin/kubelet /usr/local/bin/helm

  clog info "kubernetes uninstall success"
}

function docker_uninstall() {
  clog info "uninstalling docker"

  clog debug "stop docker"
  systemctl stop docker

  clog debug "delete residual files of docker"
  rm -rf /var/lib/docker
  rm /etc/systemd/system/docker.service
  rm /etc/docker/daemon.json
  rm /usr/bin/docker
  rm /usr/bin/dockerd
  umount /var/run/docker/netns/default
  rm -rf /var/run/docker

  clog info "docker uninstall success"
}

function containerd_uninstall() {
    clog info "uninstalling containerd"
    systemctl disable containerd --now
    rm -f /etc/crictl.yaml
    rm -rf /etc/cni
    rm -f /etc/systemd/system/containerd.service
    rm -f /usr/local/sbin/runc
    rm -f /usr/local/bin/containerd-shim-runc-v1
    rm -f /usr/local/bin/critest
    rm -f /usr/local/bin/ctr
    rm -f /usr/local/bin/containerd-shim
    rm -f /usr/local/bin/crictl
    rm -f /usr/local/bin/containerd
    rm -f /usr/local/bin/ctd-decoder
    rm -f /usr/local/bin/containerd-stress
    rm -f /usr/local/bin/containerd-shim-runc-v2
    rm -rf /opt/cni
    rm -rf /opt/containerd
    rm -rf /etc/containerd
    clog info "containerd uninstall success"
}

function cri_dockerd_uninstall() {
      clog info "uninstalling cri_dockerd"

      clog debug "stop cri_dockerd"
      systemctl stop cri-docker.service
      systemctl stop cri-docker.socket

      clog debug "delete residual files of cri_dockerd"
      rm -f /etc/systemd/system/cri-docker.socket
      rm -f /etc/systemd/system/cri-docker.service
      rm -f /usr/local/bin/cri-dockerd
      clog info "cri_dockerd uninstall success"
}

function clog() {
  TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')
  case "$1" in
    debug)
      echo -e "$TIMESTAMP \033[36mDEBUG\033[0m $2"
      ;;
    info)
      echo -e "$TIMESTAMP \033[32mINFO\033[0m $2"
      ;;
    warn)
      echo -e "$TIMESTAMP \033[33mWARN\033[0m $2"
      ;;
    error)
      echo -e "$TIMESTAMP \033[31mERROR\033[0m $2"
      ;;
    *)
      ;;
  esac
}

function main() {
  # Read the cluster's networks before kubecube_uninstall deletes /etc/kubecube: the
  # CNI cleanup needs the networks the installer configured, and their defaults are
  # not what every cluster uses.
  NET_POD_CIDR=""
  NET_SERVICE_CIDR=""
  if [ -f /etc/kubecube/manifests/install.conf ]; then
    # tr -d '\r': the conf has been CRLF on every build made from a Windows
    # checkout, and a CIDR read with a trailing carriage return matches no rule at
    # all — the sweep ran, found nothing, and left twelve rules behind.
    NET_POD_CIDR=$(grep -E '^POD_CIDR=' /etc/kubecube/manifests/install.conf | tail -1 | cut -d'"' -f2 | tr -d '\r')
    NET_SERVICE_CIDR=$(grep -E '^SERVICE_CIDR=' /etc/kubecube/manifests/install.conf | tail -1 | cut -d'"' -f2 | tr -d '\r')
  fi
  NET_POD_CIDR=${NET_POD_CIDR:-10.244.0.0/16}
  NET_SERVICE_CIDR=${NET_SERVICE_CIDR:-10.96.0.0/12}

  case ${OPT} in
    "kubecube") kubecube_uninstall
    ;;
    "k8s") kubernetes_uninstall
    ;;
    "docker") docker_uninstall
    cri_dockerd_uninstall
    ;;
    "containerd") containerd_uninstall
    ;;
    "all")
      kubecube_uninstall
      kubernetes_uninstall
      docker_uninstall
      containerd_uninstall
      cri_dockerd_uninstall
    ;;
    *)
      echo "unknown params, only support: 'kubecube','k8s','docker','containerd','all'"
    ;;
  esac

  # Delete the installer's own configuration only after the uninstallers have read
  # what they need from it — kubernetes_uninstall reads the cluster's networks there.
  rm -rf /etc/kubecube
}

main
