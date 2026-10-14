#!/usr/bin/env bash
#
# Installer entry point.
#
# Two ways in:
#
#   * offline: this file sits inside a staged bundle (build-offline-bundle.sh
#     produces it). Everything the install needs is beside it, so nothing is
#     downloaded and no network is used.
#   * online: the released behaviour. The manifests and the chart are fetched
#     from the distribution host before anything else happens.
#
# The bundle is recognised by a bundle.env next to this script.

if [ ${UID} -ne 0 ];then
  echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m please use root to execute install shell"
  exit 1
fi

ENTRY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_ENV="${ENTRY_DIR}/bundle.env"
MANIFEST_BASE="/etc/kubecube"

# env_check verifies the host prerequisites.
#
# Which prerequisites depends on the distribution, and the difference matters on
# a blank machine: kubeadm needs sshpass (to join nodes), conntrack (kube-proxy
# programs conntrack rules) and unzip. k0s needs none of them, and a fresh
# Ubuntu has neither sshpass nor conntrack installed, so demanding them would
# reject a host that can run the install perfectly well.
function env_check() {
    local distro=${1:-kubeadm}
    local need_full=true
    if [ "${distro}" = "k0s" ]; then
      need_full=false
    fi

    echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m environment checking (${distro})"

    env_ok=true
    libseccomp_has="✓"

    ldconfig -p | grep libseccomp > /dev/null
    if [ $? != 0 ]; then
      whereis libseccomp | grep .so > /dev/null
      if [ $? != 0 ]; then
        whereis -b libseccomp.so.2 | grep / > /dev/null
        if [ $? != 0 ]; then
          libseccomp_has="x"
          env_ok=false
        fi
      fi
    fi

    if [ "${need_full}" = "true" ]; then
      sshpass_has="✓"
      conntrack_has="✓"
      unzip_has="✓"

      which sshpass > /dev/null
      if [ $? != 0 ]; then
        sshpass_has="x"
        env_ok=false
      fi

      which conntrack > /dev/null
      if [ $? != 0 ]; then
        conntrack_has="x"
        env_ok=false
      fi

      which unzip > /dev/null
      if [ $? != 0 ]; then
        unzip_has="x"
        env_ok=false
      fi

      echo -e "\033[32m|---------------------------------------------------------------------|\033[0m"
      echo -e "\033[32m|     sshpass     |    conntrack    |      unzip    |  libseccomp     |\033[0m"
      echo -e "\033[32m|---------------------------------------------------------------------|\033[0m"
      echo -e "\033[32m|     ${sshpass_has}           |    ${conntrack_has}            |      ${unzip_has}        |         ${libseccomp_has}       |\033[0m"
      echo -e "\033[32m|---------------------------------------------------------------------|\033[0m"
    else
      echo -e "\033[32m|--------------------------------|\033[0m"
      echo -e "\033[32m|           libseccomp           |\033[0m"
      echo -e "\033[32m|--------------------------------|\033[0m"
      echo -e "\033[32m|              ${libseccomp_has}                 |\033[0m"
      echo -e "\033[32m|--------------------------------|\033[0m"
    fi

    if [ ${env_ok} = false ]; then
        echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m lack of dependencies, ensure them"
        exit 1
    fi
}

