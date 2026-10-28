# v1.4.0

## Feature
- install the member side of onboarding: `INSTALL_KUBECUBE_MEMBER="true"` renders
  the same chart with the pivot's own components off and the warden pointing at
  `PIVOT_CUBE_HOST`, so a cluster joins a pivot that is already running. The
  installer had no member path at all before — `install.sh` only ever installed a
  pivot — which left the other half of onboarding to hand-written helm values
- install k0s as well as kubeadm. `KUBERNETES_DISTRO` picks the provider; the
  k0s provider installs a single-node control plane from the bundled binary,
  renders `network.provider` for kuberouter, calico or cilium, and leaves a
  kubeconfig where the chart expects it. k0s carries its own containerd, so no
  external container runtime is installed
- install Cilium by default: `CNI="cilium"`, from the chart pulled as an OCI
  artifact. It runs without kube-proxy (`CILIUM_KUBE_PROXY_REPLACEMENT="true"`
  disables k0s' kube-proxy) and with `ipam.mode=kubernetes`, so Cilium uses the
  per-node podCIDR k0s already allocates instead of its own 10.0.0.0/8 pool,
  which would swallow k0s' service CIDR
- offline install: `build-offline-bundle.sh` produces a bundle carrying the
  distribution binary, every image, the charts and the binaries, and `entry.sh`
  installs from it without touching the network. `cleanup-blank.sh` returns a
  build host to "blank machine plus bundle", so the install can be re-run from a
  state that proves it needed nothing else
- the platform install states what it needs instead of inheriting the chart's
  defaults: the hotplugs are off (they pull several gigabytes this installer
  never stages), only the four components it has images for are on, the image
  tag comes from the bundle, and helm is asked to wait so a failed install fails
- `images/k0s/<version>/images.list` and its CNI companions hold the images k0s
  pulls, next to the existing `images/k8s/<version>/images.list`
- `hack/` carries the acceptance scripts: offline install checks for k0s and for
  kubeadm, a bundle smoke test, the pivot/member onboarding acceptance, the
  scoped-credential acceptance, and the egress blocker they use

## BugFix
- `cleanup.sh` uninstalls what it says it uninstalls. Tested with `all` against a
  live kubeadm cluster it reported "kubernetes uninstall success" and exited 0
  while `kubeadm reset` had never run — it asks for a confirmation a script cannot
  answer — and a running, enabled kubelet, thirteen calico interfaces, the
  installer's pod-CIDR firewall rules and its kubelet drop-in all survived. It now
  resets with `-f`, stops on a failed reset instead of continuing, disables the
  kubelet and removes the drop-in, clears the CNI interfaces, routes and rules, and
  on the platform side waits for the namespaces to terminate and deletes the
  platform CRDs a release leaves behind
- the cluster's pod and service networks are install.conf settings now
  (`POD_CIDR`, `SERVICE_CIDR`), read by both distributions: kubeadm hands them to
  `networking.podSubnet`/`serviceSubnet`, Calico's pool is set to the same pod
  CIDR (whichever form the release ships it in), and k0s writes them into its own
  config instead of the values it used to hard-code. The installer validates the
  pair at startup: an address inside the node's own subnet, or a pod network that
  overlaps the service network, stops the install instead of producing a cluster
  that reports Ready while pods hold the node's own addresses
- `install_k8s.sh` states the pod and service networks to kubeadm, and makes
  Calico's IP pool match. Without a `podSubnet` kubeadm leaves
  `Node.spec.podCIDR` empty and Calico falls back to its own `192.168.0.0/16`, so
  on any host whose network lives inside that range pod IPs come out of the
  node's own subnet: the kubelet answers for pod addresses, services land on the
  wrong host, and the failure is silent because the node still reports Ready. The
  host firewall no longer allows that pool as a workaround — it allows the
  configured pod CIDR and the service CIDR, and nothing else
- `entry.sh` checks the host for what the selected distribution actually needs.
  It demanded sshpass and conntrack from every host, and a fresh Ubuntu has
  neither, so a k0s install was refused before it started
- `install_kubecube.sh` reads the image tag from the bundle instead of leaving
  the chart's upstream tags in place, which no arm64 cluster can pull
- `build-offline-bundle.sh` normalises the chart it vendors, and matches `*.tpl`.
  A template that emits a value into a base64 field carries a carriage return
  into that base64 when the file comes from a Windows checkout: YAML tolerates
  CRLF, a webhook's caBundle does not
- `build-offline-bundle.sh` stages the metrics-server image the kubeadm path
  needs, retagged from upstream v0.7.2 under the bundle's tag. The image the
  chart used to name, `rancher-metrics-server:v0.4.1-m`, is amd64-only, so an
  arm64 kubeadm install could never start it — and a minimal bundle carries no
  platform images at all, so nothing staged it either

# v1.3.1

## Feature
- replace image to docker hub

# v1.3.0

## Feature
- remove kubecube chart
- clean up useless scripts