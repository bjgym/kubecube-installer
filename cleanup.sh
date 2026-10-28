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

  clog debug "remove kubecube files"
  rm -rf /etc/kubecube

  clog info "kubecube uninstall success"
}

function kubernetes_uninstall() {
  clog info "uninstalling kubernetes"

  # -f, because kubeadm asks for a confirmation and a script has nobody to answer
  # it. Without the flag the reset did nothing at all, and this function then
  # deleted /etc/kubernetes and the binaries and reported success over a cluster
  # that was still running.
  clog debug "kubernetes reset"
  if ! kubeadm reset -f; then
    clog error "kubeadm reset failed; stopping rather than leaving a half-uninstalled node"
    exit 1
  fi

  # The kubelet outlives the reset: it stays enabled and keeps restarting against a
  # control plane that is gone.
  clog debug "stop and disable the kubelet"
  systemctl disable --now kubelet > /dev/null 2>&1 || true
  rm -f /etc/systemd/system/kubelet.service.d/forward.conf
  systemctl daemon-reload

  # The CNI leaves interfaces, routes and the firewall rules the installer added.
  clog debug "remove cni leftovers"
  local pod_cidr=""
  if [ -f /etc/kubecube/manifests/install.conf ]; then
    pod_cidr=$(grep -E '^POD_CIDR=' /etc/kubecube/manifests/install.conf | tail -1 | cut -d'"' -f2)
  fi
  pod_cidr=${pod_cidr:-10.244.0.0/16}
  ip link show 2>/dev/null | awk -F': ' '/cali|cilium|tunl0|cni0|lxc/ {print $2}' | while read -r dev; do
    ip link delete "${dev}" > /dev/null 2>&1 || true
  done
  if iptables -S 2>/dev/null | grep -q -- "-s ${pod_cidr} "; then
    iptables -S | grep -- "-s ${pod_cidr} " | sed 's/^-A /-D /' | xargs -r -L1 iptables > /dev/null 2>&1 || true
  fi
  ip route del "${pod_cidr}" > /dev/null 2>&1 || true

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
}

main
