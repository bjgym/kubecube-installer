#!/usr/bin/env bash
#
# Pivot/member onboarding acceptance.
#
# Verifies, on a member cluster that a KubeCube pivot manages:
#   - the member is registered on the pivot and reports status=normal;
#   - the member-side warden is Running;
#   - the pivot reads the member through its proxy (admin gets 200);
#   - a non-admin user created through the pivot API is bound to a project or
#     tenant scope, and warden materialises its RoleBinding on the member;
#   - that user can read pods in the namespace it owns (200) and is refused in
#     default and kube-system (403), and is not a platform administrator.
#
# The member's apiserver makes the RBAC decision: the proxy impersonates the
# caller and forwards with the member kubeconfig, so a 403 here is the member's
# answer, not a pre-gate. A pod LIST is the honest probe; GET by name is not,
# because KubeCube's own pre-gate fires on namespaces and nodes.
#
# Needs root (or a readable member kubeconfig) on the member host, plus:
#   MEMBER_NAME        the member cluster's name as the pivot knows it (required)
#   ADMIN_PASS         the pivot administrator's password (required)
#   VERIFY_PASS        the password for the throwaway user this script creates
#                      (required; the account is created on first run and reused)
#   PIVOT_API          default https://<this host's IP>:30443
#   MEMBER_KUBECONFIG  default /etc/kubernetes/admin.conf
#   SCOPED_NS          namespace the non-admin is authorised in; default: the
#                      first namespace on the member carrying an owner label
#   MEMBER_NS          namespace the admin reads through the proxy; default: a
#                      platform-owned namespace, else any non-system one
#
# Optional: ADMIN_USER (default admin), SCOPE_TYPE/SCOPE_NAME/SCOPE_ROLE to
# override what SCOPED_NS's owner label implies, VERIFY_USER (default
# kc-verify-user), EVID (default /tmp/kubecube-onboarding-evidence),
# WAIT_SECONDS (default 180).
#
# Run:
#   sudo MEMBER_NAME=<member> ADMIN_PASS='<admin password>' \
#     VERIFY_PASS='<throwaway password>' ./hack/verify-onboarding.sh
#
# The evidence directory is left in place: it is the record of what was checked.
# Exit code 0 when every check passed, otherwise the number of failed checks.

set -euo pipefail

# --------------------------------------------------------------- parameters
PIVOT_API=${PIVOT_API:-}
MEMBER_NAME=${MEMBER_NAME:-}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=${ADMIN_PASS:-}
MEMBER_NS=${MEMBER_NS:-}
SCOPED_NS=${SCOPED_NS:-}
# Derived from SCOPED_NS's kubecube.io/namespace-owner label unless overridden.
SCOPE_TYPE=${SCOPE_TYPE:-}
SCOPE_NAME=${SCOPE_NAME:-}
# project-admin (project scope) / tenant-admin (tenant scope).
SCOPE_ROLE=${SCOPE_ROLE:-}
VERIFY_USER=${VERIFY_USER:-kc-verify-user}
VERIFY_PASS=${VERIFY_PASS:-}
MEMBER_KUBECONFIG=${MEMBER_KUBECONFIG:-/etc/kubernetes/admin.conf}
EVID=${EVID:-/tmp/kubecube-onboarding-evidence}
WAIT_SECONDS=${WAIT_SECONDS:-180}
CURL="curl -sk --max-time 30"

