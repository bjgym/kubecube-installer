#!/usr/bin/env bash
#
# The scoped-credential acceptance.
#
# The platform reaches a member cluster through exactly one credential: the
# kubeconfig in the Cluster CR, which is the kube-cube-member-agent service
# account. Its rights come from agent-rbac.yaml, which was written by deriving
# them from the code -- and derivation is how two gaps were found only when a
# flow actually ran (cannot patch namespaces, cannot get resourcequotas).
#
# So this script produces both halves of a table:
#
#   left  - what the credential holds, from the member apiserver (auth can-i);
#   right - what the platform's own flows need, by driving them through the
#           pivot API and recording every `is forbidden` that names the
#           credential.
#
# Run it on the member host, as root or with passwordless sudo. It reads the
# credential from the pivot's Cluster CR through PIVOT_KUBECONFIG, then drives
# the pivot API as a platform administrator; every flow below is one the
# platform performs itself, so a refusal here is a refusal in production.
#
# Needs:
#   PIVOT_API          full API root, e.g. https://<pivot>:30443/api/v1/cube
#   PIVOT_KUBECONFIG   kubeconfig for the pivot (default $HOME/.kube/config)
#   ADMIN_PASS         the pivot administrator's password (no default)
#   CLUSTER            the member's name on the pivot
#   TENANT, PROJECT    an existing tenant and project to create the space in
#
# Optional: ADMIN_USER (default admin), NS (the space this run creates, default
# credflow-acceptance), CLEANUP=0 to keep that namespace, and REPORT/CAN/CRED to
# move the output files.
#
# Run:
#   PIVOT_API=https://<pivot>:30443/api/v1/cube PIVOT_KUBECONFIG=/root/.kube/config \
#   ADMIN_PASS='<password>' CLUSTER=<member> TENANT=<tenant> PROJECT=<project> \
#     ./hack/credflow-acceptance.sh
#
# Output: REPORT (default /tmp/credflow-report.txt), the verdict per flow, plus
# CAN, the inventory of what the credential holds. Exit 0 only when no flow was
# refused and every probe was classified.

set -euo pipefail

PIVOT_API=${PIVOT_API:-}
PIVOT_KUBECONFIG=${PIVOT_KUBECONFIG:-${KUBECONFIG:-${HOME}/.kube/config}}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=${ADMIN_PASS:-}
CLUSTER=${CLUSTER:-}
TENANT=${TENANT:-}
PROJECT=${PROJECT:-}
NS=${NS:-credflow-acceptance}
CLEANUP=${CLEANUP:-1}

out_dir=${TMPDIR:-/tmp}
REPORT=${REPORT:-${out_dir}/credflow-report.txt}
CAN=${CAN:-${out_dir}/credflow-can.txt}
JAR=${JAR:-${out_dir}/credflow-jar.txt}
CRED=${CRED:-${out_dir}/member-agent.kubeconfig}

say() { echo; echo "=== $* ==="; }
rec() { echo "$*" | tee -a "${REPORT}"; }
note() { echo "      $*" | tee -a "${REPORT}"; }
need() {
  local name=$1
  if [ -z "${!name}" ]; then
    echo "credflow: ${name} is required; see the header of this script" >&2
    exit 2
  fi
}

need PIVOT_API
need ADMIN_PASS
need CLUSTER
need TENANT
need PROJECT
PIVOT_API=${PIVOT_API%/}

if [ "$(id -u)" -eq 0 ]; then
  kctl() { kubectl "$@"; }
else
  if ! sudo -n true > /dev/null 2>&1; then
    echo "credflow: run as root or with passwordless sudo; it reads the pivot kubeconfig and the member credential" >&2
    exit 2
  fi
  kctl() { sudo -n kubectl "$@"; }
fi

for c in kubectl curl base64 grep sed awk; do
  command -v "${c}" > /dev/null 2>&1 || { echo "credflow: ${c} is not installed" >&2; exit 2; }
done

: > "${REPORT}"

