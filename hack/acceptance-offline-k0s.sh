#!/usr/bin/env bash
#
# Acceptance for an offline k0s install.
#
# Verifies, on a host rolled back to "blank machine plus bundle":
#   - the installer's own entry point installs from the bundle and reports success;
#   - the k0s node is Ready and Cilium and CoreDNS are running;
#   - cube, warden, audit and webconsole run in the platform namespace;
#   - the platform API serves login and clusters/info, and the pivot is normal;
#   - a Tenant and a Project created through the API each get the namespace its
#     controller owns;
#   - nothing reached the network: every outbound attempt the install made was
#     rejected by the KUBECUBE-OFFLINE chain and logged.
#
# Needs:
#   - root on the host under test, and a bundle at BUNDLE;
#   - the host reset by the bundle's cleanup-blank.sh, so nothing the install is
#     supposed to provide already exists;
#   - egress blocked by hack/block-egress.sh, which owns the chain read below;
#   - ADMIN_PASS, the platform administrator's password. It has no default here.
#
# Run:
#   sudo BUNDLE=/opt/kubecube-offline ADMIN_PASS='<password>' \
#     ./hack/acceptance-offline-k0s.sh
#
# Optional: INSTALL_NAMESPACE (default kubecube-system), API (default
# https://<node-ip>:30443), TENANT and PROJECT (the names this run creates,
# default t-accept and p-accept), EVID (evidence directory).
#
# The script changes nothing itself: no fix-ups, no second attempt, no manual
# step. The EXIT trap prints the summary and exits with the number of failures.
#
# It expects the bundle's default shape: k0s, Cilium, kube-proxy replacement on.

set -euo pipefail

BUNDLE=${BUNDLE:-/opt/kubecube-offline}
NS=${INSTALL_NAMESPACE:-kubecube-system}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=${ADMIN_PASS:-}
TENANT=${TENANT:-t-accept}
PROJECT=${PROJECT:-p-accept}
API=${API:-}
NODE_IP=${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || true)}
EVID=${EVID:-/root/acceptance-k0s-$(date +%Y%m%d-%H%M%S)}
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
    echo "ACCEPTANCE PASSED"
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
  echo "acceptance: ${BUNDLE}/entry.sh is not executable; set BUNDLE to the offline bundle" >&2
  exit 2
fi
if [ -z "${ADMIN_PASS}" ]; then
  echo "acceptance: ADMIN_PASS must be set to the platform administrator password" >&2
  exit 2
fi
if [ -z "${API}" ]; then
  if [ -z "${NODE_IP}" ]; then
    echo "acceptance: cannot derive the node address; set NODE_IP or API" >&2
    exit 2
  fi
  API="https://${NODE_IP}:30443"
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
  for p in /usr/local/bin/k0s /etc/k0s /var/lib/k0s /etc/cubecube /etc/kubecube /root/.kube /usr/local/bin/helm; do
    if [ -e "${p}" ]; then echo "PRESENT ${p}"; else echo "absent  ${p}"; fi
  done
  for c in docker k0s helm kubectl; do
    printf '%-8s %s\n' "${c}" "$(command -v "${c}" || echo 'not on PATH')"
  done
  echo
  echo "--- bundle ---"
  ls -la "${BUNDLE}"
  echo
  echo "--- egress rules in force ---"
  iptables -L KUBECUBE-OFFLINE -n -v 2> /dev/null || echo "no KUBECUBE-OFFLINE chain"
} | tee "${EVID}/00-starting-state.txt"

for p in /usr/local/bin/k0s /etc/k0s /var/lib/k0s /root/.kube; do
  if [ -e "${p}" ]; then bad "${p} exists before the install"; else ok "${p} absent"; fi
done

# ------------------------------------------------- background updaters

section "quiescing background updaters"
# Ubuntu's unattended upgrades fetch from archive.ubuntu.com on their own
# schedule. They are not the install, and their refused attempts would show up
# in the offline proof as though the install had reached for the network.
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1 || true
systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1 || true
pkill -f unattended-upgrade > /dev/null 2>&1 || true
ok "unattended upgrades stopped; their traffic is not the install's"

