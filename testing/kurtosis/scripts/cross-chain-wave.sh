#!/usr/bin/env bash
# Run cross-chain waves against the CI enclave.
#
# MODES (EEZ_WAVE_MODE, default "mixed"):
#   inbound     — L1→L2 only (deposit + setValue + setValueNoRet, direct + wrapper)
#   outbound    — L2→L1 only (withdraw + setValue + setValueNoRet, direct + wrapper)
#   mixed       — inbound AND outbound, submitted together so they share a Sync block
#   mixed-pure  — mixed + pure-L2 filler txs interleaved
#
# Cross-chain submission goes to the transparent FRONTS published by eez-node:
#   inbound  → L1 front  ($L1F, enclave port l1-xchain)  (held Inbound,  effect on L2)
#   outbound → L2 front  ($L2F, enclave port l2-xchain)  (held Outbound, effect on L1)
# Pure-L2 txs go to the normal L2 RPC mempool ($L2).
#
# OPS (EEZ_WAVE_OPS, default: the mode's built-in list)
#   Each wave fires the ops named in EEZ_WAVE_OPS, in order, separated by
#   commas. An op is either built in — "<side>:<kind>", one of
#       in:set  in:noret  in:dep  in:wrap  out:set  out:noret  out:wd  out:wrap
#   — or external: "ext:<command>", where <command> is run by this harness and
#   prints the transaction it wants sent. External ops are registered in
#   TX_META and counted in the tallies exactly like the built-ins, and the
#   hit-rate and bundle-drop accounting below is unchanged by them.
#
#   Setup that only a built-in op needs (the Value targets, their cross-chain
#   proxies, and the wrappers) is skipped when the op list contains no built-in
#   op for that side, so a consumer can run its own ops alone:
#
#       EEZ_WAVE_OPS="ext:./place.sh,ext:./cancel.sh" ./cross-chain-wave.sh
#
# Requires cast, forge, jq, curl, kurtosis, and openssl.

set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# ── Op dispatch (EEZ_WAVE_OPS) ────────────────────────────────────────
# The built-in workload, as an op list per mode. Order matters: the wrapper
# runs LAST on each side so its value is the expected final Value.value().
DEFAULT_OPS_IN="in:set,in:noret,in:dep,in:wrap"
DEFAULT_OPS_OUT="out:set,out:noret,out:wd,out:wrap"

# wave_ops <mode> → one op spec per line, honouring EEZ_WAVE_OPS.
# Specs are comma-separated; surrounding whitespace is trimmed. An external
# op's command may contain spaces (its own arguments) but not a comma.
wave_ops() {
    local mode="$1" list="${EEZ_WAVE_OPS:-}" spec
    if [[ -z "$list" ]]; then
        case "$mode" in
            inbound)          list="$DEFAULT_OPS_IN" ;;
            outbound)         list="$DEFAULT_OPS_OUT" ;;
            mixed|mixed-pure) list="$DEFAULT_OPS_IN,$DEFAULT_OPS_OUT" ;;
            *) echo "cross-chain wave: unknown mode '$mode'" >&2; return 1 ;;
        esac
    fi
    while IFS= read -r spec; do
        spec="${spec#"${spec%%[![:space:]]*}"}"
        spec="${spec%"${spec##*[![:space:]]}"}"
        [[ -n "$spec" ]] && printf '%s\n' "$spec"
    done < <(printf '%s\n' "$list" | tr ',' '\n')
    return 0
}

# wave_arg_for <op> <wave> → a built-in op's argument for this wave. External
# and revert ops take none; they are handed the wave number instead.
wave_arg_for() {
    case "$1" in
        in:set)    echo $((100 + $2)) ;;
        in:noret)  echo $((200 + $2)) ;;
        in:wrap)   echo $((300 + $2)) ;;
        in:dep)    echo $(($2 * 10000000000000)) ;;   # w * 1e13 wei
        out:set)   echo $((400 + $2)) ;;
        out:noret) echo $((500 + $2)) ;;
        out:wrap)  echo $((600 + $2)) ;;
        out:wd)    echo $(($2 * 5000000000000)) ;;    # w * 5e12 wei
        *)         echo "" ;;
    esac
}

# ── External op protocol (ext:) ───────────────────────────────────────
# The harness runs the consumer's command with the enclave endpoints in the
# environment (the EEZ_WAVE_* variables set by run_ext_op, plus everything in
# the enclave's deployments.env) and the wave number as $1. The command prints
# on stdout either a bare raw signed transaction
#
#     0x02f8...
#
# or a block of key=value lines:
#
#     raw=0x02f8...      required — the signed transaction to submit
#     side=in|out|l1|l2  where to submit it; default "out"
#     kind=<label>       recorded in TX_META and the per-kind tally; default
#                        "ext". The built-in kinds are reserved.
#     arg=<label>        free-form value recorded in TX_META; default empty
#
# side: in → the L1 front (held Inbound)    l1 → the L1 mempool
#       out → the L2 front (held Outbound)  l2 → the L2 mempool
#
# Empty stdout means "nothing to send this wave": the op is skipped and not
# counted. Anything else is a harness failure and stops the run. An external
# op signs with its own keys and so owns its own nonces.
RESERVED_OP_KINDS="set noret wrap dep wd rev"

# ext_op_parse <stdout> → "raw|side|kind|arg", or nothing if the op declined.
ext_op_parse() {
    local out="$1" line key value reserved raw="" side="out" kind="ext" arg=""
    out="${out%"${out##*[![:space:]]}"}"
    [[ -n "$out" ]] || return 0
    if [[ "$out" =~ ^0x[0-9a-fA-F]+$ ]]; then
        raw="$out"
    else
        while IFS= read -r line; do
            [[ -n "${line//[[:space:]]/}" ]] || continue
            key="${line%%=*}"; value="${line#*=}"
            case "$key" in
                raw)  raw="$value" ;;
                side) side="$value" ;;
                kind) kind="$value" ;;
                arg)  arg="$value" ;;
                *) echo "external op: unknown output key '$key'" >&2; return 1 ;;
            esac
        done <<<"$out"
    fi
    [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]] \
        || { echo "external op: no raw signed transaction (raw='$raw')" >&2; return 1; }
    case "$side" in in|out|l1|l2) ;;
        *) echo "external op: unknown side '$side'" >&2; return 1 ;;
    esac
    for reserved in $RESERVED_OP_KINDS; do
        [[ "$kind" != "$reserved" ]] \
            || { echo "external op: kind '$kind' is reserved for built-in ops" >&2; return 1; }
    done
    [[ "$kind" != *"|"* && "$arg" != *"|"* ]] \
        || { echo "external op: kind and arg may not contain '|'" >&2; return 1; }
    printf '%s|%s|%s|%s\n' "$raw" "$side" "$kind" "$arg"
}

