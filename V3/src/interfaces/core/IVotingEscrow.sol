// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC165} from '@openzeppelin/contracts/interfaces/IERC165.sol';
import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC6372} from '@openzeppelin/contracts/interfaces/IERC6372.sol';
import {IERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol';
import {IERC721, IERC721Metadata} from '@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';
import {IVotes} from 'V3/interfaces/core/IVotes.sol';
import {IToken} from 'V3/interfaces/token/IToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

interface IVotingEscrow is
  IVotes,
  IERC4906,
  IERC6372,
  IERC721Metadata,
  IERC721Enumerable,
  IGuardedAccessControlEnumerable
{
  /// @notice Deposit operation kind, used in the Deposit event.
  /// @param CREATE_STAKE_TYPE Initial deposit creating a new stake.
  /// @param INCREASE_STAKE_AMOUNT Adding tokens to an existing stake.
  /// @param INCREASE_STAKING_PERIOD Extending the staking period of an existing stake.
  /// @param REVIVE_STAKE_TYPE Deposit rebuilding an empty shell's stake on an existing tokenId.
  enum DepositType {
    CREATE_STAKE_TYPE,
    INCREASE_STAKE_AMOUNT,
    INCREASE_STAKING_PERIOD,
    REVIVE_STAKE_TYPE
  }

  /// @notice Staked balance held by a sAERO. Packed into a single storage slot.
  /// @param amount Underlying token amount staked.
  /// @param end Unstake timestamp. Zero when the stake is permanent.
  /// @param isPermanent Whether the stake is in permanent mode (no decay).
  struct StakedBalance {
    uint128 amount;
    uint48 end;
    bool isPermanent;
  }

  /// @notice Per-tokenId checkpoint of the staking curve. Packs into two storage slots.
  /// @param bias Voting power at `ts` for the decay curve.
  /// @param slope Per-second decay (-dweight / dt).
  /// @param ts Timestamp at which the checkpoint was recorded.
  /// @param permanent Amount counted as permanent at this checkpoint.
  struct UserPoint {
    int128 bias;
    int128 slope;
    uint48 ts;
    uint128 permanent;
  }

  /// @notice Global checkpoint of the staking curve. Packs into two storage slots.
  /// @param bias Total voting power at `ts` for the decay curves.
  /// @param slope Aggregate per-second decay (-dweight / dt).
  /// @param ts Timestamp at which the checkpoint was recorded.
  /// @param permanentStakeBalance Total amount counted as permanent at this checkpoint.
  struct GlobalPoint {
    int128 bias;
    int128 slope;
    uint48 ts;
    uint128 permanentStakeBalance;
  }

  /// @notice A checkpoint for recorded delegated voting weights at a certain timestamp.
  /// @param fromTimestamp Timestamp at which the checkpoint took effect.
  /// @param owner Owner of the tokenId at the checkpoint timestamp.
  /// @param delegatedBalance Balance delegated to the owner at the checkpoint timestamp.
  /// @param delegatee tokenId the owner is delegating to.
  struct Checkpoint {
    uint256 fromTimestamp;
    address owner;
    uint256 delegatedBalance;
    uint256 delegatee;
  }

  /// @notice Source movement of a VPM-initiated rebalance: staking weight drained from an existing tokenId.
  /// @dev A source is always a real, existing tokenId. The accumulator (tokenId 0) is rejected as a source and the
  ///      mint sentinel (type(uint256).max) is meaningless as one, so no sentinel handling applies. Carries no
  ///      recipient: sources only drain, they never mint.
  /// @param tokenId Existing tokenId the staking weight is drained from.
  /// @param amount Underlying amount drained from tokenId.
  struct SourceDelta {
    uint256 tokenId;
    uint128 amount;
  }

  /// @notice Destination movement of a VPM-initiated rebalance: staking weight routed to a tokenId, mint, or accumulator.
  /// @dev tokenId zero is the protocol accumulator. tokenId equal to type(uint256).max requests a mint to recipient.
  /// @param tokenId Target tokenId or sentinel (0 for accumulator, type(uint256).max for mint).
  /// @param amount Underlying amount moved against tokenId.
  /// @param recipient Owner assigned to a freshly minted sAERO when tokenId is the mint sentinel; ignored otherwise.
  struct DestinationDelta {
    uint256 tokenId;
    uint128 amount;
    address recipient;
  }

  /// @notice Contract dependencies wired at construction.
  /// @param token ERC20 token escrowed by the contract.
  /// @param voter Voter the escrow mirrors chain0 ledger moves onto.
  /// @param artProxy Initial art proxy used by tokenURI.
  struct Contracts {
    address token;
    address voter;
    address artProxy;
  }

  /// @notice Initial holders of the self-administered role-admin roles, seeded at construction.
  /// @param vpmAdmin Address granted VPM_ADMIN_ROLE.
  /// @param artProxyAdmin Address granted ART_PROXY_ADMIN_ROLE.
  /// @param burnFeesAdmin Address granted BURN_FEES_ADMIN_ROLE.
  struct Admins {
    address vpmAdmin;
    address artProxyAdmin;
    address burnFeesAdmin;
  }

  /// @notice Emitted when a deposit is recorded against a tokenId.
  /// @param provider Address that funded the deposit.
  /// @param tokenId tokenId that received the deposit.
  /// @param depositType Kind of deposit performed.
  /// @param value Amount deposited.
  /// @param unstakeTime Updated unstake timestamp.
  /// @param ts Block timestamp at which the event was emitted.
  event Deposit(
    address indexed provider,
    uint256 indexed tokenId,
    DepositType indexed depositType,
    uint128 value,
    uint256 unstakeTime,
    uint256 ts
  );

  /// @notice Emitted when the protocol burns amount of the underlying TOKEN held at the accumulator.
  /// @param amount Amount of TOKEN destroyed.
  event Burn(uint128 amount);

  /// @notice Emitted when an expired stake is withdrawn.
  /// @param provider Address that withdrew the underlying tokens.
  /// @param tokenId tokenId whose staked balance was zeroed.
  /// @param value Amount withdrawn.
  /// @param ts Block timestamp at which the event was emitted.
  event Withdraw(address indexed provider, uint256 indexed tokenId, uint128 value, uint256 ts);

  /// @notice Emitted when a stake is converted to permanent mode.
  /// @param owner Owner of the tokenId.
  /// @param tokenId tokenId switched to permanent mode.
  /// @param amount Amount counted as permanent.
  /// @param ts Block timestamp at which the event was emitted.
  event UpgradeToPermanentStake(address indexed owner, uint256 indexed tokenId, uint128 amount, uint256 ts);

  /// @notice Emitted when a permanent stake is converted back to decay mode.
  /// @param owner Owner of the tokenId.
  /// @param tokenId tokenId switched out of permanent mode.
  /// @param amount Amount removed from the permanent balance.
  /// @param ts Block timestamp at which the event was emitted.
  event DowngradeFromPermanentStake(address indexed owner, uint256 indexed tokenId, uint128 amount, uint256 ts);

  /// @notice Emitted when the total supply tracked by the contract changes.
  /// @param supply Total supply after the change.
  event Supply(uint128 supply);

  /// @notice Emitted when a VPM-initiated rebalance moves staking weight between sTokens.
  /// @param sources Source deltas processed by the rebalance, in input order.
  /// @param destinations Destination deltas processed by the rebalance, in input order.
  event Rebalance(SourceDelta[] sources, DestinationDelta[] destinations);

  /// @notice Emitted when the art proxy contract is updated.
  /// @param newProxy New art proxy address.
  event ArtProxyUpdated(address indexed newProxy);

  /// @notice Thrown when a rebalance routes the protocol accumulator (tokenId 0) as a source.
  ///         The accumulator is destroyed exclusively through `burn`.
  error AccumulatorCannotBeSource();

  /// @notice Thrown when burn is called with an amount exceeding the accumulator's staked balance.
  error AmountExceedsAccumulator();

  /// @notice Thrown when a stake amount credit would exceed `type(int128).max`, the implicit cap required
  ///         for the value to round-trip through the signed slope/bias math during a future downgrade.
  ///         Without this guard a deposit between `type(int128).max + 1` and `type(uint128).max` succeeds
  ///         while permanent but cannot be downgraded to decay, leaving funds stuck.
  error AmountExceedsCap();

  /// @notice Thrown when a rebalance source delta exceeds the stake amount on its tokenId.
  /// @param tokenId tokenId whose source delta exceeds the staked amount.
  error AmountExceedsStake(uint256 tokenId);

  /// @notice Thrown when the sum of source deltas does not equal the sum of destination deltas in a rebalance.
  error BalanceMismatch();

  /// @notice Thrown when a rebalance leg that is not a mint (tokenId != type(uint256).max) carries a nonzero recipient.
  /// @param tokenId tokenId of the offending leg.
  error NonMintRecipientNotAllowed(uint256 tokenId);

  /// @notice Thrown when a historical query is given a timestamp after the current block.
  /// @param timestamp The future timestamp that was queried.
  /// @param clock The current clock value at query time.
  error FutureLookup(uint256 timestamp, uint48 clock);

  /// @notice Thrown when the provided signature nonce does not match the expected nonce.
  error InvalidNonce();

  /// @notice Thrown when an ECDSA signature recovery returns the zero address.
  error InvalidSignature();

  /// @notice Thrown when the s component of an ECDSA signature lies in the upper half order.
  error InvalidSignatureS();

  /// @notice Thrown when the requested staking period resolves to the current block or earlier.
  error StakingPeriodNotInFuture();

  /// @notice Thrown when the requested staking period exceeds MAXTIME.
  error StakingPeriodTooLong();

  /// @notice Thrown when a permanent stake is requested with a non-zero staking period.
  error StakingPeriodNotAllowed();

  /// @notice Thrown when the stake has already expired.
  error StakeExpired();

  /// @notice Thrown when reviving a token that still holds a funded stake.
  error StakeAlreadyFunded();

  /// @notice Thrown when extending a stake that holds no funds; `reviveStake` rebuilds it instead.
  error StakeNotFunded();

  /// @notice Thrown when the stake has not yet expired.
  error StakeNotExpired();

  /// @notice Thrown when the operation requires the stake to be permanent and it is not.
  error NotPermanentStake();

  /// @notice Thrown when `rebalanceUnderlying` is called by an address that does not hold VPM_ROLE.
  error NotVoterPaymentsModule();

  /// @notice Thrown when ownership changed in the current block, blocking the operation.
  error OwnershipChange();

  /// @notice Thrown when the operation cannot be performed on a permanent stake.
  error PermanentStake();

  /// @notice Thrown when the signature expiry has passed.
  error SignatureExpired();

  /// @notice Thrown when a rebalance destination has an earlier unlock than the latest source unlock.
  error UnlockTimeReduction();

  /// @notice Thrown when a required address argument is the zero address.
  error ZeroAddress();

  /// @notice Thrown when a required amount argument is zero.
  error ZeroAmount();

  /*//////////////////////////////////////////////////////////////
                          STATE-CHANGING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Set a new art proxy contract.
  /// @dev Callable only by holders of ART_PROXY_ADMIN_ROLE.
  /// @param _proxy Address of the new art proxy contract.
  function setArtProxy(address _proxy) external;

  /// @notice Record global data to checkpoint.
  function checkpoint() external;

  /// @notice Deposit _value tokens for msg.sender and stake for _stakingWeeks weeks, or permanently if
  ///         _isPermanent is true.
  /// @dev Reverts with StakingPeriodNotAllowed when _isPermanent is true and _stakingWeeks is non-zero,
  ///      so callers cannot silently provide an unused period on a permanent stake.
  /// @param _value Amount to deposit.
  /// @param _stakingWeeks Number of weeks to stake tokens for. Must be zero when _isPermanent is true.
  /// @param _isPermanent If true, create the stake directly in permanent mode with no expiry.
  /// @return _tokenId tokenId of the created sToken.
  function createStake(uint128 _value, uint48 _stakingWeeks, bool _isPermanent) external returns (uint256 _tokenId);

  /// @notice Rebuild an empty shell's stake from scratch, reusing its tokenId: deposit _value and stake for
  ///         _stakingWeeks weeks, or permanently if _isPermanent is true.
  /// @dev Only an empty shell whose stake is over qualifies — withdrawn, or fully drained past its end. Reverts
  ///      `StakeAlreadyFunded` on a funded position (those move through the increase/upgrade paths, keeping their
  ///      committed shape), `PermanentStake`/`StakeNotExpired` while the shell's stake is not over, and
  ///      `StakingPeriodNotAllowed` when _isPermanent is true and _stakingWeeks is non-zero.
  /// @param _tokenId sToken whose stake is being rebuilt.
  /// @param _value Amount to deposit.
  /// @param _stakingWeeks Number of weeks to stake tokens for. Must be zero when _isPermanent is true.
  /// @param _isPermanent If true, rebuild the stake directly in permanent mode with no expiry.
  function reviveStake(uint256 _tokenId, uint128 _value, uint48 _stakingWeeks, bool _isPermanent) external;

  /// @notice Deposit _value additional tokens for _tokenId without modifying the staking period.
  /// @dev Only the owner or an approved operator may call this.
  /// @param _tokenId tokenId to deposit into.
  /// @param _value Amount of tokens to deposit and add to the stake.
  function increaseStakeAmount(uint256 _tokenId, uint128 _value) external;

  /// @notice Extend the staking period for _tokenId. Cannot extend permanent stakes.
  /// @dev Changes the stake's unlock end on VE without touching the Voter's chain0 mirror. A previously-voted
  ///      token must re-vote afterwards to refresh its recorded stake shape (its voting power changed anyway),
  ///      otherwise inbound VPM rebalances into it revert `IVoter.DstShapeStale` until the re-vote.
  /// @dev Reverts `StakeNotFunded` on an empty shell: there is no period to extend, `reviveStake` rebuilds it.
  /// @param _tokenId tokenId to extend.
  /// @param _stakingWeeks New number of weeks until the stake ends.
  function increaseStakingPeriod(uint256 _tokenId, uint48 _stakingWeeks) external;

  /// @notice Withdraw the underlying TOKEN for an expired decay sToken to `_recipient`.
  /// @dev Callable by the tokenId's owner or an approved operator. The whole stake must already sit on the
  ///      Voter's `CHAIN0`: voting power still booked on a remote chain must be returned first (a leaf-first
  ///      `deallocate`, or `emergencyDeallocate` for a suspended chain), else this reverts
  ///      `IVoter.InsufficientChain0Allocation`. This keeps root and every leaf agreeing the token holds nothing
  ///      on their chain before the Voter ledger is cleared. Zeroes `_staked[_tokenId]` but does not destroy the
  ///      NFT: the tokenId persists at zero balance with its owner intact, per the ownership-preserving-zeroing
  ///      invariant.
  /// @param _tokenId tokenId whose staked TOKEN is withdrawn.
  /// @param _recipient Address that receives the released TOKEN.
  function withdraw(uint256 _tokenId, address _recipient) external;

  /// @notice Upgrade a decaying sToken to a permanent stake. Staking weight will be equal to `StakedBalance.amount`
  ///         with no decay. Required to delegate.
  /// @dev Only callable on decaying sTokens that have not yet expired.
  /// @dev Changes the stake shape on VE without touching the Voter's chain0 mirror. A previously-voted token must
  ///      re-vote afterwards to refresh its recorded stake shape (its voting power changed anyway), otherwise
  ///      inbound VPM rebalances into it revert `IVoter.DstShapeStale` until the re-vote.
  /// @param _tokenId tokenId to convert to permanent.
  function upgradeToPermanentStake(uint256 _tokenId) external;

  /// @notice Convert a permanent sToken back to decay mode with end = (now + MAXTIME) week-aligned.
  /// @dev Callable by the tokenId's owner or an approved operator. Requires the token's full balance to sit idle
  ///      on the Voter's chain0 (no cross-chain allocations), else reverts `IVoter.InsufficientChain0Allocation`;
  ///      deallocate with an empty `Voter.vote` first and re-vote afterwards. Subtracts the stake amount from
  ///      permanentStakeBalance, clears delegation, and schedules a new slope change.
  /// @param _tokenId tokenId to downgrade from permanent.
  function downgradeFromPermanentStake(uint256 _tokenId) external;

  /// @notice Move staking weight between sTokens in a single atomic operation.
  /// @dev Callable by any VPM_ROLE holder. The VPM must itself be authorized (operator or token approval) by each
  ///      source's owner, else the call reverts with the ERC721 approval error.
  ///      Sources reduce stake amounts and update the permanent pool
  ///      when permanent. Destinations route the moved amount to the protocol accumulator (tokenId zero), a freshly
  ///      minted sToken (tokenId equal to type(uint256).max), or an existing sToken. Enforces sum(sources) ==
  ///      sum(destinations) and the monotonic unlock rule: a destination unlock must not fall earlier than the latest
  ///      source unlock, with permanent sources forcing every non-sentinel destination to be permanent. Mints use
  ///      ERC721 _mint without the safe-mint receiver hook so VPM can predict the assigned IDs. After committing the
  ///      moves, mirrors them onto the Voter's chain0 ledger via `VOTER.rebalanceChain0`.
  /// @param _sources Source deltas reducing stake balances.
  /// @param _destinations Destination deltas applying the moved amount per destination mode.
  /// @return _mintedIds tokenIds assigned to mint destinations, in input order.
  function rebalanceUnderlying(
    SourceDelta[] calldata _sources,
    DestinationDelta[] calldata _destinations
  ) external returns (uint256[] memory _mintedIds);

  /// @notice Destroy _amount of the underlying TOKEN held at the protocol accumulator (tokenId 0).
  /// @dev Callable only by a BURN_FEES_ROLE holder. Decrements the accumulator amount, supply,
  ///      and permanentStakeBalance symmetrically, calls the TOKEN's burn, then burns the matching voting
  ///      power on the Voter's chain0 (the accumulator's VP is always parked there) via `VOTER.burn`.
  /// @param _amount Amount of TOKEN to destroy.
  function burnFees(uint128 _amount) external;

  /// @inheritdoc IVotes
  function delegate(uint256 _delegator, uint256 _delegatee) external;

  /// @inheritdoc IVotes
  function delegateBySig(
    uint256 _delegator,
    uint256 _delegatee,
    uint256 _nonce,
    uint256 _expiry,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external;

  /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Role marker held by every VoterPaymentsModule that VotingEscrow recognises.
  /// @return _role Role identifier.
  function VPM_ROLE() external view returns (bytes32 _role);

  /// @notice Admin role for VPM_ROLE. Holders can grant or revoke VPM_ROLE.
  /// @return _role Role identifier.
  function VPM_ADMIN_ROLE() external view returns (bytes32 _role);

  /// @notice Role required to call `burnFees`.
  /// @return _role Role identifier.
  function BURN_FEES_ROLE() external view returns (bytes32 _role);

  /// @notice Admin role for BURN_FEES_ROLE. Holders can grant or revoke BURN_FEES_ROLE.
  /// @return _role Role identifier.
  function BURN_FEES_ADMIN_ROLE() external view returns (bytes32 _role);

  /// @notice Role allowed to set the art proxy contract.
  /// @return _role Role identifier.
  function ART_PROXY_ADMIN_ROLE() external view returns (bytes32 _role);

  /// @notice EIP-712 typehash for the delegation struct used in delegateBySig.
  /// @return _typehash Delegation typehash.
  function DELEGATION_TYPEHASH() external view returns (bytes32 _typehash);

  /// @notice Underlying token escrowed to create sAEROs.
  /// @return _token The escrowed token.
  function TOKEN() external view returns (IToken _token);

  /// @notice Immutable Voter that VotingEscrow mirrors rebalance moves onto via `rebalanceChain0`.
  /// @return _voter The bound Voter.
  function VOTER() external view returns (IVoter _voter);

  /// @notice Address of the art proxy used for on-chain metadata.
  /// @return _proxy Art proxy address.
  function artProxy() external view returns (address _proxy);

  /// @notice Latest tokenId minted; doubles as the monotonic ID counter.
  /// @return _tokenId Latest tokenId.
  function tokenId() external view returns (uint256 _tokenId);

  /// @notice Version tag of the contract.
  /// @return _version Version string.
  function VERSION() external view returns (string memory _version);

  /// @notice Whether the given address is authorized as a VoterPaymentsModule.
  /// @param _account Candidate address to check.
  /// @return _authorized True when _account holds VPM_ROLE.
  function isAuthorizedVPM(address _account) external view returns (bool _authorized);

  /// @notice Whether a VoterPaymentsModule may operate on a specific tokenId at the VotingEscrow layer.
  /// @dev True when `_vpm` holds VPM_ROLE and is ERC-721 authorized for the token; nonexistent token returns false.
  /// @param _vpm Candidate VoterPaymentsModule address.
  /// @param _tokenId tokenId being targeted.
  /// @return _authorized True when the VPM is authorized for this tokenId.
  function isAuthorizedVPMForToken(address _vpm, uint256 _tokenId) external view returns (bool _authorized);

  /// @notice Total count of global checkpoints recorded since contract creation.
  /// @return _epoch Latest global epoch.
  function epoch() external view returns (uint256 _epoch);

  /// @notice Total amount of underlying token currently held in escrow.
  /// @return _supply Total supply.
  function supply() external view returns (uint128 _supply);

  /// @notice Aggregate balance held in permanent stakes.
  /// @return _permanent Aggregate permanent staked balance.
  function permanentStakeBalance() external view returns (uint128 _permanent);

  /// @notice Latest checkpoint epoch recorded for a given tokenId.
  /// @param _tokenId tokenId to query.
  /// @return _epoch Latest user checkpoint epoch.
  function userPointEpoch(uint256 _tokenId) external view returns (uint256 _epoch);

  /// @notice Scheduled signed slope change at a given timestamp.
  /// @param _timestamp Timestamp to query.
  /// @return _slopeChange Signed slope delta scheduled at the timestamp.
  function slopeChanges(uint48 _timestamp) external view returns (int128 _slopeChange);

  /// @notice Global checkpoint history at a given epoch index.
  /// @param _loc Global epoch index.
  /// @return _point Global checkpoint snapshot.
  function pointHistory(uint256 _loc) external view returns (GlobalPoint memory _point);

  /// @notice Get the StakedBalance (amount, end, isPermanent) for a tokenId.
  /// @param _tokenId tokenId to query.
  /// @return _staked StakedBalance for the tokenId.
  function staked(uint256 _tokenId) external view returns (StakedBalance memory _staked);

  /// @notice User checkpoint history for a given tokenId and index.
  /// @param _tokenId tokenId to query.
  /// @param _loc User epoch index.
  /// @return _point User checkpoint snapshot.
  function userPointHistory(uint256 _tokenId, uint256 _loc) external view returns (UserPoint memory _point);

  /// @notice Get the voting power for _tokenId at the current timestamp.
  /// @param _tokenId tokenId to query.
  /// @return _balance Voting power at the current timestamp.
  function balanceOfNFT(uint256 _tokenId) external view returns (uint256 _balance);

  /// @notice Get the voting power for _tokenId at a given timestamp.
  /// @param _tokenId tokenId to query.
  /// @param _t Timestamp to query voting power at.
  /// @return _balance Voting power at the given timestamp.
  function balanceOfNFTAt(uint256 _tokenId, uint256 _t) external view returns (uint256 _balance);

  /// @notice Check whether spender is owner or an approved user for a given sAERO.
  /// @param _spender Caller to check.
  /// @param _tokenId tokenId to check authorization for.
  /// @return _approved True if the spender is authorized.
  function isAuthorized(address _spender, uint256 _tokenId) external view returns (bool _approved);

  /// @notice Total number of sTOKENs in existence.
  /// @return _supply Number of sTOKENs minted.
  function totalSupply() external view override(IERC721Enumerable) returns (uint256 _supply);

  /// @notice Calculate total voting power at current timestamp.
  /// @return _votingPower Total voting power at the current timestamp.
  function totalVotingPower() external view returns (uint256 _votingPower);

  /// @notice Calculate total voting power at a given timestamp.
  /// @param _t Timestamp to query total voting power at.
  /// @return _votingPower Total voting power at the given timestamp.
  function totalVotingPowerAt(uint256 _t) external view returns (uint256 _votingPower);

  /// @notice Block in which a tokenId's ownership last changed; used for the same-block delegation guard.
  /// @dev Returns 0 for tokens that have never been transferred or have not changed ownership.
  /// @param _tokenId tokenId to query.
  /// @return _block Block number of the last ownership change.
  function ownershipChange(uint256 _tokenId) external view returns (uint256 _block);

  /// @notice The number of delegation checkpoints recorded for each tokenId.
  /// @param _tokenId tokenId to query.
  /// @return _count Number of recorded checkpoints.
  function numCheckpoints(uint256 _tokenId) external view returns (uint48 _count);

  /// @notice Signature nonce for the given account.
  /// @param _account Account to query.
  /// @return _nonce Current nonce.
  function nonces(address _account) external view returns (uint256 _nonce);

  /// @inheritdoc IVotes
  function delegates(uint256 _delegator) external view returns (uint256);

  /// @notice A record of delegated token checkpoints for each account, by index.
  /// @param _tokenId tokenId to query.
  /// @param _index Checkpoint index to query.
  /// @return _checkpoint Recorded checkpoint.
  function checkpoints(uint256 _tokenId, uint48 _index) external view returns (Checkpoint memory _checkpoint);

  /// @inheritdoc IVotes
  function getPastVotes(address _account, uint256 _tokenId, uint256 _timestamp) external view returns (uint256);

  /// @inheritdoc IVotes
  function getPastTotalSupply(uint256 _timestamp) external view returns (uint256);

  /// @inheritdoc IERC6372
  function clock() external view returns (uint48);

  /// @inheritdoc IERC6372
  function CLOCK_MODE() external view returns (string memory);
}