say "0. the credential the platform uses to reach this cluster"
if ! kctl --kubeconfig "${PIVOT_KUBECONFIG}" get cluster "${CLUSTER}" \
  -o jsonpath='{.spec.kubeconfig}' 2> /dev/null | base64 -d > "${CRED}"; then
  rec "FAIL  could not read a kubeconfig from Cluster/${CLUSTER} on the pivot"
  rec "      check PIVOT_KUBECONFIG, ADMIN/CLUSTER, and that the member is registered"
  exit 1
fi
chmod 600 "${CRED}"
if [ ! -s "${CRED}" ]; then
  rec "FAIL  no credential in the Cluster CR; nothing below can be attributed to it"
  exit 1
fi
rec "ok    credential read from the Cluster CR ($(wc -c < "${CRED}") bytes)"
grep -m1 'server:' "${CRED}" | sed 's/^/      /' || true

say "1. what it holds -- the left half"
if ! kctl --kubeconfig "${CRED}" auth can-i --list > "${CAN}" 2>&1; then
  rec "FAIL  the credential's inventory could not be read; see ${CAN}"
  exit 1
fi
cat "${CAN}"
rec "ok    inventory captured in ${CAN}"

say "2. what the platform's flows need -- the right half"
rm -f "${JAR}"
login_body=$(printf '{"name":"%s","password":"%s","loginType":"normal"}' "${ADMIN_USER}" "${ADMIN_PASS}")
code=$(curl -sk -m 20 -c "${JAR}" -X POST "${PIVOT_API}/login" -H 'Content-Type: application/json' \
  --data-binary "${login_body}" -o /dev/null -w '%{http_code}' 2> /dev/null) || code=000
if [ "${code}" != "200" ]; then
  rec "FAIL  login as ${ADMIN_USER} answered ${code}; the flows below need an admin session"
  exit 1
fi
rec "ok    logged in as ${ADMIN_USER} (the console's own path, not a shortcut)"

# probe NAME METHOD URL [body-file]
# Records ok / GAP / unclassified. A GAP is any refusal that names the
# credential: that is the platform being denied, not the caller. PROBE_CODE is
# the last HTTP status, so the caller can tell a success from a refusal.
PROBE_CODE=000
probe() {
  local name=$1 method=$2 url=$3 body=${4:-}
  local out
  if [ -n "${body}" ]; then
    out=$(curl -sk -m 30 -b "${JAR}" -X "${method}" "${url}" -H 'Content-Type: application/json' \
      --data-binary @"${body}" -w '\n%{http_code}' 2>&1) || out=""
  else
    out=$(curl -sk -m 30 -b "${JAR}" -X "${method}" "${url}" -w '\n%{http_code}' 2>&1) || out=""
  fi
  PROBE_CODE=$(printf '%s' "${out}" | tail -1)
  case "${PROBE_CODE}" in ''|*[!0-9]*) PROBE_CODE=000 ;; esac
  local msg
  msg=$(printf '%s' "${out}" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | head -1 || true)
  if printf '%s' "${msg}" | grep -q 'kubecube-member-agent'; then
    rec "GAP   ${name} [HTTP ${PROBE_CODE}] -> ${msg}"
  elif [ "${PROBE_CODE}" = "200" ]; then
    rec "ok    ${name}"
  else
    rec "?     ${name} [HTTP ${PROBE_CODE}] -> ${msg:-no message}"
  fi
}

# ---- cluster and node reads: the platform's views over the member -------------
probe "list clusters (nodes + namespaces + node metrics)" GET "${PIVOT_API}/clusters/info"
probe "clusters holding a namespace (scope read)"        GET "${PIVOT_API}/clusters/namespaces"
probe "space inventory (cross-cluster, ownership labels)" GET "${PIVOT_API}/clusters/subnamespaces?pageSize=200"

# ---- space lifecycle on the member -------------------------------------------
cat > "${out_dir}/credflow-create.json" <<EOF
{"cluster":"${CLUSTER}",
 "space":{"metadata":{"name":"${NS}","labels":{"kubecube.io/tenant":"${TENANT}","kubecube.io/project":"${PROJECT}"}}},
 "resourceQuota":{"metadata":{"name":"${CLUSTER}.${TENANT}.${PROJECT}.${NS}","namespace":"${NS}","labels":{"kubecube.io/quota":"${CLUSTER}.${TENANT}","kubecube.io/cluster":"${CLUSTER}","kubecube.io/tenant":"${TENANT}","kubecube.io/project":"${PROJECT}"}},"spec":{"hard":{"requests.cpu":"1","requests.memory":"1Gi"}}}}
