# Playbook: driving the test network by hand

Hands-on companion to `README.md`. That file covers the CI lifecycle; this one
covers poking at a running enclave from your own shell — calling a contract on
L2, calling one on L1, and getting an L2 transaction to read L1 state.

For how the pieces fit together (slot ladder, Sync block, settlement), see the
architecture reference; for the protocol structs, `sync-rollups-protocol/CLAUDE.md`.

Prerequisites: Docker, Kurtosis, Foundry, `jq`, `curl`, and the initialised
`sync-rollups-protocol` submodule.

```bash
bash testing/kurtosis/start.sh    # build images + bring up the enclave
bash testing/kurtosis/stop.sh     # tear it down
```

Rebuilding the images takes a while. To reuse what you already have:

```bash
EEZ_SKIP_NODE_BUILD=1 EEZ_SKIP_PROOF_SIGNER_BUILD=1 EEZ_SKIP_DEPLOY_BUILD=1 \
  bash testing/kurtosis/start.sh
```

---

## 0. Session setup

Kurtosis assigns random host ports on every start, so nothing can be hardcoded.
Source the init script once per shell:

```bash
cd ~/devel/eez-rollup0
source testing/kurtosis/env.sh
```

It resolves the live ports, pulls the deployment addresses out of the
`eez-deployments` artifact, exports the dev keys, and prints a health check.
Re-source it any time — after a restart, or in a new terminal.

| Variable | What it is |
|---|---|
| `$L1` | Canonical PoS L1 RPC — reth + lighthouse + mev-boost + rbuilder |
| `$L2` | Rollup L2 RPC |
| `$L1F` | **L1 front** — inbound (L1 → L2) cross-chain ingress |
| `$L2F` | **L2 front** — outbound (L2 → L1) cross-chain ingress |
| `$BUILDER`, `$BEACON` | rbuilder RPC, follower beacon HTTP |
| `$EEZ_REGISTRY_ADDRESS`, `$EEZ_ROLLUP_ID`, `$EEZL2_ADDRESS`, … | everything in `deployments.env` |
| `$KEY2`/`$ADDR2` | Hardhat #2 — **use this one**, funded on both chains and untouched by the protocol |
| `$KEY1`/`$ADDR1` | Hardhat #1 — the registered attester. Safe to spend; it only ever signs off-chain. |
| `$KEY0`/`$ADDR0` | Hardhat #0 — the live L1 poster. **Do not send L1 transactions from it.** |

All twenty Hardhat accounts are prefunded with 1 000 000 ETH on L2. Four of them
(`f39F…`, `7099…`, `3C44…`, `b9e7…`) are prefunded on L1.

The `KEY0` warning is not theoretical. The composer sends `postBatch` from that
account on every Sync slot, so its nonce advances continuously; a transaction of
yours from the same account races it and simply never lands. The symptom is
`forge create` hanging and eventually reporting `contract was not deployed`.

Two helpers come with it: `eez_status` reprints the summary, and `xsend` posts a
signed transaction to a cross-chain front.

### Before you start: is settlement alive?

```bash
eez_status
```

The proof signer refuses any window wider than **512 L2 blocks**, and the window
only grows. If posting stalls — a laptop sleeping for a few minutes is enough —
the gap passes the cap and settlement never recovers. Every slot then fails with
`window quota: window N..=M spans … blocks, limit is 512`, the safe head freezes,
and every cross-chain transaction you send afterwards waits in the held pool
forever.

`eez_status` warns when the gap is over 512. There is no repair; restart the
enclave. Sections A and B still work on a stalled enclave — section C does not.

---

## A. Call a contract on L2

The plain sequencer path. Nothing cross-chain happens.

```bash
cd $EEZ_REPO/contracts

V2=$(forge create src/Value.sol:Value \
       --rpc-url $L2 --private-key $KEY2 --broadcast --json \
       --constructor-args 41 | jq -r .deployedTo)

cast send $V2 'setValue(uint256)' 7 --rpc-url $L2 --private-key $KEY2
cast call $V2 'value()(uint256)' --rpc-url $L2      # -> 7
```

`--constructor-args` is variadic, so it must come **last**. Put it before
`--rpc-url` and it silently swallows every flag that follows; forge then falls
back to `localhost:8545` and fails with a connection error that looks like the
enclave is down.

