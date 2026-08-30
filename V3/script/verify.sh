#!/bin/bash

# Submits and watches verification for every contract of a deployment unit on a chain.
# Addresses are read from the deployment output JSON written by the deploy script.
# Constructor args are recovered from each creation transaction via --guess-constructor-args.

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <chain-name> <unit> [verifier-type] [additional-args]"
    echo "Example: $0 base Pools"
    echo "Example: $0 base Pools blockscout \"--verifier-url https://base.blockscout.com/api\""
    exit 1
fi

CHAIN_NAME=$1
UNIT=$2
VERIFIER_TYPE=${3:-"etherscan"}
ADDITIONAL_ARGS=${4:-""} # Use empty string if no fourth argument provided

if [ "$VERIFIER_TYPE" != "etherscan" ] && [ "$VERIFIER_TYPE" != "blockscout" ]; then
    echo "Error: Unsupported verifier type. Use 'blockscout' or 'etherscan'"
    exit 1
fi

# key in the output JSON -> contract source path and name, per unit
case "$UNIT" in
    Pools)
        CONTRACTS=(
            "volatilePoolImplementation:V3/src/pools/VolatilePool.sol:VolatilePool"
            "stablePoolImplementation:V3/src/pools/StablePool.sol:StablePool"
            "volatilePoolFactory:V3/src/factories/VolatilePoolFactory.sol:VolatilePoolFactory"
            "stablePoolFactory:V3/src/factories/StablePoolFactory.sol:StablePoolFactory"
            "poolTape:V3/src/pools/tape/PoolTape.sol:PoolTape"
            "discountRegistry:V3/src/fees/DiscountRegistry.sol:DiscountRegistry"
            "volatileCustomFeeModule:V3/src/fees/CustomFeeModule.sol:CustomFeeModule"
            "stableCustomFeeModule:V3/src/fees/CustomFeeModule.sol:CustomFeeModule"
            "volatileFlatFeeQuoter:V3/src/fees/FlatFeeQuoter.sol:FlatFeeQuoter"
            "stableFlatFeeQuoter:V3/src/fees/FlatFeeQuoter.sol:FlatFeeQuoter"
        )
        ;;
    RelayStack)
        CONTRACTS=(
            "relayTokenImplementation:V3/src/relay/RelayToken.sol:RelayToken"
            "relayTokenVotesImplementation:V3/src/relay/RelayTokenVotes.sol:RelayTokenVotes"
            "relayVoteAdapter:V3/src/relay/RelayVoteAdapter.sol:RelayVoteAdapter"
            "maxiRelayImplementation:V3/src/relay/MaxiRelay.sol:MaxiRelay"
            "protocolRelayImplementation:V3/src/relay/ProtocolRelay.sol:ProtocolRelay"
            "relayFactory:V3/src/relay/RelayFactory.sol:RelayFactory"
        )
        ;;
    *)
        echo "Error: Unknown unit '${UNIT}'. Use 'Pools' or 'RelayStack'."
        exit 1
        ;;
esac

UNIT_LOWER=$(echo "$UNIT" | tr '[:upper:]' '[:lower:]')
OUTPUT_FILE="deployment-addresses/${UNIT_LOWER}-${CHAIN_NAME}.json"

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: ${OUTPUT_FILE} not found. Deploy first with deploy.sh."
    exit 1
fi

# Refuse to run against an output JSON with contracts this script does not know about, so a
# contract added to the deployment unit but not to the map above cannot be skipped silently.
for JSON_KEY in $(python3 -c "import json; print('\n'.join(json.load(open('${OUTPUT_FILE}'))))"); do
    KNOWN=false
    for ENTRY in "${CONTRACTS[@]}"; do
        if [ "${ENTRY%%:*}" = "$JSON_KEY" ]; then
            KNOWN=true
            break
        fi
    done
    if [ "$KNOWN" = false ]; then
        echo "Error: ${OUTPUT_FILE} contains '${JSON_KEY}', which is not in the ${UNIT} contracts map. Update verify.sh."
        exit 1
    fi
done

FAILED=()

for ENTRY in "${CONTRACTS[@]}"; do
    KEY="${ENTRY%%:*}"
    TARGET="${ENTRY#*:}"
    ADDRESS=$(python3 -c "import json; print(json.load(open('${OUTPUT_FILE}'))['${KEY}'])") || ADDRESS=""

    if [ -z "$ADDRESS" ]; then
        echo "Error: ${KEY} not found in ${OUTPUT_FILE}"
        FAILED+=("$KEY")
        continue
    fi

    echo "Verifying ${KEY} at ${ADDRESS}..."
    if ! forge verify-contract \
        "$ADDRESS" \
        "$TARGET" \
        --rpc-url "$CHAIN_NAME" \
        --guess-constructor-args \
        --watch \
        --verifier "$VERIFIER_TYPE" ${ADDITIONAL_ARGS}; then
        FAILED+=("$KEY")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "Verification failed for: ${FAILED[*]}"
    exit 1
fi

echo "All contracts verified."
