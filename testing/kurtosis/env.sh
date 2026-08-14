# Session init for manual work against the Kurtosis test network.
#
#   source testing/kurtosis/env.sh
#
# Resolves the enclave's randomised host ports, pulls the deployment
# addresses out of the `eez-deployments` artifact, exports the deterministic
# dev keys, and reports whether settlement is still healthy.
#
# Safe to re-source at any time — every value is re-read from the live
# enclave, so run it again after `start.sh` hands out new ports.
#
# Deliberately does NOT `set -e`: this runs in your interactive shell.

# ── must be sourced ──────────────────────────────────────────────────
if [ -n "${BASH_VERSION:-}" ]; then
    _eez_self="${BASH_SOURCE[0]}"
    [ "$_eez_self" != "$0" ] || { echo "env.sh must be sourced: source $0" >&2; exit 1; }
else
    _eez_self="$0"
    case "${ZSH_EVAL_CONTEXT:-file}" in
        *file*) ;;
        *) echo "env.sh must be sourced: source $0" >&2; exit 1 ;;
    esac
fi

EEZ_KURTOSIS_DIR="$(cd "$(dirname "$_eez_self")" 2>/dev/null && pwd)"
# A relative source path resolves against the caller's cwd, so recover via git
# when this was sourced from somewhere other than the repo root.
if [ ! -f "$EEZ_KURTOSIS_DIR/start.sh" ]; then
    EEZ_KURTOSIS_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/testing/kurtosis"
fi
if [ ! -f "$EEZ_KURTOSIS_DIR/start.sh" ]; then
    echo "env.sh: cannot locate the repo. Source it from the repo root:" >&2
    echo "        source testing/kurtosis/env.sh" >&2
    unset _eez_self EEZ_KURTOSIS_DIR
    return 1
fi
EEZ_REPO="$(cd "$EEZ_KURTOSIS_DIR/../.." && pwd)"
unset _eez_self
export EEZ_KURTOSIS_DIR EEZ_REPO

export KURTOSIS_ENCLAVE="${KURTOSIS_ENCLAVE:-eez-ci}"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# ── prerequisites ────────────────────────────────────────────────────
_eez_missing=""
for _t in kurtosis cast forge jq curl; do
    command -v "$_t" >/dev/null 2>&1 || _eez_missing="$_eez_missing $_t"
done
unset _t
if [ -n "$_eez_missing" ]; then
    echo "env.sh: not in PATH:$_eez_missing" >&2
    unset _eez_missing
    return 1
fi
unset _eez_missing

# ── enclave ports ────────────────────────────────────────────────────
# `kurtosis port print` emits either "127.0.0.1:PORT" or "http://127.0.0.1:PORT";
# normalise both to a URL cast/curl accept.
_eez_port() {
    local url
    url="$(kurtosis port print "$KURTOSIS_ENCLAVE" "$1" "$2" 2>/dev/null)" || return 1
    case "$url" in
        http*) printf '%s' "$url" ;;
        "")    return 1 ;;
        *)     printf 'http://%s' "$url" ;;
    esac
}

L1="$(_eez_port el-1-reth-lighthouse rpc)"
if [ -z "$L1" ]; then
    echo "env.sh: enclave '$KURTOSIS_ENCLAVE' is not up (kurtosis enclave ls)." >&2
    echo "        start it with: bash testing/kurtosis/start.sh" >&2
    return 1
fi

L2="$(_eez_port eez-node l2-rpc)"
L1F="$(_eez_port eez-node l1-xchain)"
L2F="$(_eez_port eez-node l2-xchain)"
BUILDER="$(_eez_port el-2-reth-builder-lighthouse rbuilder-rpc)"
BEACON="$(_eez_port eez-follower http)"
export L1 L2 L1F L2F BUILDER BEACON

# ── deployment addresses ─────────────────────────────────────────────
# EEZ_REGISTRY_ADDRESS, EEZ_ROLLUP_ID, EEZL2_ADDRESS, EEZ_L1_L2_PROXY, …
EEZ_DEPLOY_DIR="${TMPDIR:-/tmp}/eez-env-$KURTOSIS_ENCLAVE"
rm -rf "$EEZ_DEPLOY_DIR" && mkdir -p "$EEZ_DEPLOY_DIR"
if kurtosis files download "$KURTOSIS_ENCLAVE" eez-deployments "$EEZ_DEPLOY_DIR" >/dev/null 2>&1; then
    set -a
    . "$EEZ_DEPLOY_DIR/deployments.env"
    set +a
    export EEZ_DEPLOY_DIR
    export EEZ_L2_GENESIS="$EEZ_DEPLOY_DIR/l2-genesis.json"
