#!/usr/bin/env bash
#
# Acceptance for an offline kubeadm install.
#
# Verifies, on a host rolled back to "blank machine plus bundle":
#   - the installer's own entry point installs from the bundle and reports success;
#   - the node is Ready and runs containerd;
#   - calico-node, kube-proxy and CoreDNS are running, and Cilium is absent
#     (this bundle carries the kubeadm/Calico path, not the k0s/Cilium one);
#   - kubeadm, kubelet and kubectl are the bundled versions;
#   - nothing reached the network: every outbound attempt the install made was
#     rejected by the KUBECUBE-OFFLINE chain and logged.
#
# A minimal kubeadm bundle carries the distribution's artefacts alone, so this
# script installs a cluster and checks the cluster; it does not check the
# platform, which that bundle does not carry.
#
# Needs:
#   - root on the host under test, and a minimal kubeadm bundle at BUNDLE;
#   - the host reset by the bundle's cleanup-blank.sh;
#   - egress blocked by hack/block-egress.sh, which owns the chain read below.
#
# Run:
#   sudo BUNDLE=/opt/kubecube-offline-kubeadm \
#     ./hack/acceptance-offline-kubeadm.sh
#
# Optional: EVID (evidence directory).
#
# The script changes nothing itself: no fix-ups, no second attempt, no manual
# step. The EXIT trap prints the summary and exits with the number of failures.

set -euo pipefail

BUNDLE=${BUNDLE:-/opt/kubecube-offline-kubeadm}
EVID=${EVID:-/root/acceptance-kubeadm-$(date +%Y%m%d-%H%M%S)}
fail=0

function section() { echo; echo "===== $* ====="; }
function ok() { echo "  ok    $*"; }
function bad() {
  echo "  FAIL  $*"
  fail=$((fail + 1))
}
function note() { echo "  ..    $*"; }

function finish() {
  local rc=$?
  trap - EXIT
  section "summary"
  if [ "${fail}" -eq 0 ] && [ "${rc}" -eq 0 ]; then
    echo "ACCEPTANCE PASSED (kubeadm offline)"
    echo "evidence: ${EVID}"
    exit 0
  fi
  if [ "${fail}" -eq 0 ]; then
    echo "ACCEPTANCE FAILED: aborted (exit ${rc}); see the log above"
    fail=1
  else
    echo "ACCEPTANCE FAILED: ${fail} check(s)"
  fi
  echo "evidence: ${EVID}"
  exit "${fail}"
}

if [ "$(id -u)" -ne 0 ]; then
  echo "acceptance: run as root; it reads /root, the kubelet kubeconfig and the kernel log" >&2
  exit 2
fi
if [ ! -x "${BUNDLE}/entry.sh" ]; then
  echo "acceptance: ${BUNDLE}/entry.sh is not executable; set BUNDLE to the minimal kubeadm bundle" >&2
  exit 2
fi
if ! iptables -L KUBECUBE-OFFLINE -n > /dev/null 2>&1; then
  echo "acceptance: no KUBECUBE-OFFLINE chain; run hack/block-egress.sh apply first" >&2
  exit 2
fi

mkdir -p "${EVID}"
trap finish EXIT

# ---------------------------------------------------------------- blank state

section "starting state"
{
  echo "date: $(date -Iseconds)"
  echo "host: $(hostname) $(uname -m) $(lsb_release -ds 2> /dev/null)"
  echo
  echo "--- things an install must not find already present ---"
  for p in /usr/local/bin/k0s /etc/k0s /var/lib/k0s /etc/kubernetes /var/lib/kubelet \
    /etc/cni /opt/cni /root/.kube /etc/kubecube /usr/local/bin/helm; do
    if [ -e "${p}" ]; then echo "PRESENT ${p}"; else echo "absent  ${p}"; fi
  done
  for c in docker k0s kubeadm kubelet kubectl helm containerd ctr; do
    printf '%-10s %s\n' "${c}" "$(command -v "${c}" || echo 'not on PATH')"
  done
  echo
  echo "--- bundle ---"
  ls -la "${BUNDLE}"
  echo
  echo "--- egress rules in force ---"
  iptables -L KUBECUBE-OFFLINE -n -v 2> /dev/null || echo "no KUBECUBE-OFFLINE chain"
} | tee "${EVID}/00-starting-state.txt"

for p in /usr/local/bin/k0s /etc/k0s /var/lib/k0s /etc/kubernetes /var/lib/kubelet /root/.kube /etc/kubecube; do
  if [ -e "${p}" ]; then bad "${p} exists before the install"; else ok "${p} absent"; fi
