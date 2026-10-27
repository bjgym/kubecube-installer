#!/usr/bin/env bash

set -e

DOCKER_VER=19.03.8
BASE="/etc/kubecube"
K8S_REGISTR="k8s.gcr.io"
CN_K8S_REGISTR="registry.cn-hangzhou.aliyuncs.com/google_containers"
CRI_DOCKERD_VERSION=0.3.0

source /etc/kubecube/manifests/install.conf
source /etc/kubecube/manifests/utils.sh

RELEASE=v${KUBERNETES_VERSION}

function docker_bin_get() {
  systemctl status docker|grep Active|grep -q running && { clog warn "docker is already running."; return 0; }

  if [[ -f "$BASE/down/docker-${DOCKER_VER}.tgz" ]];then
    clog warn "docker binaries already existed"
  else
    if [[ "$OFFLINE_INSTALL" == "true" ]]; then
      clog info "get docker binary from local"
      /bin/mv -f "${OFFLINE_PKG_PATH}/docker-$DOCKER_VER.tgz" "$BASE/down"
    else
      docker_bin_download
    fi
  fi

  tar zxf "$BASE/down/docker-$DOCKER_VER.tgz" -C "$BASE/down" && \
  /bin/cp -f "$BASE"/down/docker/* "$BASE/bin" && \
  /bin/mv -f "$BASE"/down/docker/* /usr/bin
#  ln -sf /usr/bin/docker /bin/docker
}

function docker_bin_download() {
  if [[ "$ZONE" == cn ]];then
    DOCKER_URL="https://kubecube.nos-eastchina1.126.net/docker-ce/linux/static/stable/$(arch)/docker-${DOCKER_VER}.tgz"
    #DOCKER_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable/$(arch)/docker-${DOCKER_VER}.tgz"
  else
    DOCKER_URL="https://download.docker.com/linux/static/stable/$(arch)/docker-${DOCKER_VER}.tgz"
  fi

  clog info "downloading docker binaries, version $DOCKER_VER"
  if [[ -e /usr/bin/curl ]];then
    curl -C- -O --retry 3 "$DOCKER_URL" || { clog error "downloading docker failed"; exit 1; }
  else
    wget -c "$DOCKER_URL" || { clog error "downloading docker failed"; exit 1; }
  fi
  /bin/mv -f "./docker-$DOCKER_VER.tgz" "$BASE/down"
}

function install_docker() {
  # check if a container runtime is already installed
  systemctl status docker|grep Active|grep -q running && { clog warn "docker is already running."; return 0; }

  clog debug "generate docker service file"

  # config docker service for systemd
  if [[ $(arch) == aarch64 ]]; then
  cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
[Service]
Environment="PATH=/usr/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStart=/usr/bin/dockerd
ExecStartPost=/sbin/iptables -I FORWARD -s 0.0.0.0/0 -j ACCEPT
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
  else
  cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
[Service]
Environment="PATH=/usr/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStartPre=/sbin/iptables -F
ExecStartPre=/sbin/iptables -X
ExecStartPre=/sbin/iptables -F -t nat
ExecStartPre=/sbin/iptables -X -t nat
ExecStartPre=/sbin/iptables -F -t raw
ExecStartPre=/sbin/iptables -X -t raw
ExecStartPre=/sbin/iptables -F -t mangle
ExecStartPre=/sbin/iptables -X -t mangle
ExecStart=/usr/bin/dockerd
ExecStartPost=/sbin/iptables -P INPUT ACCEPT
ExecStartPost=/sbin/iptables -P OUTPUT ACCEPT
ExecStartPost=/sbin/iptables -P FORWARD ACCEPT
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
  fi

  cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
[Service]
Environment="PATH=/usr/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStartPre=/sbin/iptables -F
ExecStartPre=/sbin/iptables -X
ExecStartPre=/sbin/iptables -F -t nat
ExecStartPre=/sbin/iptables -X -t nat
ExecStartPre=/sbin/iptables -F -t raw
ExecStartPre=/sbin/iptables -X -t raw
ExecStartPre=/sbin/iptables -F -t mangle
ExecStartPre=/sbin/iptables -X -t mangle
ExecStart=/usr/bin/dockerd
ExecStartPost=/sbin/iptables -P INPUT ACCEPT
ExecStartPost=/sbin/iptables -P OUTPUT ACCEPT
ExecStartPost=/sbin/iptables -P FORWARD ACCEPT
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF

  # configuration for dockerd
  mkdir -p /etc/docker

  CGROUP_DRIVER="systemd"

  if [[ $(arch) == x86_64 ]]; then
  clog debug "generate docker config: /etc/docker/daemon.json"
  if [[ "$ZONE" == cn ]];then
    clog debug "prepare register mirror for $ZONE"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "http://hub-mirror.c.163.com"
  ],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  else
    clog debug "standard config without registry mirrors"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  fi
  else
  if [[ "$ZONE" == cn ]];then
    clog debug "prepare register mirror for $ZONE"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "http://hub-mirror.c.163.com"
  ],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  else
    clog debug "standard config without registry mirrors"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  fi
  fi

  # start docker service
  if [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
    clog debug "turn off selinux in CentOS/Redhat"
    getenforce|grep Disabled || setenforce 0
    sed -i 's/^SELINUX=.*$/SELINUX=disabled/g' /etc/selinux/config
  fi

  clog debug "enable and start docker"
  systemctl enable docker
  systemctl daemon-reload && systemctl restart docker && sleep 4
}

function containerd_installed(){
  CONTAINERD_VERSION=1.5.5
  # if docker exist, then exit
  if command -v docker >/dev/null 2>&1; then
    clog info 'exists docker, please remove docker, or update CONTAINER_RUNTIME value as docker in install.conf `'
    return
  fi
  systemctl disable docker --now || true

  if command -v ctr >/dev/null 2>&1; then
    clog info 'exists containerd'
    return
  fi

  if [[ "$OFFLINE_INSTALL" == "true" ]]; then
    # The online path untars a containerd release tarball from the distribution
    # host. Offline the bundle carries packages instead, which is also the only
    # way to get runc and the rest of containerd's dependencies with it: the
    # release tarball has no runc in it.
    clog info "installing containerd from the bundle's packages"
    if ! dpkg -i "${OFFLINE_PKG_PATH}"/*.deb; then
      clog error "installing the bundled container runtime packages failed"
      exit 1
    fi
    if ! command -v ctr >/dev/null 2>&1; then
      clog error "ctr is still missing after installing the bundled packages"
      exit 1
    fi
    clog info "install containerd success"
    return
  fi

  os_arch="amd64"
  if [[ $(arch) == aarch64 ]]; then
    os_arch="arm64"
  fi

  wget https://kubecube.nos-eastchina1.126.net/containerd/"$CONTAINERD_VERSION"/containerd-"$CONTAINERD_VERSION"-linux-$os_arch.tar.gz -O containerd.tar.gz

  tar -C / -xzf containerd.tar.gz
  rm -rf containerd.tar.gz
  if command -v ctr >/dev/null 2>&1; then
    clog info "install containerd success"
  else
    clog error "install containerd fail"
    exit 1
  fi
}

function containerd_configuration() {
  #configuration net
  cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  sysctl --system

  #configuration containerd
  mkdir /etc/containerd || true
  containerd config default > /etc/containerd/config.toml
  sed -i '/SystemdCgroup = false/d' /etc/containerd/config.toml
  sed -i '/containerd.runtimes.runc.options/a\ \ \ \ \ \ \ \ \ \ \ \ SystemdCgroup = true' /etc/containerd/config.toml
  systemctl daemon-reload
  systemctl enable containerd --now || true

  #configuration pause
  #
  # Offline the pause image is already in the bundle, under the name images.list
  # gives it, so the config has to name that same image: a sandbox_image the
  # bundle does not carry is a cluster whose pods never start, and containerd 2.x
  # defaults to registry.k8s.io/pause:3.10.1 — newer than the pause a 1.28 cluster
  # ships with — which an offline machine cannot pull.
  #
  # Added rather than rewritten: containerd 2.x's default config carries no
  # sandbox_image line at all. And kubelet's --pod-infra-container-image no longer
  # decides this, which is what its deprecation warning says: kubelet asks CRI.
  if [[ "$OFFLINE_INSTALL" == "true" ]]; then
    # Computed here rather than read from REGISTRY and PAUSE_VERSION, which are
    # set later in the run — this function is called before both, and the empty
    # values silently produced sandbox_image = "/pause:", which containerd
    # accepts and the kubelet then fails to resolve.
    local pause_registry="${K8S_REGISTR}"
    if [[ "$ZONE" == cn ]]; then
      pause_registry="${CN_K8S_REGISTR}"
    fi
    local pause_version="${PAUSE_VERSION:-3.9}"
    local sandbox="${pause_registry}/pause:${pause_version}"

    # Which table the key belongs to changed: containerd 2.x split the CRI plugin
    # and sandbox_image moved to io.containerd.cri.v1.images, while 1.x keeps it
    # in io.containerd.grpc.v1.cri. Writing it in the wrong table is accepted in
    # silence and ignored, which leaves the kubelet looking for the pause image
    # containerd defaults to — registry.k8s.io/pause:3.10.1 on 2.2, which an
    # offline machine cannot pull. The section headers are indented, so the match
    # allows leading space and the inserted line copies it.
    local cri_table=""
    local candidate
    for candidate in 'io\.containerd\.cri\.v1\.images' 'io\.containerd\.grpc\.v1\.cri'; do
      if grep -qE "^[[:space:]]*\[plugins\.[^]]*${candidate}" /etc/containerd/config.toml; then
        cri_table="${candidate}"
        break
      fi
    done

    if [ -n "${cri_table}" ]; then
      awk -v img="${sandbox}" -v table="${cri_table}" '
        { print }
        !done && $0 ~ "^[[:space:]]*\\[plugins\\.[^]]*" table {
          match($0, /^[[:space:]]*/)
          print substr($0, 1, RLENGTH) "sandbox_image = \"" img "\""
          done = 1
        }
      ' /etc/containerd/config.toml > /etc/containerd/config.toml.new
      mv /etc/containerd/config.toml.new /etc/containerd/config.toml
    else
      # No CRI section at all: write the table the modern layout expects.
      cat >> /etc/containerd/config.toml <<EOF

