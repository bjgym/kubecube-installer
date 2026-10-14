#!/usr/bin/env bash
#
# k0s provider.
#
# Brings up a single-node k0s control plane (worker enabled) and the cluster's
# CNI, then leaves a kubeconfig where the platform chart expects it. k0s ships
# its own containerd and its own kubelet, so nothing else has to be installed on
# the host: that is what makes the offline path possible without a container
# runtime.
#
# Three things this provider deliberately does NOT do, each because doing it
# breaks the install:
#
#   * it does not override spec.images.pause. k0s composes the sandbox image as
#     "<image>:<tag>", so pinning the full reference there yields
#     "pause:3.8:3.8" and every pod sandbox fails. The bundle imports
#     registry.k8s.io/pause:3.8 under its own name instead.
#   * it does not disable k0s' bundled metrics-server. The chart's own
#     metrics-server subchart is turned off in install_kubecube.sh, and the
#     cluster keeps the one k0s ships: disabling both leaves the platform with
#     no metrics at all and every usage figure in the console reads zero.
#   * it does not install a CNI manifest of its own for kuberouter or calico:
#     k0s owns those two providers and installs them itself.
#
# Usage: sourced and called by install.sh, or run directly as root.

source /etc/kubecube/manifests/utils.sh
source /etc/kubecube/manifests/install.conf

K0S_BIN="/usr/local/bin/k0s"
K0S_CONFIG="/etc/k0s/k0s.yaml"
K0S_API_PORT="6443"
K0S_POD_CIDR="10.244.0.0/16"
K0S_SERVICE_CIDR="10.96.0.0/12"
K0S_READY_TIMEOUT=600
CILIUM_CHART_DIR="${OFFLINE_BUNDLE_DIR}/charts/cilium"

# arch_name maps uname's machine to the name the bundle and the upstream
# artifacts use.
function arch_name() {
  case "$(arch)" in
    x86_64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *)
      clog error "unsupported architecture: $(arch)"
      exit 1
      ;;
  esac
}

# k0s_prepare_host applies the host settings a cluster needs and a blank Ubuntu
# does not have.
#
# The one that bites is the firewall. Ubuntu's UFW is active by default on many
# images, with "deny (incoming), deny (routed)": the INPUT and FORWARD policies
# are DROP and UFW inserts its own drop rules into both chains. Two kinds of pod
# traffic then die at the host, and the cluster still looks healthy — node Ready,
# CNI running, service map programmed:
#
#   * pod to a service on the node itself, which includes the API server behind
#     10.96.0.1:443. That packet is delivered locally, so it is INPUT, and UFW
#     drops it: every pod's API access times out, coredns never becomes ready,
#     metrics-server panics on startup and the platform's pre-install job fails
#     with "dial tcp 10.96.0.1:443: i/o timeout".
#   * pod to anywhere else, which is FORWARD, and UFW drops that too.
#
# Changing the policy alone is not enough, because UFW's own rules are consulted
# before it; the accept has to be inserted ahead of them. The kubeadm path does
# exactly this for docker (install_k8s.sh inserts an ACCEPT at the head of
# FORWARD), and the k0s path needs it for the pod network. The rules are also
# written into the unit's drop-in so a reboot reapplies them.
function k0s_prepare_host() {
  clog info "applying host settings"

  sysctl -w net.ipv4.ip_forward=1 > /dev/null
  if [ -d /proc/sys/net/bridge ]; then
    sysctl -w net.bridge.bridge-nf-call-iptables=1 > /dev/null 2>&1 || true
  fi

  # only touch the firewall when it is in the way, and only for the pod network
  local input_policy forward_policy
  input_policy=$(iptables -S INPUT | head -1)
  forward_policy=$(iptables -S FORWARD | head -1)
  if echo "${input_policy}" | grep -q "DROP" || echo "${forward_policy}" | grep -q "DROP" \
    || iptables -S FORWARD | grep -q "ufw-before-forward"; then
    clog warn "a host firewall is dropping pod traffic (INPUT: ${input_policy#-P }, FORWARD: ${forward_policy#-P }); allowing ${K0S_POD_CIDR} through"
    iptables -P FORWARD ACCEPT
    iptables -I INPUT 1 -s "${K0S_POD_CIDR}" -j ACCEPT
    iptables -I FORWARD 1 -s "${K0S_POD_CIDR}" -j ACCEPT
  fi

  # Not persisted in /etc/default/ufw on purpose: that file is the operator's
  # firewall configuration, and the unit drop-in is enough to survive a reboot.
  mkdir -p /etc/systemd/system/k0scontroller.service.d
  cat > /etc/systemd/system/k0scontroller.service.d/forward.conf << EOF
[Service]
# Pod traffic has to reach services on this node (INPUT) and leave it (FORWARD).
# Ubuntu's UFW defaults both to DROP, which breaks every pod's egress while
# leaving the cluster looking healthy.
ExecStartPost=/sbin/iptables -P FORWARD ACCEPT
ExecStartPost=/sbin/iptables -I INPUT 1 -s ${K0S_POD_CIDR} -j ACCEPT
ExecStartPost=/sbin/iptables -I FORWARD 1 -s ${K0S_POD_CIDR} -j ACCEPT
EOF
  systemctl daemon-reload
}

