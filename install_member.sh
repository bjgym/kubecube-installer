#!/usr/bin/env bash
#
# Installs the platform's member side into a cluster that a pivot elsewhere
# manages.
#
# A member is the same chart with the pivot's own components switched off. That
# single switch is what makes the chart render a member: with
# componentsEnable.kubecube off, the warden agent dials the pivot at
# global.nodeIP:30443 instead of an in-cluster service, and it registers itself
# with the pivot (wardenRegisterModeEnable is on by default), so nothing is ever
# pushed into this cluster from the other side.
#
# Everything it needs is already in the offline bundle: the same images, the same
# chart, the same tag.
#
# Install it with INSTALL_KUBECUBE_MEMBER="true" and:
#
#   PIVOT_CUBE_HOST   the pivot's reachable API NodePort, <pivotIP>:30443
#   PIVOT_KUBECONFIG  a kubeconfig for the pivot, which the warden uses to talk
#                     to the platform (default /root/.kube/config)
#   MEMBER_KUBECONFIG the kubeconfig of the cluster being joined
#                     (default /etc/kubernetes/admin.conf)
#   MEMBER_CLUSTER_NAME the name the member registers under (default: hostname)

source /etc/kubecube/manifests/utils.sh
source /etc/kubecube/manifests/install.conf

# The bundle records the image tag it was built with; guessing it produces a
# release that never pulls.
if [ "${OFFLINE}" = "true" ]; then
  if [ ! -f "${OFFLINE_BUNDLE_DIR}/bundle.env" ]; then
    clog error "${OFFLINE_BUNDLE_DIR}/bundle.env is missing"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${OFFLINE_BUNDLE_DIR}/bundle.env"
fi

if [ -z "${KUBECUBE_IMAGE_TAG}" ]; then
  clog error "KUBECUBE_IMAGE_TAG is empty: offline installs take it from bundle.env, online installs have to set it in install.conf"
  exit 1
fi

if [ -z "${KUBECUBE_IMAGE_REGISTRY}" ]; then KUBECUBE_IMAGE_REGISTRY="docker.io"; fi
if [ -z "${KUBECUBE_IMAGE_PROJECT}" ]; then KUBECUBE_IMAGE_PROJECT="kubecube"; fi

PIVOT_CUBE_HOST=${PIVOT_CUBE_HOST:-}
PIVOT_KUBECONFIG=${PIVOT_KUBECONFIG:-/root/.kube/config}
MEMBER_KUBECONFIG=${MEMBER_KUBECONFIG:-/etc/kubernetes/admin.conf}
MEMBER_CLUSTER_NAME=${MEMBER_CLUSTER_NAME:-$(hostname)}

if [ -z "${PIVOT_CUBE_HOST}" ]; then
  clog error "PIVOT_CUBE_HOST must be set to the pivot's API NodePort, for example 10.211.55.5:30443"
  exit 1
fi
if [ ! -f "${MEMBER_KUBECONFIG}" ]; then
  clog error "${MEMBER_KUBECONFIG} does not exist: point MEMBER_KUBECONFIG at this cluster's kubeconfig"
  exit 1
fi
if [ ! -f "${PIVOT_KUBECONFIG}" ]; then
  clog error "${PIVOT_KUBECONFIG} does not exist: the warden needs a kubeconfig for the pivot"
  exit 1
fi

# The member registers by reporting its own kubeconfig, and the pivot then dials
# the `server:` in it. A loopback address there registers the member
# successfully and breaks every request afterwards, which reads as a broken
# member rather than as a kubeconfig the pivot cannot reach.
if grep -qE 'server:[[:space:]]*https?://(127\.0\.0\.1|localhost)' "${MEMBER_KUBECONFIG}"; then
  clog error "${MEMBER_KUBECONFIG} points at a loopback address; the pivot has to be able to reach this cluster's API server"
  exit 1
fi

# PIVOT_KUBECONFIG has to be the pivot's. If it is this cluster's own, the warden
# registers the member into itself: the CRD is already here, the Cluster object
# is created here, the pivot never hears about it — and the helm release still
# goes green, so nothing points at the mistake.
if ! KUBECONFIG="${PIVOT_KUBECONFIG}" kubectl -n "${INSTALL_NAMESPACE:-kubecube-system}" get deploy kubecube > /dev/null 2>&1; then
  clog error "no kubecube deployment in ${INSTALL_NAMESPACE:-kubecube-system} through ${PIVOT_KUBECONFIG}: that kubeconfig does not point at a pivot"
  exit 1
fi