[plugins.'io.containerd.cri.v1.images']
  sandbox_image = "${sandbox}"
EOF
    fi

    # containerd 2.x reads the sandbox image from
    # [plugins.'io.containerd.cri.v1.images'.pinned_images] sandbox = ... and
    # ignores sandbox_image, which is the key 1.x uses. Writing only
    # sandbox_image looked right in the file and changed nothing: the kubelet kept
    # asking for registry.k8s.io/pause:3.10.1, containerd's own default, which an
    # offline machine cannot pull, and every pod failed with CreatePodSandbox.
    # Both keys are written, because containerd accepts and ignores the one it
    # does not use.
    if grep -qE "^[[:space:]]*\[plugins\.[^]]*pinned_images\]" /etc/containerd/config.toml; then
      if grep -qE "^[[:space:]]*sandbox[[:space:]]*=" /etc/containerd/config.toml; then
        sed -i -E "s|^[[:space:]]*sandbox[[:space:]]*=.*|      sandbox = \"${sandbox}\"|" /etc/containerd/config.toml
      else
        awk -v img="${sandbox}" '
          { print }
          !done && /^[[:space:]]*\[plugins\.[^]]*pinned_images\]/ {
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "  sandbox = \"" img "\""
            done = 1
          }
        ' /etc/containerd/config.toml > /etc/containerd/config.toml.new
        mv /etc/containerd/config.toml.new /etc/containerd/config.toml
      fi
    fi

    if grep -qE "sandbox_image = \"${pause_registry}/pause:" /etc/containerd/config.toml; then
      clog debug "containerd sandbox_image: $(grep sandbox_image /etc/containerd/config.toml | head -1 | tr -s ' ')"
      clog debug "containerd cri table: ${cri_table:-appended io.containerd.cri.v1.images}"
    else
      clog error "the containerd sandbox_image is missing or malformed; the kubelet would look for the pause image containerd defaults to and never find it offline"
      exit 1
    fi

    # The daemon was started earlier in this same function, before this edit, so
    # it is running the config from before the edit: containerd only reads
    # /etc/containerd/config.toml at startup, and "enable --now" on a running
    # unit does nothing. Without this restart everything above is written,
    # verified and then ignored.
    systemctl restart containerd
    systemctl is-active --quiet containerd \
      || { clog error "containerd did not come back after the sandbox image change"; exit 1; }

    # What the file says is not the evidence: "containerd config dump" prints the
    # value in force, and on 2.x that is pinned_images.sandbox. Reading the file is
    # what let a correct-looking sandbox_image sit there while the kubelet kept
    # asking for a different image.
    local in_force
    in_force=$(containerd config dump 2> /dev/null | grep -E "^[[:space:]]*sandbox(_image)?[[:space:]]*=" | tr -s ' ' | tr '\n' ' ')
    if echo "${in_force}" | grep -qE "${pause_registry}/pause:"; then
      clog debug "containerd sandbox image in force: ${in_force}"
    else
      clog error "containerd is not using the sandbox image this bundle carries; in force: ${in_force:-none}"
      exit 1
    fi
  elif [[ "$ZONE" == cn ]];then
    sed -i 's|k8s.gcr.io/pause|registry.cn-hangzhou.aliyuncs.com/k8sxio/pause|' /etc/containerd/config.toml
    ctr -n k8s.io i pull registry.cn-hangzhou.aliyuncs.com/k8sxio/pause:3.5 || true
    ctr -n k8s.io i tag registry.cn-hangzhou.aliyuncs.com/k8sxio/pause:3.5 k8s.gcr.io/pause:3.5 || true
  fi
}


