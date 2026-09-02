#!/usr/bin/env bash
# Reference external wave op — the `ext:` contract of cross-chain-wave.sh.
#
#   EEZ_WAVE_OPS="ext:./testing/kurtosis/scripts/example-ext-op.sh" \
#       bash testing/kurtosis/scripts/cross-chain-wave.sh
#
# It sends one ordinary L2 transfer per wave, of the wave number in wei. Its
# only job is to document and exercise the contract; a consuming repository
# writes its own ops and keeps them in its own repository.
#
# In:  the EEZ_WAVE_* environment (endpoints, chain ids, gas prices, the wave
#      number) plus everything in the enclave's deployments.env, and the wave
#      number as $1.
# Out: the key=value block the harness parses. An op with nothing to send this
#      wave prints nothing instead.
#
# The default key is the public devnet account the README documents. The
# mixed-pure filler signs with the same account, so set EEZ_EXAMPLE_OP_KEY to
# something else before combining this op with that mode.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

WAVE="${1:-${EEZ_WAVE_NUMBER:-1}}"
KEY="${EEZ_EXAMPLE_OP_KEY:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
TO="${EEZ_EXAMPLE_OP_TO:-0x3333333333333333333333333333333333333333}"

ADDR="$(cast wallet address --private-key "$KEY")"
NONCE="$(cast nonce "$ADDR" --rpc-url "$EEZ_WAVE_L2_RPC")"

RAW="$(cast mktx \
    --chain-id "$EEZ_WAVE_L2_CHAIN_ID" \
    --private-key "$KEY" \
    --nonce "$NONCE" \
    --gas-limit 21000 \
    --gas-price "$EEZ_WAVE_L2_GAS_PRICE" \
    --priority-gas-price "$EEZ_WAVE_PRIORITY_GAS_PRICE" \
    --value "$WAVE" \
    "$TO")"

cat <<OP
raw=$RAW
side=l2
kind=example
arg=$WAVE
OP
