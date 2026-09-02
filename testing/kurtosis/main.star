# Kurtosis local network: canonical L1, builder stack, and eez-node.
#
# ── Package API (frozen) ─────────────────────────────────────────────────────
# The supported surface of this package is `run(plan, args)` plus the `eez`
# args key set in EEZ_ARG_KEYS below. Both are stable: a consuming repository
# may depend on them, an unrecognised `eez` key is rejected rather than
# silently ignored, and adding a key is a deliberate API change.
#
# Remote consumption:
#
#     kurtosis run github.com/inertialabsxyz/eez-rollup0/testing/kurtosis \
#         '{"eez": {...}}'
#
# A remote run evaluates this file directly and never runs `start.sh`, so it
# builds nothing. Every image named in the `eez` keys must already be published
# to a registry the enclave can pull from; the `:dev` defaults below exist only
# for a local `start.sh` run, which builds them first.
#
# ── External deployment bundle ───────────────────────────────────────────────
# The `eez-deployments` step is the seam for a consuming repository's own
# contracts. Its contract is fixed:
#
#   in    exactly the six environment variables in DEPLOY_ENV_KEYS, set on an
#         `eez.deploy_image` container running `eez.deploy_cmd`
#   out   exactly one files artifact named `eez-deployments`, holding
#         `deployments.env` and `l2-genesis.json` at its root
#
# Set `eez.deploy_image` + `eez.deploy_cmd` to deploy arbitrary contracts into
# the enclave; the framework never learns what they are. Set
# `eez.deployments_artifact` to the name of an artifact that already satisfies
# the output contract to skip deployment entirely.

ethereum_package = import_module(
    "github.com/ethpandaops/ethereum-package/main.star@199620b24ac979c676010c5a68b2893c2bce4f1f"
)
blockscout = import_module("./blockscout.star")

# Pair A fixed ports inside the enclave.
EMBEDDED_L1_RPC_PORT = 18545
EMBEDDED_L1_ENGINE_PORT = 18551
L2_RPC_PORT = 18688
L2_ENGINE_PORT = 18684
L2_P2P_PORT = 30640
L1_XCHAIN_PORT = 18999
L2_XCHAIN_PORT = 18998
BUILDER_FLASHBOTS_RPC_PORT = 8645
PROOF_SIGNER_GRPC_PORT = 50061
L2_CHAIN_ID = "6290"

# The frozen `eez` args key set (see the API note above).
EEZ_ARG_KEYS = [
    # external deployment seam
    "deploy_image",
    "deploy_cmd",
    "deployments_artifact",
    # service images
    "eez_node_image",
    "proof_signer_image",
    "follower_image",
    # private-network keys
    "poster_key",
    "proof_signer_key",
    "l2_system_key",
    # topology, timing, and logging
    "builder_rpc_url",
    "l1_block_time_ms",
    "l2_block_time_ms",
    "proof_time_ms",
    "submission_slack_ms",
    "max_speculative_depth",
    "fee_recipient",
    "proof_signer_rust_log",
    # explorers
    "enable_explorers",
    "blockscout_image",
    "blockscout_frontend_image",
    "blockscout_postgres_image",
    "blockscout_verifier_image",
]

# The environment the deployment step is given — these six and nothing else.
DEPLOY_ENV_KEYS = [
    "EEZ_L1_RPC_URL",
    "EEZ_L1_POSTER_KEY",
    "EEZ_PROOF_SIGNER_KEY",
    "EEZ_L2_SYSTEM_KEY",
    "EEZ_DEPLOYMENTS_FILE",
    "EEZ_GENESIS_OUT",
]

# The one artifact the deployment step stores, and the name a supplied
# `eez.deployments_artifact` is expected to carry.
DEPLOYMENTS_ARTIFACT = "eez-deployments"

# What the bundled protocol deployment runs when no `eez.deploy_cmd` is given.
# A consumer's command reads DEPLOY_ENV_KEYS and leaves the same two files.
DEFAULT_DEPLOY_CMD = (
    "mkdir -p /out"
    + " && bash /repo/scripts/deploy.sh"
    + " && cp -R /repo/contracts/broadcast /out/foundry-broadcast"
)


def _reject_unknown_eez_keys(eez):
    unknown = []
    for key in eez.keys():
        if key not in EEZ_ARG_KEYS:
            unknown.append(key)
    if len(unknown) > 0:
        fail(
            "unsupported eez args key(s): {}. ".format(", ".join(sorted(unknown)))
            + "This package's API is run(plan, args) with the eez keys: {}".format(
                ", ".join(sorted(EEZ_ARG_KEYS))
            )
        )