function k8s_bin_get() {
  [[ (-f "/usr/local/bin/kubelet") && (-f "/usr/local/bin/kubeadm") && (-f "/usr/local/bin/kubectl") && (-f "/usr/local/bin/crictl") ]] && { clog warn "kubernetes binaries existed"; return 0; }

  os_arch="amd64"
  if [[ $(arch) == aarch64 ]]; then
      os_arch="arm64"
  fi

  CNI_VERSION="v0.8.2"
  RELEASE_VERSION="v0.4.0"
  DOWNLOAD_DIR=/usr/local/bin
  # The pause image the bundle carries; images/k8s/<version>/images.list names the
  # same one, and containerd's sandbox_image has to agree with it or pods never
  # get a sandbox.
  PAUSE_VERSION="3.9"

  # crictl tracks the Kubernetes minor version, and that matters more than it
  # looks: crictl up to 1.25 speaks CRI v1alpha2, containerd 2.x serves only v1,
  # and kubeadm's preflight asks crictl for the runtime status. A v1.22.0 crictl
  # against containerd 2.2 fails with "unknown service
  # runtime.v1alpha2.RuntimeService", which reads like a broken container runtime
  # and is really a client that is too old. The bundle carries the file this name
  # resolves to, so the builder derives it the same way.
  CRICTL_VERSION="v1.17.0"
  K8S_VERSION_MAIN=$(echo "$KUBERNETES_VERSION"|cut -d. -f2)
  if [ $K8S_VERSION_MAIN -gt 21 ]; then
    CRICTL_VERSION="v1.${K8S_VERSION_MAIN}.0"
  fi

  mkdir -p /opt/cni/bin
  mkdir -p $DOWNLOAD_DIR
  mkdir -p /etc/systemd/system/kubelet.service.d

  if [[ "$OFFLINE_INSTALL" == "true" ]]; then
    k8s_bin_local
  else
    k8s_bin_download
  fi

  # The kubelet needs to be told which CRI endpoint to use. With containerd that
  # has to be explicit: the dockershim it would otherwise fall back to was
  # removed in 1.24, so a kubelet without this line never registers a node. It
  # used to be written only on the download path, which left the offline path
  # with a kubelet that could not start at all.
  if [[ ${CONTAINER_RUNTIME} = "containerd" ]]; then
    # --container-runtime is deliberately absent: kubelet removed it in 1.27 when
    # dockershim went away, and a kubelet that is handed it refuses to start at
    # all — "failed to parse kubelet flag: unknown flag: --container-runtime" —
    # which reads as a broken node rather than a stale flag. The endpoint is what
    # selects the runtime now.
    sed -i '2a\Environment="KUBELET_EXTRA_ARGS=--runtime-cgroups=/system.slice/containerd.service --runtime-request-timeout=15m --container-runtime-endpoint=unix:///run/containerd/containerd.sock"' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
  fi
}

