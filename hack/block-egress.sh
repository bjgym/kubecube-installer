#!/usr/bin/env bash
#
# The offline-proof firewall for an acceptance run.
#
# Blocks the host's access to everything except the connection that carries your
# session and the local network, and logs every rejected attempt in the kernel
# log under the KUBECUBE-OFFLINE prefix. The acceptance scripts read that prefix:
# a logged rejection proves the install never reached out, and names the
# addresses an offline bundle has to carry.
#
# Needs root and iptables. TUNNEL_HOST is required: it is the address your SSH
# session arrives from, and blocking it would take away the run's own output.
# ALLOW_CIDRS lets the local network through (it carries no install traffic).
#
# Run:
#   sudo TUNNEL_HOST=<host> ./hack/block-egress.sh apply
#   sudo TUNNEL_HOST=<host> ./hack/block-egress.sh check
#   sudo ./hack/block-egress.sh undo
#
# apply is idempotent: it removes and recreates its own KUBECUBE-OFFLINE chain,
# so removing it never disturbs another firewall rule.

set -euo pipefail

TUNNEL_HOST=${TUNNEL_HOST:-}
ALLOW_CIDRS=${ALLOW_CIDRS:-"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"}
CHAIN=KUBECUBE-OFFLINE
LOG_PREFIX=KUBECUBE-OFFLINE

function undo() {
  # delete every reference first, then the chain itself
  while iptables -D OUTPUT -j "${CHAIN}" 2> /dev/null; do :; done
  iptables -F "${CHAIN}" 2> /dev/null || true
  iptables -X "${CHAIN}" 2> /dev/null || true
  echo "egress rules removed"
}

function show() {
  iptables -L "${CHAIN}" -n -v 2> /dev/null || echo "no ${CHAIN} chain"
}

function check() {
  echo "== external fetch (must fail) =="
  if curl -s -o /dev/null -m 8 https://quay.io/v2/ 2> /dev/null; then
    echo "  FAIL  quay.io answered; the block is not in force"
    return 1
  fi
  echo "  ok    quay.io unreachable"
  echo "== the session's own path (must stay open) =="
  if [ -n "${TUNNEL_HOST}" ] && iptables -C "${CHAIN}" -d "${TUNNEL_HOST}" -j RETURN 2> /dev/null; then
    echo "  ok    ${TUNNEL_HOST} is exempt"
  else
    echo "  FAIL  ${TUNNEL_HOST:-TUNNEL_HOST} is not exempt; the session may drop"
    return 1
  fi
}

function usage() {
  cat <<'USAGE'
block-egress.sh -- install, inspect or remove the offline-proof firewall

  sudo TUNNEL_HOST=<host> ./hack/block-egress.sh apply   # default
  sudo TUNNEL_HOST=<host> ./hack/block-egress.sh check
  sudo ./hack/block-egress.sh undo

  TUNNEL_HOST   required; the address your session arrives from
  ALLOW_CIDRS   local networks to exempt, default
                "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
USAGE
}

action=${1:-apply}
case "${action}" in
  apply|check|undo|help|-h|--help) ;;
  *)
    echo "block-egress: unknown action ${action}" >&2
    usage >&2
    exit 2
    ;;
esac

if [ "${action}" = "help" ] || [ "${action}" = "-h" ] || [ "${action}" = "--help" ]; then
  usage
  exit 0
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "block-egress: run as root; it edits the host firewall" >&2
  exit 2
fi
if ! command -v iptables > /dev/null 2>&1; then
  echo "block-egress: iptables is not installed" >&2
  exit 2
fi
if [ "${action}" = "undo" ]; then
  undo
  show
  exit 0
fi
if [ -z "${TUNNEL_HOST}" ]; then
  echo "block-egress: TUNNEL_HOST must be set to the address your session arrives from" >&2
  exit 2
fi

if [ "${action}" = "check" ]; then
  show
  check
  echo "EGRESS BLOCK CHECK PASSED"
  exit 0
fi

undo

iptables -N "${CHAIN}"
iptables -A "${CHAIN}" -o lo -j RETURN
# The session itself arrives over the tunnel; blocking it would take away the
# run's own output.
iptables -A "${CHAIN}" -d "${TUNNEL_HOST}" -j RETURN
# The local network carries no install traffic.
for cidr in ${ALLOW_CIDRS}; do
  iptables -A "${CHAIN}" -d "${cidr}" -j RETURN
done
# Multicast is the machine talking to its own network (avahi's mDNS among
# others), not the install reaching out. Letting it through keeps the rejection
# log about the install.
iptables -A "${CHAIN}" -d 224.0.0.0/4 -j RETURN
# Rate limited so a retry loop cannot flood the kernel log; the prefix is what
# the acceptance report greps for.
iptables -A "${CHAIN}" -m limit --limit 30/min -j LOG --log-prefix "${LOG_PREFIX} "
iptables -A "${CHAIN}" -j REJECT --reject-with icmp-port-unreachable
iptables -I OUTPUT 1 -j "${CHAIN}"

if ! iptables -L "${CHAIN}" -n > /dev/null 2>&1; then
  echo "EGRESS BLOCK FAILED: ${CHAIN} is not present after apply" >&2
  exit 1
fi

echo "EGRESS BLOCK ACTIVE except ${TUNNEL_HOST} and: ${ALLOW_CIDRS}"
echo "remove it with: sudo ./hack/block-egress.sh undo"
show
