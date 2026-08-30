// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title Commands
 * @notice Command IDs and command-byte encoding constants used by the Metarouter.
 */
library Commands {
  /// Payments
  /**
   * @notice Transfers a full execution-address balance with a minimum floor.
   * @return The SWEEP command ID.
   */
  uint256 public constant SWEEP = 0x04;

  /**
   * @notice Transfers a balance portion selected with `Amount` or `Pips` to a recipient.
   * @return The TRANSFER command ID.
   */
  uint256 public constant TRANSFER = 0x05;

  /**
   * @notice Wraps an `Amount` or `Pips` portion of the available native ETH.
   * @return The WRAP_ETH command ID.
   */
  uint256 public constant WRAP_ETH = 0x0b;

  /**
   * @notice Unwraps a WETH balance portion selected with `Amount` or `Pips` and sends ETH to a recipient.
   * @return The UNWRAP_WETH command ID.
   */
  uint256 public constant UNWRAP_WETH = 0x0c;

  /**
   * @notice Pulls an `Amount` or `Pips` share of `msgSender()`'s balance into the execution address.
   * @return The FUND_ERC20 command ID.
   */
  uint256 public constant FUND_ERC20 = 0x0f;

  /**
   * @notice Transfers an NFT held in batch custody to a recipient.
   * @dev Sits at the tail of the ID sequence because new IDs extend it; it belongs to this group.
   * @return The TRANSFER_NFT command ID.
   */
  uint256 public constant TRANSFER_NFT = 0x34;

  /// Swaps
  /**
   * @notice Executes an exact-input CL swap.
   * @return The CL_SWAP_EXACT_IN command ID.
   */
  uint256 public constant CL_SWAP_EXACT_IN = 0x00;

  /**
   * @notice Executes an exact-output CL swap.
   * @return The CL_SWAP_EXACT_OUT command ID.
   */
  uint256 public constant CL_SWAP_EXACT_OUT = 0x01;

  /**
   * @notice Executes an exact-input V2 swap.
   * @return The V2_SWAP_EXACT_IN command ID.
   */
  uint256 public constant V2_SWAP_EXACT_IN = 0x08;

  /**
   * @notice Executes an exact-output V2 swap.
   * @return The V2_SWAP_EXACT_OUT command ID.
   */
  uint256 public constant V2_SWAP_EXACT_OUT = 0x09;

  /// V2 liquidity
  /**
   * @notice Adds liquidity and mints LP tokens.
   * @return The ADD_LIQUIDITY command ID.
   */
  uint256 public constant ADD_LIQUIDITY = 0x22;

  /**
   * @notice Burns LP tokens for the underlying assets.
   * @return The REMOVE_LIQUIDITY command ID.
   */
  uint256 public constant REMOVE_LIQUIDITY = 0x23;

  /// CL positions
  /**
   * @notice Mints a new CL position.
   * @return The MINT_CL_POSITION command ID.
   */
  uint256 public constant MINT_CL_POSITION = 0x24;

  /**
   * @notice Adds liquidity to a position.
   * @return The INCREASE_CL_LIQUIDITY command ID.
   */
  uint256 public constant INCREASE_CL_LIQUIDITY = 0x25;

  /**
   * @notice Removes liquidity from a position.
   * @return The DECREASE_CL_LIQUIDITY command ID.
   */
  uint256 public constant DECREASE_CL_LIQUIDITY = 0x26;

  /**
   * @notice Collects tokens owed by a position.
   * @return The COLLECT_CL_FEES command ID.
   */
  uint256 public constant COLLECT_CL_FEES = 0x27;

  /**
   * @notice Burns a CL position NFT after all liquidity and owed tokens have been removed.
   * @return The BURN_CL_POSITION command ID.
   */
  uint256 public constant BURN_CL_POSITION = 0x28;

  /// Staking
  /**
   * @notice Stakes an LP balance or CL position in a gauge.
   * @return The STAKE_GAUGE command ID.
   */
  uint256 public constant STAKE_GAUGE = 0x29;

  /**
   * @notice Withdraws the caller's gauge stake.
   * @return The UNSTAKE_GAUGE command ID.
   */
  uint256 public constant UNSTAKE_GAUGE = 0x2a;

  /// Claims
  /**
   * @notice Claims the caller's gauge rewards.
   * @return The CLAIM_GAUGE_REWARDS command ID.
   */
  uint256 public constant CLAIM_GAUGE_REWARDS = 0x2d;

  /**
   * @notice Claims the caller's account-level V2 LP fees.
   * @return The CLAIM_V2_POOL_FEES command ID.
   */
  uint256 public constant CLAIM_V2_POOL_FEES = 0x2f;

  /// Stake and relay
  /**
   * @notice Stakes TOKEN and creates an sAERO.
   * @return The CREATE_STAKE command ID.
   */
  uint256 public constant CREATE_STAKE = 0x30;

  /**
   * @notice Deposits an existing sAERO into a relay.
   * @return The DEPOSIT_RELAY command ID.
   */
  uint256 public constant DEPOSIT_RELAY = 0x32;

  /// Cross-chain
  /**
   * @notice Bridges a supported token held by the execution address.
   * @return The BRIDGE_TOKEN command ID.
   */
  uint256 public constant BRIDGE_TOKEN = 0x12;

  /**
   * @notice Dispatches a destination plan through ICA.
   * @return The EXECUTE_CROSS_CHAIN command ID.
   */
  uint256 public constant EXECUTE_CROSS_CHAIN = 0x13;

  /**
   * @notice Burns held `ReceiptToken` on a leaf to mint `TOKEN` to a root recipient.
   * @return The REDEEM command ID.
   */
  uint256 public constant REDEEM = 0x14;

  /// Control flow
  /**
   * @notice Executes a catchable nested command list.
   * @return The EXECUTE_SUB_PLAN command ID.
   */
  uint256 public constant EXECUTE_SUB_PLAN = 0x21;

  /**
   * @notice Reverts when an ERC20 or native balance is below a minimum.
   * @dev Address zero selects native ETH.
   * @return The BALANCE_CHECK command ID.
   */
  uint256 public constant BALANCE_CHECK = 0x0e;

  /// Command-byte encoding
  /**
   * @notice High bit of a command byte; when set, marks the command as allow-revert.
   * @dev The swallowed failure also covers a revert from an invalid or undefined command, not only a handler's
   *      own failure.
   * @return The allow-revert flag mask.
   */
  bytes1 public constant FLAG_ALLOW_REVERT = 0x80;

  /**
   * @notice Low seven bits of a command byte holding the command ID.
   * @return The command-ID bit mask.
   */
  bytes1 public constant COMMAND_TYPE_MASK = 0x7f;
}