function k8s_bin_local() {
  clog info "get k8s bin from local"

  clog debug "get cni plugin"
  tar -zxvf ${OFFLINE_PKG_PATH}/cni-plugins-linux-${os_arch}-${CNI_VERSION}.tgz -C /opt/cni/bin > /dev/null

  # crictl is what the *online* path pulls images with. Offline the images come
  # from the bundle, so it is optional here: it is not in the Ubuntu archive and
  # its only other source is GitHub, which is exactly what an offline machine
  # cannot reach.
  if [ -f "${OFFLINE_PKG_PATH}/crictl-${CRICTL_VERSION}-linux-${os_arch}.tar.gz" ]; then
    clog debug "get crictl"
    tar -zxvf ${OFFLINE_PKG_PATH}/crictl-${CRICTL_VERSION}-linux-${os_arch}.tar.gz -C $DOWNLOAD_DIR > /dev/null
  else
    clog warn "no crictl in the offline package; it is only used to pull images, which offline comes from the bundle"
  fi

  clog debug "get kubeadm,kubelet,kubectl"
  # Copied, not moved. The offline package is the only source of these three
  # binaries, and moving them out of it leaves a bundle that installs a cluster
  # exactly once: a second run — after a failure, or on a second machine that
  # shares the package — fails on a kubeadm that is no longer there.
  cp -a ${OFFLINE_PKG_PATH}/kubeadm $DOWNLOAD_DIR
  cp -a ${OFFLINE_PKG_PATH}/kubelet $DOWNLOAD_DIR
  cp -a ${OFFLINE_PKG_PATH}/kubectl $DOWNLOAD_DIR
  # One path per argument. The brace form "{a,b,c}" is not expansion, it is a
  # single word with braces in it, so the old chmod matched nothing and left the
  # three binaries without the execute bit.
  chmod +x "${DOWNLOAD_DIR}/kubeadm" "${DOWNLOAD_DIR}/kubelet" "${DOWNLOAD_DIR}/kubectl"

  clog debug "config for kubelet service"
  cat ${OFFLINE_PKG_PATH}/kubelet.service | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service
  cat ${OFFLINE_PKG_PATH}/10-kubeadm.conf | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
}

