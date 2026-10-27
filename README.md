# KubeCube-Installer

KubeCube installer is here for install kubecube by "all-in-one" way. More details follow [doc](https://www.kubecube.io/docs/installation-guide/).

## Quick start

set version

```bash
export KUBECUBE_VERSION=v1.8
```

### All in one install

```bash
curl -fsSL https://kubecube.nos-eastchina1.126.net/kubecube-installer/release/v1.3/entry.sh | bash
```

### Custom install

```bash
export CUSTOMIZE="true";curl -fsSL https://kubecube.nos-eastchina1.126.net/kubecube-installer/release/v1.3/entry.sh | bash
```

### Offline install

The offline path carries everything the install needs, so the target machine
never has to reach a registry or a download host.

Build the bundle on a machine that has network access, docker and Go:

```bash
WORKSPACE=/root/kubecube-src ./build-offline-bundle.sh
```

It writes `/opt/kubecube-offline`, which contains the k0s binary, every image,
the platform and Cilium charts, helm and kubectl, and the installer scripts.
Then, on the target machine, one command:

```bash
bash /opt/kubecube-offline/entry.sh
```

The bundle records what it carries in `bundle.env` (image tag, k0s version,
Cilium version, CNI) and the checksum of every file in `bundle.manifest`; the
installer verifies the files it installs against that manifest.

To return a build host to "blank machine plus bundle" before an acceptance run:

```bash
./cleanup-blank.sh          # dry run
./cleanup-blank.sh --yes    # do it
```

### Verifying an install

`hack/` holds the acceptance scripts that check a finished install (offline k0s
and kubeadm, a staged bundle, pivot/member onboarding and the member
credential), plus the egress blocker the offline checks use. See
[hack/README.md](hack/README.md) for what each one proves and what it needs.

### Choosing the distribution and the CNI

`install.conf` decides both. The defaults are k0s and Cilium.

| `KUBERNETES_DISTRO` | `CNI` | Notes |
|---|---|---|
| `k0s` | `cilium` (default) | k0s installs no CNI (`provider: custom`) and the installer installs the Cilium chart |
| `k0s` | `calico` | k0s installs calico from its own images |
| `k0s` | `kuberouter` | k0s' bundled CNI, the one that needs no extra images |
| `kubeadm` | `calico` | the original path, unchanged |

Two versions move together: Cilium 1.16 is the last Cilium line that supports
Kubernetes 1.28, and k0s 1.28 is the last k0s line whose control-plane taint key
is still `master`. Raise Kubernetes and Cilium together, never alone.

### Joining a cluster to a pivot

`INSTALL_KUBECUBE_PIVOT="true"` installs a pivot. A cluster that should be
*managed* by one installs the member side instead:

```bash
INSTALL_KUBECUBE_MEMBER="true"
PIVOT_CUBE_HOST="<pivotIP>:30443"
PIVOT_KUBECONFIG="/root/.kube/config"          # a kubeconfig for the pivot
MEMBER_KUBECONFIG="/etc/kubernetes/admin.conf" # this cluster's kubeconfig
MEMBER_CLUSTER_NAME=""                         # empty means the hostname
```

It renders the same chart with `componentsEnable.kubecube="false"`, which is what
makes it a member: the warden dials the pivot instead of an in-cluster service,
and registers itself (`wardenRegisterModeEnable` is on by default), so nothing is
pushed into the member from the pivot.

## Clean UP

```bash
curl -o cleanup.sh https://kubecube.nos-eastchina1.126.net/hack/cleanup.sh
```

```bash
# params can be: 'kubecube','k8s','docker','containerd','all'
/bin/bash cleanup.sh all
```