#!/usr/bin/env bash

IPADDR=$(hostname -I |awk '{print $1}')
Uptime_day=$(uptime |awk '{print $3,$4}')
CPU_NUM=$(grep -c 'processor' /proc/cpuinfo)
Uptime=$(uptime -p |awk '{print $6,$7,$8,$9}')
MEM_INFO=$(free -m |awk '/Mem/ {print "memory total:",$2"M"}')
CPU_Model=$(awk -F: '/name/ {print $NF}' /proc/cpuinfo |uniq)
CPU_ARCH=$(arch)
MEM_Avail=$(free -m |awk '/Mem/ {print "memory available:",$4"M"}')
DISK_INFO=$(df -h |grep -w "/" |awk '{print "disk total:",$1,$2}')
DISK_Avail=$(df -h |grep -w "/" |awk '{print "disk available:",$1,$4}')
LOAD_INFO=$(uptime |awk '{print "CPU load: "$(NF-2),$(NF-1),$NF}'|sed 's/\,//g')

# system_info inspect current machine
function system_info () {
  echo -e "\033[32m-------------System Infomation-------------\033[0m"
  echo -e "\033[32m System running time：${Uptime_day}${Uptime} \033[0m"
  echo -e "\033[32m IP: ${IPADDR} \033[0m"
  echo -e "\033[32m CPU model:${CPU_Model} \033[0m"
  echo -e "\033[32m CPU arch:${CPU_ARCH}  \033[0m"
  echo -e "\033[32m CPU cores: ${CPU_NUM} \033[0m"
  echo -e "\033[32m ${DISK_INFO} \033[0m"
  echo -e "\033[32m ${DISK_Avail} \033[0m"
  echo -e "\033[32m ${MEM_INFO} \033[0m"
  echo -e "\033[32m ${MEM_Avail} \033[0m"
  echo -e "\033[32m ${LOAD_INFO} \033[0m"
  echo -e "\033[32m--------------------------------------------\033[0m"
}

# clog print log with timestamp and custom level
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

# init_etcd_secret create etcd secret for monitoring at first
function init_etcd_secret (){
  kubectl create namespace kubecube-monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic etcd-certs -n kubecube-monitoring --dry-run=client -o yaml \
  --from-file=ca.crt=/etc/kubernetes/pki/ca.crt \
  --from-file=client.crt=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --from-file=client.key=/etc/kubernetes/pki/apiserver-etcd-client.key | kubectl apply -f -
}