usage() {
  cat <<'USAGE'
verify-onboarding.sh -- KubeCube pivot/member onboarding acceptance

  PIVOT_API          pivot API, default https://<this host's IP>:30443
  MEMBER_NAME        the member cluster's name as the pivot knows it (required)
  ADMIN_USER         pivot admin user, default admin
  ADMIN_PASS         pivot admin password (required)
  MEMBER_NS          a namespace on the member to read through the proxy,
                     default: a platform-owned one, else any non-system one
  SCOPED_NS          namespace the non-admin user is authorised in,
                     default: the first namespace on the member that carries
                     kubecube.io/namespace-owner
  SCOPE_TYPE/NAME    override the scope derived from SCOPED_NS's owner label
                     (project|tenant)
  SCOPE_ROLE         override the role, default project-admin / tenant-admin
  VERIFY_USER        the non-admin account this script creates, default kc-verify-user
  VERIFY_PASS        its password (required; reused on a re-run)
  MEMBER_KUBECONFIG  member kubeconfig, default /etc/kubernetes/admin.conf
  EVID               evidence directory, default /tmp/kubecube-onboarding-evidence
  WAIT_SECONDS       how long to wait for warden to materialise RBAC, default 180

Exit code: 0 when everything passed, otherwise the number of failed checks.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "${MEMBER_NAME}" ]; then
  echo "verify-onboarding: MEMBER_NAME is required (the member cluster's name on the pivot)" >&2
  exit 2
fi
if [ -z "${ADMIN_PASS}" ]; then
  echo "verify-onboarding: ADMIN_PASS is required (the pivot administrator password)" >&2
  exit 2
fi
if [ -z "${VERIFY_PASS}" ]; then
  echo "verify-onboarding: VERIFY_PASS is required (password for the throwaway verify user)" >&2
  exit 2
fi

# ------------------------------------------------------------- small helpers
local_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
  if [ -z "${ip}" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  printf '%s' "${ip}"
}

if [ -z "${PIVOT_API}" ]; then
  PIVOT_API="https://$(local_ip):30443"
fi
PIVOT_API=${PIVOT_API%/}

PASSED=0
FAILED=0
STEP=0

step() {
  STEP=$((STEP + 1))
  printf '\n[%02d] %s\n' "${STEP}" "$1"
}

ok() {
  PASSED=$((PASSED + 1))
  printf '     ok    %s\n' "$1"
  [ -n "${2:-}" ] && printf '           evidence: %s\n' "$2"
  return 0
}

fail() {
  FAILED=$((FAILED + 1))
  printf '     FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '           evidence: %s\n' "$2"
  return 0
}

# http <method> <url> <body-file-or-empty> <out-file> <jar>
http() {
  local method=$1 url=$2 body=$3 out=$4 jar=$5
  if [ -n "${body}" ]; then
    ${CURL} -X "${method}" -H 'Content-Type: application/json' \
      -b "${jar}" -c "${jar}" --data-binary "@${body}" -o "${out}" -w '%{http_code}' "${url}" || true
  else
    ${CURL} -X "${method}" -b "${jar}" -c "${jar}" -o "${out}" -w '%{http_code}' "${url}" || true
  fi
}

# json_item <file> <key> <value> -- prints the first compact JSON object that
# carries "key":"value". gin writes c.JSON without indentation, and the only
# nested objects here are string maps, so splitting on "},{" is safe.
json_item() {
  sed 's/},{/}\n{/g' "$1" 2>/dev/null | grep -F "\"$2\":\"$3\"" | head -1
}

has_field() { # <file> <"key":"value">
  grep -qF "$2" "$1" 2>/dev/null
}

kubectl_member() {
  kubectl --kubeconfig="${MEMBER_KUBECONFIG}" "$@"
}

ns_owner_label() { # <namespace> -> "project-x" / "tenant-y" / ""
  local ns=$1 v
  v=$(kubectl_member get namespace "${ns}" -o yaml 2>/dev/null \
    | awk -F': *' '/^[[:space:]]*kubecube\.io\/namespace-owner:/{print $2; exit}' | tr -d '"' || true)
  if [ -z "${v}" ]; then
    v=$(kubectl_member get namespace "${ns}" -o go-template='{{index .metadata.labels "kubecube.io/namespace-owner"}}' 2>/dev/null || true)
  fi
  printf '%s' "${v}"
}

# ---------------------------------------------------------------- preflight
step "preflight: tools, pivot reachability, member kubeconfig"
mkdir -p "${EVID}"
: > "${EVID}/admin.cookies"
: > "${EVID}/user.cookies"