The transaction enters reth's ordinary mempool. `eez-driver` decides when blocks
are produced and pushes them in over the engine API; yours lands in whichever
slot comes next. In the node log it shows up as `produced block N … kind=live`.

It will not be on the safe head immediately — see section D.

---

## B. Call a contract on L1

Same shape, different RPC. The L1 is a stock PoS devnet; eez is just another user
of it.

```bash
V1=$(forge create src/Value.sol:Value \
       --rpc-url $L1 --private-key $KEY2 --broadcast --json \
       --constructor-args 41 | jq -r .deployedTo)

cast send $V1 'setValue(uint256)' 3 --rpc-url $L1 --private-key $KEY2
cast call $V1 'value()(uint256)' --rpc-url $L1      # -> 3
```

Expect roughly one L1 block (12 s) per transaction, not the 2 s you get on L2.

The only eez presence on L1 is the registry, which is worth poking at directly —
it is the settlement contract:

```bash
cast call $EEZ_REGISTRY_ADDRESS 'lastVerifiedBlock(uint64)(uint256)' \
     $EEZ_ROLLUP_ID --rpc-url $L1

cast logs --address $EEZ_REGISTRY_ADDRESS --from-block $EEZ_REGISTRY_DEPLOY_BLOCK \
     'BatchPosted(uint256)' --rpc-url $L1 | tail -20
```

---

## C. Cross-chain: L2 and L1 in one transaction

### The rule that governs everything

Direction is decided **by the endpoint you post to** — not by the `to` address,
not by the chain id:

- L1-signed transaction → `$L1F` → held → effect executed on **L2**
- L2-signed transaction → `$L2F` → held → effect executed on **L1**

A cross-chain transaction sent to `$L1`/`$L2` instead is an ordinary transaction
that reverts on the proxy. A pure transaction sent to a front is poison-evicted
at compose time.

### Why `cast send` does not work here

`cast send` calls `eth_estimateGas` first. The front forwards that upstream, where
the proxy call has no loaded execution entry and reverts — estimation fails and
you never get to submit. Build the transaction offline with an explicit gas
limit, then post the raw bytes:

```bash
RAW=$(cast mktx --chain-id <id> --private-key $KEY2 --nonce <n> \
        --gas-limit 800000 --gas-price <gp> --priority-gas-price 1 \
        <to> '<sig>' <args>)
xsend $L2F "$RAW"
```

### C1. An L2 transaction that reads L1 state

An L2 contract calls an L1 contract and consumes its **return value inside the
same L2 transaction**. The composer simulates the L1 call, captures the return
data, and synthesises it back into the L2 frame.

`contracts/src/SetterWrapper.sol` is the minimal demonstration: it calls
`proxy.setValue(v)`, decodes the `(bool changed, uint256 newValue)` that L1
returned, and emits it.

```bash
# 1. The target lives on L1 — $V1 from section B.

# 2. On L2, create the proxy identity for that L1 address. rid=0 is L1/mainnet.
PROXY=$(cast call $EEZL2_ADDRESS \
          'computeCrossChainProxyAddress(address,uint64)(address)' $V1 0 --rpc-url $L2)

cast send $EEZL2_ADDRESS 'createCrossChainProxy(address,uint64)' $V1 0 \
     --rpc-url $L2 --private-key $KEY2          # pure L2 tx — normal RPC

# 3. The L2-side wrapper that calls the proxy and decodes what L1 returned.
W=$(forge create src/SetterWrapper.sol:SetterWrapper \
      --rpc-url $L2 --private-key $KEY2 --broadcast --json \
      --constructor-args $PROXY | jq -r .deployedTo)

# 4. The cross-chain transaction — offline, then posted to the L2 FRONT.
NONCE=$(cast nonce $ADDR2 --rpc-url $L2)
GP=$(cast gas-price --rpc-url $L2)
RAW=$(cast mktx --chain-id $(cast chain-id --rpc-url $L2) \
        --private-key $KEY2 --nonce $NONCE \
        --gas-limit 800000 --gas-price $GP --priority-gas-price 1 \
        $W 'setViaProxy(uint256)' 7)
xsend $L2F "$RAW"

# 5. The effect lands on L1; the L1 return value comes back in an L2 log.
cast call $V1 'value()(uint256)' --rpc-url $L1                        # -> 7
cast logs --address $W 'Wrapped(uint256,bool,bool,uint256)' --rpc-url $L2
```