function k8s_bin_download() {
  clog info "downloading kubernetes: ${KUBERNETES_VERSION} binaries"

  clog debug "downloading cni plugin"

  if [[ "$ZONE" == cn ]];then
    curl -L "https://kubecube.nos-eastchina1.126.net/containernetworking/${CNI_VERSION}/cni-plugins-linux-${os_arch}-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

    clog debug "downloading crictl"
    curl -L "https://kubecube.nos-eastchina1.126.net/cri-tools/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${os_arch}.tar.gz" | tar -C $DOWNLOAD_DIR -xz

    clog debug "downloading kubeadm,kubelet,kubectl"
#    RELEASE=v${KUBERNETES_VERSION}
    cd $DOWNLOAD_DIR
    curl -L --remote-name-all https://kubecube.nos-eastchina1.126.net/kubernetes/${RELEASE}/bin/linux/${os_arch}/{kubeadm,kubelet,kubectl}
    chmod +x {kubeadm,kubelet,kubectl}

    clog debug "config for kubelet service"
#    RELEASE_VERSION="v0.4.0"
    curl -sSL "https://kubecube.nos-eastchina1.126.net/githubusercontent/kubernetes/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service
    curl -sSL "https://kubecube.nos-eastchina1.126.net/githubusercontent/kubernetes/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
  else
    curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${os_arch}-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

    clog debug "downloading crictl"
    curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${os_arch}.tar.gz" | tar -C $DOWNLOAD_DIR -xz

    clog debug "downloading kubeadm,kubelet,kubectl"
#    RELEASE=v${KUBERNETES_VERSION}
    cd $DOWNLOAD_DIR
    curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/${os_arch}/{kubeadm,kubelet,kubectl}
    chmod +x {kubeadm,kubelet,kubectl}

    clog debug "config for kubelet service"
#    RELEASE_VERSION="v0.4.0"
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
  fi

  if [[ "$CONTAINER_RUNTIME" == "docker" ]] ;then
    firstVersion=$(echo "$KUBERNETES_VERSION" | awk -F '.' '{{print $1}}')
    secondVersion=$(echo "$KUBERNETES_VERSION" | awk -F '.' '{{print $2}}')
    if [[ "$firstVersion" -eq 1 && "$secondVersion" -gt 23 ]];then
        cri_dockerd_install
    fi
  fi
}

function cri_dockerd_install() {
    systemctl status cri-docker|grep Active|grep -q running && { clog warn "cri-docker is already running."; return 0; }
    clog info "start install cri docker"
    cd $DOWNLOAD_DIR
    curl -L --remote-name-all https://kubecube.nos-eastchina1.126.net/cri-dockerd/${CRI_DOCKERD_VERSION}/${os_arch}/{cri-docker.service,cri-docker.socket,cri-dockerd}
    clog info "get cri docker end"
    chmod +x cri-dockerd
    mv cri-dockerd /usr/local/bin/cri-dockerd || true
    mv cri-docker.service /etc/systemd/system/cri-docker.service
    mv cri-docker.socket /etc/systemd/system/cri-docker.socket
    clog info "move cri docker service end"
    sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
    systemctl daemon-reload
    systemctl enable cri-docker.service
    systemctl enable --now cri-docker.socket
    clog info "start cri docker service end"
}

