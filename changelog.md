# v1.4.0

## Feature
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

## BugFix
- `entry.sh` checks the host for what the selected distribution actually needs.
  It demanded sshpass and conntrack from every host, and a fresh Ubuntu has
  neither, so a k0s install was refused before it started
- `install_kubecube.sh` reads the image tag from the bundle instead of leaving
  the chart's upstream tags in place, which no arm64 cluster can pull
- `build-offline-bundle.sh` normalises the chart it vendors, and matches `*.tpl`.
  A template that emits a value into a base64 field carries a carriage return
  into that base64 when the file comes from a Windows checkout: YAML tolerates
  CRLF, a webhook's caBundle does not

# v1.3.1

## Feature
- replace image to docker hub

# v1.3.0

## Feature
- remove kubecube chart
- clean up useless scripts