Settlement takes about 30 s on the CI profile — one Sync slot to compose, then
the L1 block that carries the bundle. The `Wrapped` log decodes to
`(input=7, ok=true, changed=true, newValue=7)`: the last two words are what the
*L1* `Value.setValue` returned, delivered back into the L2 transaction's frame.
That round trip is the whole point of the system.

Watch it compose: 

```bash
kurtosis service logs -f $KURTOSIS_ENCLAVE eez-node | grep -E 'compose_sync_slot|held|bundle'
```

The mirror direction is the same recipe with everything swapped: create the proxy
on `$EEZ_REGISTRY_ADDRESS` with `rid=$EEZ_ROLLUP_ID`, sign for the L1 chain id,
and post to `$L1F`. `contracts/script/CreateValueProxy.s.sol` does the L1-side
proxy creation.

At most three cross-chain user transactions ride in one bundle
(`EEZ_MAX_USER_TXS_PER_BUNDLE`, default 3) — send more and the excess drains over
later slots.

### C2. The static read — specified, not implemented

The protocol has a genuine read path: an L2 contract `STATICCALL`s a proxy and
`EEZL2.staticCrossChainCall` resolves it from a `StaticExecutionEntry` the
composer pre-computed. `CrossChainProxy._fallback()` even detects static context
by attempting a `tstore` in a capped self-call, and routes accordingly. All of
that is live in Solidity.

The Rust side does not produce those entries:

```bash
grep -n "is_static" crates/eez-evm-inspector/src/inspector.rs   # :489 static frames skipped
grep -n "STATIC_CALL" crates/eez-protocol/src/entries/mod.rs    # :22, :162 "not supported"
```

The inspector returns early on `inputs.is_static`, so a static proxy call is
never recorded as a cross-chain action, and `finalize_l1_rolling_hashes` rejects
any batch with a non-empty `staticEntries`. `staticEntries` is therefore always
empty and a static cross-chain read reverts `ExecutionNotFound`.

Use C1 when you need L1 data on L2. Re-check the two greps above before assuming
this is still true.

---

## D. Watching it

```bash
kurtosis enclave inspect $KURTOSIS_ENCLAVE
kurtosis service logs -f $KURTOSIS_ENCLAVE eez-node
kurtosis service logs -f $KURTOSIS_ENCLAVE eez-proof-signer
```

The `kind=live|future|sync` field on each `produced block` line is the clearest
window into the scheduler — exactly one Sync block per L1 block, and only that
block carries cross-chain work.

L2 has two heads, and the gap between them is the trust model:

```bash
cast block-number --rpc-url $L2               # unsafe head — every 2s
cast block safe --field number --rpc-url $L2  # safe head — only on settlement
```

---

## E. When something misbehaves

| Symptom | Cause |
|---|---|
| `eez_status` reports settlement stalled | Window past the 512-block signer cap. Unrecoverable — restart the enclave. |
| Cross-chain tx accepted, never lands | Settlement stalled, or the bundle keeps dropping. Check `eez-node` logs for `bundle`. |
| `cast send` to a front fails on gas estimation | Expected. Use `cast mktx` + `xsend`. |
| Front rejects the tx outright | Wrong direction for that endpoint, or the wrong source chain id in the signature. |
| `ExecutionNotFound` on a proxy call | The proxy was never created, or you're attempting a static read (C2). |
| `forge` connection-refused on `localhost:8545` | `--constructor-args` was not last and ate the `--rpc-url` flag. |
| `forge create` hangs, then `contract was not deployed` | You sent from `$KEY0` on L1 and lost the nonce race with the poster. Use `$KEY2`. |
| `env.sh` says the enclave is not up | `kurtosis enclave ls` — run `start.sh`. |

## F. The executable specification

Two scripts are worth more than this document, because they cannot drift from the
code:

- `testing/kurtosis/scripts/cross-chain-wave.sh` — inbound, outbound, mixed and
  `mixed-pure` waves across every op type, with convergence and settlement
  assertions. Set `EEZ_FUND_FROM_KEY=$KEY1`, since it looks for an `args.yaml`
  this repo does not ship.
- `scripts/xchain-test.sh` — the fuller matrix, plus load and restart modes.

```bash
EEZ_WAVE_MODE=inbound EEZ_WAVE_COUNT=1 EEZ_FUND_FROM_KEY=$KEY1 \
  bash testing/kurtosis/scripts/cross-chain-wave.sh
```
