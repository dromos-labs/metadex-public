// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';
import {RelayRakeLib} from 'V3/relay/libraries/RelayRakeLib.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {IRelayState} from 'V3/interfaces/relay/IRelayState.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/**
 * @title  RelayRewardsLib
 * @notice Everything that moves reward value or the accounting behind it: the notification, the
 *         claim payout and the per-holder settle, the entrypoint feed (`pull`), the appreciation lane
 *         (`compound`), the reward-token registry, the L2 sweep and the cross-chain claim dispatch.
 *         `notifyReward` and `compound` take the rake before the yield reaches the holders.
 *         The Relay keeps the access checks.
 * @dev    EXTERNAL (linked) library, delegatecalled (EIP-170).
 * @dev    One placement here is worth stating, so it is not "corrected" later. `sweep` sits with
 *         `pull` and `compound` because all three are bounded by the same rule, the balance above
 *         `accountedBalance`, which is this library's invariant rather than an admin concern.
 */
library RelayRewardsLib {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeTransferLib for address;
  using SafeCastLibrary for uint256;

  /// @notice Scalar inputs of a transfer-hook settle, bundled to stay under the legacy pipeline's
  ///         stack limit.
  /// @param yieldToken The Relay's yield token (YT), whose balances the accumulator reads.
  /// @param from Transfer sender (zero on a mint).
  /// @param to Transfer recipient (zero on a burn).
  /// @param amount Units the transfer moves.
  /// @param accScale Fixed-point scale of the per-share reward accumulator.
  /// @param closed Whether the Relay is closed. A closed Relay settles exits on the principal
  ///        alone, so the escrow no longer locks the yield side.
  struct SettleContext {
    IRelayToken yieldToken;
    address from;
    address to;
    uint256 amount;
    uint256 accScale;
    bool closed;
  }

  /// @notice Take the rake from `_amount` of `_token`, then distribute the rest to all current
  ///         holders by advancing its per-share index, bounded to the un-accounted balance that
  ///         actually arrived.
  /// @param _rewardTokenSet Reward-token registry (the Relay's storage); gates the notify.
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _rewardIndex Per-token reward-per-share accumulator (the Relay's storage).
  /// @param _rakes The rake state (the Relay's storage).
  /// @param _feeAccrued Per-token rake accruals (the Relay's storage).
  /// @param _yieldToken The Relay's yield token (YT); its supply is the per-share denominator.
  /// @param _token Reward token being distributed.
  /// @param _amount Gross batch; the rake comes out of it before the rest spreads across the supply.
  /// @param _accScale Fixed-point scaling factor of the accumulator.
  /// @param _factory The Relay's factory, which takes the report and relays it to the tape.
  /// @dev `_amount` cannot exceed the un-accounted balance that actually arrived. An index delta
  ///      that floors to zero reverts: the amount would stay owed but never distributed, so the
  ///      keeper batches above that minimum.
  function notifyReward(
    EnumerableSet.AddressSet storage _rewardTokenSet,
    mapping(address token => uint256 accounted) storage _accountedBalance,
    mapping(address token => uint256 index) storage _rewardIndex,
    IRelay.RakeState storage _rakes,
    mapping(address token => IRelay.FeeAccrual accrual) storage _feeAccrued,
    IRelayToken _yieldToken,
    address _token,
    uint256 _amount,
    uint256 _accScale,
    address _factory
  ) external {
    if (!_rewardTokenSet.contains(_token)) revert IRelay.UnknownRewardToken();

    // slither-disable-next-line uninitialized-local
    uint256 _distributed;
    // slither-disable-next-line uninitialized-local
    uint256 _newIndex;
    {
      uint256 _supply = _yieldToken.totalSupply();
      if (_supply == 0) revert IRelay.NoSupply();

      if (_amount > IERC20(_token).balanceOf(address(this)) - _accountedBalance[_token]) {
        revert IRelay.RewardExceedsBalance();
      }

      (uint256 _net, uint256 _fees) = RelayRakeLib.skim(_rakes, _feeAccrued, _token, _amount);

      uint256 _indexDelta = (_net * _accScale) / _supply;
      if (_indexDelta == 0) revert IRelay.RewardTooSmall();

      // Round up so the accounted balance covers every claim the advanced index can pay out, also
      // when a holder settles several advances in one merged delta. The rest of the batch stays
      // un-accounted for the next notifyReward to distribute.
      _distributed = Math.ceilDiv(_indexDelta * _supply, _accScale);
      _accountedBalance[_token] += _fees + _distributed;
      _newIndex = _rewardIndex[_token] + _indexDelta;
      _rewardIndex[_token] = _newIndex;
    }
    emit IRelay.RewardNotified(_token, _distributed, _newIndex);

    _reportReward(_factory, _token, _distributed, _newIndex);
  }

  /// @notice Hand `_amount` of `_token` to the calling entrypoint, bounded to the un-accounted
  ///         balance so it can never pull reward tokens already owed to claimants.
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _token Reward token to pull out to the entrypoint.
  /// @param _amount Amount to transfer to the caller.
  /// @dev Delegatecalled, so `msg.sender` is the entrypoint; the Relay runs the role gate.
  function pull(
    mapping(address token => uint256 accounted) storage _accountedBalance,
    address _token,
    uint256 _amount
  ) external {
    if (_amount > IERC20(_token).balanceOf(address(this)) - _accountedBalance[_token]) {
      revert IRelay.RewardExceedsBalance();
    }
    _token.safeTransfer(msg.sender, _amount);
    emit IRelay.Pulled(msg.sender, _token, _amount);
  }

  /// @notice Moves the requested ERC-20 amounts out of the Relay's custody. Each entry is bounded
  ///         to its token's un-accounted balance, so a sweep can never move rewards already owed
  ///         to claimants.
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _legs ERC-20 sweep legs; each moves `amount` of `token` from the Relay to `recipient`.
  /// @dev Delegatecalled; the Relay runs the role and tier gates. A token never notified has a zero
  ///      accounted balance, so stuck and excluded tokens stay fully sweepable.
  function sweep(
    mapping(address token => uint256 accounted) storage _accountedBalance,
    IRelay.ERC20Sweep[] calldata _legs
  ) external {
    for (uint256 i; i < _legs.length; ++i) {
      IRelay.ERC20Sweep calldata _leg = _legs[i];
      if (_leg.amount > IERC20(_leg.token).balanceOf(address(this)) - _accountedBalance[_leg.token]) {
        revert IRelay.RewardExceedsBalance();
      }
      _leg.token.safeTransfer(_leg.recipient, _leg.amount);
      emit IRelay.TokenSwept(_leg.token, _leg.recipient, _leg.amount);
    }
  }

  /// @notice Guards and executes the stake growth of a compound: `_amount` must not exceed the
  ///         un-accounted TOKEN balance, so TOKEN already owed to claimants is never staked. The
  ///         rake comes out of `_amount` and the rest is staked. The Relay rolls the lock before
  ///         calling in.
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _rakes The rake state (the Relay's storage).
  /// @param _feeAccrued Per-token rake accruals (the Relay's storage).
  /// @param _votingEscrow VotingEscrow the TOKEN is staked into.
  /// @param _principalToken The PT satellite, whose supply must be nonzero for the backing to have a
  ///        claimant.
  /// @param _token The protocol TOKEN being compounded.
  /// @param _tokenId The Relay's sAERO receiving the stake.
  /// @param _amount Gross TOKEN amount.
  /// @param _factory The Relay's factory, which takes the report and relays it to the tape.
  /// @param _backingBefore The Relay's backing before this compound, reported as its sum with the net.
  /// @return _net TOKEN amount staked, after the rake.
  /// @dev Only the principal redeems backing, so compounding with no principal outstanding would
  ///      strand the weight: unrecoverable on a closed Relay, and taken by the next depositor on an
  ///      open one.
  function compound(
    mapping(address token => uint256 accounted) storage _accountedBalance,
    IRelay.RakeState storage _rakes,
    mapping(
      address token => IRelay.FeeAccrual accrual
    ) storage _feeAccrued,
    IVotingEscrow _votingEscrow,
    IRelayToken _principalToken,
    address _token,
    uint256 _tokenId,
    uint256 _amount,
    address _factory,
    uint256 _backingBefore
  ) external returns (uint256 _net) {
    uint256 _supply = _principalToken.totalSupply();
    if (_supply == 0) revert IRelay.NoPrincipalSupply();
    if (_amount > IERC20(_token).balanceOf(address(this)) - _accountedBalance[_token]) {
      revert IRelay.RewardExceedsBalance();
    }

    uint256 _fees;
    (_net, _fees) = RelayRakeLib.skim(_rakes, _feeAccrued, _token, _amount);
    _accountedBalance[_token] += _fees;

    _votingEscrow.increaseStakeAmount(_tokenId, _net.toUint128());
    emit IRelay.Compounded(_net);

    // The caller adds the net to `totalBacking` after this returns, so the backing reported is the
    // sum rather than a storage read that would still be one compound behind.
    _reportBacking(_factory, _net, _backingBefore + _net, _supply);
  }

  /// @notice Register a reward token in the accumulator registry, guarding the growth rules.
  /// @param _rewardTokenSet Reward-token registry (the Relay's storage).
  /// @param _token Reward token to add.
  /// @param _canGrow Whether the tier lets the registry grow beyond its first token.
  /// @param _maxTokens Hard cap on the registry size.
  /// @dev The satellite pair is read back from the Relay rather than passed in, keeping the two
  ///      reads out of the Relay's bytecode; `requireUsableRewardToken` carries the rule itself, so
  ///      the creation seed applies the same one.
  function addRewardToken(
    EnumerableSet.AddressSet storage _rewardTokenSet,
    address _token,
    bool _canGrow,
    uint256 _maxTokens
  ) external {
    IRelayState _relay = IRelayState(address(this));
    requireUsableRewardToken(_token, address(_relay.principalToken()), address(_relay.yieldToken()));
    if (_rewardTokenSet.length() != 0 && !_canGrow) revert IRelay.RewardRegistryLocked();
    if (_rewardTokenSet.length() >= _maxTokens) revert IRelay.RewardRegistryFull();
    if (!_rewardTokenSet.add(_token)) revert IRelay.RewardTokenAlreadyAdded();
    emit IRelay.RewardTokenAdded(_token);
  }

  /// @notice Drop a reward token that never distributed anything, reopening its registry slot.
  /// @param _rewardTokenSet Reward-token registry (the Relay's storage).
  /// @param _rewardIndex Per-token reward-per-share accumulator (the Relay's storage).
  /// @param _token Reward token to drop.
  /// @dev The gate is the index, not the accounted balance. `notifyReward`, `claimSettled` and the
  ///      transfer-hook settle all require membership, so dropping a token that ever paid would
  ///      freeze the rights it left behind; a zero index proves no holder ever accrued in it, which
  ///      is exactly the misregistration this undoes. The accounted balance would be the wrong gate:
  ///      it keeps the flooring dust of every batch, so it never returns to zero once a token paid,
  ///      and a token re-added after it did reach zero would run a live index against zeroed
  ///      checkpoints.
  function removeRewardToken(
    EnumerableSet.AddressSet storage _rewardTokenSet,
    mapping(address token => uint256 index) storage _rewardIndex,
    address _token
  ) external {
    if (_rewardIndex[_token] != 0) {
      revert IRelay.RewardTokenPaid();
    }
    if (!_rewardTokenSet.remove(_token)) revert IRelay.UnknownRewardToken();
    emit IRelay.RewardTokenRemoved(_token);
  }

  /// @notice Settle the caller's accrual for `_token` at their current YT balance, then pay the
  ///         full settled amount out to `_to`.
  /// @param _rewardTokenSet Reward-token registry (the Relay's storage); gates the claim.
  /// @param _pendingReward Per-(holder, token) settled, unclaimed reward (the Relay's storage).
  /// @param _userCheckpoint Per-(holder, token) last-settled index (the Relay's storage).
  /// @param _rewardIndex Per-token accumulator (the Relay's storage).
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _yieldToken The Relay's yield token (YT), whose balance the accrual is proportional to.
  /// @param _token Reward token to claim.
  /// @param _to Recipient of the payout.
  /// @param _accScale Fixed-point scaling factor of the accumulator.
  /// @return _amount Reward amount transferred.
  /// @dev Delegatecalled, so `msg.sender` is the claiming holder. CEI: the pending balance is
  ///      zeroed and de-accounted before the transfer.
  function claimSettled(
    EnumerableSet.AddressSet storage _rewardTokenSet,
    mapping(address holder => mapping(address token => uint256 pending)) storage _pendingReward,
    mapping(address holder => mapping(address token => uint256 checkpoint)) storage _userCheckpoint,
    mapping(address token => uint256 index) storage _rewardIndex,
    mapping(address token => uint256 accounted) storage _accountedBalance,
    IRelayToken _yieldToken,
    address _token,
    address _to,
    uint256 _accScale
  ) external returns (uint256 _amount) {
    if (!_rewardTokenSet.contains(_token)) revert IRelay.UnknownRewardToken();

    // Lock the accrual since the caller's last checkpoint, at their current YT balance.
    uint256 _index = _rewardIndex[_token];
    uint256 _delta = _index - _userCheckpoint[msg.sender][_token];
    if (_delta > 0) {
      _pendingReward[msg.sender][_token] += Math.mulDiv(_yieldToken.balanceOf(msg.sender), _delta, _accScale);
      _userCheckpoint[msg.sender][_token] = _index;
    }

    _amount = _pendingReward[msg.sender][_token];
    if (_amount == 0) revert IRelay.NothingToClaim();

    _pendingReward[msg.sender][_token] = 0;
    _accountedBalance[_token] -= _amount;

    _token.safeTransfer(_to, _amount);
    emit IRelay.RewardClaimed(msg.sender, _token, _to, _amount);
  }

  /// @notice The yield-token hook's settle: enforce the escrow lock on holder-to-holder moves, then
  ///         lock each nonzero end's accrual to date into `pendingReward` at the pre-change balance.
  /// @param _rewardTokenSet Reward-token registry (the Relay's storage).
  /// @param _pendingReward Per-(holder, token) settled, unclaimed reward (the Relay's storage).
  /// @param _userCheckpoint Per-(holder, token) last-settled index (the Relay's storage).
  /// @param _rewardIndex Per-token accumulator (the Relay's storage).
  /// @param _escrowedShares Per-holder escrowed (queued, undrained) shares (the Relay's storage).
  /// @param _ctx The transfer ends, the moving amount, the YT and the accumulator scale.
  /// @dev The sender's pre-change balance must keep covering its escrow. Burns clear the escrow
  ///      before the token fires the hook, so a fully escrowed holder drains cleanly. Once the
  ///      Relay is closed the drain burns the principal alone, so the escrow stops locking the
  ///      yield side: it is the holder's receipt for the fee tail, theirs to sell while the exit
  ///      waits.
  function settleTransfer(
    EnumerableSet.AddressSet storage _rewardTokenSet,
    mapping(address holder => mapping(address token => uint256 pending)) storage _pendingReward,
    mapping(address holder => mapping(address token => uint256 checkpoint)) storage _userCheckpoint,
    mapping(address token => uint256 index) storage _rewardIndex,
    mapping(address holder => uint256 shares) storage _escrowedShares,
    SettleContext memory _ctx
  ) external {
    if (!_ctx.closed && _ctx.from != address(0) && _ctx.to != address(0)) {
      uint256 _escrowed = _escrowedShares[_ctx.from];
      if (_escrowed != 0 && _ctx.yieldToken.balanceOf(_ctx.from) < _escrowed + _ctx.amount) {
        revert IRelay.EscrowedSharesLocked();
      }
    }

    if (_ctx.from != address(0)) {
      _settleAll(
        _rewardTokenSet,
        _pendingReward,
        _userCheckpoint,
        _rewardIndex,
        _ctx.from,
        _ctx.yieldToken.balanceOf(_ctx.from),
        _ctx.accScale
      );
    }
    if (_ctx.to != address(0)) {
      _settleAll(
        _rewardTokenSet,
        _pendingReward,
        _userCheckpoint,
        _rewardIndex,
        _ctx.to,
        _ctx.yieldToken.balanceOf(_ctx.to),
        _ctx.accScale
      );
    }
  }

  /// @notice Claims the Relay's accrued fee and incentive rewards for `_chainId` to the recipient
  ///         configured for that chain, funding the cross-chain dispatch with msg.value.
  /// @param _leafRecipient Per-chain claim recipients (the Relay's storage).
  /// @param _voter Voter the claim is driven through.
  /// @param _relayTokenId The Relay's sAERO whose rewards are claimed.
  /// @param _chainId Chain to claim rewards on: the local chain for a root claim, a leaf otherwise.
  /// @param _gasLimit Destination gas budget for the leaf claim dispatch (ignored on a root claim).
  /// @param _feeClaims Fee claim requests forwarded to the Voter.
  /// @param _incentiveClaims Incentive claim requests forwarded to the Voter.
  /// @dev The reward recipient is resolved from per-chain config, never from the caller, who only
  ///      receives the native-fee refund. A root claim must carry zero value.
  function claimRewards(
    mapping(uint256 chainId => address recipient) storage _leafRecipient,
    IVoter _voter,
    uint256 _relayTokenId,
    uint256 _chainId,
    uint256 _gasLimit,
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims
  ) external {
    address _recipient = recipientFor(_leafRecipient, _chainId);
    if (_chainId == block.chainid && msg.value != 0) revert IRelay.NoValueOnRootClaim();

    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](1);
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: _chainId,
      gasLimit: _gasLimit,
      value: msg.value,
      recipient: _recipient,
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });
    _voter.claimRewards{value: msg.value}(_relayTokenId, _claimRewardsParams, msg.sender);
  }

  /// @notice Prices `_holder`'s claimable reward in `_token`: the settled pending plus the accrual
  ///         since the last checkpoint.
  /// @param _pendingReward Per-(holder, token) settled, unclaimed reward (the Relay's storage).
  /// @param _userCheckpoint Per-(holder, token) last-settled index (the Relay's storage).
  /// @param _rewardIndex Per-token accumulator (the Relay's storage).
  /// @param _yieldToken The Relay's yield token (YT), whose balance the accrual is proportional to.
  /// @param _holder Holder to price.
  /// @param _token Reward token to price.
  /// @param _accScale Fixed-point scaling factor of the accumulator.
  /// @return _amount Claimable reward amount.
  function claimable(
    mapping(address holder => mapping(address token => uint256 pending)) storage _pendingReward,
    mapping(
      address holder => mapping(address token => uint256 checkpoint)
    ) storage _userCheckpoint,
    mapping(address token => uint256 index) storage _rewardIndex,
    IRelayToken _yieldToken,
    address _holder,
    address _token,
    uint256 _accScale
  ) external view returns (uint256 _amount) {
    uint256 _delta = _rewardIndex[_token] - _userCheckpoint[_holder][_token];
    _amount = _pendingReward[_holder][_token] + Math.mulDiv(_yieldToken.balanceOf(_holder), _delta, _accScale);
  }

  /// @notice Reject a reward token no claim could ever pay out from.
  /// @param _token Reward token being registered.
  /// @param _principalToken The Relay's principal token.
  /// @param _yieldToken The Relay's yield token.
  /// @dev Internal so both registration paths inline it: the KEEPER's `addRewardToken` and the
  ///      creation seed in `RelayInitLib.setUp`.
  function requireUsableRewardToken(address _token, address _principalToken, address _yieldToken) internal view {
    if (_token == address(0)) revert IRelay.ZeroAddress();

    // A codeless address holds no balance to pay a claim from, and every notify would revert on it.
    if (_token.code.length == 0) revert IRelay.RewardTokenNotAContract();

    // The Relay and its own share tokens make the accumulator circular: a notify would distribute
    // the balances the claims are priced against, and the Relay itself can never claim as a holder,
    // so whatever the share supply routes to it stays there.
    if (_token == address(this) || _token == _principalToken || _token == _yieldToken) {
      revert IRelay.InvalidRewardToken();
    }
  }

  /// @notice Resolves the recipient a claim for `_chainId` lands at: the Relay itself on the local
  ///         chain, otherwise the configured leaf recipient.
  /// @param _leafRecipient Per-chain claim recipients (the Relay's storage).
  /// @param _chainId Chain whose claim recipient is resolved.
  /// @return _recipient The resolved claim recipient.
  /// @dev Reverts RecipientNotSet when a leaf chain has no recipient configured, so a claim can
  ///      never dispatch to the zero address.
  function recipientFor(
    mapping(uint256 chainId => address recipient) storage _leafRecipient,
    uint256 _chainId
  ) internal view returns (address _recipient) {
    if (_chainId == block.chainid) return address(this);
    _recipient = _leafRecipient[_chainId];
    if (_recipient == address(0)) revert IRelay.RecipientNotSet();
  }

  /// @notice Settles `_holder`'s accrual across every registered reward token at the given YT
  ///         balance and advances their checkpoints.
  /// @param _rewardTokenSet Reward-token registry (the Relay's storage).
  /// @param _pendingReward Per-(holder, token) settled, unclaimed reward (the Relay's storage).
  /// @param _userCheckpoint Per-(holder, token) last-settled index (the Relay's storage).
  /// @param _rewardIndex Per-token accumulator (the Relay's storage).
  /// @param _holder Holder being settled.
  /// @param _balance The holder's YT balance, read once by the caller before any change.
  /// @param _accScale Fixed-point scaling factor of the accumulator.
  /// @dev Accrual is proportional to the YT balance — the yield token is the accumulator's target.
  ///      Cost is linear in the registry size, which bounds the gas of every share move.
  function _settleAll(
    EnumerableSet.AddressSet storage _rewardTokenSet,
    mapping(address holder => mapping(address token => uint256 pending)) storage _pendingReward,
    mapping(address holder => mapping(address token => uint256 checkpoint)) storage _userCheckpoint,
    mapping(address token => uint256 index) storage _rewardIndex,
    address _holder,
    uint256 _balance,
    uint256 _accScale
  ) private {
    uint256 _length = _rewardTokenSet.length();
    for (uint256 i; i < _length; ++i) {
      address _token = _rewardTokenSet.at(i);
      uint256 _index = _rewardIndex[_token];
      uint256 _delta = _index - _userCheckpoint[_holder][_token];
      if (_delta > 0) {
        _pendingReward[_holder][_token] += Math.mulDiv(_balance, _delta, _accScale);
        _userCheckpoint[_holder][_token] = _index;
      }
    }
  }

  /// @notice Reports a distribution to the factory, which relays it to the tape fail-open.
  /// @dev Runs in the library's delegatecall frame, so the factory sees the Relay as its caller and
  ///      gates on `_isRelay`. A plain call, matching the gauge: the fail-open belongs on the factory's
  ///      own call into the tape, so a broken tape never blocks a distribution while a starved one
  ///      still fails loudly. Swallowing here would let a gas-short distribution succeed without
  ///      recording, which is where an estimator lands every time.
  /// @param _factory The Relay's factory.
  /// @param _token The reward token distributed.
  /// @param _distributed The amount paid to holders, post rake.
  /// @param _index The per-share index after the advance.
  function _reportReward(address _factory, address _token, uint256 _distributed, uint256 _index) private {
    IRelayFactory(_factory).recordRewardTape(_token, _distributed, _index);
  }

  /// @notice Reports a compound to the factory, which relays it to the tape fail-open.
  /// @dev Same contract as `_reportReward`.
  /// @param _factory The Relay's factory.
  /// @param _net The amount staked into backing, post rake.
  /// @param _backing The Relay's backing after this compound lands.
  /// @param _supply The principal supply the backing prices against, already read for the guard.
  function _reportBacking(address _factory, uint256 _net, uint256 _backing, uint256 _supply) private {
    IRelayFactory(_factory).recordBackingTape(_net, _backing, _supply);
  }
}