preflight_ok=1
for c in curl kubectl awk sed grep head tr cut; do
  command -v "${c}" > /dev/null 2>&1 || { printf '     FAIL  %s is not installed\n' "${c}"; preflight_ok=0; }
done
if [ -z "${MEMBER_NAME}" ]; then
  printf '     FAIL  MEMBER_NAME is not set (the member cluster name as the pivot knows it)\n'
  preflight_ok=0
fi
if [ ! -f "${MEMBER_KUBECONFIG}" ]; then
  printf '     note  %s does not exist; falling back to %s\n' "${MEMBER_KUBECONFIG}" "${KUBECONFIG:-/root/.kube/config}"
  if [ -f "${KUBECONFIG:-/root/.kube/config}" ]; then
    MEMBER_KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
  else
    printf '     FAIL  no member kubeconfig found\n'
    preflight_ok=0
  fi
fi
if [ "${preflight_ok}" -eq 0 ]; then
  FAILED=$((FAILED + 1))
  printf '\nONBOARDING FAILED: preflight did not pass. Nothing was verified.\n'
  exit "${FAILED}"
fi

if kubectl_member get ns > "${EVID}/00-member-namespaces.txt" 2>&1 && [ -s "${EVID}/00-member-namespaces.txt" ]; then
  ok "member kubeconfig ${MEMBER_KUBECONFIG} answers" "${EVID}/00-member-namespaces.txt"
else
  fail "kubectl cannot list namespaces with ${MEMBER_KUBECONFIG}" "${EVID}/00-member-namespaces.txt"
fi

# the login route sits outside the auth middleware, so any answer that is not a
# connection failure proves the pivot is reachable
probe=$(${CURL} -o "${EVID}/00-pivot-probe.txt" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -d '{}' \
  "${PIVOT_API}/api/v1/cube/login" 2>/dev/null) || probe=000
if [ "${probe}" = "000" ]; then
  fail "cannot reach ${PIVOT_API} (set PIVOT_API to the pivot's API address)" "${EVID}/00-pivot-probe.txt"
  printf '\nONBOARDING FAILED: the pivot API is unreachable.\n'
  exit "${FAILED}"
fi
ok "pivot ${PIVOT_API} reachable (login answered HTTP ${probe})" "${EVID}/00-pivot-probe.txt"

SUMMARIZED=0
on_exit() {
  local rc=$?
  if [ "${SUMMARIZED}" -eq 1 ]; then
    exit "${rc}"
  fi
  printf '\nONBOARDING FAILED: aborted before the summary (exit %s). Evidence in %s\n' "${rc}" "${EVID}" >&2
  [ "${rc}" -ne 0 ] || rc=1
  exit "${rc}"
}
trap on_exit EXIT

# ------------------------------------------------------------------ 1. login
step "pivot login as ${ADMIN_USER}"
printf '{"name":"%s","password":"%s","loginType":"normal"}' "${ADMIN_USER}" "${ADMIN_PASS}" > "${EVID}/01-login-request.json"
code=$(http POST "${PIVOT_API}/api/v1/cube/login" "${EVID}/01-login-request.json" "${EVID}/01-login.json" "${EVID}/admin.cookies")
if [ "${code}" = "200" ] && grep -q 'Authorization' "${EVID}/admin.cookies"; then
  ok "HTTP ${code}, Authorization cookie captured" "${EVID}/01-login.json"
else
  fail "HTTP ${code} (expected 200 and an Authorization cookie)" "${EVID}/01-login.json"
  printf '\nCannot continue without an admin session.\n'
  SUMMARIZED=1
  exit $((FAILED > 0 ? FAILED : 1))
fi

# ------------------------------------------------------- 2. member is listed
step "member ${MEMBER_NAME} appears in clusters/info with status=normal"
code=$(http GET "${PIVOT_API}/api/v1/cube/clusters/info" "" "${EVID}/02-clusters-info.json" "${EVID}/admin.cookies")
item=$(json_item "${EVID}/02-clusters-info.json" clusterName "${MEMBER_NAME}" || true)
if [ "${code}" != "200" ]; then
  fail "HTTP ${code} from clusters/info" "${EVID}/02-clusters-info.json"
