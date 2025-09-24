// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2EmergencyCouncil} from 'V3/interfaces/migration/v2/IV2EmergencyCouncil.sol';
import {IV2RootVotingRewardsFactory} from 'V3/interfaces/migration/v2/IV2RootVotingRewardsFactory.sol';

/**
 * @title Velodrome Migration Interface
 * @notice Interface for migrating Velodrome v2 positions to v3
 */
interface IVelodromeMigration is IMigration {
  /**
   * @notice Emitted when a migration settlement message is dispatched to root
   * @param _nonce Nonce of the dispatched message
   * @param _recipient Address that receives the v3 position
   */
  event MessageDispatched(uint64 indexed _nonce, address indexed _recipient);

  /**
   * @notice Thrown when converting the basis output results in zero TOKEN
   */
  error ZeroConversion();

  /**
   * @notice Thrown when the root domain is zero or matches the mailbox local domain
   */
  error InvalidDomain();

  /**
   * @notice Kills v2 Velodrome root gauges through the emergency council
   * @param _gauges v2 root gauges to kill
   */
  function killRootGauges(address[] calldata _gauges) external;

  /**
   * @notice Kills v2 Velodrome leaf gauges through the emergency council
   * @param _gauges v2 root gauges linked to the leaf gauges to kill
   */
  function killLeafGauges(address[] calldata _gauges) external;

  /**
   * @notice Revives v2 Velodrome root gauges through the emergency council
   * @param _gauges v2 root gauges to revive
   */
  function reviveRootGauges(address[] calldata _gauges) external;

  /**
   * @notice Revives v2 Velodrome leaf gauges through the emergency council
   * @param _gauges v2 root gauges linked to the leaf gauges to revive
   */
  function reviveLeafGauges(address[] calldata _gauges) external;

  /**
   * @notice Sets the recipient of v2 rewards forwarded to a leaf chain
   * @param _chainId Identifier of the leaf chain
   * @param _recipient Address that receives rewards on the leaf chain
   */
  function setRecipient(uint256 _chainId, address _recipient) external;

  /**
   * @notice Quotes the native token fee required to migrate a v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   * @param _recipient Address that receives the v3 position
   * @return Native token fee required for dispatch
   */
  function quoteDepositVeNFT(uint256 _tokenId, address _recipient) external view returns (uint256);

  /**
   * @notice Quotes the native token fee required to migrate liquid v2 tokens
   * @param _amount Amount of liquid v2 tokens to migrate
   * @param _recipient Address that receives the v3 tokens
   * @return Native token fee required for dispatch
   */
  function quoteDepositLiquid(uint256 _amount, address _recipient) external view returns (uint256);

  /**
   * @notice Returns the gas limit for root settlement message execution
   * @return _dispatchGasLimit The root settlement message gas limit
   */
  function DISPATCH_GAS_LIMIT() external view returns (uint256 _dispatchGasLimit);

  /**
   * @notice Returns the address of the Hyperlane mailbox
   * @return The Hyperlane mailbox address
   */
  function MAILBOX() external view returns (IMailbox);

  /**
   * @notice Returns the Hyperlane domain identifier of the root chain
   * @return The root chain domain identifier
   */
  function ROOT_DOMAIN() external view returns (uint32);

  /**
   * @notice Returns the nonce of the latest dispatched migration message
   * @return The latest dispatch nonce
   */
  function dispatchNonce() external view returns (uint64);

  /**
   * @notice Returns the v2 emergency council used for Velodrome gauge management
   * @return _emergencyCouncil The v2 emergency council
   */
  function V2_EMERGENCY_COUNCIL() external view returns (IV2EmergencyCouncil _emergencyCouncil);

  /**
   * @notice Returns the v2 root voting rewards factory used to configure cross-chain reward recipients
   * @return _rootVotingRewardsFactory The v2 root voting rewards factory
   */
  function V2_ROOT_VOTING_REWARDS_FACTORY()
    external
    view
    returns (IV2RootVotingRewardsFactory _rootVotingRewardsFactory);
}
