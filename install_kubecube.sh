#!/usr/bin/env bash
#
# Installs the platform chart on the pivot cluster.
#
# The values written here are the difference between "the chart's defaults" and
# "a cluster this installer just built". The chart's defaults assume a full
# upstream cluster and an online registry: they enable the monitoring and thanos
# hotplugs, they enable the console and the cloud shell, and they point at
# upstream image tags. None of that survives an offline arm64 install, so every
# one of those is written out explicitly below.

source /etc/kubecube/manifests/utils.sh
source /etc/kubecube/manifests/install.conf

# The bundle records the image tag it was built with, so the values here and the
# images imported into the cluster come from one place. Guessing the tag would
# produce a release that never pulls.
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

if [ -z "${KUBECUBE_IMAGE_REGISTRY}" ]; then
  KUBECUBE_IMAGE_REGISTRY="docker.io"
fi
if [ -z "${KUBECUBE_IMAGE_PROJECT}" ]; then
  KUBECUBE_IMAGE_PROJECT="kubecube"
fi

if [ "$(kubectl get nodes | wc -l)" -eq 2 ]
then
  # A one-node cluster has to run the platform's pods itself. k0s --single
  # already leaves the node untainted, so this only bites the kubeadm path; the
  # removal is harmless when there is no taint to remove.
  #
  # The removal itself lives in utils.sh because the member installer needs the
  # same thing for the same reason, on a cluster whose kubeconfig is not the one
  # KUBECONFIG points at.
  echo "[WARN]delete taint of master node while only one node found"
  untaint_single_node
fi

if [ ! -z ${KUBERNETES_BIND_ADDRESS} ]; then
  IPADDR=${KUBERNETES_BIND_ADDRESS}
fi

function render_values() {
  # k0s ships its own metrics-server, and the chart's subchart collides with it:
  # helm refuses to adopt the ServiceAccount k0s already created, and the whole
  # release fails with "exists and cannot be imported into the current release".
  # The cluster has metrics either way; this only decides who provides them.
  local metric_server="${METRIC_SERVER_ENABLE}"
  if [ "${KUBERNETES_DISTRO}" = "k0s" ]; then
    metric_server="false"
  fi

  # The metrics-server reference, chosen the way the bundle chose it: the public
  # mirror on a cn build, the project's own name elsewhere. A value that names a
  # registry is used as written by the sub chart, so the release pulls exactly what
  # the bundle carries.
  local metrics_server_image
  if [ "${ZONE}" = "cn" ]; then
    metrics_server_image="registry.cn-hangzhou.aliyuncs.com/google_containers/metrics-server:v0.7.2"
  else
    metrics_server_image="metrics-server:${KUBECUBE_IMAGE_TAG}"
  fi

  clog info "render pivot values for kubecube chart values (image tag ${KUBECUBE_IMAGE_TAG})"
cat > render-values.yaml <<EOF
# pivot-value.yaml
#
# Written by install_kubecube.sh. Every key here is a deliberate deviation from
# the chart's defaults; see the comments at the top of that script.

global:
  # control-plane node IP which is used for exporting NodePort svc.
  nodeIP: ${IPADDR}

  hub:
    registry: ${KUBECUBE_IMAGE_REGISTRY}
    project: ${KUBECUBE_IMAGE_PROJECT}

  # The images this installer put into the cluster, all built together and all
  # carrying the same tag.
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
    metricsServer: ${metrics_server_image}
    cfssl: cfssl:${KUBECUBE_IMAGE_TAG}
    kubectl: bitnami-kubectl:${KUBECUBE_IMAGE_TAG}

  # the pre-install job mints the platform's TLS material with the bundled
  # cfssl image.
  certs:
    mode: auto

  # The hotplugs pull monitoring, thanos, logseer, logagent and elasticsearch,
  # which is several gigabytes of images this installer never staged. A cluster
  # that enables them installs nothing but ImagePullBackOff.
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

  componentsEnable:
    kubecube: "true"
    warden: "true"
    audit: "true"
    webconsole: "true"
    cloudshell: "${CLOUDSHELL_ENABLE}"
    frontend: "${FRONTEND_ENABLE}"

  dependencesEnable:
    ingressController: "${INGRESS_CONTROLLER_ENABLE}" # set "true" to deploy if ingress is not already in cluster.
    localPathStorage: "${LOCAL_PATH_STORAGE_ENABLE}"
    metricServer: "${metric_server}" # k0s ships its own, so this stays "false" there.

  localKubeConfig: $(cat /root/.kube/config | base64 -w 0) # local cluster kubeconfig base64
  pivotKubeConfig: $(cat /root/.kube/config | base64 -w 0) # pivot cluster kubeconfig base64

warden:
  containers:
    warden:
      args:
        cluster: "pivot-cluster"  # set current cluster name
EOF
}

# wait_platform_ready reports what is actually running, so a failed install says
# which component failed instead of only that helm gave up.
#
# The deployment count is part of the condition, not decoration: an empty
# namespace also has nothing that is not ready, so "no pod is unready" alone
# reports success for a release that installed nothing at all.
function wait_platform_ready() {
  clog info "waiting for the platform components"
  local expected=4
  local deadline=$((SECONDS + 600))
  while [ ${SECONDS} -lt ${deadline} ]; do
    local deploys not_ready
    deploys=$(kubectl -n "${INSTALL_NAMESPACE}" get deploy --no-headers 2> /dev/null | wc -l)
    not_ready=$(kubectl -n "${INSTALL_NAMESPACE}" get pods --no-headers 2> /dev/null \
      | grep -v -e " Running " -e " Completed " | wc -l)
    if [ "${deploys}" -ge "${expected}" ] && [ "${not_ready}" -eq 0 ]; then
      kubectl -n "${INSTALL_NAMESPACE}" get deploy
      kubectl -n "${INSTALL_NAMESPACE}" get pods
      return 0
    fi
    sleep 10
  done

  clog error "the platform did not become ready in 600s (${deploys:-0} deployment(s) found, expected at least ${expected})"
  kubectl -n "${INSTALL_NAMESPACE}" get deploy
  kubectl -n "${INSTALL_NAMESPACE}" get pods
  kubectl -n "${INSTALL_NAMESPACE}" describe pods | tail -100
  exit 1
}

render_values

clog info "deploy kubecube"
/usr/local/bin/helm install kubecube -n ${INSTALL_NAMESPACE} --create-namespace /etc/kubecube/kubecube-chart -f ./render-values.yaml --wait --timeout 15m

wait_platform_ready
clog info "kubecube is up in namespace ${INSTALL_NAMESPACE}"