# The chart's own namespace, so the member's warden lands where the pivot expects
# to find it.
NS=${INSTALL_NAMESPACE:-kubecube-system}

# open_member_apiserver lets the pivot reach this cluster's API server.
#
# Registration runs the other way: the member's warden dials out to the pivot, so
# onboarding looks healthy while the pivot is unable to dial back — and it stays
# unable. What that produces is a Cluster stuck at `processing` while its warden
# is 1/1 on this side, and "confirm warden in cluster <name> failed, try
# redeploy" in the pivot's cube log.
#
# On a host that filters inbound traffic — UFW's default posture on Ubuntu — the
# API server's port has to be opened to the pivot explicitly. The kubeadm path
# sets only the FORWARD policy, and nothing else in either installer knows the
# pivot's address, which is why this is here rather than in install_k8s.sh.
function open_member_apiserver() {
  local pivot_ip=${PIVOT_CUBE_HOST%%:*}
  local port=${APISERVER_PORT:-6443}

  case "${pivot_ip}" in
    '' | *[!0-9.]*)
      # A name resolves to whatever it resolves to on the pivot's own side, and
      # opening a port to something this host cannot resolve is guesswork.
      clog warn "PIVOT_CUBE_HOST is not an IPv4 literal; if this host filters inbound traffic, open port ${port} to the pivot by hand"
      return 0
      ;;
  esac

  if command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q "^Status: active"; then
    if ufw allow from "${pivot_ip}" to any port "${port}" proto tcp > /dev/null 2>&1; then
      clog info "allowed ${pivot_ip} to reach this cluster's API server on ${port} (ufw)"
    else
      clog warn "could not add the ufw rule for ${pivot_ip} to reach ${port}"
    fi
    return 0
  fi

  if iptables -S INPUT 2> /dev/null | grep -q "^-P INPUT DROP"; then
    while iptables -D INPUT -s "${pivot_ip}" -p tcp --dport "${port}" -j ACCEPT > /dev/null 2>&1; do :; done
    if iptables -I INPUT 1 -s "${pivot_ip}" -p tcp --dport "${port}" -j ACCEPT > /dev/null 2>&1; then
      clog info "allowed ${pivot_ip} to reach this cluster's API server on ${port} (iptables)"
      # Said plainly: a rule added here is gone at the next boot, and a member
      # that stops answering after a reboot is a confusing failure to debug.
      clog warn "that rule does not survive a reboot: make it permanent in this host's firewall configuration"
    else
      clog warn "could not add the iptables rule for ${pivot_ip} to reach ${port}"
    fi
    return 0
  fi

  clog info "this host does not filter inbound traffic; the pivot can already reach its API server"
}

# The pivot's JWT secret, written into both of the keys that have to agree. The
# default is the chart's own default, which is what a pivot installed without
# overriding it uses.
PIVOT_JWT_SECRET=${PIVOT_JWT_SECRET:-56F0D8DB90241C6E}