elif [ -z "${item}" ]; then
  fail "cluster ${MEMBER_NAME} is not in the list" "${EVID}/02-clusters-info.json"
elif printf '%s' "${item}" | grep -qF '"status":"normal"'; then
  ok "listed and status=normal" "${EVID}/02-clusters-info.json"
else
  fail "listed but status is $(printf '%s' "${item}" | grep -oE '"status":"[^"]*"' | head -1), expected \"status\":\"normal\"" "${EVID}/02-clusters-info.json"
fi

# --------------------------------------------------- 3. member-side warden up
step "member-side warden is online (kubectl -n kubecube-system)"
kubectl_member -n kubecube-system get pods -o wide > "${EVID}/03-warden-pods.txt" 2>&1 || true
# The Running pod, not the first line: a rollout leaves the previous pod
# Terminating for as long as its volumes take to detach, and a check that reads
# the first line reports the cluster as broken for the whole of that window. That
# happened here: a warden stuck in Terminating for 16 hours turned a passing
# member into three failures, and the failure pointed at the pod rather than at
# the thing being verified.
warden_line=$(grep -E '^warden-[a-z0-9]+-[a-z0-9]+' "${EVID}/03-warden-pods.txt" | grep ' Running ' | head -1 || true)
if [ -z "${warden_line}" ]; then
  any_warden=$(grep -E '^warden-[a-z0-9]+-[a-z0-9]+' "${EVID}/03-warden-pods.txt" | head -1 || true)
  if [ -n "${any_warden}" ]; then
    fail "no warden pod is Running: ${any_warden}" "${EVID}/03-warden-pods.txt"
  else
    fail "no warden pod in kubecube-system on the member" "${EVID}/03-warden-pods.txt"
  fi
else
  ok "warden pod Running: $(printf '%s' "${warden_line}" | awk '{print $1}')" "${EVID}/03-warden-pods.txt"
fi
kubectl_member -n kubecube-system get deploy warden -o wide > "${EVID}/03-warden-deploy.txt" 2>&1 || true

# ------------------------------------- 4. resolve the namespaces and the scope
step "resolve MEMBER_NS, SCOPED_NS and the scope that owns it"
ns_list=$(kubectl_member get namespaces -o name 2>/dev/null | sed 's|^namespace/||' || true)
printf '%s\n' "${ns_list}" > "${EVID}/04-namespaces.txt"

if [ -z "${MEMBER_NS}" ]; then
  MEMBER_NS=$(kubectl_member get namespaces -l kubecube.io/namespace-owner -o name 2>/dev/null \
    | sed 's|^namespace/||' | head -1 || true)
fi
if [ -z "${MEMBER_NS}" ]; then
  MEMBER_NS=$(printf '%s\n' "${ns_list}" | grep -vE '^(kube-system|kube-public|kube-node-lease|kubecube-system)$' | head -1 || true)
fi
[ -n "${MEMBER_NS}" ] || MEMBER_NS=default

if [ -z "${SCOPED_NS}" ]; then
  SCOPED_NS=$(kubectl_member get namespaces -l kubecube.io/namespace-owner -o name 2>/dev/null \
    | sed 's|^namespace/||' | head -1 || true)
fi

owner=""
if [ -n "${SCOPED_NS}" ]; then
  owner=$(ns_owner_label "${SCOPED_NS}" || true)
fi

if [ -z "${SCOPE_TYPE}" ] && [ -n "${owner}" ]; then
  case "${owner}" in
    project-*) SCOPE_TYPE=project; SCOPE_NAME=${owner#project-} ;;
    tenant-*)  SCOPE_TYPE=tenant;  SCOPE_NAME=${owner#tenant-}  ;;
  esac
fi
[ -n "${SCOPE_ROLE}" ] || { [ "${SCOPE_TYPE}" = "tenant" ] && SCOPE_ROLE=tenant-admin || SCOPE_ROLE=project-admin; }

{
  printf 'MEMBER_NS=%s\nSCOPED_NS=%s\nowner_label=%s\nSCOPE_TYPE=%s\nSCOPE_NAME=%s\nSCOPE_ROLE=%s\n' \
    "${MEMBER_NS}" "${SCOPED_NS}" "${owner}" "${SCOPE_TYPE}" "${SCOPE_NAME}" "${SCOPE_ROLE}"
} > "${EVID}/04-resolved.txt"

if [ -z "${SCOPED_NS}" ] || [ -z "${SCOPE_TYPE}" ] || [ -z "${SCOPE_NAME}" ]; then
  fail "could not resolve an owned namespace; set SCOPED_NS + SCOPE_TYPE + SCOPE_NAME by hand" "${EVID}/04-resolved.txt"
  printf '\nHints: kubectl --kubeconfig=%s get ns -l kubecube.io/namespace-owner\n' "${MEMBER_KUBECONFIG}"
  SUMMARIZED=1
  exit $((FAILED > 0 ? FAILED : 1))
fi
ok "MEMBER_NS=${MEMBER_NS} SCOPED_NS=${SCOPED_NS} scope=${SCOPE_TYPE}/${SCOPE_NAME} role=${SCOPE_ROLE}" "${EVID}/04-resolved.txt"

# --------------------------------------- 5. the platform reads member through
#                                             the proxy (200)
step "admin reads member ${MEMBER_NS} pods through the proxy"
proxy_url() { printf '%s/api/v1/cube/proxy/clusters/%s/api/v1/namespaces/%s/%s' "${PIVOT_API}" "$1" "$2" "$3"; }
code=$(http GET "$(proxy_url "${MEMBER_NAME}" "${MEMBER_NS}" "pods?pageSize=200")" "" \
  "${EVID}/05-admin-pods.json" "${EVID}/admin.cookies")
if [ "${code}" = "200" ]; then
  ok "HTTP 200, $(grep -oF '"kind":"PodList"' "${EVID}/05-admin-pods.json" > /dev/null && echo 'PodList' || echo 'a list') returned" "${EVID}/05-admin-pods.json"
else
  fail "HTTP ${code} (expected 200: the member apiserver serves admin via the synced platform-admin ClusterRoleBinding)" "${EVID}/05-admin-pods.json"
fi

# ---------------------------------------------------- 6. create the plain user
step "create non-admin user ${VERIFY_USER}"
printf '{"apiVersion":"user.kubecube.io/v1","kind":"User","metadata":{"name":"%s"},"spec":{"password":"%s","displayName":"%s"}}' \
  "${VERIFY_USER}" "${VERIFY_PASS}" "${VERIFY_USER}" > "${EVID}/06-create-user-request.json"
code=$(http POST "${PIVOT_API}/api/v1/cube/user/" "${EVID}/06-create-user-request.json" \
  "${EVID}/06-create-user.json" "${EVID}/admin.cookies")
if [ "${code}" = "200" ]; then
  ok "HTTP 200, user created" "${EVID}/06-create-user.json"
elif grep -qF 'exists' "${EVID}/06-create-user.json" 2>/dev/null; then
  ok "user already exists (idempotent re-run)" "${EVID}/06-create-user.json"
else
  fail "HTTP ${code} (expected 200; a 307 means the trailing slash was dropped)" "${EVID}/06-create-user.json"
fi

# ------------------------------------------------- 7. bind it to a real scope
step "bind ${VERIFY_USER} to ${SCOPE_TYPE}/${SCOPE_NAME} as ${SCOPE_ROLE}"
case "${SCOPE_TYPE}" in
  project) scope_label_key=kubecube.io/project ;;
  tenant)  scope_label_key=kubecube.io/tenant  ;;
  *)       scope_label_key="" ;;