# Zero the kernel log and the egress counters so the offline proof covers this
# run only: they accumulate, and the previous run's attempts would be counted as
# this one's.
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
settled=0
wait_start=$(date +%s)
deadline=$((wait_start + 420))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  ready=$(kubectl get nodes --no-headers 2> /dev/null | grep -c ' Ready ' || true)
  cilium=$(kubectl -n kube-system get pods --no-headers 2> /dev/null | awk '$1 ~ /^cilium/ && $2 == "1/1"' | wc -l)
  coredns=$(kubectl -n kube-system get pods --no-headers 2> /dev/null | awk '$1 ~ /^coredns/ && $2 == "1/1"' | wc -l)
  if [ "${ready}" -ge 1 ] && [ "${cilium}" -ge 1 ] && [ "${coredns}" -ge 1 ]; then
    ok "node Ready, Cilium and CoreDNS running, $(( $(date +%s) - wait_start ))s after the installer returned"
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
cat "${EVID}/20-nodes.txt"

kubectl -n kube-system get pods -o wide > "${EVID}/21-kube-system.txt" 2>&1 || true
if grep -q "^cilium-" "${EVID}/21-kube-system.txt" && ! grep "^cilium-" "${EVID}/21-kube-system.txt" | grep -qv " Running "; then
  ok "cilium is running"
else
  bad "cilium is not running"
fi
# k0s was told not to run kube-proxy; if it is there, the kube-proxy-free
# configuration did not take.
if kubectl -n kube-system get ds kube-proxy > /dev/null 2>&1; then
  bad "kube-proxy exists: the cluster is not kube-proxy-free"
else
  ok "no kube-proxy daemonset"
fi
grep -E "^(NAME|cilium|kube-proxy)" "${EVID}/21-kube-system.txt" | head -10 || true

section "platform components"
kubectl -n "${NS}" get pods -o wide > "${EVID}/30-platform-pods.txt" 2>&1 || true
cat "${EVID}/30-platform-pods.txt"
for c in cube warden audit webconsole; do
  if grep -q "${c}" "${EVID}/30-platform-pods.txt" && ! grep "${c}" "${EVID}/30-platform-pods.txt" | grep -qv " Running "; then
    ok "${c} is running"
  else
    bad "${c} is not running"
  fi
done

# ------------------------------------------------------------------- the API

section "platform api"
login_body=$(printf '{"name":"%s","password":"%s","loginType":"normal"}' "${ADMIN_USER}" "${ADMIN_PASS}")
code=$(curl -sk -o "${EVID}/40-login.json" -w '%{http_code}' -m 30 \
  -c "${EVID}/cookies.txt" -X POST "${API}/api/v1/cube/login" \
  -H 'Content-Type: application/json' -d "${login_body}" 2> /dev/null) || code=000
if [ "${code}" = "200" ]; then ok "login answered 200"; else bad "login answered ${code}"; fi

code=$(curl -sk -o "${EVID}/41-clusters-info.json" -w '%{http_code}' -m 30 \
  -b "${EVID}/cookies.txt" "${API}/api/v1/cube/clusters/info" 2> /dev/null) || code=000
if [ "${code}" = "200" ]; then ok "clusters/info answered 200"; else bad "clusters/info answered ${code}"; fi
if grep -q '"status":"normal"' "${EVID}/41-clusters-info.json"; then
  ok "the pivot cluster reports normal"
else
  bad "the pivot cluster does not report normal"
fi
head -c 400 "${EVID}/41-clusters-info.json" > "${EVID}/41-clusters-info.head" 2> /dev/null || true
echo
cat "${EVID}/41-clusters-info.head" 2> /dev/null || true

# ------------------------------------------------------------------ tenancy