function images_download() {
  if [[ "$OFFLINE_INSTALL" == "true" ]]; then
      clog info "loading image form local"
      if [[ ${CONTAINER_RUNTIME} = "containerd" ]]; then
        # Same archive, same importer as the k0s path. The bundle normalises it
        # first: docker save writes an archive whose OCI index names platforms
        # the archive does not carry, and containerd follows that index and
        # fails with "content digest ...: not found".
        ctr -n k8s.io images import "${OFFLINE_PKG_PATH}/offline_images.tar"
      else
        docker load < ${OFFLINE_PKG_PATH}/offline_images.tar
      fi
  else
      clog info "downloading images"

      # download k8s images
      if [[ "$INSTALL_KUBERNETES" == "true" ]]; then
        for image in $(cat /etc/kubecube/manifests/images/k8s/v${KUBERNETES_VERSION}/images.list)
        do
            if [[ ${CONTAINER_RUNTIME} = "containerd" ]]; then
                 clog debug "pulling image ${image}"
                 crictl pull "${image}"
            elif [[ ${CONTAINER_RUNTIME} = "docker" ]]; then
                 /usr/bin/docker pull "${image}"
            else
              clog error "container_runtime error, only support docker and containerd now!"
              exit 1
            fi
        done
      fi

      # todo: downloads image need by cube pivot cluster
      if [[ "$INSTALL_KUBECUBE_PIVOT" == "true" ]]; then
        for image in $(cat /etc/kubecube/kubecube-chart/images.list)
        do
            if [[ ${CONTAINER_RUNTIME} = "containerd" ]]; then
                 clog debug "pulling image ${image}"
                 crictl pull "${image}"
            elif [[ ${CONTAINER_RUNTIME} = "docker" ]]; then
                 /usr/bin/docker pull "${image}"
            else
              clog error "container_runtime error, only support docker and containerd now!"
              exit 1
            fi
        done
      fi
  fi
}

# k8s_prepare_host_network lets pod traffic through a host firewall.
#
# Ubuntu with ufw enabled — which is the default on a fresh 24.04 — sets the INPUT
# and FORWARD policies to DROP ("deny (incoming), deny (routed)"), and Kubernetes
# needs both paths: pod to a service on this node is INPUT, pod to anywhere else
# is FORWARD. The cluster then looks healthy — control plane up, node registered —
# and every pod fails with "connect: operation not permitted". The first thing to
# notice here was calico's own install-cni, whose token request to the API server
# goes through the service ClusterIP.
#
# The k0s path learned this already; these are the same rules for kubeadm, with
# the service CIDR added because a pod reaches the API server through its
# ClusterIP rather than the node address. Two pod CIDRs are allowed because the
# CNI decides that: calico's upstream manifest defaults to 192.168.0.0/16 and k0s
# configures 10.244.0.0/16.
function k8s_prepare_host_network() {
  local pod_cidrs="10.244.0.0/16 192.168.0.0/16"
  local service_cidr="10.96.0.0/12"
  local pod_cidr
  local forward_policy
  forward_policy=$(iptables -S FORWARD | head -1)

  if [ "${forward_policy}" != "-P ACCEPT" ] \
    || iptables -S FORWARD | grep -q "ufw-before-forward"; then
    clog warn "a host firewall is dropping pod traffic (FORWARD: ${forward_policy#-P }); allowing pod and service traffic through"
    iptables -P FORWARD ACCEPT
    iptables -I FORWARD 1 -s "${service_cidr}" -j ACCEPT
    for pod_cidr in ${pod_cidrs}; do
      iptables -I INPUT 1 -s "${pod_cidr}" -j ACCEPT
      iptables -I FORWARD 1 -s "${pod_cidr}" -j ACCEPT
    done

    # The rules are lost when the firewall reloads, so they are re-applied every
    # time the kubelet starts — the one service every node runs.
    mkdir -p /etc/systemd/system/kubelet.service.d
    {
      echo '[Service]'
      echo '# Pod traffic has to reach services on this node (INPUT) and leave it'
      echo '# (FORWARD). ufw drops both, and these rules do not survive a reload.'
      echo 'ExecStartPost=/sbin/iptables -P FORWARD ACCEPT'
      echo "ExecStartPost=/sbin/iptables -I FORWARD 1 -s ${service_cidr} -j ACCEPT"
      for pod_cidr in ${pod_cidrs}; do
        echo "ExecStartPost=/sbin/iptables -I INPUT 1 -s ${pod_cidr} -j ACCEPT"
        echo "ExecStartPost=/sbin/iptables -I FORWARD 1 -s ${pod_cidr} -j ACCEPT"
      done
    } > /etc/systemd/system/kubelet.service.d/forward.conf
    systemctl daemon-reload
    clog info "pod traffic allowed; rules re-applied when the kubelet starts"
  fi
}