esac
if [ -z "${scope_label_key}" ]; then
  fail "SCOPE_TYPE '${SCOPE_TYPE}' is not project or tenant" "${EVID}/04-resolved.txt"
else
  printf '{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"RoleBinding","metadata":{"name":"kc-verify-binding","namespace":"default","labels":{"%s":"%s"}},"subjects":[{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"%s"}],"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"%s"}}' \
    "${scope_label_key}" "${SCOPE_NAME}" "${VERIFY_USER}" "${SCOPE_ROLE}" > "${EVID}/07-binding-request.json"
  code=$(http POST "${PIVOT_API}/api/v1/cube/authorization/bindings" "${EVID}/07-binding-request.json" \
    "${EVID}/07-binding.json" "${EVID}/admin.cookies")
  if [ "${code}" = "200" ]; then
    ok "HTTP 200, scope binding recorded on the User CR" "${EVID}/07-binding.json"
  else
    fail "HTTP ${code} (expected 200; 403 means the caller does not reach this scope)" "${EVID}/07-binding.json"
  fi
fi

# ------------------------- 8. wait for warden to materialise the member RBAC
step "warden materialises a RoleBinding for ${VERIFY_USER} in ${SCOPED_NS} (up to ${WAIT_SECONDS}s)"
deadline=$((SECONDS + WAIT_SECONDS))
found=0
while [ "${SECONDS}" -lt "${deadline}" ]; do
  kubectl_member -n "${SCOPED_NS}" get rolebindings -o json > "${EVID}/08-rolebindings.json" 2>/dev/null || true
  if grep -qF "\"name\": \"${VERIFY_USER}\"" "${EVID}/08-rolebindings.json" 2>/dev/null \
     || grep -qF "\"name\":\"${VERIFY_USER}\"" "${EVID}/08-rolebindings.json" 2>/dev/null; then
    found=1
    break
  fi
  sleep 5
