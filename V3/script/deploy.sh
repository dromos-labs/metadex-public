#!/bin/bash

# Check if required arguments are provided
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <chain-name> <unit> [verifier-type] [additional-args]"
    echo "Example (simulation only): $0 base Pools"
    echo "Example (with deployment): $0 base Pools etherscan"
    echo "Example with additional args: $0 base Pools etherscan \"--account deployer\""
    exit 1
fi

CHAIN_NAME=$1
UNIT=$2
VERIFIER_TYPE=${3:-""} # Use empty string if no third argument provided
ADDITIONAL_ARGS=${4:-""} # Use empty string if no fourth argument provided

# Path to the deployment script of the requested unit
SCRIPT_PATH="V3/script/deployParameters/${CHAIN_NAME}/Deploy${UNIT}.s.sol:Deploy${UNIT}"

if [ ! -f "V3/script/deployParameters/${CHAIN_NAME}/Deploy${UNIT}.s.sol" ]; then
    echo "Error: Unknown unit '${UNIT}' for chain '${CHAIN_NAME}' (no ${SCRIPT_PATH%%:*})"
    exit 1
fi

echo "Running ${UNIT} simulation for ${CHAIN_NAME}..."
# Run simulation first
if forge script ${SCRIPT_PATH} --slow --rpc-url ${CHAIN_NAME} -vvvv; then
    # If no verifier type is provided, exit after successful simulation
    if [ -z "$VERIFIER_TYPE" ]; then
        echo "Simulation completed successfully. No deployment performed (no verifier type provided)."
        exit 0
    fi

    # Set verifier arguments based on verifier type
    if [ "$VERIFIER_TYPE" = "blockscout" ]; then
        VERIFIER_ARG="--verifier blockscout"
    elif [ "$VERIFIER_TYPE" = "etherscan" ]; then
        VERIFIER_ARG="--verifier etherscan"
    else
        echo "Error: Unsupported verifier type. Use 'blockscout' or 'etherscan'"
        exit 1
    fi

    echo "Simulation successful! Proceeding with actual deployment..."

    # Run actual deployment with verification
    forge script ${SCRIPT_PATH} --slow --rpc-url ${CHAIN_NAME} --broadcast --verify ${VERIFIER_ARG} ${ADDITIONAL_ARGS} -vvvv
else
    echo "Simulation failed! Please check the output above for errors."
    exit 1
fi