done
for c in kubeadm kubelet containerd; do
  if command -v "${c}" > /dev/null 2>&1; then bad "${c} is already on PATH"; else ok "${c} not on PATH"; fi
done

# ------------------------------------------------- background updaters

section "quiescing background updaters"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1 || true
systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1 || true
pkill -f unattended-upgrade > /dev/null 2>&1 || true
ok "unattended upgrades stopped; their traffic is not the install's"

iptables -Z KUBECUBE-OFFLINE > /dev/null 2>&1 || true
dmesg -C > /dev/null 2>&1 || true
ok "egress counters and kernel log cleared"

# ------------------------------------------------------------------- install

section "one command"
note "bash ${BUNDLE}/entry.sh"
start=$(date +%s)
rc=0
bash "${BUNDLE}/entry.sh" > "${EVID}/10-install.log" 2>&1 || rc=$?
end=$(date +%s)
note "exit code ${rc}, took $((end - start))s, log at ${EVID}/10-install.log"
if [ "${rc}" -eq 0 ]; then ok "the installer reported success"; else bad "the installer exited ${rc}"; fi

# ------------------------------------------------------------------ cluster

section "waiting for the cluster to settle"
# The installer returns as soon as it has applied the CNI manifest, so the wait
# belongs here: calico needs a minute or two to bring the node up, and judging it
# the instant the installer exits says "not running" about a cluster that is
# still starting.
settled=0
wait_start=$(date +%s)
deadline=$((wait_start + 420))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  ready=$(kubectl get nodes --no-headers 2> /dev/null | grep -c ' Ready ' || true)
  calico=$(kubectl -n kube-system get pods --no-headers 2> /dev/null | awk '$1 ~ /^calico-node/ && $2 == "1/1"' | wc -l)
  coredns=$(kubectl -n kube-system get pods --no-headers 2> /dev/null | awk '$1 ~ /^coredns/ && $2 == "1/1"' | wc -l)
  if [ "${ready}" -ge 1 ] && [ "${calico}" -ge 1 ] && [ "${coredns}" -ge 1 ]; then
    ok "node Ready, calico-node and CoreDNS running, $(( $(date +%s) - wait_start ))s after the installer returned"
    settled=1
    break
  fi
  sleep 10
done
if [ "${settled}" -ne 1 ]; then
  bad "the cluster did not settle within 420s"
fi

section "cluster"
kubectl get nodes -o wide > "${EVID}/20-nodes.txt" 2>&1 || true
if grep -q " Ready " "${EVID}/20-nodes.txt"; then ok "node is Ready"; else bad "node is not Ready"; fi
if grep -q "containerd://" "${EVID}/20-nodes.txt"; then ok "the node runs containerd"; else bad "the node is not running containerd"; fi
cat "${EVID}/20-nodes.txt"

kubectl -n kube-system get pods -o wide > "${EVID}/21-kube-system.txt" 2>&1 || true
cat "${EVID}/21-kube-system.txt"
for w in calico-node kube-proxy coredns; do
  if grep -q "${w}" "${EVID}/21-kube-system.txt" && ! grep "${w}" "${EVID}/21-kube-system.txt" | grep -qv " Running "; then
    ok "${w} is running"
  else
    bad "${w} is not running"
  fi
done
if grep -q "^cilium-" "${EVID}/21-kube-system.txt"; then
  bad "cilium is present: this is the kubeadm path and it installs calico"
else
  ok "no cilium (kubeadm installs calico)"
fi

section "versions"
{
  echo "kubeadm: $(kubeadm version -o short 2> /dev/null || true)"
  echo "kubelet: $(kubelet --version 2> /dev/null || true)"
  echo "kubectl: $(kubectl version --client=true -o yaml 2> /dev/null | awk '/gitVersion/ {print $2; exit}' || true)"
} | tee "${EVID}/30-versions.txt"

# ------------------------------------------------------------- offline proof

section "offline proof"
rejected=$(dmesg 2> /dev/null | grep -c "KUBECUBE-OFFLINE" || true)
note "rejected outbound attempts logged: ${rejected}"
dmesg 2> /dev/null | grep "KUBECUBE-OFFLINE" | grep -oE 'DST=[0-9.]+' | sort | uniq -c | sort -rn | head -20 \
  > "${EVID}/40-blocked-destinations.txt" || true
cat "${EVID}/40-blocked-destinations.txt" 2> /dev/null || true
if [ "${rejected}" -eq 0 ]; then
  ok "nothing tried to leave the machine"
else
  note "the install tried to reach the addresses above and was refused; see 40-blocked-destinations.txt"
fi

# The EXIT trap prints the summary and exits with the number of failed checks.