EOF
created=0
probe "create a space (namespace + quota + rolebinding wait)" POST "${PIVOT_API}/clusters/nsquota" "${out_dir}/credflow-create.json"
if [ "${PROBE_CODE}" = "200" ]; then
  created=1
fi

# ---- the two rights derivation got wrong, asked directly ---------------------
# The delete flow's console route is not spelled here: a guessed URL answers 404
# and says nothing about the credential. auth can-i asks the member apiserver
# the question this acceptance is actually about.
say "3. the operations the platform performs, asked directly"
for verb in get list watch patch update delete; do
  ans=$(kctl --kubeconfig "${CRED}" auth can-i "${verb}" namespaces 2> /dev/null || true)
  case "${ans}" in
    yes*) rec "ok    credential may ${verb} namespaces (cluster-wide)" ;;
    no*) rec "GAP   credential may not ${verb} namespaces (cluster-wide)" ;;
    *) rec "?     credential: ${verb} namespaces -> ${ans:-no answer}" ;;
  esac
done
ans=$(kctl --kubeconfig "${CRED}" auth can-i get resourcequotas --all-namespaces 2> /dev/null || true)
case "${ans}" in
  yes*) rec "ok    credential may get resourcequotas (cluster-wide)" ;;
  no*) rec "GAP   credential may not get resourcequotas (cluster-wide)" ;;
  *) rec "?     credential: get resourcequotas -> ${ans:-no answer}" ;;
esac

# ---- the delete half of the walk, done with the credential itself ------------
# The create above proves the credential can make a space. Deleting one is the other
# half of the walk the platform performs, and `auth can-i delete` only says the rule
# exists — this asks the member's apiserver to actually carry it out, on the
# namespace the create just made.
if [ "${created}" -eq 1 ]; then
  say "4. the credential deletes the space it created"
  if kctl --kubeconfig "${CRED}" delete namespace "${NS}" --wait=true --timeout=120s > /dev/null 2>&1; then
    rec "ok    credential deleted namespace ${NS}"
    created=0
  else
    rec "GAP   credential could not delete namespace ${NS} it created"
  fi
fi

# ---- leave the member as it was found ---------------------------------------
if [ "${created}" -eq 1 ] && [ "${CLEANUP}" -eq 1 ]; then
  say "cleanup"
  if kctl delete namespace "${NS}" --wait=false > /dev/null 2>&1; then
    note "removed namespace ${NS} again"
  else
    note "could not remove namespace ${NS}; delete it before the next run"
  fi
fi

echo
say "verdict"
gaps=$(grep -c '^GAP' "${REPORT}" || true)
unknowns=$(grep -c '^?' "${REPORT}" || true)
oks=$(grep -c '^ok' "${REPORT}" || true)
rec "flows the credential was refused:  ${gaps}"
rec "flows that could not be classified: ${unknowns}"
rec "flows that succeeded:              ${oks}"

status=0
if [ "${gaps}" -gt 0 ]; then
  rec ""
  rec "Each GAP above is a permission agent-rbac.yaml does not grant and the platform"
  rec "needs. Add it from the refusal text, not from guesswork: the message names the"
  rec "verb, the resource and the namespace."
  status=1
fi
if [ "${unknowns}" -gt 0 ]; then
  rec ""
  rec "A flow marked '?' neither succeeded nor named the credential, so it is not"
  rec "evidence either way. Fix the flow before treating this run as a pass."
  status=1
fi
if [ "${oks}" -eq 0 ]; then
  rec "No flow succeeded; this run proves nothing."
  status=1
fi

echo
if [ "${status}" -eq 0 ]; then
  rec "CREDENTIAL ACCEPTANCE PASSED (${oks} flows; no refusal named the credential)"
else
  rec "CREDENTIAL ACCEPTANCE FAILED"
fi
echo "full report: ${REPORT}"
exit "${status}"