done
if [ "${found}" -eq 1 ]; then
  ok "RoleBinding present in ${SCOPED_NS} for ${VERIFY_USER}" "${EVID}/08-rolebindings.json"
else
  fail "no RoleBinding naming ${VERIFY_USER} in ${SCOPED_NS} after ${WAIT_SECONDS}s" "${EVID}/08-rolebindings.json"
fi
kubectl_member get clusterrolebindings -o json > "${EVID}/08-clusterrolebindings.json" 2>/dev/null || true

# --------------------------------------------- 9. the user logs in on its own
step "login as ${VERIFY_USER} (its own token, not the admin's)"
printf '{"name":"%s","password":"%s","loginType":"normal"}' "${VERIFY_USER}" "${VERIFY_PASS}" > "${EVID}/09-login-request.json"
code=$(http POST "${PIVOT_API}/api/v1/cube/login" "${EVID}/09-login-request.json" \
  "${EVID}/09-login.json" "${EVID}/user.cookies")
if [ "${code}" = "200" ] && grep -q 'Authorization' "${EVID}/user.cookies"; then
  ok "HTTP 200, own Authorization cookie captured" "${EVID}/09-login.json"
else
  fail "HTTP ${code} (expected 200)" "${EVID}/09-login.json"
fi

# --------------------------- 10. the user reads the namespace it was given
step "${VERIFY_USER} reads pods in the authorised namespace ${SCOPED_NS} -> 200"
code=""
deadline=$((SECONDS + WAIT_SECONDS))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  code=$(http GET "$(proxy_url "${MEMBER_NAME}" "${SCOPED_NS}" "pods?pageSize=200")" "" \
    "${EVID}/10-user-scoped-pods.json" "${EVID}/user.cookies")
  [ "${code}" = "200" ] && break
  sleep 5
done
if [ "${code}" = "200" ]; then
  ok "HTTP 200 in ${SCOPED_NS}" "${EVID}/10-user-scoped-pods.json"
else
  fail "HTTP ${code} in ${SCOPED_NS} (expected 200)" "${EVID}/10-user-scoped-pods.json"
