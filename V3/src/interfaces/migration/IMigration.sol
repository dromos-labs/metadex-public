// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IV2EpochGovernor} from 'V3/interfaces/migration/v2/IV2EpochGovernor.sol';
import {IV2Minter} from 'V3/interfaces/migration/v2/IV2Minter.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

/**
 * @title V2-to-V3 Migration Interface
 * @notice Interface for migrating v2 positions into v3.
 */
interface IMigration is IV2EpochGovernor {
  /**
   * @notice Parameters for initializing the shared migration engine
   * @param owner Owner of the migration contract
   * @param deployer Address funding the migration veNFT seed amount
   * @param v2Token Address of the v2 token
   * @param escrow Address of the v2 voting escrow
   * @param voter Address of the v2 voter
   * @param migrationOpen Timestamp when migration opens
   * @param restricted V2 veNFT identifiers restricted from migration
   */
  struct BaseParams {
    address owner;
    address deployer;
    address v2Token;
    address escrow;
    address voter;
    uint48 migrationOpen;
    uint256[] restricted;
  }

  /**
   * @notice Emitted when a v2 veNFT is migrated to v3
   * @param _depositor Address that deposited the v2 veNFT
   * @param _recipient Address that receives the v3 position
   * @param _v2TokenId Identifier of the migrated v2 veNFT
   * @param _amount Amount locked in the v2 veNFT
   * @param _out Converted v3 token amount
   * @param _permanent Whether the v2 veNFT was permanent
   * @param _liquid Whether the migration settled as liquid tokens
   */
  event VeNFTMigrated(
    address indexed _depositor,
    address indexed _recipient,
    uint256 indexed _v2TokenId,
    uint256 _amount,
    uint256 _out,
    bool _permanent,
    bool _liquid
  );

  /**
   * @notice Emitted when liquid v2 tokens are migrated to v3
   * @param _depositor Address that deposited the v2 tokens
   * @param _recipient Address that receives the v3 tokens
   * @param _amountIn Amount of v2 tokens deposited
   * @param _out Converted v3 token amount
   */
  event LiquidMigrated(address indexed _depositor, address indexed _recipient, uint256 _amountIn, uint256 _out);

  /**
   * @notice Emitted when a v2 veNFT is permanently restricted from migration.
   * @param _tokenId Restricted v2 veNFT identifier.
   */
  event RestrictionsSet(uint256 indexed _tokenId);

  /**
   * @notice Emitted when the V2 tail emission rate is nudged
   */
  event NudgeExecuted();

  /**
   * @notice Emitted when the V2 epoch governor result is set
   * @param _result The V2 epoch governor result
   */
  event ResultSet(ProposalState _result);

  /**
   * @notice Thrown when the migration has not opened
   */
  error MigrationNotOpen();

  /**
   * @notice Thrown when a v2 veNFT is restricted from migration
   * @param _tokenId Identifier of the restricted v2 veNFT
   */
  error Restricted(uint256 _tokenId);

  /**
   * @notice Thrown when a v2 veNFT is not a normal escrow
   * @param _tokenId Identifier of the invalid v2 veNFT
   */
  error NotNormalVeNFT(uint256 _tokenId);

  /**
   * @notice Thrown when a v2 veNFT has no locked balance
   * @param _tokenId Identifier of the empty v2 veNFT
   */
  error NothingToConvert(uint256 _tokenId);

  /**
   * @notice Thrown when a v2 veNFT has an active vote
   * @param _tokenId Identifier of the v2 veNFT
   */
  error AlreadyVoted(uint256 _tokenId);

  /**
   * @notice Thrown when the caller does not own the v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   */
  error NotOwner(uint256 _tokenId);

  /**
   * @notice Thrown when an address is the zero address
   */
  error ZeroAddress();

  /**
   * @notice Thrown when the deposited amount is zero
   */
  error ZeroAmount();

  /**
   * @notice Thrown when the migration opening timestamp is invalid
   */
  error InvalidOpen();

  /**
   * @notice Thrown when the V2 tail emission rate does not decrease
   */
  error TailEmissionRateNotDecreased();

  /**
   * @notice Migrates a v2 veNFT into a v3 staked position.
   * @dev Expired v2 veNFTs settle as liquid TOKEN instead.
   *      On Velodrome, callers must ensure `_recipient` on root can manage the resulting sTOKEN for staked migrations.
   *      On Velodrome, if message delivery crosses an epoch end, a non-permanent stake can be extended by one week.
   *      Therefore, non-permanent migrations should not be dispatched close to an epoch end.
   * @param _tokenId Identifier of the v2 veNFT to migrate.
   * @param _recipient Address that receives the v3 position.
   */
  function depositVeNFT(uint256 _tokenId, address _recipient) external payable;