# render_values takes the two kubeconfigs to embed. It is called twice: once with
# the operator's own credentials, which is what creates the ServiceAccounts and
# roles the scoped credentials are for, and once with the scoped ones, so that
# what stays in the Secret is never an admin kubeconfig.
function render_values() {
  local local_kubeconfig=$1 pivot_kubeconfig=$2
  clog info "render member values for the kubecube chart (image tag ${KUBECUBE_IMAGE_TAG})"
  cat > member-values.yaml << EOF
# Written by install_member.sh. The pivot's components are off, which is what
# makes this a member rather than a pivot; see the comments at the top.
global:
  # The pivot's address: the member's warden dials it, because with
  # componentsEnable.kubecube off the chart renders no in-cluster cube service to
  # talk to.
  nodeIP: ${PIVOT_CUBE_HOST%%:*}

  hub:
    registry: ${KUBECUBE_IMAGE_REGISTRY}
    project: ${KUBECUBE_IMAGE_PROJECT}

  images:
    kubecube: kubecube:${KUBECUBE_IMAGE_TAG}
    warden: warden:${KUBECUBE_IMAGE_TAG}
    wardenInit: warden-init:${KUBECUBE_IMAGE_TAG}
    audit: audit:${KUBECUBE_IMAGE_TAG}
    webconsole: webconsole:${KUBECUBE_IMAGE_TAG}
    cloudshell: cloudshell:${KUBECUBE_IMAGE_TAG}
    frontend: frontend:${KUBECUBE_IMAGE_TAG}
    dependenceJob: warden-dependence:${KUBECUBE_IMAGE_TAG}
    ingressController: ingress-nginx-controller:${KUBECUBE_IMAGE_TAG}
    ingressControllerJob: ingress-nginx-kube-webhook-certgen:${KUBECUBE_IMAGE_TAG}
    localPathStorageProvisioner: rancher-local-path-provisioner:${KUBECUBE_IMAGE_TAG}
    cfssl: cfssl:${KUBECUBE_IMAGE_TAG}
    kubectl: bitnami-kubectl:${KUBECUBE_IMAGE_TAG}

  certs:
    mode: auto

  hotPlugEnable:
    pivot:
      logseer: "disabled"
      logagent: "disabled"
      elasticsearch: "disabled"
      monitoring: "disabled"
      thanos: "disabled"
    common:
      logseer: "disabled"
      logagent: "disabled"
      elasticsearch: "disabled"
      monitoring: "disabled"
      thanos: "disabled"

  # Only the agent. Everything else in this chart belongs to a pivot, and a
  # member that renders it installs a second control plane into itself.
  componentsEnable:
    kubecube: "false"
    warden: "true"
    audit: "false"
    webconsole: "false"
    # The member runs its own shell. No extra permission is needed for that: the
    # pod fetches the user's kubeconfig from the pivot at
    # https://<global.nodeIP>:30443, and nodeIP above is already the pivot's host.
    # Leaving this false makes every shell request fall back to the pivot's pod,
    # which works but puts the session's jail and its pod in different clusters.
    cloudshell: "true"
    frontend: "false"

  dependencesEnable:
    ingressController: "false"
    localPathStorage: "false"
    metricServer: "false"

  # local: this cluster. pivot: the platform, which the warden uses to report in.
  localKubeConfig: $(base64 -w 0 < "${local_kubeconfig}")
  pivotKubeConfig: $(base64 -w 0 < "${pivot_kubeconfig}")

warden:
  containers:
    warden:
      # The JWT secret is two unlinked keys that have to agree: the pivot's cube
      # mints tokens with kubecube.env.jwtSecret, and this cluster's warden
      # validates them with warden.containers.warden.env.JWTSecret. The chart's
      # defaults happen to be the same literal, so leaving both alone works
      # until the pivot was installed with something else — and then the only
      # symptom is that user kubeconfigs stop working, with nothing in the logs
      # pointing at the secret.
      env:
        JWTSecret: "${PIVOT_JWT_SECRET}"
      args:
        cluster: "${MEMBER_CLUSTER_NAME}"
        inMemberCluster: "true"
        isClusterWritable: "true"

# The other half of that pair, on the component that mints the tokens.
kubecube:
  env:
    jwtSecret: "${PIVOT_JWT_SECRET}"
EOF
}

# wait_member_ready reports what is running, so a failure names the component
# rather than only saying helm gave up.
function wait_member_ready() {
  clog info "waiting for the member's warden"
  local deadline=$((SECONDS + 600))
  while [ ${SECONDS} -lt ${deadline} ]; do
    local deploys not_ready
    deploys=$(KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get deploy --no-headers 2> /dev/null | wc -l)
    not_ready=$(KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get pods --no-headers 2> /dev/null \
      | grep -v -e " Running " -e " Completed " | wc -l)
    if [ "${deploys}" -ge 1 ] && [ "${not_ready}" -eq 0 ]; then
      KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get deploy
      KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get pods
      return 0
    fi
    sleep 10
  done

  clog error "the member's warden did not become ready in 600s"
  KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get deploy
  KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get pods
  KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" describe pods | tail -80
  exit 1
}

# Two single-line omissions that both surface as something else. A one-node
# member keeps the control-plane taint, so its own warden never schedules and the
# install waits out its timeout. And an unopened API server port leaves the pivot
# unable to dial the cluster it just registered, which reads as a broken member.
untaint_single_node "${MEMBER_KUBECONFIG}"
open_member_apiserver

render_values "${MEMBER_KUBECONFIG}" "${PIVOT_KUBECONFIG}"

clog info "deploy the member side as ${MEMBER_CLUSTER_NAME}, registering with ${PIVOT_CUBE_HOST}"
KUBECONFIG="${MEMBER_KUBECONFIG}" /usr/local/bin/helm upgrade --install kubecube -n "${NS}" --create-namespace \
  /etc/kubecube/kubecube-chart -f ./member-values.yaml --wait --timeout 15m