fi

# -------------------------- 11/12. the user is refused elsewhere
for ns in default kube-system; do
  step "${VERIFY_USER} reads pods in ${ns} -> 403"
  code=$(http GET "$(proxy_url "${MEMBER_NAME}" "${ns}" "pods?pageSize=200")" "" \
    "${EVID}/11-user-${ns}-pods.json" "${EVID}/user.cookies")
  if [ "${code}" = "403" ]; then
    ok "HTTP 403 in ${ns}" "${EVID}/11-user-${ns}-pods.json"
  elif [ "${ns}" = "${SCOPED_NS}" ]; then
    ok "skipped: ${ns} is the authorised namespace" "${EVID}/11-user-${ns}-pods.json"
  else
    fail "HTTP ${code} in ${ns} (expected 403)" "${EVID}/11-user-${ns}-pods.json"
  fi
done

# --------------------------------- 13. the user is NOT a platform admin
step "${VERIFY_USER} is not a platform administrator"
code=$(http GET "${PIVOT_API}/api/v1/cube/authorization/identities?user=${VERIFY_USER}" "" \
  "${EVID}/13-identities.json" "${EVID}/admin.cookies")
if [ "${code}" != "200" ]; then
  fail "HTTP ${code} from authorization/identities" "${EVID}/13-identities.json"
elif has_field "${EVID}/13-identities.json" '"platformAdmin":true'; then
  fail "identities reports platformAdmin=true" "${EVID}/13-identities.json"
elif has_field "${EVID}/13-identities.json" '"platformAdmin":false'; then
  ok "platformAdmin=false" "${EVID}/13-identities.json"
else
  fail "identities carries no platformAdmin field" "${EVID}/13-identities.json"
fi
# and the raw status field on the User CR, which is what the check above reads.
# ListUsers matches the query fuzzily, so this only counts when exactly one user
# came back; otherwise identities above is the authority.
code=$(http GET "${PIVOT_API}/api/v1/cube/user?query=${VERIFY_USER}" "" \
  "${EVID}/13-user-status.json" "${EVID}/admin.cookies")
if [ "${code}" = "200" ]; then
  total=$(grep -oE '"total":[0-9]+' "${EVID}/13-user-status.json" | head -1 | cut -d: -f2 || true)
  if [ "${total}" = "1" ]; then
    if has_field "${EVID}/13-user-status.json" '"platformAdmin":true'; then
      fail "User CR status.platformAdmin is true" "${EVID}/13-user-status.json"
    else
      ok "User CR status carries no platformAdmin=true" "${EVID}/13-user-status.json"
    fi
  else
    printf '     note  query matched %s user(s); identities above is the gate\n' "${total:-unknown}"
    printf '           evidence: %s\n' "${EVID}/13-user-status.json"
  fi
else
  printf '     note  could not read the User CR (HTTP %s); identities above is the gate\n' "${code}"
fi

# --------------------------------------------------------------- 14. summary
step "summary"
cat > "${EVID}/14-summary.txt" <<SUMMARY
pivot            ${PIVOT_API}
member           ${MEMBER_NAME}
member kubeconfig ${MEMBER_KUBECONFIG}
MEMBER_NS        ${MEMBER_NS}
SCOPED_NS        ${SCOPED_NS}
scope            ${SCOPE_TYPE}/${SCOPE_NAME} as ${SCOPE_ROLE}
verify user      ${VERIFY_USER}
checks passed    ${PASSED}
checks failed    ${FAILED}
SUMMARY
cat "${EVID}/14-summary.txt"

printf '\n'
if [ "${FAILED}" -eq 0 ]; then
  printf 'ONBOARDING PASSED (%d checks)\n' "${PASSED}"
  SUMMARIZED=1
  exit 0
fi
printf 'ONBOARDING FAILED: %d of %d checks failed. Evidence in %s\n' "${FAILED}" "$((PASSED + FAILED))" "${EVID}"
SUMMARIZED=1
exit "${FAILED}"