# Everything above is pure, so sourcing this script yields the op helpers
# without touching an enclave — scripts/verify-harness-hooks.sh relies on it.
# Everything below needs a running enclave.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

K="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$K/../.." && pwd)"
ENCLAVE="${KURTOSIS_ENCLAVE:-eez-ci}"
LOG_DIR="$REPO/datadir/smoke-logs"
mkdir -p "$LOG_DIR"

MODE="${EEZ_WAVE_MODE:-mixed}"
WAVES="${EEZ_WAVE_COUNT:-3}"

OPS=()
while IFS= read -r op; do OPS+=("$op"); done < <(wave_ops "$MODE")
(( ${#OPS[@]} )) \
    || { echo "cross-chain wave: no ops for mode='$MODE' EEZ_WAVE_OPS='${EEZ_WAVE_OPS:-}'"; exit 1; }
# Which built-in sides are in play. An ext: op declares its own side at run
# time, so it contributes to neither and needs none of their setup.
HAS_IN=0; HAS_OUT=0
for op in "${OPS[@]}"; do
    case "$op" in
        in:*)  HAS_IN=1 ;;
        out:*) HAS_OUT=1 ;;
        ext:*) ;;
        *) echo "cross-chain wave: bad op '$op' in EEZ_WAVE_OPS"; exit 1 ;;
    esac
done

for t in cast forge jq curl kurtosis openssl; do command -v "$t" >/dev/null || { echo "$t not in PATH"; exit 1; }; done

# L1 is the canonical shared chain; fronts are published by eez-node.
_port() { kurtosis port print "$ENCLAVE" "$1" "$2" 2>/dev/null || true; }
_http() { case "$1" in http*) echo "$1";; "") echo "";; *) echo "http://$1";; esac; }
: "${L1:=$(_http "$(_port el-1-reth-lighthouse rpc)")}"
: "${L2:=$(_http "$(_port eez-node l2-rpc)")}"
: "${L1F:=$(_http "$(_port eez-node l1-xchain)")}"
: "${L2F:=$(_http "$(_port eez-node l2-xchain)")}"
[[ -n "$L1" && -n "$L2" && -n "$L1F" && -n "$L2F" ]] \
    || { echo "could not resolve enclave ports — is '$ENCLAVE' up? (kurtosis enclave inspect $ENCLAVE)"; exit 1; }

NODE_LOG="${EEZ_NODE_LOG:-$LOG_DIR/wave-$MODE-node.log}"
SIGNER_LOG="${EEZ_PROOF_SIGNER_LOG:-$LOG_DIR/wave-$MODE-proof-signer.log}"
DEPLOY_DIR="$(mktemp -d /tmp/eez-deployments.XXXXXX)"
trap 'rm -rf "$DEPLOY_DIR"' EXIT

# Pull the deployment artifact from the enclave by default.
if [[ "${EEZ_USE_LOCAL_DEPLOYMENTS:-0}" == "1" && -f "$REPO/deployments.env" ]]; then
    set -a; source "$REPO/deployments.env"; set +a
else
    kurtosis files download "$ENCLAVE" eez-deployments "$DEPLOY_DIR" >/dev/null 2>&1 \
        || { echo "kurtosis files download failed — is '$ENCLAVE' up and deployed?"; exit 1; }
    set -a; source "$DEPLOY_DIR/deployments.env"; set +a
fi
[[ -n "${EEZ_REGISTRY_ADDRESS:-}" ]] || { echo "EEZ_REGISTRY_ADDRESS unset — deployments.env incomplete"; exit 1; }

# Hardhat accounts are funded on L2; L1 actors are funded below.
HH_KEY_2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a   # L2 contract deployer / L2 proxy creator
# Fresh users avoid stale held-pool nonce state from earlier interrupted runs.
HH_KEY_REV_IN="0x$(openssl rand -hex 32)"
HH_ADDR_REV_IN=$(cast wallet address --private-key "$HH_KEY_REV_IN")
HH_KEY_REV_OUT="0x$(openssl rand -hex 32)"
HH_ADDR_REV_OUT=$(cast wallet address --private-key "$HH_KEY_REV_OUT")
HH_KEY_IN="${EEZ_WAVE_IN_KEY:-0x$(openssl rand -hex 32)}"
HH_ADDR_IN=$(cast wallet address --private-key "$HH_KEY_IN")
HH_KEY_OUT="${EEZ_WAVE_OUT_KEY:-0x$(openssl rand -hex 32)}"
HH_ADDR_OUT=$(cast wallet address --private-key "$HH_KEY_OUT")
# Pure-L2 filler user.
HH_KEY_PURE=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # #2 (L2 deployer, idle at wave time)
HH_KEY_2_ADDR=$(cast wallet address --private-key "$HH_KEY_2")