# k0s_check_config refuses the combinations this provider does not implement,
# rather than installing something the operator did not ask for.
function k0s_check_config() {
  if [ "${KUBERNETES_DISTRO}" != "k0s" ]; then
    clog error "install_k0s.sh called with KUBERNETES_DISTRO=${KUBERNETES_DISTRO}"
    exit 1
  fi

  # Only the single-node shape is implemented. The other NODE_MODE values join a
  # cluster that already exists, which needs the kubeadm path's machinery.
  if [ "${NODE_MODE}" != "master" ]; then
    clog error "k0s supports NODE_MODE=\"master\" (single node) only, got \"${NODE_MODE}\""
    exit 1
  fi

  case "${CNI}" in
    kuberouter | calico | cilium) ;;
    *)
      clog error "k0s supports CNI kuberouter, calico or cilium, got \"${CNI}\""
      exit 1
      ;;
  esac

  if [ "${OFFLINE}" = "true" ] && [ ! -d "${OFFLINE_BUNDLE_DIR}" ]; then
    clog error "OFFLINE=true but ${OFFLINE_BUNDLE_DIR} does not exist"
    exit 1
  fi
}

# k0s_bin_install places the k0s binary. Offline it comes from the bundle and is
# checked against the checksum the bundle recorded; online it comes from the
# project's install script, which needs github reachability.
function k0s_bin_install() {
  local arch
  arch=$(arch_name)

  if [ "${OFFLINE}" = "true" ]; then
    local src="${OFFLINE_BUNDLE_DIR}/k0s/k0s-${arch}"
    if [ ! -f "${src}" ]; then
      clog error "bundle is missing ${src}"
      exit 1
    fi
    clog info "verifying the bundled k0s binary"
    k0s_verify_checksum "${src}"
    install -m 0755 "${src}" "${K0S_BIN}"
  else
    clog info "installing k0s from the project's install script"
    curl -sSLf https://get.k0s.sh | sh
  fi

  clog info "k0s version: $(${K0S_BIN} version)"
}

