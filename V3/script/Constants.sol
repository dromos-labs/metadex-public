// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title Constants
 * @notice Constants used by the V3 deployment scripts
 */
abstract contract Constants {
  /*////////////////////////////////////////////////////////////
                            CHAINIDS
  ////////////////////////////////////////////////////////////*/

  uint256 public constant LOCAL_ANVIL_CHAINID = 31_337;

  /*////////////////////////////////////////////////////////////
                        DEPLOYS SETUP
  ////////////////////////////////////////////////////////////*/

  bytes public constant CREATEX_BYTECODE = hex'bd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f';
  address public constant CREATEX_ADDRESS = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
  address public constant DEPLOYER = 0x4994DacdB9C57A811aFfbF878D92E00EF2E5C4C2;

  /*////////////////////////////////////////////////////////////
                            ENTROPY
  ////////////////////////////////////////////////////////////*/

  // Pool deployment unit
  bytes11 public constant VOLATILE_POOL_ENTROPY = 0x0000000000000000000030;
  bytes11 public constant VOLATILE_POOL_FACTORY_ENTROPY = 0x0000000000000000000031;
  bytes11 public constant STABLE_POOL_ENTROPY = 0x0000000000000000000038;
  bytes11 public constant STABLE_POOL_FACTORY_ENTROPY = 0x0000000000000000000039;
  bytes11 public constant POOL_TAPE_ENTROPY = 0x000000000000000000003a;
  bytes11 public constant DISCOUNT_REGISTRY_ENTROPY = 0x000000000000000000003b;
  bytes11 public constant VOLATILE_CUSTOM_FEE_MODULE_ENTROPY = 0x000000000000000000003c;
  bytes11 public constant STABLE_CUSTOM_FEE_MODULE_ENTROPY = 0x000000000000000000003d;
  bytes11 public constant VOLATILE_FLAT_FEE_QUOTER_ENTROPY = 0x0000000000000000000051;
  bytes11 public constant STABLE_FLAT_FEE_QUOTER_ENTROPY = 0x0000000000000000000052;

  // Upcoming deployment units
  bytes11 public constant ROUTER_ENTROPY = 0x0000000000000000000032;
  bytes11 public constant VOTING_ESCROW_ENTROPY = 0x0000000000000000000033;
  bytes11 public constant MINTER_ENTROPY = 0x0000000000000000000035;
  bytes11 public constant VOTER_ENTROPY = 0x0000000000000000000036;
  bytes11 public constant FACTORY_REGISTRY_ENTROPY = 0x0000000000000000000037;

  // Relay deployment unit (root only)
  bytes11 public constant RELAY_FACTORY_ENTROPY = 0x0000000000000000000034;
  bytes11 public constant MAXI_RELAY_IMPLEMENTATION_ENTROPY = 0x000000000000000000003e;
  bytes11 public constant PROTOCOL_RELAY_IMPLEMENTATION_ENTROPY = 0x000000000000000000003f;
  bytes11 public constant RELAY_TOKEN_IMPLEMENTATION_ENTROPY = 0x000000000000000000005c;
  bytes11 public constant RELAY_TOKEN_VOTES_IMPLEMENTATION_ENTROPY = 0x000000000000000000005d;
  bytes11 public constant RELAY_VOTE_ADAPTER_ENTROPY = 0x000000000000000000005e;

  // 40 - 50 is reserved for use by slipstream contracts
}
