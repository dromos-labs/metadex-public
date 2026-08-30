// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {MAXTIME, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {RelayRewardsLib} from 'V3/relay/libraries/RelayRewardsLib.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/**
 * @title  RelayInitLib
 * @notice Applies a fresh clone's initialization inputs: validates the parameters, writes the
 *         config, checks the seed invariants and creates the PT/YT satellite clones. The Relay
 *         keeps the initializer guard, the role setup and the bootstrap mint.
 * @dev    EXTERNAL (linked) library, delegatecalled (EIP-170), so the satellite clones are created
 *         by the Relay itself and each satellite's `initialize` sees `msg.sender == relay`.
 */
library RelayInitLib {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeTransferLib for address;

  /// @notice The protocol-wide dependencies `setUp` needs, bundled to stay under the legacy
  ///         pipeline's stack limit.
  /// @param votingEscrow VotingEscrow the seed invariants are checked against.
  /// @param vpm VoterPaymentsModule approved to spend the Relay's sAERO, so exits can drain it.
  /// @param token The protocol TOKEN the permanent compound allowance is granted for.
  /// @param principalTokenImplementation Checkpointed RelayToken implementation cloned as the PT.
  /// @param yieldTokenImplementation Plain RelayToken implementation cloned as the YT.
  struct SetUpContext {
    IVotingEscrow votingEscrow;
    address vpm;
    address token;
    address principalTokenImplementation;
    address yieldTokenImplementation;
  }

  /// @notice Validates the initialization inputs, writes the config, checks the seed invariants,
  ///         sets the compound allowance and the VPM approval, and clones the PT/YT satellites.
  /// @param _params The initialization inputs (see `IRelay.initialize`).
  /// @param _relayConfig The Relay's config storage the validated `_params.config` is written to.
  /// @param _rewardTokenSet Reward-token registry, seeded with `_params.rewardToken` when non-zero.
  /// @param _ctx The Relay's protocol-wide dependencies.
  /// @return _seed The seed stake backing the bootstrap shares (the sAERO's staked amount).
  /// @return _principalToken The freshly cloned principal token (PT); soulbound.
  /// @return _yieldToken The freshly cloned yield token (YT); transferable only when
  ///         `_params.ytTransferable` is set.
  /// @dev The seed invariants (the Relay owns the sAERO and it carries a non-zero stake) block the
  ///      first-depositor inflation attack. Reads `staked().amount` rather than `balanceOfNFT`,
  ///      which returns 0 in the block that binds the sAERO. The PT clones a checkpointed
  ///      implementation and the YT a plain one, so governance weight is always the principal
  ///      balance.
  function setUp(
    IRelay.InitParams memory _params,
    IRelay.RelayConfig storage _relayConfig,
    EnumerableSet.AddressSet storage _rewardTokenSet,
    SetUpContext memory _ctx
  ) external returns (uint256 _seed, address _principalToken, address _yieldToken) {
    if (
      _params.admin == address(0) || _params.keeper == address(0) || _params.bootstrapOwner == address(0)
        || address(_params.vpm) == address(0) || address(_params.governor) == address(0)
        || address(_params.voteAdapter) == address(0)
    ) {
      revert IRelay.ZeroAddress();
    }
    // Creation holds the module to the same bar as rotation: the escrow refuses weight moves from
    // an unauthorized module, so an unvetted one would revert every deposit and every drain.
    if (!_ctx.votingEscrow.isAuthorizedVPM(_ctx.vpm)) revert IRelay.ModuleNotAuthorized();
    IRelay.RelayConfig memory _config = _params.config;
    // A zero floor lets a zero-share exit into a FIFO whose entries cannot be cancelled: the drain
    // reverts on it forever (the module refuses to move nothing) and `close` reads it as covered,
    // so one transaction from anyone would end every exit. The deposit floor follows the same rule.
    if (_config.minDeposit == 0 || _config.minWithdrawal == 0) revert IRelay.ZeroQueueFloor();
    // With a zero window anyone could close a working Relay as soon as an exit queues.
    if (_config.evacuationWindow == 0) revert IRelay.InvalidEvacuationWindow();
    // A zero keeper window would make the overdue drain permissionless from the first block.
    if (_config.keeperWindow == 0) revert IRelay.InvalidKeeperWindow();
    // A zero entrypoint timelock lets an L2 admin propose and attach an entrypoint in one block,
    // leaving depositors no window to exit first.
    if (_config.entrypointTimelock == 0) revert IRelay.InvalidEntrypointTimelock();

    // A memory struct cannot be assigned to a storage-pointer parameter, so copy field by field.
    // A field added to RelayConfig must be added here too, or every clone zeroes it silently.
    _relayConfig.tokenId = _config.tokenId;
    _relayConfig.minDeposit = _config.minDeposit;
    _relayConfig.keeperWindow = _config.keeperWindow;
    _relayConfig.minWithdrawal = _config.minWithdrawal;
    _relayConfig.entrypointTimelock = _config.entrypointTimelock;
    _relayConfig.lockWeeks = _config.lockWeeks;
    _relayConfig.evacuationWindow = _config.evacuationWindow;
    _relayConfig.name = _config.name;
    _relayConfig.symbol = _config.symbol;

    IVotingEscrow.StakedBalance memory _seedBalance = _ctx.votingEscrow.staked(_config.tokenId);
    if (_ctx.votingEscrow.ownerOf(_config.tokenId) != address(this)) revert IRelay.NotTokenOwner();
    if (_seedBalance.amount == 0) revert IRelay.ZeroInitialDeposit();
    // lockWeeks must mirror the seed's permanence: a permanent seed with non-zero lockWeeks would
    // revert every lock extension, and a time-locked seed with zero lockWeeks would silently decay.
    if (_seedBalance.isPermanent != (_config.lockWeeks == 0)) revert IRelay.LockWeeksMismatch();
    // The escrow week-floors the start before comparing against MAXTIME, so a horizon that
    // overshoots by less than the floor's remainder passes at creation and then makes `_extendLock`
    // fail part of every later week. Bound it here, where a bad config is still uncreatable.
    if (uint256(_config.lockWeeks) * WEEK > MAXTIME) revert IRelay.LockWeeksTooLong();

    // Permanent max allowance, so `compound` needs no approval per call.
    _ctx.token.safeApprove(address(_ctx.votingEscrow), type(uint256).max);

    // A withdraw drain puts the Relay's sAERO in the source position, and the escrow authorizes
    // sources by approval: without this no exit could ever settle. The Relay never transfers its
    // sAERO, so the approval never clears.
    _ctx.votingEscrow.approve(_ctx.vpm, _config.tokenId);

    _seed = uint256(_seedBalance.amount);

    _principalToken = Clones.clone(_ctx.principalTokenImplementation);
    IRelayToken(_principalToken)
      .initialize(string.concat(_config.name, ' PT'), string.concat(_config.symbol, '-PT'), false);
    _yieldToken = Clones.clone(_ctx.yieldTokenImplementation);
    IRelayToken(_yieldToken)
      .initialize(string.concat(_config.name, ' YT'), string.concat(_config.symbol, '-YT'), _params.ytTransferable);

    // An implementation that holds code but wires nothing leaves both clones inert: their calls
    // return success, so the bootstrap mint below would appear to run against no supply at all. Read
    // the two fields `initialize` writes back, which no inert clone can answer.
    if (IRelayToken(_principalToken).relay() != address(this) || IRelayToken(_principalToken).transferable()) {
      revert IRelay.SatelliteNotInitialized();
    }
    if (
      IRelayToken(_yieldToken).relay() != address(this)
        || IRelayToken(_yieldToken).transferable() != _params.ytTransferable
    ) revert IRelay.SatelliteNotInitialized();

    // The single-slot tiers close the registry on their first token, so the creator may pin it here,
    // in the call that also names the entrypoints it has to match. It lands after the clones so it
    // faces the same admission rule the KEEPER's later adds do.
    if (_params.rewardToken != address(0)) {
      RelayRewardsLib.requireUsableRewardToken(_params.rewardToken, _principalToken, _yieldToken);
      // The set is empty here, so the add always lands.
      // slither-disable-next-line unused-return
      _rewardTokenSet.add(_params.rewardToken);
      emit IRelay.RewardTokenAdded(_params.rewardToken);
    }
  }
}
