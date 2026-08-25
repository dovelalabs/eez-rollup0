#!/usr/bin/env bash
# Remove the local Kurtosis devnet enclave.
set -euo pipefail

ENCLAVE="${KURTOSIS_ENCLAVE:-eez-ci}"

command -v kurtosis >/dev/null || { echo "kurtosis not found in PATH" >&2; exit 1; }

echo "==> removing enclave '$ENCLAVE'"
kurtosis enclave rm -f "$ENCLAVE" 2>/dev/null || true

# Host-side explorer container from dev-up.sh, if one is running.
docker rm -f "${EEZ_OTTERSCAN_NAME:-eez-otterscan}" >/dev/null 2>&1 || true

echo "Kurtosis devnet enclave removed."
