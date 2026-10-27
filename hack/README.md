# Verification scripts

These scripts assert things about a finished installation. They do not install
anything and they do not repair anything: run one after `entry.sh` (or after a
member has joined a pivot) and read its exit code.

Every script prints a `PASSED`/`FAILED` summary. Exit code 0 means every check
passed, 1 means a check failed, and 2 means a prerequisite was missing or the
invocation was wrong, so nothing was verified.

| Script | What it proves | What it needs |
|---|---|---|
| `acceptance-offline-k0s.sh` | A blank host installs k0s and the platform from one offline bundle: node Ready, Cilium and CoreDNS up, the four platform pods Running, login and `clusters/info` answering, a Tenant and Project getting their namespaces, and no outbound traffic. | Root; `BUNDLE` (default `/opt/kubecube-offline`); `ADMIN_PASS`; the host reset by `cleanup-blank.sh`; `block-egress.sh` applied. |
| `acceptance-offline-kubeadm.sh` | A blank host installs a kubeadm cluster from the minimal bundle: node Ready on containerd, Calico, kube-proxy and CoreDNS Running, no Cilium, the bundled versions, and no outbound traffic. | Root; `BUNDLE` (default `/opt/kubecube-offline-kubeadm`); the host reset by `cleanup-blank.sh`; `block-egress.sh` applied. |
| `verify-k0s-bundle.sh` | A staged k0s bundle is complete and installable before the build host is wiped: checksums, layout, the bundle's `install.conf`, Cilium digest switches, LF line endings, `bash -n`, chart rendering, image archives and image-tag agreement. | A built bundle; `bash`, `tar`, `sha256sum`; `helm` (from the bundle's `bin/` when present); docker only with `--load-images`. |
| `verify-onboarding.sh` | A kubeadm member is managed by a KubeCube pivot: registered as `normal`, warden Running, admin reads it through the proxy, a non-admin user gets its scoped namespace (200) and is refused elsewhere (403), and is not a platform administrator. | Root on the member (or a readable member kubeconfig); `MEMBER_NAME`, `ADMIN_PASS`, `VERIFY_PASS`; a pivot API; `MEMBER_KUBECONFIG` (default `/etc/kubernetes/admin.conf`). |
| `credflow-acceptance.sh` | The member credential in the Cluster CR holds what the platform's own flows need: the flows are driven through the pivot API, and every refusal naming the credential is reported as a gap, alongside a direct `auth can-i` inventory of the operations that were missed. | Root (or passwordless sudo) on the member; `PIVOT_API`, `PIVOT_KUBECONFIG`, `ADMIN_PASS`, `CLUSTER`, and an existing `TENANT`/`PROJECT`. |
| `block-egress.sh` | Not an assertion: it installs or removes the `KUBECUBE-OFFLINE` chain that makes an offline claim provable, and logs every rejected destination under that prefix. | Root; `iptables`; `TUNNEL_HOST`, the address your session arrives from. |

## Running them

The offline acceptance runs come first: they need a host that has been rolled
back, a built bundle, and the firewall.

```bash
sudo TUNNEL_HOST=<your-session-host> ./hack/block-egress.sh apply
sudo BUNDLE=/opt/kubecube-offline ADMIN_PASS='<admin password>' \
  ./hack/acceptance-offline-k0s.sh
sudo ./hack/block-egress.sh undo
```

The onboarding and credential acceptances run against a live pivot/member pair:

```bash
sudo MEMBER_NAME=<member> ADMIN_PASS='<admin password>' VERIFY_PASS='<test password>' \
  ./hack/verify-onboarding.sh

PIVOT_API=https://<pivot>:30443/api/v1/cube PIVOT_KUBECONFIG=/root/.kube/config \
ADMIN_PASS='<admin password>' CLUSTER=<member> TENANT=<tenant> PROJECT=<project> \
  ./hack/credflow-acceptance.sh
```

Variables that carry a credential or name a real cluster are not defaulted: a
missing one stops the run with exit code 2 rather than falling back to a value
that would make the check pass for the wrong reason. The full parameter list is
in each script's header comment; `verify-k0s-bundle.sh`, `verify-onboarding.sh`
and `block-egress.sh` also answer `-h`.

## Status

All scripts pass `bash -n`. They have not been run end to end against a cluster:
the assertions were reviewed against the installer, the chart and the platform
API, but a green `bash -n` says nothing about behaviour.