# EOAs funded on L1 so they can pay gas on the shared chain.
L1_FUNDED_KEYS=("$HH_KEY_IN")
_yaml() { grep -E "^[[:space:]]*$1:" "${KURTOSIS_ARGS_FILE:-$K/args.yaml}" 2>/dev/null | head -1 \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"$//'; }
FUND_FROM_KEY="${EEZ_FUND_FROM_KEY:-${EEZ_PROOF_SIGNER_KEY:-$(_yaml proof_signer_key)}}"
[[ -n "$FUND_FROM_KEY" ]] || { echo "could not resolve a funding key — set EEZ_FUND_FROM_KEY or check $K/args.yaml"; exit 1; }
L1_SETUP_KEY="${EEZ_L1_SETUP_KEY:-$FUND_FROM_KEY}"

EEZL2_ADDRESS="${EEZL2_ADDRESS:-0x4200000000000000000000000000000000000007}"
SYS_ADDR="${EEZ_L2_SYSTEM_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
MAINNET_RID="${EEZ_L1_ROLLUP_ID:-0}"   # L1's rollup id (outbound proxy target)

# Deposit/withdraw recipient EOAs. Random by default to avoid deterministic
# proxy collisions across repeated runs on the same enclave.
L2_DEP_RECIPIENT="${L2_DEP_RECIPIENT:-0x$(openssl rand -hex 20)}"
L1_WD_RECIPIENT="${L1_WD_RECIPIENT:-0x$(openssl rand -hex 20)}"

echo "════════════════════════════════════════════════════════════════"
echo " WAVE TEST (kurtosis) — mode=$MODE waves=$WAVES"
echo "════════════════════════════════════════════════════════════════"
echo "    L1 (shared)  = $L1"
echo "    L2           = $L2"
echo "    L1 front     = $L1F   (Inbound)"
echo "    L2 front     = $L2F   (Outbound)"
echo "    registry     = $EEZ_REGISTRY_ADDRESS  rollupId=${EEZ_ROLLUP_ID:-?}"
echo "    users        = inbound:$HH_ADDR_IN outbound:$HH_ADDR_OUT"

# Retry a read-only command (survives transient RPC hiccups under load).
retry() {
    local n=0 max="${RETRY_MAX:-6}" delay="${RETRY_DELAY:-3}" out rc
    while :; do
        out=$("$@" 2>&1); rc=$?
        (( rc == 0 )) && { printf '%s' "$out"; return 0; }
        (( ++n >= max )) && { echo "retry: '$*' failed after $n attempts: $out" >&2; return "$rc"; }
        sleep "$delay"
    done
}

# ── Reachability ─────────────────────────────────────────────────────
L1_UP=$(cast block-number --rpc-url "$L1" 2>/dev/null || echo "")
[[ -n "$L1_UP" ]] || { echo "L1 RPC $L1 not reachable — is the enclave up?"; exit 1; }
L2_UP=$(cast block-number --rpc-url "$L2" 2>/dev/null || echo "")
[[ -n "$L2_UP" ]] || { echo "L2 RPC $L2 not reachable"; exit 1; }
echo "    L1=$L1_UP L2=$L2_UP"

PRIORITY_GAS_PRICE="${EEZ_TEST_PRIORITY_GAS_PRICE_WEI:-1}"

gas_price_for() { # <rpc> -> max fee in wei
    local rpc="$1" gp base_hex base minimum
    gp=$(cast gas-price --rpc-url "$rpc" 2>/dev/null || echo 1000000000)
    gp="${EEZ_TEST_GAS_PRICE_WEI:-$gp}"
    base_hex=$(cast block latest --field baseFeePerGas --rpc-url "$rpc" 2>/dev/null || echo 0)
    base=$(cast to-dec "$base_hex" 2>/dev/null || echo 0)
    minimum=$((2 * base + PRIORITY_GAS_PRICE))
    (( gp < minimum )) && gp="$minimum"
    echo "$gp"
}

fund_l1() {
    local to="$1" from_addr nonce
    from_addr=$(cast wallet address --private-key "$FUND_FROM_KEY")
    nonce=$(retry cast nonce "$from_addr" --rpc-url "$L1")
    cast send "$to" --value 10ether --private-key "$FUND_FROM_KEY" --nonce "$nonce" \
        --gas-price "$(gas_price_for "$L1")" \
        --priority-gas-price "$PRIORITY_GAS_PRICE" --rpc-url "$L1" >/dev/null
}

fund_l2() {
    local to="$1" nonce
    nonce=$(retry cast nonce "$HH_KEY_2_ADDR" --rpc-url "$L2")
    cast send "$to" --value 10ether --private-key "$HH_KEY_2" --nonce "$nonce" \
        --gas-price "$(gas_price_for "$L2")" \
        --priority-gas-price "$PRIORITY_GAS_PRICE" --rpc-url "$L2" >/dev/null
}

# ── Fund L1-side actors ──────────────────────────────────────────────
for k in "${L1_FUNDED_KEYS[@]}"; do
    a=$(cast wallet address --private-key "$k")
    if [[ "$(cast balance "$a" --rpc-url "$L1" 2>/dev/null || echo 0)" == "0" ]]; then
        echo "==> funding $a on L1 (10 ETH)"
        fund_l1 "$a" || { echo "failed to fund $a — is the funding key funded on L1?"; exit 1; }
    fi
done

if [[ "${EEZ_INCLUDE_REVERTS:-0}" == "1" ]]; then
    echo "==> funding revert senders (L1 $HH_ADDR_REV_IN / L2 $HH_ADDR_REV_OUT)"
    fund_l1 "$HH_ADDR_REV_IN" || { echo "failed to fund revert sender on L1"; exit 1; }
    fund_l2 "$HH_ADDR_REV_OUT" || { echo "failed to fund revert sender on L2"; exit 1; }
fi

if [[ "$(cast balance "$HH_ADDR_OUT" --rpc-url "$L2" 2>/dev/null || echo 0)" == "0" ]]; then
    echo "==> funding $HH_ADDR_OUT on L2 (10 ETH)"
    fund_l2 "$HH_ADDR_OUT" || { echo "failed to fund $HH_ADDR_OUT on L2"; exit 1; }
fi

forge_deploy() { # <rpc> <key> <script:contract> <sig> <args...>  → echoes forge stdout
    local rpc="$1" key="$2" sc="$3" sig="$4" gas_price out; shift 4
    gas_price=$(gas_price_for "$rpc")
    if ! out=$(cd "$REPO/contracts" && forge script "script/$sc" --sig "$sig" "$@" \
        --rpc-url "$rpc" --broadcast --private-key "$key" --gas-price "$gas_price" --skip-simulation 2>&1); then
        printf '%s\n' "$out" >&2
        return 1
    fi
    printf '%s\n' "$out"
}
grab() { grep -oE "$1=0x[0-9a-fA-F]{40}" | head -1 | cut -d= -f2; }

# ── Deploy L2 targets (Value + ValueNoRet), inbound built-ins only ───
if (( HAS_IN )); then
    echo "==> deploying L2 targets (Value, ValueNoRet)"
    L2_VALUE=$(forge_deploy "$L2" "$HH_KEY_2" DeployValueL2.s.sol:DeployValueL2 'run(uint256)' 0 | grab EEZ_VALUE_ADDRESS)
    L2_VALUE_NORET=$(forge_deploy "$L2" "$HH_KEY_2" DeployValueNoRetL2.s.sol:DeployValueNoRetL2 'run(uint256)' 0 | grab EEZ_VALUE_NORET_ADDRESS)
    [[ -n "$L2_VALUE" && -n "$L2_VALUE_NORET" ]] || { echo "L2 target deploy failed"; exit 1; }
    echo "    L2 Value=$L2_VALUE  ValueNoRet=$L2_VALUE_NORET"
fi

# ── Deploy L1 outbound targets (Value + ValueNoRet on L1) ────────────
if (( HAS_OUT )); then
    echo "==> deploying L1 outbound targets (Value, ValueNoRet on L1)"
    L1_VALUE=$(forge_deploy "$L1" "$L1_SETUP_KEY" DeployValueL2.s.sol:DeployValueL2 'run(uint256)' 0 | grab EEZ_VALUE_ADDRESS)
    L1_VALUE_NORET=$(forge_deploy "$L1" "$L1_SETUP_KEY" DeployValueNoRetL2.s.sol:DeployValueNoRetL2 'run(uint256)' 0 | grab EEZ_VALUE_NORET_ADDRESS)
    [[ -n "$L1_VALUE" && -n "$L1_VALUE_NORET" ]] || { echo "L1 target deploy failed"; exit 1; }
    echo "    L1 Value=$L1_VALUE  ValueNoRet=$L1_VALUE_NORET"
fi

L1_CHAIN_ID=$(cast chain-id --rpc-url "$L1")
L2_CHAIN_ID=$(cast chain-id --rpc-url "$L2")
# ── Helpers: create an L1 (inbound) proxy and an L2 (outbound) proxy ──
# L1 proxy = createCrossChainProxy(target_on_L2, rid=EEZ_ROLLUP_ID) on the L1 EEZ.
create_l1_proxy() { # <target_on_L2> → proxy addr
    forge_deploy "$L1" "$L1_SETUP_KEY" CreateValueProxy.s.sol:CreateValueProxy \
        'run(address,address,uint64)' "$EEZ_REGISTRY_ADDRESS" "$1" "$EEZ_ROLLUP_ID" | grab EEZ_VALUE_PROXY
}
# L2 proxy = computeCrossChainProxyAddress(target_on_L1, MAINNET) then
# createCrossChainProxy on the L2 CCM (a PURE L2 tx → normal L2 RPC).
create_l2_proxy() { # <target_on_L1> → proxy addr
    local tgt="$1" p code nonce raw
    p=$(cast call "$EEZL2_ADDRESS" 'computeCrossChainProxyAddress(address,uint64)(address)' "$tgt" "$MAINNET_RID" --rpc-url "$L2" | tr -d '[:space:]')
    code=$(cast code "$p" --rpc-url "$L2" 2>/dev/null || echo 0x)
    if [[ "$code" == "0x" || -z "$code" ]]; then
        nonce=$(cast nonce "$HH_KEY_2_ADDR" --rpc-url "$L2")
        raw=$(cast mktx --rpc-url "$L2" --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_2" --nonce "$nonce" \
            --gas-limit 1500000 --gas-price "$(gas_price_for "$L2")" \
            "$EEZL2_ADDRESS" 'createCrossChainProxy(address,uint64)' "$tgt" "$MAINNET_RID")
        curl -s -X POST "$L2" -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$raw\"],\"id\":1}" >/dev/null
        for _ in $(seq 1 30); do
            code=$(cast code "$p" --rpc-url "$L2" 2>/dev/null || echo 0x)
            [[ "$code" != "0x" && -n "$code" ]] && break
            sleep 1
        done
    fi
    echo "$p"
}

echo "==> creating cross-chain proxies for the built-in ops in play"
if (( HAS_IN )); then
    IN_VALUE_PROXY=$(create_l1_proxy "$L2_VALUE")
    IN_NORET_PROXY=$(create_l1_proxy "$L2_VALUE_NORET")
    IN_DEP_PROXY=$(create_l1_proxy "$L2_DEP_RECIPIENT")
    [[ -n "$IN_VALUE_PROXY" && -n "$IN_NORET_PROXY" && -n "$IN_DEP_PROXY" ]] \
        || { echo "inbound proxy creation failed"; exit 1; }
    echo "    inbound proxies: setter=$IN_VALUE_PROXY noret=$IN_NORET_PROXY deposit=$IN_DEP_PROXY"
    # Inbound wrapper on L1 over the setter proxy.
    IN_WRAPPER=$(forge_deploy "$L1" "$L1_SETUP_KEY" DeploySetterWrapperL1.s.sol:DeploySetterWrapperL1 'run(address)' "$IN_VALUE_PROXY" | grab EEZ_SETTER_WRAPPER)
    echo "    inbound wrapper (L1) = $IN_WRAPPER"
fi
if (( HAS_OUT )); then
    OUT_VALUE_PROXY=$(create_l2_proxy "$L1_VALUE")
    OUT_NORET_PROXY=$(create_l2_proxy "$L1_VALUE_NORET")
    OUT_WD_PROXY=$(create_l2_proxy "$L1_WD_RECIPIENT")
    [[ -n "$OUT_VALUE_PROXY" && -n "$OUT_NORET_PROXY" && -n "$OUT_WD_PROXY" ]] \
        || { echo "outbound proxy creation failed"; exit 1; }
    echo "    outbound proxies: setter=$OUT_VALUE_PROXY noret=$OUT_NORET_PROXY withdraw=$OUT_WD_PROXY"
    # Outbound wrapper on L2 over the outbound setter proxy.
    OUT_WRAPPER=$(forge_deploy "$L2" "$HH_KEY_2" DeploySetterWrapperL1.s.sol:DeploySetterWrapperL1 'run(address)' "$OUT_VALUE_PROXY" | grab EEZ_SETTER_WRAPPER)
    echo "    outbound wrapper (L2) = $OUT_WRAPPER"
fi

echo
echo
echo "==> setup complete; running waves"
RECEIPT_WAIT_SECS="${EEZ_RECEIPT_WAIT_SECS:-300}"
WAVE_GAP_SECS="${EEZ_WAVE_GAP_SECS:-20}"
FILLER_PER_GAP="${EEZ_FILLER_PER_GAP:-2}"
# One reverting cross-chain call per side per wave (bogus selector, no
# fallback). They must NOT settle, and must not disturb the rest.
INCLUDE_REVERTS="${EEZ_INCLUDE_REVERTS:-0}"
PURE_RECIPIENT=0x2222222222222222222222222222222222222222

refresh_node_log() { docker logs "$(docker ps --format "{{.Names}}" | grep -m1 "eez-node--")" >"$NODE_LOG" 2>&1 || true; }
refresh_signer_log() { docker logs "$(docker ps --format "{{.Names}}" | grep -m1 "eez-proof-signer--")" >"$SIGNER_LOG" 2>&1 || true; }
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# The relay needs a few L1 slots before it includes anything. Firing into that
# window burns MAX_BUNDLE_ATTEMPTS and evicts the ops as poison — a harness
# artifact that looks exactly like a node bug.
# Count a registry event from a block. Baselined per run: several modes share
# one enclave, so counting from the deploy block would count their events too.
registry_events() { # <event-sig> [from-block]
    cast logs --address "$EEZ_REGISTRY_ADDRESS" \
        --from-block "${2:-${EEZ_REGISTRY_DEPLOY_BLOCK:-0}}" --to-block latest \
        "$1" --rpc-url "$L1" --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0
}

settled_count() { refresh_node_log; strip_ansi <"$NODE_LOG" | grep -c "settled=true" || true; }

wait_for_builder() {
    local deadline=$(( SECONDS + ${EEZ_BUILDER_WARM_SECS:-600} )) base hits
    # Baseline first: an earlier mode's settlements are still in the log.
    base=$(settled_count)
    echo "==> waiting for the builder to include a bundle"
    while :; do
        # `-c` not `-q`: -q exits on first match, SIGPIPEs sed, and pipefail
        # then reports the successful pipeline as failed.
        hits=$(settled_count)
        if (( ${hits:-0} > ${base:-0} )); then
            echo "    ✓ builder is including bundles ($((hits - base)) new this run)"; return 0
        fi
        (( SECONDS < deadline )) || {
            echo "    ✗ no bundle included in ${EEZ_BUILDER_WARM_SECS:-600}s"; return 1
        }
        sleep 10
    done
}

# receipt_status <hash> <rpc> → "1" mined-ok, "0x0" reverted, "missing"
receipt_status() {
    local r st
    r=$(timeout 3 curl -s -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$1\"],\"id\":1}" \
        "$2" 2>/dev/null)
    st=$(echo "$r" | jq -r '.result.status // "missing"' 2>/dev/null)
    [[ "$st" == "0x1" ]] && echo "1" || echo "${st:-missing}"
}

wait_nonce_at_least() {
    local rpc="$1" addr="$2" want="$3" label="$4"
    local wait_end=$(( SECONDS + RECEIPT_WAIT_SECS )) got
    while (( SECONDS < wait_end )); do
        got=$(retry cast nonce "$addr" --rpc-url "$rpc")
        (( got >= want )) && return 0
        sleep 5
    done
    echo "    ✗ timed out waiting for $label nonce >= $want" >&2
    return 1
}

# send_front <front_url> <raw_tx> — eth_sendRawTransaction to a cross-chain
# front; fails loud if the admission gate rejects (invariant 7 is LOUD).
send_front() {
    local resp i rc
    # Fronts refuse submissions until the node reconciles with L1; wait that
    # out. Any other error is fatal.
    for i in $(seq 1 120); do
        resp=$(curl -sS --max-time 10 -X POST "$1" -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$2\"],\"id\":1}" 2>/dev/null); rc=$?
        # Empty body = no answer. Without this the grep below misses and a tx
        # that was NEVER SENT reports success.
        (( rc == 0 )) && [[ -n "$resp" ]] || {
            echo "    ✗ submit failed (curl rc=$rc, ${#resp} byte body)" >&2; return 1; }
        grep -q '"error"' <<<"$resp" || return 0
        grep -q 'starting up' <<<"$resp" || { echo "    ✗ front rejected tx: $resp" >&2; return 1; }
        sleep 1
    done
    echo "    ✗ front still starting up after 120s" >&2
    return 1
}

# send_raw <rpc_url> <raw_tx> — eth_sendRawTransaction to an ordinary mempool,
# for the l1:/l2: sides an external op can ask for. Fails loud like send_front.
send_raw() {
    local resp rc
    resp=$(curl -sS --max-time 10 -X POST "$1" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$2\"],\"id\":1}" 2>/dev/null); rc=$?
    (( rc == 0 )) && [[ -n "$resp" ]] \
        || { echo "    ✗ submit failed (curl rc=$rc, ${#resp} byte body)" >&2; return 1; }
    grep -q '"error"' <<<"$resp" && { echo "    ✗ RPC rejected tx: $resp" >&2; return 1; }
    return 0
}

run_waves() {
    local do_pure=0
    [[ "$MODE" != mixed-pure ]] || do_pure=1

    # ── Baselines (deltas asserted at the end) ───────────────────────
    local DEP_BEFORE=0 WD_BEFORE=0
    (( HAS_IN ))  && DEP_BEFORE=$(retry cast balance "$L2_DEP_RECIPIENT" --rpc-url "$L2")
    (( HAS_OUT )) && WD_BEFORE=$(retry cast balance "$L1_WD_RECIPIENT" --rpc-url "$L1")

    # ── Local nonce chains (see header) ──────────────────────────────
    # External ops sign with their own keys, so they keep their own nonces.
    local IN_NONCE=0 OUT_NONCE=0 PURE_NONCE PURE_ADDR
    (( HAS_IN ))  && IN_NONCE=$(retry cast nonce "$HH_ADDR_IN" --rpc-url "$L1")
    (( HAS_OUT )) && OUT_NONCE=$(retry cast nonce "$HH_ADDR_OUT" --rpc-url "$L2")
    if (( do_pure )); then
        PURE_ADDR=$(cast wallet address --private-key "$HH_KEY_PURE")
        PURE_NONCE=$(retry cast nonce "$PURE_ADDR" --rpc-url "$L2")
    fi
    local IN_WAVE_TARGET=0 OUT_WAVE_TARGET=0

    # Per-tx metadata for the confirmed-view tally: "hash|side|kind|arg".
    # side=in|out; kind=set|noret|wrap|dep|wd.
    local TX_META=()
    local IN_HASHES=() OUT_HASHES=()
    local EXT_L1_HASHES=() EXT_L2_HASHES=()
    local REV_IN_HASHES=() REV_OUT_HASHES=()
    local REV_IN_NONCE=0 REV_OUT_NONCE=0

    # run_ext_op <command> <wave> → "raw|side|kind|arg", empty if it declined.
    # The command's own arguments are word-split out of <command>; the wave
    # number is appended as its last argument.
    run_ext_op() {
        local cmd="$1" w="$2" out rc
        local -a argv=()
        read -r -a argv <<<"$cmd"
        (( ${#argv[@]} )) || { echo "    ✗ empty external op command" >&2; return 1; }
        out=$(
            EEZ_WAVE_NUMBER="$w" \
            EEZ_WAVE_TOTAL="$WAVES" \
            EEZ_WAVE_L1_RPC="$L1" \
            EEZ_WAVE_L2_RPC="$L2" \
            EEZ_WAVE_L1_FRONT="$L1F" \
            EEZ_WAVE_L2_FRONT="$L2F" \
            EEZ_WAVE_L1_CHAIN_ID="$L1_CHAIN_ID" \
            EEZ_WAVE_L2_CHAIN_ID="$L2_CHAIN_ID" \
            EEZ_WAVE_L1_GAS_PRICE="$(gas_price_for "$L1")" \
            EEZ_WAVE_L2_GAS_PRICE="$(gas_price_for "$L2")" \
            EEZ_WAVE_PRIORITY_GAS_PRICE="$PRIORITY_GAS_PRICE" \
            "${argv[@]}" "$w"
        ); rc=$?
        (( rc == 0 )) || { echo "    ✗ external op exited $rc: $cmd" >&2; return 1; }
        ext_op_parse "$out"
    }

    # mk_and_send <op> <wave> — the EEZ_WAVE_OPS dispatch.
    #   in:set/noret/wrap/dep  → L1-signed tx via the L1 front
    #   out:set/noret/wrap/wd  → L2-signed tx via the L2 front
    #   ext:<command>          → the consumer's command decides both
    mk_and_send() {
        local op="$1" w="$2" arg raw="" hash side kind parsed
        local GP PG
        GP=$(gas_price_for "$L1")
        PG="$PRIORITY_GAS_PRICE"
        arg=$(wave_arg_for "$op" "$w")
        side="${op%%:*}"
        kind="${op#*:}"
        case "$op" in
            in:set)   raw=$(cast mktx --chain-id "$L1_CHAIN_ID" --private-key "$HH_KEY_IN" --nonce "$IN_NONCE" \
                        --gas-limit 600000 --gas-price "$GP" --priority-gas-price "$PG" \
                        "$IN_VALUE_PROXY" 'setValue(uint256)' "$arg") ;;
            in:noret) raw=$(cast mktx --chain-id "$L1_CHAIN_ID" --private-key "$HH_KEY_IN" --nonce "$IN_NONCE" \
                        --gas-limit 600000 --gas-price "$GP" --priority-gas-price "$PG" \
                        "$IN_NORET_PROXY" 'setValue(uint256)' "$arg") ;;
            in:wrap)  raw=$(cast mktx --chain-id "$L1_CHAIN_ID" --private-key "$HH_KEY_IN" --nonce "$IN_NONCE" \
                        --gas-limit 800000 --gas-price "$GP" --priority-gas-price "$PG" \
                        "$IN_WRAPPER" 'setViaProxy(uint256)' "$arg") ;;
            in:dep)   raw=$(cast mktx --chain-id "$L1_CHAIN_ID" --private-key "$HH_KEY_IN" --nonce "$IN_NONCE" \
                        --gas-limit 600000 --gas-price "$GP" --priority-gas-price "$PG" --value "$arg" \
                        "$IN_DEP_PROXY") ;;
            out:set)   raw=$(cast mktx --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_OUT" --nonce "$OUT_NONCE" \
                        --gas-limit 600000 --gas-price "$(gas_price_for "$L2")" --priority-gas-price "$PRIORITY_GAS_PRICE" \
                        "$OUT_VALUE_PROXY" 'setValue(uint256)' "$arg") ;;
            out:noret) raw=$(cast mktx --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_OUT" --nonce "$OUT_NONCE" \
                        --gas-limit 600000 --gas-price "$(gas_price_for "$L2")" --priority-gas-price "$PRIORITY_GAS_PRICE" \
                        "$OUT_NORET_PROXY" 'setValue(uint256)' "$arg") ;;
            out:wrap)  raw=$(cast mktx --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_OUT" --nonce "$OUT_NONCE" \
                        --gas-limit 800000 --gas-price "$(gas_price_for "$L2")" --priority-gas-price "$PRIORITY_GAS_PRICE" \
                        "$OUT_WRAPPER" 'setViaProxy(uint256)' "$arg") ;;
            out:wd)    raw=$(cast mktx --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_OUT" --nonce "$OUT_NONCE" \
                        --gas-limit 600000 --gas-price "$(gas_price_for "$L2")" --priority-gas-price "$PRIORITY_GAS_PRICE" --value "$arg" \
                        "$OUT_WD_PROXY") ;;
            in:rev)   raw=$(cast mktx --chain-id "$L1_CHAIN_ID" --private-key "$HH_KEY_REV_IN" --nonce "$REV_IN_NONCE" \
                        --gas-limit 600000 --gas-price "$GP" --priority-gas-price "$PG" \
                        "$IN_VALUE_PROXY" 'noSuchFunction()') ;;
            out:rev)  raw=$(cast mktx --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_REV_OUT" --nonce "$REV_OUT_NONCE" \
                        --gas-limit 600000 --gas-price "$(gas_price_for "$L2")" --priority-gas-price "$PRIORITY_GAS_PRICE" \
                        "$OUT_VALUE_PROXY" 'noSuchFunction()') ;;
            ext:*)     parsed=$(run_ext_op "${op#ext:}" "$w") || exit 1
                       [[ -n "$parsed" ]] || { echo "    · $op declined wave $w"; return 0; }
                       IFS='|' read -r raw side kind arg <<<"$parsed" ;;
            *) echo "cross-chain wave: bad op $op"; exit 1 ;;
        esac
        [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]] || { echo "    ✗ mktx failed ($op): $raw"; exit 1; }
        hash=$(cast keccak "$raw")
        case "$side" in
            in)
                send_front "$L1F" "$raw" || exit 1
                if [[ "$kind" == rev ]]; then REV_IN_HASHES+=("$hash"); REV_IN_NONCE=$((REV_IN_NONCE + 1));
                else
                    IN_HASHES+=("$hash")
                    [[ "$op" == ext:* ]] || IN_NONCE=$((IN_NONCE + 1))
                fi ;;
            out)
                send_front "$L2F" "$raw" || exit 1
                if [[ "$kind" == rev ]]; then REV_OUT_HASHES+=("$hash"); REV_OUT_NONCE=$((REV_OUT_NONCE + 1));
                else
                    OUT_HASHES+=("$hash")
                    [[ "$op" == ext:* ]] || OUT_NONCE=$((OUT_NONCE + 1))
                fi ;;
            l1) send_raw "$L1" "$raw" || exit 1; EXT_L1_HASHES+=("$hash") ;;
            l2) send_raw "$L2" "$raw" || exit 1; EXT_L2_HASHES+=("$hash") ;;
        esac
        TX_META+=("$hash|$side|$kind|$arg")
    }

    submit_pure_filler() {
        local count="$1" j raw
        for ((j=0; j<count; j++)); do
            raw=$(cast mktx --chain-id "$L2_CHAIN_ID" --private-key "$HH_KEY_PURE" --nonce "$PURE_NONCE" \
                --gas-limit 21000 --gas-price "$(gas_price_for "$L2")" --priority-gas-price "$PRIORITY_GAS_PRICE" \
                --value 100000000 "$PURE_RECIPIENT" 2>&1)
            [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]] || break
            curl -s -X POST "$L2" -H 'Content-Type: application/json' \
                -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"$raw\"],\"id\":9}" >/dev/null
            PURE_NONCE=$((PURE_NONCE + 1))
            sleep 1
        done
    }

    # ── Waves ─────────────────────────────────────────────────────────
    # Per wave: direct setter, noret setter, value transfer, then the wrapper
    # LAST so the wrapper's value is the expected final Value.value() (both
    # write the same target through the same proxy, in submission order).
    local w
    # Baseline for the per-run event counts below.
    # +1: the current head is already mined, so its events predate this run.
    L1_FIRST_COUNTED_BLOCK=$(( $(retry cast block-number --rpc-url "$L1") + 1 ))
    # Here, not at setup: the helpers it calls are defined above this point.
    wait_for_builder || return 1
    echo
    echo "==> firing $WAVES wave(s), mode=$MODE"
    for ((w=1; w<=WAVES; w++)); do
        echo "── wave $w/$WAVES"
        local op
        for op in "${OPS[@]}"; do mk_and_send "$op" "$w"; done
        (( INCLUDE_REVERTS && w == 1 && HAS_IN ))  && mk_and_send in:rev "$w"
        (( INCLUDE_REVERTS && w == 1 && HAS_OUT )) && mk_and_send out:rev "$w"
        (( HAS_IN ))  && IN_WAVE_TARGET="$IN_NONCE"
        (( HAS_OUT )) && OUT_WAVE_TARGET="$OUT_NONCE"
        echo "    ops: ${OPS[*]}"
        (( do_pure )) && { submit_pure_filler "$FILLER_PER_GAP"; echo "    pure: $FILLER_PER_GAP L2 filler txs"; }
        if (( w < WAVES )); then
            if (( HAS_IN )); then
                wait_nonce_at_least "$L1" "$HH_ADDR_IN" "$IN_WAVE_TARGET" "inbound sender" || exit 1
            fi
            if (( HAS_OUT )); then
                wait_nonce_at_least "$L2" "$HH_ADDR_OUT" "$OUT_WAVE_TARGET" "outbound sender" || exit 1
            fi
        fi
        sleep "$WAVE_GAP_SECS"
    done

    # ── Wait for inclusion ─────────────────────────────────────────────
    # inbound → L1 receipts, outbound → L2 receipts.
    local total=$(( ${#IN_HASHES[@]} + ${#OUT_HASHES[@]} + ${#EXT_L1_HASHES[@]} + ${#EXT_L2_HASHES[@]} ))
    echo
    echo "==> waiting up to ${RECEIPT_WAIT_SECS}s for $total cross-chain inclusions"
    local wait_end=$(( SECONDS + RECEIPT_WAIT_SECS )) confirmed evicted h last_line=""
    while (( SECONDS < wait_end )); do
        confirmed=0
        for h in "${IN_HASHES[@]:-}";  do [[ -n "$h" && "$(receipt_status "$h" "$L1")" == "1" ]] && confirmed=$((confirmed+1)); done
        for h in "${OUT_HASHES[@]:-}"; do [[ -n "$h" && "$(receipt_status "$h" "$L2")" == "1" ]] && confirmed=$((confirmed+1)); done
        for h in "${EXT_L1_HASHES[@]:-}"; do [[ -n "$h" && "$(receipt_status "$h" "$L1")" == "1" ]] && confirmed=$((confirmed+1)); done
        for h in "${EXT_L2_HASHES[@]:-}"; do [[ -n "$h" && "$(receipt_status "$h" "$L2")" == "1" ]] && confirmed=$((confirmed+1)); done
        refresh_node_log
        evicted=$(grep -c "evicted" "$NODE_LOG" 2>/dev/null || true); evicted=${evicted:-0}
        local line="    progress: $confirmed/$total confirmed, $evicted eviction log line(s) (elapsed ${SECONDS}s)"
        [[ "$line" != "$last_line" ]] && { echo "$line"; last_line="$line"; }
        (( confirmed >= total )) && { echo "    all confirmed"; break; }
        sleep 5
    done
    if (( confirmed != total )); then
        echo "    ✗ only $confirmed/$total cross-chain transactions succeeded" >&2
        exit 1
    fi
    echo "    settling 15s..."; sleep 15
    refresh_node_log

    # ── Confirmed view (only receipt-confirmed ops count) ──────────────
    local m mh mside mkind marg
    local IN_LAST_VALUE="" IN_LAST_NORET="" IN_DEP_SUM=0
    local OUT_LAST_VALUE="" OUT_LAST_NORET="" OUT_WD_SUM=0
    local -A KIND_COUNT=()
    for m in "${TX_META[@]:-}"; do
        [[ -n "$m" ]] || continue
        IFS='|' read -r mh mside mkind marg <<<"$m"
        if [[ "$mside" == in || "$mside" == l1 ]]; then
            [[ "$(receipt_status "$mh" "$L1")" == "1" ]] || continue
        else
            [[ "$(receipt_status "$mh" "$L2")" == "1" ]] || continue
        fi
        KIND_COUNT["$mside:$mkind"]=$(( ${KIND_COUNT["$mside:$mkind"]:-0} + 1 ))
        case "$mside:$mkind" in
            in:set|in:wrap)   IN_LAST_VALUE="$marg" ;;
            in:noret)         IN_LAST_NORET="$marg" ;;
            in:dep)           IN_DEP_SUM=$((IN_DEP_SUM + marg)) ;;
            out:set|out:wrap) OUT_LAST_VALUE="$marg" ;;
            out:noret)        OUT_LAST_NORET="$marg" ;;
            out:wd)           OUT_WD_SUM=$((OUT_WD_SUM + marg)) ;;
        esac
    done

    # ── Assertions ──────────────────────────────────────────────────────
    echo
    echo "==> assertions"
    local ok_all=1 signer_ok=0 attested_hash=""

    # Per-kind confirmed tally. An ext: op appears here under its own kind.
    local tally="" kindkey
    if (( ${#KIND_COUNT[@]} )); then
        for kindkey in $(printf '%s\n' "${!KIND_COUNT[@]}" | sort); do
            tally+="$kindkey=${KIND_COUNT[$kindkey]} "
        done
    fi
    echo "    ℹ ops confirmed by kind: ${tally:-none}"

    # The destination call fails, so status=1 would mean a call that reverted
    # on the far side settled as if it had applied.
    if (( INCLUDE_REVERTS )); then
        local rh rev_total=0 rev_ok=0 rst
        for rh in "${REV_IN_HASHES[@]:-}"; do
            [[ -n "$rh" ]] || continue
            rev_total=$((rev_total+1)); rst=$(receipt_status "$rh" "$L1")
            [[ "$rst" != "1" ]] && rev_ok=$((rev_ok+1)) || echo "    ✗ inbound revert op settled as success: $rh"
        done
        for rh in "${REV_OUT_HASHES[@]:-}"; do
            [[ -n "$rh" ]] || continue
            rev_total=$((rev_total+1)); rst=$(receipt_status "$rh" "$L2")
            [[ "$rst" != "1" ]] && rev_ok=$((rev_ok+1)) || echo "    ✗ outbound revert op settled as success: $rh"
        done
        if (( rev_total > 0 && rev_ok == rev_total )); then
            echo "    ✓ reverting cross-chain calls did not settle: $rev_ok/$rev_total"
        else
            echo "    ✗ reverting-call handling: $rev_ok/$rev_total behaved correctly"; ok_all=0
        fi
    fi

    check_eq() { # <label> <actual> <expected>
        if [[ "$2" == "$3" && -n "$3" ]]; then
            echo "    ✓ $1: $2"
        else
            echo "    ✗ $1: actual=$2 expected=$3"; ok_all=0
        fi
    }

    # Each convergence check runs only if its op was in the list. Inclusion is
    # already asserted above, so a non-empty accumulator means the op fired and
    # confirmed. An external op asserts its own outcome, in its own repository.
    if (( HAS_IN )); then
        local v n d
        if [[ -n "$IN_LAST_VALUE" ]]; then
            v=$(retry cast call "$L2_VALUE" 'value()(uint256)' --rpc-url "$L2")
            check_eq "inbound setter converged (L2 Value.value)"       "$v" "$IN_LAST_VALUE"
        fi
        if [[ -n "$IN_LAST_NORET" ]]; then
            n=$(retry cast call "$L2_VALUE_NORET" 'value()(uint256)' --rpc-url "$L2")
            check_eq "inbound noret converged (L2 ValueNoRet.value)"   "$n" "$IN_LAST_NORET"
        fi
        d=$(retry cast balance "$L2_DEP_RECIPIENT" --rpc-url "$L2")
        check_eq "inbound deposits converged (L2 recipient bal)"   "$d" "$((DEP_BEFORE + IN_DEP_SUM))"
    fi
    if (( HAS_OUT )); then
        local v n d
        if [[ -n "$OUT_LAST_VALUE" ]]; then
            v=$(retry cast call "$L1_VALUE" 'value()(uint256)' --rpc-url "$L1")
            check_eq "outbound setter converged (L1 Value.value)"      "$v" "$OUT_LAST_VALUE"
        fi
        if [[ -n "$OUT_LAST_NORET" ]]; then
            n=$(retry cast call "$L1_VALUE_NORET" 'value()(uint256)' --rpc-url "$L1")
            check_eq "outbound noret converged (L1 ValueNoRet.value)"  "$n" "$OUT_LAST_NORET"
        fi
        d=$(retry cast balance "$L1_WD_RECIPIENT" --rpc-url "$L1")
        check_eq "outbound withdrawals converged (L1 recipient)"   "$d" "$((WD_BEFORE + OUT_WD_SUM))"
    fi

    # postBatches actually landed on L1 (the original bundle-drop symptom).
    # Counted from THIS run's starting block, not the deploy block.
    local PB_COUNT
    PB_COUNT=$(registry_events "BatchPosted(uint256)" "$L1_FIRST_COUNTED_BLOCK")
    if (( PB_COUNT >= WAVES )); then
        echo "    ✓ postBatches on L1 this run: $PB_COUNT (≥ $WAVES waves)"
    else
        echo "    ✗ postBatches on L1 this run: $PB_COUNT (expected ≥ $WAVES)"; ok_all=0
    fi

    local EXECUTION_COUNT
    EXECUTION_COUNT=$(registry_events "L2ExecutionPerformed(uint64,bytes32)" "$L1_FIRST_COUNTED_BLOCK")
    if (( EXECUTION_COUNT > 0 )); then
        echo "    ✓ L2 execution events on L1 this run: $EXECUTION_COUNT"
    else
        echo "    ✗ no L2ExecutionPerformed event found"; ok_all=0
    fi

    # L1's stored state root must converge with the current L2 safe block.
    local LAST_SETTLED="" L1_TRACKED="" L1_RECHECK="" L2_ROOT="" L2_SAFE=0 SAFE_BLOCK=""
    local root_deadline=$((SECONDS + ${EEZ_STATE_ROOT_WAIT_SECS:-30})) root_matched=0
    LAST_SETTLED=$(strip_ansi <"$NODE_LOG" | grep "bundle outcome observed" | grep "settled=true" \
        | grep -oE "sync_height=[0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1 || true)
    if [[ -n "$LAST_SETTLED" ]]; then
        while (( SECONDS < root_deadline )); do
            L1_TRACKED=$(retry cast call "$EEZ_REGISTRY_ADDRESS" 'rollups(uint64)(address,bytes32,uint256)' \
                "$EEZ_ROLLUP_ID" --rpc-url "$L1" | sed -n '2p' | tr -d '[:space:]')
            SAFE_BLOCK=$(retry cast block safe --rpc-url "$L2" --json)
            L2_SAFE=$(jq -r '.number' <<<"$SAFE_BLOCK" | xargs cast to-dec)
            L2_ROOT=$(jq -r '.stateRoot' <<<"$SAFE_BLOCK")
            L1_RECHECK=$(retry cast call "$EEZ_REGISTRY_ADDRESS" 'rollups(uint64)(address,bytes32,uint256)' \
                "$EEZ_ROLLUP_ID" --rpc-url "$L1" | sed -n '2p' | tr -d '[:space:]')
            if [[ "${L1_TRACKED,,}" == "${L1_RECHECK,,}" \
                && "${L1_RECHECK,,}" == "${L2_ROOT,,}" ]]; then
                root_matched=1
                break
            fi
            sleep 1
        done
        if (( root_matched )); then
            echo "    ✓ L1 rollups($EEZ_ROLLUP_ID).stateRoot == L2 safe root at height $L2_SAFE"
        else
            echo "    ✗ L1 stateRoot $L1_RECHECK != L2 safe root $L2_ROOT at height $L2_SAFE"; ok_all=0
        fi
        if (( L2_SAFE >= LAST_SETTLED )); then
            echo "    ✓ L2 safe head reached settled height: $L2_SAFE"
        else
            echo "    ✗ L2 safe head $L2_SAFE is below settled height $LAST_SETTLED"; ok_all=0
        fi
    else
        echo "    ✗ no settled bundle found in the node log (grep 'settled=true')"; ok_all=0
    fi

    # Zero production deriver divergence errors.
    local DIVERGED
    DIVERGED=$(grep -c "diverged from L1-confirmed batch" "$NODE_LOG" 2>/dev/null || true); DIVERGED=${DIVERGED:-0}
    if (( DIVERGED == 0 )); then
        echo "    ✓ zero state-root divergence events"
    else
        echo "    ✗ $DIVERGED state-root divergence event(s)"; ok_all=0
    fi

    # Dropped-bundle telemetry.
    local DROPS
    DROPS=$(grep -c "bundle dropped" "$NODE_LOG" 2>/dev/null || true); DROPS=${DROPS:-0}
    echo "    ℹ dropped-bundle log lines: $DROPS"

    # Correlate the composer's accepted attestation with the signer's completed
    # validation pipeline.
    local signer_line=""
    refresh_node_log
    refresh_signer_log
    attested_hash=$(strip_ansi <"$NODE_LOG" | grep 'remote prover attested the window' \
        | grep -oE 'hash=0x[0-9a-fA-F]{64}' | tail -1 | cut -d= -f2 || true)
    if [[ -n "$attested_hash" ]]; then
        signer_line=$(strip_ansi <"$SIGNER_LOG" \
            | grep -F "recomputed_public_inputs_hash=$attested_hash" | tail -1 || true)
    fi
    if [[ "$signer_line" == *"window validated and signed"* ]]; then
        signer_ok=1
    fi

    echo
    if (( ok_all )); then
        echo "==> WAVE TEST PASSED (mode=$MODE waves=$WAVES, $total cross-chain ops, $PB_COUNT PBs)"
    else
        echo "==> WAVE TEST FAILED (mode=$MODE)"
    fi
    if (( signer_ok )); then
        echo "==> PROOF SIGNER TEST PASSED (publicInputsHash=$attested_hash)"
    else
        echo "==> PROOF SIGNER TEST FAILED (no matching validated signer attestation)"
    fi
    if (( ok_all && signer_ok )); then
        exit 0
    else
        exit 1
    fi
}
run_waves
