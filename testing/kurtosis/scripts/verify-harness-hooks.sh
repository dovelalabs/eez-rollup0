#!/usr/bin/env bash
# Verify the external-consumer hooks of this Kurtosis package.
#
# Three groups, one per hook:
#
#   UP-1  the eez-deployments step is an external deployment seam with a fixed
#         six-env-vars-in / one-artifact-out contract
#   UP-2  cross-chain-wave.sh dispatches over EEZ_WAVE_OPS and can run a
#         consumer's own `ext:` op
#   UP-3  the package is consumable from another repository under its own name,
#         with a frozen run(plan, args) + `eez` key API
#
# Hermetic: no enclave, no Docker, no network. The behavioural half of UP-2
# runs the real helpers out of cross-chain-wave.sh against a stubbed `cast`.
# The enclave-level counterpart is the `ext` row of verify-cross-chain-waves.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$K/../.." && pwd)"
MAIN_STAR="$K/main.star"
WAVE_SH="$HERE/cross-chain-wave.sh"

PASS=0
FAIL=0

ok()   { echo "    ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "    ✗ $1"; FAIL=$((FAIL + 1)); }
check() { # <label> <actual> <expected>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: actual='$2' expected='$3'"; fi
}
check_contains() { # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1: '$3' not found"; fi
}
check_fails() { # <label> <command...> — the command must exit non-zero
    if "${@:2}" >/dev/null 2>&1; then bad "$1 (the input was accepted)"; else ok "$1"; fi
}

# ── Readers over main.star ────────────────────────────────────────────
# The deployment step, as one flat string (comments and newlines removed).
deploy_step() {
    awk '/^    else:$/{f=1} f{print} f&&/^        \)$/{exit}' "$MAIN_STAR"
}
star_list() { # <NAME> → the string entries of a top-level list constant
    awk -v name="$1" '$0 == name " = [" {f=1; next} f && /^\]/{exit} f' "$MAIN_STAR" \
        | sed -nE 's/^[[:space:]]*"([^"]+)",$/\1/p'
}
star_eez_keys() { # every eez.get() key, including the line-wrapped calls
    tr '\n' ' ' <"$MAIN_STAR" | grep -oE 'eez\.get\( *"[a-z0-9_]+"' \
        | sed -E 's/.*"([a-z0-9_]+)"/\1/' | sort -u
}

echo "════════════════════════════════════════════════════════════════"
echo " HARNESS HOOKS"
echo "════════════════════════════════════════════════════════════════"

# ── UP-1 — external deployment bundle ─────────────────────────────────
echo "==> UP-1 external deployment bundle"

ARG_KEYS="$(star_list EEZ_ARG_KEYS)"
for key in deploy_image deploy_cmd deployments_artifact; do
    if grep -qx "$key" <<<"$ARG_KEYS"; then
        ok "eez.$key is part of the package API"
    else
        bad "eez.$key is missing from EEZ_ARG_KEYS"
    fi
done

STEP="$(deploy_step)"
DECLARED_ENV="$(star_list DEPLOY_ENV_KEYS | sort)"
ACTUAL_ENV="$(sed -nE 's/^[[:space:]]*"(EEZ_[A-Z0-9_]+)":.*/\1/p' <<<"$STEP" | sort)"
check "the deployment step's environment is DEPLOY_ENV_KEYS" "$ACTUAL_ENV" "$DECLARED_ENV"
check "the contract is exactly six environment variables" "$(wc -l <<<"$DECLARED_ENV" | tr -d ' ')" "6"

check_contains "deployments.env is named by the contract" "$STEP" '"EEZ_DEPLOYMENTS_FILE": "/out/deployments.env"'
check_contains "l2-genesis.json is named by the contract" "$STEP" '"EEZ_GENESIS_OUT": "/out/l2-genesis.json"'
check_contains "the consumer supplies the image" "$STEP" 'image=eez.get("deploy_image"'
check_contains "the consumer supplies the command" "$STEP" 'run=eez.get("deploy_cmd", DEFAULT_DEPLOY_CMD)'
check_contains "one artifact out, under the contract's name" "$STEP" \
    'store=[StoreSpec(src="/out", name=DEPLOYMENTS_ARTIFACT)]'
check "the artifact name is eez-deployments" \
    "$(sed -nE 's/^DEPLOYMENTS_ARTIFACT = "(.*)"$/\1/p' "$MAIN_STAR")" "eez-deployments"

check "the deployment step stores exactly one artifact" \
    "$(grep -c 'StoreSpec(' "$MAIN_STAR")" "2"   # the JWT step stores the other

# A supplied artifact must reach every consumer, so the raw step result is read
# once — where `deployments` is bound — and never again.
check "deployments_artifact short-circuits the step" \
    "$(grep -c 'supplied_artifact != ""' "$MAIN_STAR")" "1"
check "the step result is read once, into the bound name" \
    "$(grep -c 'deploy\.files_artifacts\[0\]' "$MAIN_STAR")" "1"
check "every consumer reads the bound artifact" \
    "$(grep -cE '(: |= )deployments,?$' "$MAIN_STAR")" "3"

# ── UP-2 — generic external op ────────────────────────────────────────
echo "==> UP-2 generic external op"

# The pure half of cross-chain-wave.sh: op parsing and dispatch, no enclave.
# shellcheck source=./cross-chain-wave.sh
source "$WAVE_SH"

check "the built-in inbound workload is unchanged" \
    "$(EEZ_WAVE_OPS= wave_ops inbound | tr '\n' ' ')" "in:set in:noret in:dep in:wrap "
check "the built-in outbound workload is unchanged" \
    "$(EEZ_WAVE_OPS= wave_ops outbound | tr '\n' ' ')" "out:set out:noret out:wd out:wrap "
check "mixed is inbound then outbound" \
    "$(EEZ_WAVE_OPS= wave_ops mixed | tr '\n' ' ')" \
    "in:set in:noret in:dep in:wrap out:set out:noret out:wd out:wrap "
check "mixed-pure fires the same ops as mixed" \
    "$(EEZ_WAVE_OPS= wave_ops mixed-pure | tr '\n' ' ')" \
    "$(EEZ_WAVE_OPS= wave_ops mixed | tr '\n' ' ')"
check_fails "an unknown mode is rejected" wave_ops nonsense

check "EEZ_WAVE_OPS overrides the mode's list" \
    "$(EEZ_WAVE_OPS="ext:./a.sh, out:set ,ext:./b.sh --flag v" wave_ops mixed | tr '\n' '|')" \
    "ext:./a.sh|out:set|ext:./b.sh --flag v|"

# The per-wave arguments the built-in assertions depend on.
check "in:set argument"   "$(wave_arg_for in:set 3)"   "103"
check "in:noret argument" "$(wave_arg_for in:noret 3)" "203"
check "in:wrap argument"  "$(wave_arg_for in:wrap 3)"  "303"
check "in:dep argument"   "$(wave_arg_for in:dep 3)"   "30000000000000"
check "out:set argument"   "$(wave_arg_for out:set 3)"   "403"
check "out:noret argument" "$(wave_arg_for out:noret 3)" "503"
check "out:wrap argument"  "$(wave_arg_for out:wrap 3)"  "603"
check "out:wd argument"    "$(wave_arg_for out:wd 3)"    "15000000000000"
check "an external op takes no built-in argument" "$(wave_arg_for ext:./a.sh 3)" ""

RAW=0x02f8730182014b8459682f00
check "a bare raw transaction is accepted" \
    "$(ext_op_parse "$RAW")" "$RAW|out|ext|"
check "a key=value block sets side, kind, and arg" \
    "$(ext_op_parse "$(printf 'raw=%s\nside=l2\nkind=place\narg=7\n' "$RAW")")" \
    "$RAW|l2|place|7"
check "blank lines and ordering do not matter" \
    "$(ext_op_parse "$(printf '\nside=in\n\nraw=%s\n' "$RAW")")" "$RAW|in|ext|"
check "an op with nothing to send declines" "$(ext_op_parse "$(printf '\n  \n')")" ""
check_fails "an unknown output key is rejected"  ext_op_parse "$(printf 'raw=%s\nnope=1\n' "$RAW")"
check_fails "an unknown side is rejected"        ext_op_parse "$(printf 'raw=%s\nside=l3\n' "$RAW")"
check_fails "a reserved kind is rejected"        ext_op_parse "$(printf 'raw=%s\nkind=wrap\n' "$RAW")"
check_fails "a missing transaction is rejected"  ext_op_parse "$(printf 'side=out\n')"
check_fails "a malformed transaction is rejected" ext_op_parse "raw=deadbeef"
check_fails "a kind that would corrupt TX_META is rejected" \
    ext_op_parse "$(printf 'raw=%s\nkind=a|b\n' "$RAW")"

# The reference op, end to end, against a stubbed cast.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat >"$STUB_DIR/cast" <<STUB
#!/usr/bin/env bash
case "\$1" in
    wallet) echo 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC ;;
    nonce)  echo 4 ;;
    mktx)   echo $RAW ;;
    *)      echo "unexpected cast \$1" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/cast"