def run(plan, args):
    eth_args = args["ethereum_package"]
    eez = args.get("eez", {})
    _reject_unknown_eez_keys(eez)
    enable_explorers = eez.get("enable_explorers", False)

    poster_key = eez.get("poster_key", "")
    proof_signer_key = eez.get("proof_signer_key", "")
    l2_system_key = eez.get("l2_system_key", "")
    if (
        poster_key in ["", "0xCHANGE_ME"]
        or proof_signer_key in ["", "0xCHANGE_ME"]
        or l2_system_key in ["", "0xCHANGE_ME"]
    ):
        fail(
            "set eez.poster_key, eez.proof_signer_key, and eez.l2_system_key in the args file "
            + "(set deterministic test keys in the selected args file)"
        )

    # Pair B: canonical L1, validators, and MEV stack.
    eth = ethereum_package.run(plan, eth_args)

    participants = eth.all_participants
    l1_el = participants[0].el_context

    # Feed the follower all Pair B beacon peers for stable block gossip.
    cl_enrs = [p.cl_context.enr for p in participants]
    cl_multiaddrs = [p.cl_context.multiaddr for p in participants]
    cl_peer_ids = [p.cl_context.peer_id for p in participants]

    # Find the rbuilder participant.
    builder_el = None
    for p in participants:
        if "builder" in p.el_context.service_name:
            builder_el = p.el_context
            break

    builder_rpc = eez.get("builder_rpc_url", "")
    if builder_rpc == "":
        if builder_el == None:
            fail(
                "no rbuilder participant found (service name containing 'builder'); "
                + "set eez.builder_rpc_url explicitly"
            )
        builder_rpc = "http://{}:{}".format(
            builder_el.dns_name, BUILDER_FLASHBOTS_RPC_PORT
        )

    chain_id = str(eth_args.get("network_params", {}).get("network_id", "7331"))
    l2_chain_id = L2_CHAIN_ID

    # Pair A engine API JWT.
    jwt = plan.run_sh(
        description="mint engine-API JWT (embedded reth <-> follower)",
        image="alpine:3.20",
        run="mkdir -p /jwt && tr -dc 'a-f0-9' < /dev/urandom | head -c 64 > /jwt/jwtsecret",
        store=[StoreSpec(src="/jwt/jwtsecret", name="eez-jwt")],
    )

    # The external deployment seam (see the header). Either the consumer hands
    # in an artifact that already satisfies the output contract, or the step
    # runs their command in their image with exactly DEPLOY_ENV_KEYS set and
    # stores what it leaves in /out as the one `eez-deployments` artifact.
    supplied_artifact = eez.get("deployments_artifact", "")
    if supplied_artifact != "":
        deployments = supplied_artifact
        plan.print(
            "eez-deployments: using supplied artifact '{}'; deployment skipped".format(
                supplied_artifact
            )
        )
    else:
        deploy = plan.run_sh(
            description="deploy contracts + generate L2 genesis on the shared L1",
            image=eez.get("deploy_image", "eez-deploy:dev"),
            env_vars={
                "EEZ_L1_RPC_URL": l1_el.rpc_http_url,
                "EEZ_L1_POSTER_KEY": poster_key,
                "EEZ_PROOF_SIGNER_KEY": proof_signer_key,
                "EEZ_L2_SYSTEM_KEY": l2_system_key,
                "EEZ_DEPLOYMENTS_FILE": "/out/deployments.env",
                "EEZ_GENESIS_OUT": "/out/l2-genesis.json",
            },
            run=eez.get("deploy_cmd", DEFAULT_DEPLOY_CMD),
            store=[StoreSpec(src="/out", name=DEPLOYMENTS_ARTIFACT)],
            wait="900s",
        )
        deployments = deploy.files_artifacts[0]

    signer_cmd = " ".join(
        [
            "set -eu;",
            "test -f /out/deployments.env;",
            "set -a; . /out/deployments.env; set +a;",
            "exec eez-proof-signer",
            "--listen-addr=0.0.0.0:{}".format(PROOF_SIGNER_GRPC_PORT),
            "--chain-config=/out/l2-genesis.json",
        ]
    )

    plan.add_service(
        name="eez-proof-signer",
        config=ServiceConfig(
            image=eez.get("proof_signer_image", "eez-proof-signer:dev"),
            ports={
                "grpc": PortSpec(
                    number=PROOF_SIGNER_GRPC_PORT,
                    transport_protocol="TCP",
                    wait="2m",
                ),
            },
            files={
                "/out": deployments,
            },
            env_vars={
                "EEZ_PROOF_SIGNER_KEY": proof_signer_key,
                "EEZ_L2_SYSTEM_KEY": l2_system_key,
                "RUST_LOG": eez.get("proof_signer_rust_log", "info"),
            },
            entrypoint=["/bin/sh", "-c"],
            cmd=[signer_cmd],
        ),
    )

    # eez-node: embedded L1, composer, L2, and cross-chain fronts.
    eez_env = {
        "EEZ_L1_EMBEDDED": "1",
        "EEZ_L1_CHAIN": "devnet",
        "EEZ_L1_CHAIN_PATH": "/genesis/genesis.json",
        "EEZ_L1_JWT_SECRET": "/jwt/jwtsecret",
        "EEZ_L1_HTTP_PORT": str(EMBEDDED_L1_RPC_PORT),
        "EEZ_L1_AUTH_PORT": str(EMBEDDED_L1_ENGINE_PORT),
        "EEZ_L1_CHAIN_ID": chain_id,
        "EEZ_L1_RPC_URL": "http://127.0.0.1:{}".format(EMBEDDED_L1_RPC_PORT),
        "EEZ_L1_TARGET_RPC_URL": l1_el.rpc_http_url,
        "EEZ_L1_BUILDER_RPC_URL": builder_rpc,
        "EEZ_L1_TRUSTED_PEERS": l1_el.enode,
        "EEZ_L1_BLOCK_TIME_MS": str(eez.get("l1_block_time_ms", 12000)),
        "EEZ_L2_BLOCK_TIME_MS": str(eez.get("l2_block_time_ms", 2000)),
        "EEZ_PROOF_TIME_MS": str(eez.get("proof_time_ms", 5000)),
        "EEZ_SUBMISSION_SLACK_MS": str(eez.get("submission_slack_ms", 2500)),
        "EEZ_MAX_SPECULATIVE_DEPTH": str(eez.get("max_speculative_depth", 0)),
        "EEZ_L1_POSTER_KEY": poster_key,
        "EEZ_PROVER_URL": "http://eez-proof-signer:{}".format(PROOF_SIGNER_GRPC_PORT),
        "EEZ_WITNESS_DB_PATH": "/data/witnesses",
        "EEZ_L2_DATADIR": "/data/l2",
        "EEZ_L2_HTTP_PORT": str(L2_RPC_PORT),
        "EEZ_L2_RPC_URL": "http://127.0.0.1:{}".format(L2_RPC_PORT),
        "EEZ_L1_XCHAIN_PORT": str(L1_XCHAIN_PORT),
        "EEZ_L2_XCHAIN_PORT": str(L2_XCHAIN_PORT),
        "EEZ_L2_AUTH_PORT": str(L2_ENGINE_PORT),
        "EEZ_L2_P2P_PORT": str(L2_P2P_PORT),
        "EEZ_L2_SYSTEM_KEY": l2_system_key,
        "EEZL2_ADDRESS": "0x4200000000000000000000000000000000000007",
    }

    node_cmd = " ".join(
        [
            "set -eu;",
            "echo 'eez-node: sourcing /out/deployments.env';",
            "test -f /out/deployments.env;",
            "grep -E '^(EEZ_REGISTRY_ADDRESS|EEZ_REGISTRY_DEPLOY_BLOCK|EEZ_ROLLUP_ID|EEZ_INITIAL_STATE_ROOT|EEZ_L1_L2_PROXY|EEZ_L1_BRIDGE_SENDER)=' /out/deployments.env;",
            "set -a; . /out/deployments.env; set +a;",
            'echo "eez-node: loaded EEZ_REGISTRY_ADDRESS=$EEZ_REGISTRY_ADDRESS EEZ_ROLLUP_ID=$EEZ_ROLLUP_ID EEZ_INITIAL_STATE_ROOT=$EEZ_INITIAL_STATE_ROOT";',
            "exec eez-node node",
            "--chain=/out/l2-genesis.json",
            "--datadir=$EEZ_L2_DATADIR",
            "--http --http.addr=0.0.0.0 --http.port=$EEZ_L2_HTTP_PORT --http.api=eth,net,web3,debug,trace",
            "--authrpc.addr=127.0.0.1 --authrpc.port=$EEZ_L2_AUTH_PORT",
            "--port=$EEZ_L2_P2P_PORT --discovery.port=$EEZ_L2_P2P_PORT",
            "--discovery.v5.port=$((EEZ_L2_P2P_PORT+1))",
            "--ipcdisable --disable-discovery",
        ]
    )

    # Follower beacon drives eez-node's embedded reth over the engine API.
    plan.add_service(
        name="eez-node",
        config=ServiceConfig(
            image=eez.get("eez_node_image", "eez-node:dev"),
            ports={
                "l1-engine": PortSpec(
                    number=EMBEDDED_L1_ENGINE_PORT, transport_protocol="TCP"
                ),
                "l2-rpc": PortSpec(
                    number=L2_RPC_PORT,
                    transport_protocol="TCP",
                    application_protocol="http",
                ),
                "l1-xchain": PortSpec(
                    number=L1_XCHAIN_PORT,
                    transport_protocol="TCP",
                    application_protocol="http",
                ),
                "l2-xchain": PortSpec(
                    number=L2_XCHAIN_PORT,
                    transport_protocol="TCP",
                    application_protocol="http",
                ),
            },
            files={
                "/out": deployments,
                "/genesis": "el_cl_genesis_data",
                "/jwt": jwt.files_artifacts[0],
            },
            env_vars=eez_env,
            entrypoint=["/bin/sh", "-c"],
            cmd=[node_cmd],
        ),
    )

    plan.add_service(
        name="eez-follower",
        config=ServiceConfig(
            image=eez.get("follower_image", "sigp/lighthouse:v8.1.2"),
            private_ip_address_placeholder="FOLLOWER_IP",
            ports={
                "http": PortSpec(
                    number=5252, transport_protocol="TCP", application_protocol="http"
                ),
            },
            files={
                "/testnet": "el_cl_genesis_data",
                "/jwt": jwt.files_artifacts[0],
            },
            entrypoint=["lighthouse"],
            cmd=[
                "beacon_node",
                "--testnet-dir=/testnet",
                "--datadir=/data",
                "--execution-endpoint=http://eez-node:{}".format(
                    EMBEDDED_L1_ENGINE_PORT
                ),
                "--jwt-secrets=/jwt/jwtsecret",
                "--boot-nodes=" + ",".join(cl_enrs),
                "--libp2p-addresses=" + ",".join(cl_multiaddrs),
                "--trusted-peers=" + ",".join(cl_peer_ids),
                "--enable-private-discovery",
                "--disable-packet-filter",
                "--disable-enr-auto-update",
                "--enr-address=FOLLOWER_IP",
                "--enr-udp-port=9000",
                "--enr-tcp-port=9000",
                "--subscribe-all-subnets",
                "--listen-address=0.0.0.0",
                "--port=9000",
                "--http",
                "--http-address=0.0.0.0",
                "--http-port=5252",
                "--suggested-fee-recipient="
                + eez.get(
                    "fee_recipient", "0x0000000000000000000000000000000000000000"
                ),
            ],
        ),
    )

    if enable_explorers:
        explorer_params = {
            "postgres_image": eez.get("blockscout_postgres_image", "postgres:alpine"),
            "backend_image": eez.get(
                "blockscout_image", "ghcr.io/blockscout/blockscout:latest"
            ),
            "verifier_image": eez.get(
                "blockscout_verifier_image",
                "ghcr.io/blockscout/smart-contract-verifier:latest",
            ),
            "frontend_image": eez.get(
                "blockscout_frontend_image", "ghcr.io/blockscout/frontend:latest"
            ),
        }
        blockscout.launch(
            plan=plan,
            prefix="l1",
            network_name="EEZ L1",
            chain_id=chain_id,
            rpc_url=l1_el.rpc_http_url,
            params=explorer_params,
        )
        l2_explorer_params = dict(explorer_params)
        # EEZL2 is a genesis predeploy, so Blockscout must import the L2 alloc
        # to classify it as a contract before accepting source verification.
        # The Geth adapter understands alloc-based genesis files and uses the
        # debug namespace exposed by the L2 Reth node for internal calls.
        l2_explorer_params["json_rpc_variant"] = "geth"
        l2_explorer_params["chain_spec_artifact"] = deployments
        l2_explorer_params["chain_spec_path"] = "/chain-spec/l2-genesis.json"
        blockscout.launch(
            plan=plan,
            prefix="l2",
            network_name="EEZ L2",
            chain_id=l2_chain_id,
            rpc_url="http://eez-node:{}/".format(L2_RPC_PORT),
            params=l2_explorer_params,
        )

    plan.print(
        "EEZ local network ready, L1 chain_id={}, L2 chain_id={}".format(
            chain_id, l2_chain_id
        )
    )