# bundle_stage copies the staged bundle into the layout the installer scripts
# expect (/etc/kubecube/manifests and /etc/kubecube/kubecube-chart) and installs
# the binaries the bundle carries.
function bundle_stage() {
  clog_info "staging the offline bundle from ${ENTRY_DIR}"

  mkdir -p "${MANIFEST_BASE}/down" "${MANIFEST_BASE}/bin"

  if [ ! -d "${ENTRY_DIR}/manifests" ]; then
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[31mERROR\033[0m the bundle has no manifests directory"
    exit 1
  fi
  if [ ! -d "${ENTRY_DIR}/charts/kubecube-chart" ]; then
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[31mERROR\033[0m the bundle has no charts/kubecube-chart"
    exit 1
  fi

  rm -rf "${MANIFEST_BASE}/manifests" "${MANIFEST_BASE}/kubecube-chart"
  cp -a "${ENTRY_DIR}/manifests" "${MANIFEST_BASE}/manifests"
  cp -a "${ENTRY_DIR}/charts/kubecube-chart" "${MANIFEST_BASE}/kubecube-chart"

  # helm and kubectl come from the bundle: the online path downloads helm and
  # the kubeadm path installs kubectl, and neither happens offline.
  local bin
  for bin in helm kubectl; do
    if [ -f "${ENTRY_DIR}/bin/${bin}" ]; then
      install -m 0755 "${ENTRY_DIR}/bin/${bin}" "/usr/local/bin/${bin}"
      clog_info "installed ${bin} from the bundle"
    elif [ "${bin}" = "helm" ]; then
      echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[31mERROR\033[0m the bundle has no helm binary"
      exit 1
    fi
  done

  # The bundle's own install.conf is the one that must win: it carries
  # OFFLINE="true" and the image tag the bundle was built with.
  cp -a "${ENTRY_DIR}/install.conf" "${MANIFEST_BASE}/manifests/install.conf"
}

function clog_info() {
  echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m $1"
}

function clog_error() {
  echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[31mERROR\033[0m $1"
}

if [ -f "${BUNDLE_ENV}" ]; then
  # ------------------------------------------------------------------ offline
  bundle_stage

  # shellcheck source=/dev/null
  source "${MANIFEST_BASE}/manifests/install.conf"
  env_check "${KUBERNETES_DISTRO}"

  if [[ ${CUSTOMIZE} = "true" ]]; then
    echo -e "\033[32m================================================\033[0m"
    echo -e "\033[32m 1. Please make sure under kubecube folder      \033[0m"
    echo -e "\033[32m 'cd ${MANIFEST_BASE}/manifests'                 \033[0m"
    echo -e "\033[32m 2. Please modify install.conf                  \033[0m"
    echo -e "\033[32m 'vi install.conf'                              \033[0m"
    echo -e "\033[32m 3. Confirm every args then do command below:   \033[0m"
    echo -e "\033[32m '/bin/bash ${MANIFEST_BASE}/manifests/install.sh' \033[0m"
    echo -e "\033[32m================================================\033[0m"
    exit 0
  fi

  /bin/bash ${MANIFEST_BASE}/manifests/install.sh
  exit $?
fi

# -------------------------------------------------------------------- online
mkdir -p "${MANIFEST_BASE}/down" "${MANIFEST_BASE}/bin"
cd "${MANIFEST_BASE}"

if [ -e "./manifests" ]; then
  echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m manifests and kubecube-chart already exist"
else
  echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m downloading manifests for kubecube"
  wget https://kubecube.nos-eastchina1.126.net/kubecube-installer/release/v1.3/manifests.tar.gz -O manifests.tar.gz
  tar -xzvf manifests.tar.gz > /dev/null

  echo -e "$(date +'%Y-%m-%d %H:%M:%S') \033[32mINFO\033[0m downloading kubecube-chart ${KUBECUBE_VERSION}"
  wget https://kubecube.nos-eastchina1.126.net/kubecube-chart/${KUBECUBE_VERSION}/kubecube-chart.tar.gz -O kubecube-chart.tar.gz
  tar -xzvf kubecube-chart.tar.gz > /dev/null
fi

# shellcheck source=/dev/null
source "${MANIFEST_BASE}/manifests/install.conf"
env_check "${KUBERNETES_DISTRO}"

if [[ ${CUSTOMIZE} = "true" ]]; then
  echo -e "\033[32m================================================\033[0m"
  echo -e "\033[32m 1. Please make sure under kubecube folder      \033[0m"
  echo -e "\033[32m 'cd /etc/kubecube/manifests'                   \033[0m"
  echo -e "\033[32m 2. Please modify install.conf                  \033[0m"
  echo -e "\033[32m 'vi install.conf'                              \033[0m"
  echo -e "\033[32m 3. Confirm every args then do command below:   \033[0m"
  echo -e "\033[32m '/bin/bash install.sh'                         \033[0m"
  echo -e "\033[32m================================================\033[0m"
  exit 0
fi

/bin/bash /etc/kubecube/manifests/install.sh