function preparation() {
  clog info "doing previous preparation"

  k8s_prepare_host_network

  clog debug "closing swap"
  swapoff -a
  sed -i '/swap/s/^/#/g' /etc/fstab

  clog debug "config kernel params, passing bridge flow of IPv4 to iptables chain"
cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
  modprobe br_netfilter
  sysctl -p /etc/sysctl.d/k8s.conf
  echo "1" > /proc/sys/net/ipv4/ip_forward

  clog info "enable kubelet service"
  systemctl enable --now kubelet
}

function make_cluster_configuration (){
  clog info "make configuration for kubeadm"

  mkdir -p /etc/cube/kubeadm

  REGISTRY=${K8S_REGISTR}
  if [[ "$ZONE" == cn ]];then
    REGISTRY=${CN_K8S_REGISTR}
  fi

  if [ ! -z ${KUBERNETES_BIND_ADDRESS} ]; then
    clog info "use customize k8s bind address ${KUBERNETES_BIND_ADDRESS}"
    IPADDR=${KUBERNETES_BIND_ADDRESS}
  fi

API_SERVER_CONF=$(cat <<- EOF
# set control plane components listen on IPADDR
controllerManager:
  extraArgs:
    bind-address: ${IPADDR}
scheduler:
  extraArgs:
    bind-address: ${IPADDR}
imageRepository: ${REGISTRY}
EOF
)
# enable metrics endpoint on all interfaces
KUBE_PROXY_CONF=$(cat <<- EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: 0.0.0.0:10249
EOF
)

if [ -z ${CONTROL_PLANE_ENDPOINT} ]; then
  clog debug "vip not be set, use node ip"
  CONTROL_PLANE_ENDPOINT=${IPADDR}
fi

# Which kubeadm config API to write. v1beta2 is what 1.15 through 1.21 read;
# 1.22 moved to v1beta3, and kubeadm 1.28 refuses to migrate v1beta2 at all —
# "your configuration file uses an old API spec ... Please use kubeadm v1.22
# instead" — which is where installing 1.28 from this path stopped. v1beta3 is
# accepted from 1.22 through 1.29 and migrates cleanly to the v1beta4 that 1.27+
# writes, so one spec covers everything the installer supports and the migrate
# step below still runs.
local minor
minor=$(echo "${KUBERNETES_VERSION}" | cut -d. -f2)
KUBEADM_API="kubeadm.k8s.io/v1beta2"
if [ "${minor}" -ge 22 ]; then
  KUBEADM_API="kubeadm.k8s.io/v1beta3"
fi
clog debug "kubeadm config api ${KUBEADM_API} for kubernetes ${KUBERNETES_VERSION}"

cat >/etc/cube/kubeadm/init.config <<EOF
apiVersion: ${KUBEADM_API}
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_VERSION}
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}
${API_SERVER_CONF}
---
${KUBE_PROXY_CONF}
EOF
}

function Install_Kubernetes_Master (){
  clog info "init kubernetes, version: ${KUBERNETES_VERSION}"
  mv /etc/cube/kubeadm/init.config /etc/cube/kubeadm/old.config
  kubeadm config migrate --old-config /etc/cube/kubeadm/old.config --new-config /etc/cube/kubeadm/init.config
  if [ ${NODE_MODE} = "master" ];then
    kubeadm init --config=/etc/cube/kubeadm/init.config
  elif [ ${NODE_MODE} = "control-plane-master" ];then
    kubeadm init --config=/etc/cube/kubeadm/init.config --upload-certs
  fi

  mkdir -p ${HOME}/.kube
  cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
  chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

  clog debug "installing cni ${CNI}"
  kubectl apply -f /etc/kubecube/manifests/cni/${CNI}/${RELEASE} > /dev/null

  sleep 7 >/dev/null
  clog debug "inspect node"
  kubectl get node

  sleep 7 >/dev/null
  clog debug "inspect pod"
  kubectl get pod --all-namespaces

  sleep 7 >/dev/null
  clog debug "inspect service"
  kubectl get svc --all-namespaces

  clog info "kubernetes ${KUBERNETES_VERSION} deploy completed"
}

