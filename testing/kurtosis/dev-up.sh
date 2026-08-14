#!/usr/bin/env bash
# Start the test network with block explorers attached.
#
#   bash testing/kurtosis/dev-up.sh
#
# Wraps start.sh. CI is untouched: the explorer services are injected into a
# derived copy of the args file rather than into ci-args.yaml, so `run-ci.sh`
# and `start.sh` behave exactly as before.
#
# What you get:
#   Blockscout  — full L1 explorer, indexed inside the enclave
#   Dora        — L1 beacon-chain explorer
#   Otterscan   — L2 explorer, a container on the host reading the L2 RPC
#
# Images are reused by default (the network is usually already built). Set
# EEZ_DEV_BUILD=1 to rebuild them first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENCLAVE="${KURTOSIS_ENCLAVE:-eez-ci}"
BASE_ARGS="${1:-$HERE/ci-args.yaml}"
OTS_NAME="${EEZ_OTTERSCAN_NAME:-eez-otterscan}"
OTS_PORT="${EEZ_OTTERSCAN_PORT:-5100}"
OTS_IMAGE="${EEZ_OTTERSCAN_IMAGE:-otterscan/otterscan:latest}"

command -v docker >/dev/null || { echo "docker not found in PATH" >&2; exit 1; }
[[ -f "$BASE_ARGS" ]] || { echo "args file not found: $BASE_ARGS" >&2; exit 1; }

# ── derive an args file with the L1 explorers enabled ────────────────
# `additional_services` belongs to the ethereum_package block, so inject it
# immediately before the `eez:` block that follows.
DEV_ARGS="${TMPDIR:-/tmp}/eez-dev-args-$ENCLAVE.yaml"
if grep -qE "^[[:space:]]+additional_services:" "$BASE_ARGS"; then
    echo "==> $BASE_ARGS already sets additional_services; using it unchanged"
    cp "$BASE_ARGS" "$DEV_ARGS"
else
    awk '
        /^eez:/ && !injected {
            print "  # Injected by dev-up.sh — L1 execution + consensus explorers."
            print "  additional_services:"
            print "    - blockscout"
            print "    - dora"
            print ""
            injected = 1
        }
        { print }
    ' "$BASE_ARGS" > "$DEV_ARGS"
    grep -q "additional_services" "$DEV_ARGS" \
        || { echo "failed to inject additional_services into $BASE_ARGS" >&2; exit 1; }
fi
echo "==> dev args: $DEV_ARGS"

# ── bring the network up ─────────────────────────────────────────────
# Kurtosis cannot add a service that already exists, so a running enclave has
# to go before the explorer-enabled topology can be laid down. These enclaves
# are ephemeral test infrastructure; nothing in them is worth preserving.
if kurtosis enclave inspect "$ENCLAVE" >/dev/null 2>&1; then
    echo "==> removing the existing '$ENCLAVE' enclave first (all chain state is lost)"
    bash "$HERE/stop.sh"
fi

if [[ "${EEZ_DEV_BUILD:-0}" != "1" ]]; then
    export EEZ_SKIP_NODE_BUILD=1 EEZ_SKIP_PROOF_SIGNER_BUILD=1 EEZ_SKIP_DEPLOY_BUILD=1
fi
bash "$HERE/start.sh" "$DEV_ARGS"

# ── Otterscan against the L2 ─────────────────────────────────────────
# ERIGON_URL is read by the BROWSER, not by this container, so it has to be a
# host-reachable URL — which is exactly what `kurtosis port print` hands back.
_port() {
    local url
    url="$(kurtosis port print "$ENCLAVE" "$1" "$2" 2>/dev/null)" || return 1
    case "$url" in http*) printf '%s' "$url" ;; *) printf 'http://%s' "$url" ;; esac
}

L2_RPC="$(_port eez-node l2-rpc)"
[[ -n "$L2_RPC" ]] || { echo "could not resolve the L2 RPC port" >&2; exit 1; }

echo "==> starting Otterscan ($OTS_NAME) against $L2_RPC"
docker rm -f "$OTS_NAME" >/dev/null 2>&1 || true
docker run -d --name "$OTS_NAME" -p "$OTS_PORT:80" \
    -e ERIGON_URL="$L2_RPC" \
    "$OTS_IMAGE" >/dev/null

BLOCKSCOUT="$(_port blockscout-frontend http || _port blockscout http || true)"
DORA="$(_port dora http || true)"

cat <<EOF

════════════════════════════════════════
  Explorers
════════════════════════════════════════
L2 (Otterscan)   : http://localhost:$OTS_PORT
L1 (Blockscout)  : ${BLOCKSCOUT:-<not resolved — kurtosis enclave inspect $ENCLAVE>}
L1 beacon (Dora) : ${DORA:-<not resolved — kurtosis enclave inspect $ENCLAVE>}

Blockscout indexes from genesis and takes a minute or two to catch up.
Tear everything down with: bash testing/kurtosis/stop.sh
EOF