# The scoped credentials, now that the chart has created the ServiceAccounts and
# the roles they are for.
#
# Two passes rather than one because of the order the objects have to exist in: a
# kubeconfig is an *input* to the chart, and the ServiceAccount it names is
# created *by* that chart. The first pass carries the operator's own kubeconfigs
# and exists to create the accounts and rules; the second replaces both with
# ServiceAccount tokens bound to templates/agent-rbac.yaml, so what stays in the
# Secret afterwards — and what the warden registers with the pivot as this
# cluster's kubeconfig — is a token that can be revoked and that carries no
# secret read, no node write and no exec.
member_agent_kubeconfig=/etc/kubecube/member-agent.kubeconfig
pivot_agent_kubeconfig=/etc/kubecube/pivot-agent.kubeconfig

clog info "mint the scoped credentials"
agent_kubeconfig "${MEMBER_KUBECONFIG}" kubecube-member-agent "${NS}" "${member_agent_kubeconfig}" || exit 1
agent_kubeconfig "${PIVOT_KUBECONFIG}" warden-agent "${NS}" "${pivot_agent_kubeconfig}" || exit 1

render_values "${member_agent_kubeconfig}" "${pivot_agent_kubeconfig}"
clog info "re-deploy the member side with the scoped credentials"
KUBECONFIG="${MEMBER_KUBECONFIG}" /usr/local/bin/helm upgrade --install kubecube -n "${NS}" --create-namespace \
  /etc/kubecube/kubecube-chart -f ./member-values.yaml --wait --timeout 15m

# The kubeconfigs live in a Secret, and a Secret change does not roll a
# Deployment. The warden reads both files once at startup, so without this it
# goes on using whatever it read before — the admin kubeconfig the first pass
# gave it — and the second pass buys nothing while every check still looks green.
clog info "restart the warden so it picks the scoped credentials up"
KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" rollout restart deploy/warden
KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" rollout status deploy/warden --timeout=300s

# The pivot reads this cluster's kubeconfig from the Cluster CR, and the warden's
# registration only ever creates that object: it treats AlreadyExists as success
# and never updates it. So the scoped credential has to be written where the
# pivot actually looks, or the pivot goes on dialling the member with whatever
# the first pass registered — an admin kubeconfig, held by the cluster the
# platform is meant to be managing with limited rights.
#
# A merge patch of that single field, not a re-apply of the object: applying a
# full dump makes the platform re-ensure the member's resources, and the tenancy
# objects it rewrites then carry an empty pivotResourceVersion, which its own
# sync path cannot parse (strconv.Atoi fails and the object is skipped for good).
cluster_creds_patch=/tmp/kubecube-member-kubeconfig-patch.yaml
cat > "${cluster_creds_patch}" <<EOF
spec:
  kubeconfig: $(base64 -w 0 < "${member_agent_kubeconfig}")
EOF

if KUBECONFIG="${PIVOT_KUBECONFIG}" kubectl get cluster "${MEMBER_CLUSTER_NAME}" > /dev/null 2>&1; then
  if KUBECONFIG="${PIVOT_KUBECONFIG}" kubectl patch cluster "${MEMBER_CLUSTER_NAME}" --type merge \
    --patch-file "${cluster_creds_patch}" > /dev/null; then
    clog info "registered the scoped credential on the pivot's Cluster ${MEMBER_CLUSTER_NAME}"
  else
    clog warn "could not write the scoped credential to the Cluster CR: the pivot keeps the credential it already has"
  fi
else
  # Not a failure: the warden registers this cluster itself, and on a first
  # install that has not happened yet. A later run finds the Cluster and writes it.
  clog warn "the pivot has no Cluster ${MEMBER_CLUSTER_NAME} yet; it registers itself, so re-run this script to record the scoped credential"
fi
rm -f "${cluster_creds_patch}"

# The chart's warden Service is a NodePort whose three ports (31443, 32444,
# 32445) are hardcoded in the template with no values key. On a host that also
# runs a pivot those ports already belong to the pivot's warden, and the
# collision is worse than a failed bind: the platform rewrites every cluster's
# kubeconfig host from 6443 to 31443, so a user's member kubeconfig can end up
# talking to the pivot's warden, whose auth proxy forwards to its own cluster.
#
# Nothing here needs those ports published. Registration dials out to the pivot,
# and the member's webhook addresses this Service by its cluster DNS name, so
# making it ClusterIP removes both the collision and the ambiguity.
if KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" get svc warden > /dev/null 2>&1; then
  clog info "making the member's warden Service ClusterIP: its NodePorts are hardcoded and would collide with the pivot's"
  KUBECONFIG="${MEMBER_KUBECONFIG}" kubectl -n "${NS}" patch svc warden --type merge -p '{"spec":{"type":"ClusterIP"}}' > /dev/null
fi

wait_member_ready
clog info "member ${MEMBER_CLUSTER_NAME} is up; the pivot should now list it"