EXAMPLE_OUT="$(
    PATH="$STUB_DIR:$PATH" \
    EEZ_WAVE_L2_RPC=http://stub EEZ_WAVE_L2_CHAIN_ID=6290 \
    EEZ_WAVE_L2_GAS_PRICE=1000000000 EEZ_WAVE_PRIORITY_GAS_PRICE=1 \
    bash "$HERE/example-ext-op.sh" 2
)"
check "the reference external op emits a parseable transaction" \
    "$(ext_op_parse "$EXAMPLE_OUT")" "$RAW|l2|example|2"

# ── UP-3 — consumable from another repository ─────────────────────────
echo "==> UP-3 consumable from another repository"

PACKAGE_NAME="$(sed -nE 's/^name:[[:space:]]*(.*)$/\1/p' "$K/kurtosis.yml")"
ORIGIN="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
if [[ -n "$ORIGIN" ]]; then
    SLUG="$(sed -E 's#^git@([^:]+):#\1/#; s#^https?://##; s#\.git$##' <<<"$ORIGIN")"
    check "the package name matches its own remote" "$PACKAGE_NAME" "$SLUG/testing/kurtosis"
else
    ok "no origin remote in this checkout; package-name comparison skipped"
fi

check "the package API rejects unknown eez keys" \
    "$(grep -c '^    _reject_unknown_eez_keys(eez)$' "$MAIN_STAR")" "1"
check "every eez key read is part of the frozen API" \
    "$(comm -23 <(star_eez_keys) <(sort <<<"$ARG_KEYS") | tr '\n' ' ')" ""
check "the frozen API has no key the package ignores" \
    "$(comm -13 <(star_eez_keys) <(sort <<<"$ARG_KEYS") | tr '\n' ' ')" ""

if grep -q 'never runs `start.sh`' "$MAIN_STAR"; then
    ok "main.star documents that a remote run bypasses start.sh"
else
    bad "main.star does not document that a remote run bypasses start.sh"
fi
if grep -q "kurtosis run $PACKAGE_NAME" "$K/README.md"; then
    ok "the README documents remote consumption"
else
    bad "the README does not document remote consumption"
fi

echo
if (( FAIL == 0 )); then
    echo "==> HARNESS HOOKS PASSED ($PASS checks)"
else
    echo "==> HARNESS HOOKS FAILED ($FAIL of $((PASS + FAIL)) checks)"
    exit 1
fi