else
    echo "env.sh: could not download the eez-deployments artifact — is the deploy step done?" >&2
fi

# ── deterministic dev keys (private network only) ────────────────────
# Hardhat accounts 0/1/2, all funded on both chains.
#
#   KEY2  use this one. Funded on L1 and L2, untouched by the protocol.
#   KEY1  the proof signer / registered attester. It never sends transactions
#         (it signs off-chain), so it is safe to spend from; this is what
#         scripts/cross-chain-wave.sh uses as its L1 setup key.
#   KEY0  the live L1 poster. The composer sends postBatch from it every slot,
#         so a transaction of yours races its nonce and will never land.
#         Do NOT send L1 transactions from KEY0.
export KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export KEY2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ADDR0="$(cast wallet address --private-key $KEY0 2>/dev/null)"
ADDR1="$(cast wallet address --private-key $KEY1 2>/dev/null)"
ADDR2="$(cast wallet address --private-key $KEY2 2>/dev/null)"
export ADDR0 ADDR1 ADDR2

# ── helpers ──────────────────────────────────────────────────────────

# xsend <front-url> <raw-tx> — submit a signed cross-chain tx to an ingress
# front. Plain `cast send` cannot be used: it estimates gas first, and the
# estimate is forwarded upstream where the proxy call reverts. Build the tx
# with `cast mktx --gas-limit …` and pass the raw bytes here.
xsend() {
    if [ $# -ne 2 ]; then
        echo "usage: xsend <front-url> <0x-raw-tx>" >&2
        return 2
    fi
    local resp
    resp="$(curl -sS -X POST "$1" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$2\"],\"id\":1}")" || return 1
    printf '%s\n' "$resp"
    case "$resp" in *'"error"'*) return 1 ;; esac
}

# eez_status — re-print the endpoint summary and the settlement health check.
eez_status() {
    local l1h l2h l2s gap
    l1h="$(cast block-number --rpc-url "$L1" 2>/dev/null)"
    l2h="$(cast block-number --rpc-url "$L2" 2>/dev/null)"
    l2s="$(cast block safe --field number --rpc-url "$L2" 2>/dev/null)"

    printf '  L1  %-28s chain %s\n' "$L1"  "$(cast chain-id --rpc-url "$L1" 2>/dev/null)"
    printf '  L2  %-28s chain %s\n' "$L2"  "$(cast chain-id --rpc-url "$L2" 2>/dev/null)"
    printf '  L1F %-28s inbound  L1 -> L2\n' "$L1F"
    printf '  L2F %-28s outbound L2 -> L1\n' "$L2F"
    printf '  registry %s  rollupId %s\n' "${EEZ_REGISTRY_ADDRESS:-?}" "${EEZ_ROLLUP_ID:-?}"
    printf '  heads    L1 %s   L2 %s (safe %s)\n' "${l1h:-?}" "${l2h:-?}" "${l2s:-?}"

    # The only number that matters for settlement health is the UNPOSTED
    # WINDOW: L2 latest minus L2 safe. The proof signer refuses a window
    # wider than 512 L2 blocks, and an unposted window only grows — once
    # past the cap it can never come back under it.
    #
    # L2 height being ~6x L1 height is normal, not a lag: the sequencer
    # produces K = L1_block_time / L2_block_time blocks per L1 block.
    if [ -n "$l2h" ] && [ -n "$l2s" ]; then
        gap=$(( l2h - l2s ))
        printf '  window   %s / 512 unposted L2 blocks' "$gap"
        if [ "$gap" -gt 512 ]; then
            printf '  ** STALLED **\n'
            printf '\n  Settlement is past the signer cap and cannot recover.\n'
            printf '  Cross-chain txs will hang in the held pool forever.\n'
            printf '  Fix: bash testing/kurtosis/stop.sh && bash testing/kurtosis/start.sh\n'
        elif [ "$gap" -gt 256 ]; then
            printf '  -- lagging, watch it\n'
        else
            printf '  ok\n'
        fi
    fi
}

echo "eez test network — enclave '$KURTOSIS_ENCLAVE'"
eez_status
echo
echo "  keys     KEY2/ADDR2 — use this one.  KEY1 attester.  KEY0 is the poster, do not spend it."
echo "  helpers  xsend <front> <raw-tx>   eez_status"
echo "  guide    testing/kurtosis/PLAYBOOK.md"