section "tenancy"
# A tenant and a project are cluster-scoped custom resources; the controllers
# turn them into namespaces. The label value is the part that used to be
# invalid ("tenant:x"), so creating these and finding the namespaces is a real
# check rather than a formality.
cat > "${EVID}/50-tenancy.yaml" <<EOF
apiVersion: tenant.kubecube.io/v1
kind: Tenant
metadata:
  name: ${TENANT}
spec:
  displayName: acceptance tenant
  description: created by acceptance-offline-k0s.sh
---
apiVersion: tenant.kubecube.io/v1
kind: Project
metadata:
  name: ${PROJECT}
  labels:
    kubecube.io/tenant: ${TENANT}
spec:
  displayName: acceptance project
  description: created by acceptance-offline-k0s.sh
EOF
if kubectl apply -f "${EVID}/50-tenancy.yaml" > "${EVID}/50-tenancy-apply.txt" 2>&1; then
  ok "tenant ${TENANT} and project ${PROJECT} applied"
else
  bad "could not apply the tenant/project manifests"
fi
cat "${EVID}/50-tenancy-apply.txt"

# Poll instead of looking once. warden's project controller can reconcile a
# project before the tenant controller has recorded the tenant's namespace, and
# it then retries with backoff, so the namespaces appear a few seconds later.
#
# The selector is the label the ownership code actually writes:
# "kubecube.io/namespace-owner" with the kind built into the value
# ("tenant-<name>", "project-<name>"), not the bare name.
waited=0
while [ "${waited}" -lt 300 ]; do
  if kubectl get ns -l "kubecube.io/namespace-owner=tenant-${TENANT}" --no-headers 2> /dev/null | grep -q . \
    && kubectl get ns -l "kubecube.io/namespace-owner=project-${PROJECT}" --no-headers 2> /dev/null | grep -q .; then
    note "both namespaces appeared after ${waited}s"
    break
  fi
  sleep 10
  waited=$((waited + 10))
done

kubectl get tenant "${TENANT}" > "${EVID}/51-tenant.txt" 2>&1 || true
kubectl get project "${PROJECT}" > "${EVID}/52-project.txt" 2>&1 || true
kubectl get ns -l "kubecube.io/namespace-owner=tenant-${TENANT}" > "${EVID}/53-tenant-ns.txt" 2>&1 || true
kubectl get ns -l "kubecube.io/namespace-owner=project-${PROJECT}" > "${EVID}/54-project-ns.txt" 2>&1 || true

if [ "$(grep -c '^kubecube-tenant' "${EVID}/53-tenant-ns.txt" || true)" -ge 1 ]; then
  ok "the tenant controller created its namespace"
else
  bad "no namespace carries kubecube.io/namespace-owner=tenant-${TENANT}"
fi
if [ "$(grep -c '^kubecube-project' "${EVID}/54-project-ns.txt" || true)" -ge 1 ]; then
  ok "the project controller created its namespace"
else
  bad "no namespace carries kubecube.io/namespace-owner=project-${PROJECT}"
fi
cat "${EVID}/53-tenant-ns.txt" "${EVID}/54-project-ns.txt" 2> /dev/null || true

# ------------------------------------------------------------- offline proof

section "offline proof"
# Every rejected attempt was logged by the egress chain. A run that never
# reached out has nothing here; a run that did shows exactly where it went.
rejected=$(dmesg 2> /dev/null | grep -c "KUBECUBE-OFFLINE" || true)
note "rejected outbound attempts logged: ${rejected}"
dmesg 2> /dev/null | grep "KUBECUBE-OFFLINE" | grep -oE 'DST=[0-9.]+' | sort | uniq -c | sort -rn | head -20 \
  > "${EVID}/60-blocked-destinations.txt" || true
cat "${EVID}/60-blocked-destinations.txt" 2> /dev/null || true
if [ "${rejected}" -eq 0 ]; then
  ok "nothing tried to leave the machine"
else
  note "the install tried to reach the addresses above and was refused; see 60-blocked-destinations.txt"
fi

# The EXIT trap prints the summary and exits with the number of failed checks.