  /**
   * @notice Migrates liquid v2 tokens to v3
   * @param _amount Amount of v2 tokens to migrate
   * @param _recipient Address that receives the v3 tokens
   */
  function depositLiquid(uint256 _amount, address _recipient) external payable;

  /**
   * @notice Permanently restricts v2 veNFTs from migration.
   * @param _tokenIds v2 veNFT identifiers to restrict.
   */
  function setRestricted(uint256[] calldata _tokenIds) external;

  /**
   * @notice Sets the V2 epoch governor result returned to the V2 Minter
   * @param _result The V2 epoch governor result
   */
  function setResult(ProposalState _result) external;

  /**
   * @notice Allocates the migration veNFT's voting weight across v2 pools.
   * @param _pools v2 pools receiving voting weight.
   * @param _weights Relative weights assigned to the pools.
   */
  function vote(address[] calldata _pools, uint256[] calldata _weights) external;

  /**
   * @notice Resets the migration veNFT's active v2 vote.
   */
  function resetVote() external;

  /**
   * @notice Claims v2 fee rewards for the migration veNFT.
   * @param _feeContracts Fee reward contracts to claim from.
   * @param _tokens Reward tokens requested from each fee contract.
   * @param _recipient Address receiving the claimed rewards.
   */
  function claimFees(address[] calldata _feeContracts, address[][] calldata _tokens, address _recipient) external;

  /**
   * @notice Claims v2 incentive rewards for the migration veNFT.
   * @param _incentiveContracts Incentive reward contracts to claim from.
   * @param _tokens Reward tokens requested from each incentive contract.
   * @param _recipient Address receiving the claimed rewards.
   */
  function claimIncentives(
    address[] calldata _incentiveContracts,
    address[][] calldata _tokens,
    address _recipient
  ) external;

  /**
   * @notice Pauses migration deposit entrypoints.
   */
  function pause() external;

  /**
   * @notice Reopens migration deposit entrypoints.
   */
  function unpause() external;

  /**
   * @notice Decreases the v2 tail emission rate by up to one basis point
   */
  function decreaseTailEmissionRate() external;

  /**
   * @notice Returns the address of the V2 token contract
   * @return The V2 token address
   */
  function V2_TOKEN() external view returns (IERC20);

  /**
   * @notice Returns the address of the V2 Voter contract
   * @return The V2 Voter address
   */
  function V2_VOTER() external view returns (IV2Voter);

  /**
   * @notice Returns the address of the V2 Minter contract
   * @return The V2 Minter address
   */
  function V2_MINTER() external view returns (IV2Minter);

  /**
   * @notice Returns the address of the V2 VotingEscrow contract
   * @return The V2 VotingEscrow address
   */
  function V2_ESCROW() external view returns (IV2VotingEscrow);

  /**
   * @notice Returns the v3 activation timestamp
   * @return The v3 activation timestamp
   */
  function ACTIVATION() external view returns (uint48);

  /**
   * @notice Returns the timestamp when migration opens
   * @return The migration opening timestamp
   */
  function MIGRATION_OPEN() external view returns (uint48);

  /**
   * @notice Returns the identifier of the migration veNFT
   * @return The migration veNFT identifier
   */
  function MIGRATION_TOKEN_ID() external view returns (uint256);

  /**
   * @notice Returns the v2 token amount migrated
   * @dev On Aerodrome, this also represents the v3 TOKEN amount settled
   * @return The migrated amount
   */
  function paidBasis() external view returns (uint256);

  /**
   * @notice Returns the depositor of a migrated v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   * @return Address that deposited the v2 veNFT
   */
  function depositorOf(uint256 _tokenId) external view returns (address);

  /**
   * @notice Returns whether a v2 veNFT is restricted from migration
   * @param _tokenId Identifier of the v2 veNFT
   * @return Whether the v2 veNFT is restricted
   */
  function restricted(uint256 _tokenId) external view returns (bool);

  /**
   * @notice Previews the current conversion result for a v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   * @return Amount to be migrated from the v2 veNFT
   * @return Converted v3 token amount
   * @return Whether the v2 lock is permanent
   * @return Whether the conversion settles as liquid tokens
   */
  function previewConversion(uint256 _tokenId) external view returns (uint256, uint256, bool, bool);
}