# spin do wait print for circle
function spin() {
  sp='/-\|'
  printf ' '
  sleep 0.5
  while true; do
    printf '\b%.1s' "$sp"
    sp=${sp#?}${sp%???}
    sleep 0.5
  done
}

# cmd_must_exist check whether command is installed.
function cmd_must_exist {
    local CMD
    CMD=$(command -v "${1}")
    if [[ ! -x ${CMD} ]]; then
      echo "please install ${1} and verify they are in \$PATH."
      exit 1
    fi
}

# wait_pod_ready waits for pod state becomes ready until timeout.
# Parmeters:
#  - $1: pod label, such as "app=etcd"
#  - $2: pod namespace, such as "karmada-system"
#  - $3: time out, such as "200s"
function wait_pod_ready() {
    local pod_label=$1
    local pod_namespace=$2
    local wait_timeout=$3

    echo "wait the $pod_label ready..."
    set +e
    kubectl_with_retry wait --for=condition=Ready --timeout=30s pods -l app=${pod_label} -n ${pod_namespace}
    ret=$?
    set -e
    if [ $ret -ne 0 ];then
      echo "kubectl describe info:"
      kubectl describe pod -l app=${pod_label} -n ${pod_namespace}
    fi
    return ${ret}
}

# kubectl_with_retry will retry if execute kubectl command failed
# tolerate kubectl command failure that may happen before the pod is created by  StatefulSet/Deployment.
# default retry 10 times
function kubectl_with_retry() {
    local ret=0
    for i in {1..10}; do
        kubectl "$@"
        ret=$?
        if [[ ${ret} -ne 0 ]]; then
            echo "kubectl $* failed, retrying(${i} times)"
            sleep 1
            continue
        else
            return 0
        fi
    done

    echo "kubectl $* failed"
    kubectl "$@"
    return ${ret}
}

# untaint_single_node removes the control-plane taint from a one-node cluster.
#
# A one-node cluster has to run the platform's own pods, so the taint that keeps
# ordinary workloads off a control plane has to go. k0s --single already leaves
# the node untainted, which is why this only bites the kubeadm path.
#
# Both keys are handled: the key was renamed from `master` to `control-plane`,
# and 1.28 — the version this installer pins — is the last line that uses the old
# one. A member is not necessarily on the same version as its pivot.
#
# Shared by the pivot and the member installers, because the symptom is the same
# on both and only one of them used to do anything about it: the member's pods
# stay Pending with "0/1 nodes are available: 1 node(s) had untolerated taint
# {node-role.kubernetes.io/control-plane}", and the install waits on them.
#
# Takes an optional kubeconfig, because the member installer talks to a cluster
# that is not necessarily the one KUBECONFIG points at.
function untaint_single_node() {
  local kubeconfig=${1:-}
  local kubectl_args=()
  if [ -n "${kubeconfig}" ]; then
    kubectl_args=(--kubeconfig "${kubeconfig}")
  fi

  local nodes node key
  nodes=$(kubectl "${kubectl_args[@]}" get nodes --no-headers 2> /dev/null | wc -l)
  if [ "${nodes}" -ne 1 ]; then
    return 0
  fi

  node=$(kubectl "${kubectl_args[@]}" get nodes --no-headers 2> /dev/null | awk 'NR==1{print $1}')
  if [ -z "${node}" ]; then
    return 0
  fi

  for key in node-role.kubernetes.io/master node-role.kubernetes.io/control-plane; do
    if kubectl "${kubectl_args[@]}" get node "${node}" -o go-template='{{range .spec.taints}}{{.key}}{{"\n"}}{{end}}' 2> /dev/null | grep -qx "${key}"; then
      if kubectl "${kubectl_args[@]}" taint node "${node}" "${key}-" > /dev/null 2>&1; then
        clog info "removed the ${key} taint from ${node}: a one-node cluster runs the platform's pods itself"
      else
        clog warn "could not remove the ${key} taint from ${node}"
      fi
    fi
  done
}

# agent_kubeconfig writes a kubeconfig for a ServiceAccount, using an admin
# kubeconfig only to create it.
#
# The platform keeps a kubeconfig for every cluster it manages, and a warden
# keeps one for the cluster it runs in. Both used to be that cluster's admin
# kubeconfig — a credential that cannot be narrowed and cannot be revoked:
# whoever holds it can do anything to that cluster for as long as it exists. What
# is written here instead is a ServiceAccount token, limited to the ClusterRole
# the caller has already bound to the account and revocable by deleting the
# Secret. The admin kubeconfig stays what it always was: the operator's own
# credential, used at install time and not left behind in a Secret.
#
# The token Secret is of kind kubernetes.io/service-account-token rather than the
# output of `kubectl create token`, which expires in an hour: a member whose
# warden loses its credential an hour after the install is worse than one that
# was never installed at all. The same Secret carries the cluster CA, so nothing
# here has to decode a kubeconfig to find it.
#
#   agent_kubeconfig <admin-kubeconfig> <serviceaccount> <namespace> <output-file>
function agent_kubeconfig() {
  local admin=$1 sa=$2 ns=$3 out=$4
  local secret="${sa}-token"
  local token="" server="" ca="" waited=0

  kubectl --kubeconfig "${admin}" -n "${ns}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${sa}
  namespace: ${ns}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${ns}
  annotations:
    kubernetes.io/service-account.name: ${sa}
type: kubernetes.io/service-account-token
EOF
  if [ $? -ne 0 ]; then
    clog error "could not create ${ns}/${sa}"
    return 1
  fi

  # The token controller fills the Secret in asynchronously.
  while [ "${waited}" -lt 60 ]; do
    token=$(kubectl --kubeconfig "${admin}" -n "${ns}" get secret "${secret}" -o go-template='{{.data.token}}' 2> /dev/null | base64 -d 2> /dev/null || true)
    if [ -n "${token}" ]; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if [ -z "${token}" ]; then
    clog error "no token was issued for ${ns}/${sa} within 60s"
    return 1
  fi

  # ca.crt stays base64: that is exactly what certificate-authority-data wants.
  ca=$(kubectl --kubeconfig "${admin}" -n "${ns}" get secret "${secret}" -o go-template='{{index .data "ca.crt"}}' 2> /dev/null || true)
  server=$(kubectl --kubeconfig "${admin}" config view --minify 2> /dev/null | awk '/^[[:space:]]*server:/{print $2; exit}')

  if [ -z "${ca}" ] || [ -z "${server}" ]; then
    clog error "could not read the CA or the server address for ${ns}/${sa}"
    return 1
  fi

  cat > "${out}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: agent
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: agent
    user:
      token: ${token}
contexts:
  - name: agent
    context:
      cluster: agent
      user: agent
current-context: agent
EOF
  chmod 0600 "${out}"
  clog info "wrote ${out} for ${ns}/${sa}, server ${server}"
}

function helm_download() {
  # Only a host that has no helm needs the download. The offline bundle installs
  # helm itself, and reaching for the distribution host from a machine with no
  # network turns a working install into a failed wget.
  if command -v helm > /dev/null 2>&1; then
    clog info "helm is already installed: $(helm version --short)"
    return 0
  fi

  clog info "download helm bin"
  if [[ $(arch) == x86_64 ]]; then
    wget https://kubecube.nos-eastchina1.126.net/helm/helm-v3.5.4-linux-amd64.tar.gz -O helm.tar.gz
    tar -xzvf helm.tar.gz > /dev/null
    chmod +x linux-amd64/helm
    mv linux-amd64/helm /usr/local/bin/helm
  else
    wget https://kubecube.nos-eastchina1.126.net/helm/helm-v3.6.2-linux-arm64.tar.gz -O helm.tar.gz
    tar -xzvf helm.tar.gz > /dev/null
    chmod +x linux-arm64/helm
    mv linux-arm64/helm /usr/local/bin/helm
  fi
}

function sign_cert() {
  clog info "signing cert..."
  mkdir -p ca
  cd ca

  ns=$1
  extra_ip=$2

  clog debug "generate ca key and ca cert"
  openssl genrsa -out ca.key 2048 > /dev/null
  openssl req -x509 -new -nodes -key ca.key -subj "/CN=*.kubecube-system" -days 10000 -out ca.crt > /dev/null

  clog debug "generate tls key"
  openssl genrsa -out tls.key 2048 > /dev/null

  clog debug "make tls csr"
cat << EOF >csr.conf
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C = ch
ST = zj
L = hz
O = kubecube
CN = *.${ns}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = *.${ns}
DNS.2 = *.${ns}.svc
DNS.3 = *.${ns}.svc.cluster.local
IP.1 = 127.0.0.1
IP.2 = ${extra_ip}

[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names
EOF
  openssl req -new -key tls.key -out tls.csr -config csr.conf

  clog debug "generate tls cert"
  openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -days 10000 -extensions v3_ext -extfile csr.conf
  cd ..
}

# --- the cluster's pod and service networks ----------------------------------
#
# POD_CIDR and SERVICE_CIDR are the one place both distributions read these from.
# kubeadm is told them as networking.podSubnet/serviceSubnet, Calico's IP pool is
# set to the same pod CIDR, and k0s writes them into its own config. The check
# below exists because the failure it prevents is silent: a pod network that
# overlaps the node's own network hands pods addresses the node already answers
# for, services land on the wrong host, and the cluster still reports Ready.

# ip_to_int prints a dotted quad as an integer.
ip_to_int() {
  local IFS=.
  # shellcheck disable=SC2086  # splitting the quad is the point
  local o=($1)
  echo $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

# cidr_bounds prints "<network> <broadcast>" for a CIDR, both as integers.
cidr_bounds() {
  local bits=${1#*/} base mask
  base=$(ip_to_int "${1%/*}")
  mask=0
  if [ "${bits}" -gt 0 ]; then
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  fi
  echo $(( base & mask )) $(( (base & mask) | (~mask & 0xFFFFFFFF) ))
}

# cidr_contains succeeds when the address sits inside the CIDR.
cidr_contains() {
  local bounds net bcast ip
  ip=$(ip_to_int "$2")
  bounds=$(cidr_bounds "$1")
  net=${bounds% *}
  bcast=${bounds#* }
  [ "${ip}" -ge "${net}" ] && [ "${ip}" -le "${bcast}" ]
}

# cidr_overlaps succeeds when two CIDRs share an address.
cidr_overlaps() {
  local a b an ab bn bb
  a=$(cidr_bounds "$1")
  b=$(cidr_bounds "$2")
  an=${a% *}; ab=${a#* }
  bn=${b% *}; bb=${b#* }
  [ "${an}" -le "${bb}" ] && [ "${bn}" -le "${ab}" ]
}

# validate_cidr refuses anything that is not an IPv4 network of /8 to /30.
validate_cidr() {
  local cidr=$1 bits name=${2:-$1}
  if ! [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    clog error "${name} '${cidr}' is not an IPv4 CIDR (expected e.g. 10.244.0.0/16)"
    exit 1
  fi
  bits=${cidr#*/}
  if [ "${bits}" -lt 8 ] || [ "${bits}" -gt 30 ]; then
    clog error "${name} '${cidr}' has a /${bits} prefix; a cluster network is /8 to /30"
    exit 1
  fi
}

# check_cluster_cidrs validates the pair and refuses one that holds this node's
# own addresses.
#
# It is meant for a blank host. On a machine that already runs a cluster the node
# holds its own pod addresses, and the check reports them — re-running the
# installer over an existing cluster is not supported anyway.
check_cluster_cidrs() {
  local pod=${POD_CIDR:-10.244.0.0/16}
  local svc=${SERVICE_CIDR:-10.96.0.0/12}
  local addr

  validate_cidr "${pod}" "POD_CIDR"
  validate_cidr "${svc}" "SERVICE_CIDR"

  if cidr_overlaps "${pod}" "${svc}"; then
    clog error "POD_CIDR ${pod} overlaps SERVICE_CIDR ${svc}; the two networks have to be disjoint"
    exit 1
  fi

  # The node's addresses come from the interfaces, not from `hostname -I`: that one
  # answers with the addresses resolved for the hostname, and on this very machine
  # it omitted the second NIC — the exact address a pod network must not contain.
  # Interfaces the CNI and docker create are skipped so a leftover pod address is
  # not mistaken for the node's.
  local addrs
  addrs=$(ip -4 -o addr show 2> /dev/null \
    | awk '$2 !~ /^(cali|veth|docker|cni0|tunl0|cilium|lxc|flannel)/ {print $4}' \
    | cut -d/ -f1)

  for addr in ${addrs}; do
    if cidr_contains "${pod}" "${addr}"; then
      clog error "POD_CIDR ${pod} contains this node's own address ${addr}: pods would be handed addresses the node answers for. Pick a pod network outside the node's subnet, e.g. 172.20.0.0/16 or 100.64.0.0/16"
      exit 1
    fi
    if cidr_contains "${svc}" "${addr}"; then
      clog error "SERVICE_CIDR ${svc} contains this node's own address ${addr}; pick a service network outside the node's subnet"
      exit 1
    fi
  done

  clog info "cluster networks: pods ${pod}, services ${svc}"
}