function Install_Kubernetes_Node (){
  clog info "init kubernetes, version：${KUBERNETES_VERSION}"

  if [ ! -z ${ACCESS_PASSWORD} ]; then
    clog info "access master node use password"
    TOKEN=$(sshpass -p ${ACCESS_PASSWORD} ssh -p ${SSH_PORT} ${SSH_USER}@${MASTER_IP} "kubeadm token create --ttl=10m")
    Hash=$(sshpass -p ${ACCESS_PASSWORD} ssh -p ${SSH_PORT} ${SSH_USER}@${MASTER_IP} "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'")
    if [ ! -z ${CONTROL_PLANE_ENDPOINT} ]; then
        CertificateKey=$(sshpass -p ${ACCESS_PASSWORD} ssh -p ${SSH_PORT} ${SSH_USER}@${MASTER_IP} "kubeadm init phase upload-certs --upload-certs | awk 'END {print}'")
    fi
  elif [ ! -z ${ACCESS_PRIVATE_KEY_PATH} ]; then
    clog info "access master node use private key"
    TOKEN=$(ssh -i ${ACCESS_PRIVATE_KEY_PATH} -o "StrictHostKeyChecking no" ${SSH_USER}@${MASTER_IP} -p ${SSH_PORT} "kubeadm token create --ttl=10m")
    Hash=$(ssh -i ${ACCESS_PRIVATE_KEY_PATH} -o "StrictHostKeyChecking no" ${SSH_USER}@${MASTER_IP} -p ${SSH_PORT} "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'")
    if [ ! -z ${CONTROL_PLANE_ENDPOINT} ]; then
        CertificateKey=$(ssh -i ${ACCESS_PRIVATE_KEY_PATH} ${SSH_USER}@${MASTER_IP} -p ${SSH_PORT} "kubeadm init phase upload-certs --upload-certs | awk 'END {print}'")
    fi
  else
    clog error "ACCESS_PASSWORD or ACCESS_PRIVATE_KEY_PATH must be specified"
  fi

  nodename=$(hostname | tr 'A-Z' 'a-z')

  if [ ${NODE_MODE} = "node-join-control-plane" ]; then
    clog info "node join control plane as master"
    kubeadm join ${MASTER_IP}:6443 --token ${TOKEN} --discovery-token-ca-cert-hash sha256:${Hash} --control-plane --certificate-key ${CertificateKey}
    mkdir -p ${HOME}/.kube
    cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
    chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
  elif [ ${NODE_MODE} = "node-join-master" ]; then
    clog info "node join cluster as worker"
    kubeadm join ${MASTER_IP}:6443 --token ${TOKEN} --discovery-token-ca-cert-hash sha256:${Hash}
    if [ ! -z ${ACCESS_PASSWORD} ]; then
      sshpass -p ${ACCESS_PASSWORD} ssh -p ${SSH_PORT} ${SSH_USER}@${MASTER_IP} "kubectl label nodes $nodename node-role.kubernetes.io/node="
    else
      ssh -i ${ACCESS_PRIVATE_KEY_PATH} -o "StrictHostKeyChecking no" ${SSH_USER}@${MASTER_IP} -p ${SSH_PORT} "kubectl label nodes $nodename node-role.kubernetes.io/node="
    fi
      mkdir -p ${HOME}/.kube
      cp -i /etc/kubernetes/kubelet.conf ${HOME}/.kube/config
      chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
  fi
}

function Main() {
  mkdir -p /etc/kubecube/down
  mkdir -p /etc/kubecube/bin

  if [[ ${CONTAINER_RUNTIME} = "containerd" ]]; then
    containerd_installed
    containerd_configuration
  elif [[ ${CONTAINER_RUNTIME} = "docker" ]]; then
    docker_bin_get
    install_docker
  else
    clog error "container_runtime error, only support docker and containerd now!"
    exit 1
  fi

  k8s_bin_get
  images_download

  if [[ ${PRE_DOWNLOAD} = "true" ]]; then
    exit 0
  fi

  preparation
  make_cluster_configuration

  clog info "installing node MODE: ${NODE_MODE}"

  if [ "${NODE_MODE}" = "master" ] || [ "${NODE_MODE}" = "control-plane-master" ];then
    Install_Kubernetes_Master
  elif [ "${NODE_MODE}" = "node-join-control-plane" ] || [ "${NODE_MODE}" = "node-join-master" ]; then
    Install_Kubernetes_Node
  fi
}

Main