# k0s_verify_checksum checks a file against the bundle's manifest. The manifest
# is a list of "<sha256>  <path relative to the bundle>" lines.
function k0s_verify_checksum() {
  local file=$1
  local manifest="${OFFLINE_BUNDLE_DIR}/bundle.manifest"
  local rel=${file#"${OFFLINE_BUNDLE_DIR}"/}

  if [ ! -f "${manifest}" ]; then
    clog warn "no bundle.manifest, skipping checksum for ${rel}"
    return 0
  fi

  local want
  want=$(awk -v f="${rel}" '$2 == f { print $1 }' "${manifest}")
  if [ -z "${want}" ]; then
    clog warn "${rel} is not listed in bundle.manifest, skipping checksum"
    return 0
  fi

  local got
  got=$(sha256sum "${file}" | awk '{print $1}')
  if [ "${got}" != "${want}" ]; then
    clog error "checksum mismatch for ${rel}: want ${want}, got ${got}"
    exit 1
  fi
  clog debug "${rel} checksum ok"
}

# k0s_images_import loads every image the cluster needs into k0s' containerd
# before the cluster starts pulling anything. k0s' own components (coredns,
# konnectivity, metrics-server) and the sandbox image have to be there already,
# or they fail against a network that is not there.
function k0s_images_import() {
  if [ "${OFFLINE}" != "true" ]; then
    return 0
  fi

  local dir="${OFFLINE_BUNDLE_DIR}/images"
  local tar
  shopt -s nullglob
  local tars=("${dir}"/*.tar)
  shopt -u nullglob

  if [ ${#tars[@]} -eq 0 ]; then
    clog error "no image archives in ${dir}"
    exit 1
  fi

  # k0s' containerd has to be up to receive images, so this runs right after
  # k0s_service_start. The components that need these images retry until they
  # are there, which is why importing second is safe.
  clog info "importing ${#tars[@]} image archive(s) into k0s containerd"
  for tar in "${tars[@]}"; do
    k0s_verify_checksum "${tar}"
    clog debug "importing $(basename "${tar}")"
    if ! ${K0S_BIN} ctr -n k8s.io images import "${tar}" > /dev/null; then
      clog error "importing $(basename "${tar}") failed"
      exit 1
    fi
  done

  # The sandbox image is the one the kubelet asks for by name on every pod. If
  # it is missing, everything else looks healthy and no pod ever starts.
  if ! ${K0S_BIN} ctr -n k8s.io images ls | grep -q "registry.k8s.io/pause:3.8"; then
    clog error "registry.k8s.io/pause:3.8 is missing after the import"
    exit 1
  fi
  clog info "images imported, sandbox image present"
}

# k0s_config_render writes /etc/k0s/k0s.yaml.
#
# The CNI mapping is the whole point of the file:
#   cilium     -> provider "custom": k0s installs no CNI and the chart does it
#   calico     -> provider "calico": k0s installs it from its own images
#   kuberouter -> provider "kuberouter": k0s' bundled default
function k0s_config_render() {
  local provider
  local kube_proxy_disabled="false"

  case "${CNI}" in
    cilium)
      provider="custom"
      if [ "${CILIUM_KUBE_PROXY_REPLACEMENT}" = "true" ]; then
        kube_proxy_disabled="true"
      fi
      ;;
    calico) provider="calico" ;;
    kuberouter) provider="kuberouter" ;;
  esac

  clog info "rendering ${K0S_CONFIG} (provider: ${provider}, kube-proxy disabled: ${kube_proxy_disabled})"
  mkdir -p /etc/k0s

  cat > "${K0S_CONFIG}" << EOF
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
spec:
  api:
    port: ${K0S_API_PORT}
    sans:
      - ${IPADDR}
      - 127.0.0.1
      - localhost
  network:
    provider: ${provider}
    podCIDR: ${K0S_POD_CIDR}
    serviceCIDR: ${K0S_SERVICE_CIDR}
    kubeProxy:
      disabled: ${kube_proxy_disabled}
EOF

  ${K0S_BIN} config validate -c "${K0S_CONFIG}" || {
    clog error "k0s rejected the generated configuration"
    exit 1
  }
}

# k0s_service_install registers the systemd unit. --single enables the worker and
# leaves the node untainted, which is what a one-machine install wants.
#
# kube-proxy is disabled twice over when Cilium replaces it: in the cluster
# config, and on this command line. Both are honoured, and the two together mean
# a change in either place cannot quietly leave kube-proxy running next to
# Cilium — which is a configuration that looks healthy and misroutes service
# traffic.
function k0s_service_install() {
  local args=(--single --config "${K0S_CONFIG}")
  if [ "${CNI}" = "cilium" ] && [ "${CILIUM_KUBE_PROXY_REPLACEMENT}" = "true" ]; then
    args+=(--disable-components kube-proxy)
  fi

  clog info "installing the k0scontroller service: k0s install controller ${args[*]}"
  if systemctl list-unit-files | grep -q "^k0scontroller.service"; then
    clog warn "k0scontroller.service already exists, reinstalling"
    ${K0S_BIN} stop > /dev/null 2>&1 || true
    ${K0S_BIN} reset > /dev/null 2>&1 || true
  fi
  ${K0S_BIN} install controller "${args[@]}"
}

# k0s_service_start starts the controller and waits for containerd to accept
# connections, so the image import that follows has somewhere to land.
function k0s_service_start() {
  clog info "starting k0s"
  systemctl start k0scontroller

  local i
  for i in $(seq 1 60); do
    if ${K0S_BIN} ctr -n k8s.io images ls > /dev/null 2>&1; then
      clog info "k0s containerd is up"
      return 0
    fi
    sleep 2
  done

  clog error "k0s containerd did not come up"
  journalctl -u k0scontroller --no-pager | tail -50
  exit 1
}

# k0s_wait_api waits for the API server to answer, which is all that is needed
# before installing the CNI.
#
# The node cannot report Ready before a CNI is in place: a kubelet with no CNI
# configuration sets NetworkUnavailable and stays NotReady. With provider
# "custom" nothing installs a CNI but this installer, so waiting for Ready first
# waits for something the script has not done yet — the install then sits here
# for the whole timeout with coredns and metrics-server Pending behind it.
function k0s_wait_api() {
  clog info "waiting for the API server"
  local waited=0
  while [ ${waited} -lt 300 ]; do
    if ${K0S_BIN} kubectl get nodes --no-headers 2> /dev/null | grep -q .; then
      clog info "the API server is answering"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  clog error "the API server did not answer in 300s"
  journalctl -u k0scontroller --no-pager | tail -50
  exit 1
}

# k0s_wait_ready waits for the node to report Ready.
#
# The pattern is " Ready " with the spaces on purpose: "NotReady" contains
# "Ready", and a loose match returns success while the node is still not ready.
function k0s_wait_ready() {
  clog info "waiting for the node to become ready (up to ${K0S_READY_TIMEOUT}s)"
  local waited=0
  while [ ${waited} -lt ${K0S_READY_TIMEOUT} ]; do
    if ${K0S_BIN} kubectl get nodes --no-headers 2> /dev/null | grep -q " Ready "; then
      ${K0S_BIN} kubectl get nodes
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done

  clog error "the node did not become ready in ${K0S_READY_TIMEOUT}s"
  ${K0S_BIN} kubectl get nodes
  ${K0S_BIN} kubectl get pods -A
  exit 1
}

# cni_install_cilium installs the bundled Cilium chart.
#
# k0s is told "provider: custom", so this is the only thing that sets up pod
# networking. ipam.mode=kubernetes makes Cilium use the per-node podCIDR k0s'
# controller-manager already allocates (10.244.0.0/16 split per node); Cilium's
# own default pool is 10.0.0.0/8, which swallows k0s' service CIDR 10.96.0.0/12.
function cni_install_cilium() {
  local chart="${CILIUM_CHART_DIR}"
  local chart_values="${OFFLINE_BUNDLE_DIR}/charts/cilium-values.yaml"
  local runtime_values="/etc/kubecube/manifests/cilium-runtime-values.yaml"
  local replacement="false"
  if [ "${CILIUM_KUBE_PROXY_REPLACEMENT}" = "true" ]; then
    replacement="true"
  fi

  if [ "${OFFLINE}" = "true" ]; then
    if [ ! -d "${chart}" ]; then
      clog error "bundle is missing the cilium chart at ${chart}"
      exit 1
    fi
    if [ ! -f "${chart_values}" ]; then
      clog error "bundle is missing ${chart_values}"
      exit 1
    fi
    clog info "installing cilium ${CILIUM_VERSION} from the bundle"
  else
    clog info "pulling the cilium ${CILIUM_VERSION} chart"
    helm repo add cilium https://helm.cilium.io/ --force-update > /dev/null
    helm pull cilium/cilium --version "${CILIUM_VERSION}" -d /tmp
    chart=$(ls /tmp/cilium-"${CILIUM_VERSION}".tgz)

    # The same values the bundle builder writes. They have to match: they decide
    # which images the chart asks for.
    chart_values="/etc/kubecube/manifests/cilium-base-values.yaml"
    cat > "${chart_values}" << EOF
kubeProxyReplacement: ${replacement}
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
  fi

  # Only the node address is install-time knowledge; everything else comes from
  # the values file the bundle carries.
  cat > "${runtime_values}" << EOF
# Written by install_k0s.sh.
k8sServiceHost: ${IPADDR}
k8sServicePort: ${K0S_API_PORT}
EOF

  if [ "${replacement}" = "true" ]; then
    clog info "cilium replaces kube-proxy; k0s' kube-proxy is disabled in ${K0S_CONFIG}"
  fi

  if ! helm upgrade --install cilium "${chart}" --namespace kube-system \
    --values "${chart_values}" --values "${runtime_values}" --wait --timeout 10m; then
    # Fatal on purpose: without a CNI the node never becomes Ready, and carrying
    # on turns a failed helm install into a ten minute wait for something that
    # is not coming.
    clog error "installing cilium failed"
    ${K0S_BIN} kubectl -n kube-system get pods 2> /dev/null || true
    exit 1
  fi
}

# cni_wait_ready waits for the CNI to be serving pod networking.
function cni_wait_ready() {
  case "${CNI}" in
    cilium)
      clog info "waiting for the cilium daemonset"
      if ! ${K0S_BIN} kubectl -n kube-system rollout status daemonset/cilium --timeout=10m; then
        clog error "the cilium daemonset did not become ready"
        ${K0S_BIN} kubectl -n kube-system get pods
        exit 1
      fi
      ;;
    calico)
      clog info "waiting for k0s' calico daemonset"
      ${K0S_BIN} kubectl -n kube-system rollout status daemonset/calico-node --timeout=10m || true
      ;;
    kuberouter)
      clog info "waiting for k0s' kube-router daemonset"
      ${K0S_BIN} kubectl -n kube-system rollout status daemonset/kube-router --timeout=10m || true
      ;;
  esac
}

# kubeconfig_prepare writes /root/.kube/config, which install_kubecube.sh reads
# for the chart's localKubeConfig and pivotKubeConfig.
#
# The server is rewritten to the node IP: the chart hands this kubeconfig to
# warden, which runs inside the cluster and cannot resolve "localhost".
function kubeconfig_prepare() {
  clog info "writing /root/.kube/config"
  mkdir -p /root/.kube
  ${K0S_BIN} kubeconfig admin > /root/.kube/config
  sed -i -E "s#server: https://[^ ]*#server: https://${IPADDR}:${K0S_API_PORT}#" /root/.kube/config
  chmod 600 /root/.kube/config

  if ! kubectl get nodes > /dev/null 2>&1; then
    clog error "/root/.kube/config does not reach the cluster"
    exit 1
  fi
  clog info "kubeconfig ready: $(grep -m1 'server:' /root/.kube/config)"
}

# Main runs the provider.
function Main() {
  k0s_check_config
  k0s_prepare_host
  k0s_bin_install
  k0s_config_render
  k0s_service_install
  k0s_service_start
  k0s_images_import
  k0s_wait_api

  # The kubeconfig comes before the CNI, not after it: cilium is installed with
  # helm, and helm reads /root/.kube/config. Without it helm reports
  # "Kubernetes cluster unreachable" and installs nothing.
  kubeconfig_prepare

  # The CNI goes in before the Ready wait, not after it: see k0s_wait_api. For
  # calico and kuberouter k0s installs the CNI itself, so this step is only the
  # cilium case, and the ordering is harmless for the other two.
  if [ "${CNI}" = "cilium" ]; then
    cni_install_cilium
  fi
  k0s_wait_ready
  cni_wait_ready

  clog info "k0s cluster is up: distro k0s ${K0S_VERSION}, cni ${CNI}"
}

Main
