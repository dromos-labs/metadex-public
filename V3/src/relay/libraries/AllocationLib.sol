// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {DEALLOC_GAUGE, WEEK} from 'V3/libraries/ProtocolConstants.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayState} from 'V3/interfaces/relay/IRelayState.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

/**
 * @title  AllocationLib
 * @notice Everything the Relay does with its voting weight below the Voter: it validates an
 *         allocation and sends it on, keeps the stake's lock rolling so that weight stays alive, and
 *         runs the evacuation dispatch of a permanently closed Relay. Allocation growth is limited to
 *         the free chain0 weight above the withdrawal reserve; everything else is forwarded unchanged.
 * @dev    EXTERNAL (linked) library on purpose: its functions are delegatecalled, keeping their
 *         bytecode out of every Relay implementation (EIP-170). `msg.value` is preserved across
 *         the delegatecall, so the Voter is paid from the Relay's balance.
 * @dev    `allocate` reads its pricing inputs back from the Relay through the Relay's own ABI
 *         instead of taking them as parameters, which is deliberate and measured: hoisting those
 *         four reads back to the call site costs the Relay 182 B of bytecode, most of what
 *         `ProtocolRelay` has left under EIP-170. `QueueLib.requireUncoveredHead` carries the same
 *         note for the same reason.
 */
library AllocationLib {
  /// @notice The Voter's chain id for idle weight: free (unallocated) weight stays on this chain.
  uint256 internal constant _CHAIN0 = 0;

  /// @notice Limit the call's growth to the free chain0 weight above the withdrawal reserve, then
  ///         forward the allocation to the Voter.
  /// @param _voter The Voter the dispatches are cast against.
  /// @param _tokenId The Relay's sAERO whose voting power is allocated.
  /// @param _chainDispatches Caller-supplied per-chain additive deltas plus dispatch funding.
  /// @param _gaugeDispatches Caller-supplied per-chain gauge overwrites plus dispatch funding.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  /// @dev Exits come first: the queue's priced total never leaves chain0, so the call may only
  ///      grow chains using the free weight above that reserve. Bounding the sum of the deltas
  ///      bounds exactly what leaves chain0. The Voter validates every other rule.
  /// @dev The queue is priced against the stake net of the pending deposits, never against
  ///      `totalBacking`. A donation credits chain0 the moment it lands, so this call is free to
  ///      send it away, and `processDonations` then hands its value to the share holders: pricing on
  ///      the backing counter alone would let a vote spend weight the queue is about to be owed and
  ///      leave the head exit unpayable. The two readings agree exactly while no donation waits.
  function allocate(
    IVoter _voter,
    uint256 _tokenId,
    IVoter.ChainAllocationDispatch[] calldata _chainDispatches,
    IVoter.GaugeAllocationDispatch[] calldata _gaugeDispatches,
    address _refundRecipient
  ) external {
    IRelayState _relay = IRelayState(address(this));
    uint256 _supply = _relay.principalToken().totalSupply();

    // What the shares can already claim: the whole stake minus the weight the queued deposits
    // parked on it, which no share owns until the drain admits it.
    uint256 _claimable = uint256(_relay.VOTING_ESCROW().staked(_tokenId).amount) - _relay.pendingDepositWeight();
    uint256 _reserve = _supply == 0 ? 0 : (_relay.pendingWithdrawalShares() * _claimable) / _supply;
    uint256 _free = _voter.allocationChainAmounts(_tokenId, _CHAIN0);
    uint256 _growBudget = _free > _reserve ? _free - _reserve : 0;

    // slither-disable-next-line uninitialized-local
    uint256 _growth;
    for (uint256 _i; _i < _chainDispatches.length; ++_i) {
      _growth += _chainDispatches[_i].delta;
    }
    if (_growth > _growBudget) revert IRelay.InsufficientFreeWeight();

    _voter.allocate{value: msg.value}(_tokenId, _chainDispatches, _gaugeDispatches, _refundRecipient);
  }

  /// @notice Roll the Relay sAERO's lock forward to the configured horizon, keeping the stake's
  ///         voting weight alive for the allocations that spend it.
  /// @param _votingEscrow VotingEscrow holding the Relay's stake.
  /// @param _tokenId The Relay's sAERO.
  /// @param _lockWeeks Lock horizon in weeks; zero means a permanent stake and makes this a no-op.
  /// @dev Skipped when the current end already holds the horizon: an unconditional call would revert
  ///      `StakingPeriodNotInFuture` within the same calendar week and block allocations. Lives here
  ///      rather than inline on the Relay because decoding the escrow's `StakedBalance` costs the
  ///      Protocol tier ~550 bytes, which it cannot spare under EIP-170.
  function extendLock(IVotingEscrow _votingEscrow, uint256 _tokenId, uint48 _lockWeeks) external {
    if (_lockWeeks == 0) return;

    uint256 _targetEnd = (block.timestamp / WEEK) * WEEK + uint256(_lockWeeks) * WEEK;
    if (_targetEnd > _votingEscrow.staked(_tokenId).end) {
      _votingEscrow.increaseStakingPeriod(_tokenId, _lockWeeks);
    }
  }

  /// @notice Forward an emergency deallocation to the Voter, funded by the call's msg.value. The
  ///         Voter enforces its own preconditions (the chain is Suspended and emergency
  ///         deallocation is enabled for it) and credits chain0 synchronously.
  /// @param _voter The Voter driving the emergency path.
  /// @param _tokenId The Relay's sAERO whose weight returns.
  /// @param _chainId Suspended chain whose full booked weight returns.
  /// @param _gasLimit Destination gas for the emergency message to the leaf.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  function emergencyDeallocate(
    IVoter _voter,
    uint256 _tokenId,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external {
    _voter.emergencyDeallocate{value: msg.value}(_tokenId, _chainId, _gasLimit, _refundRecipient);
  }

  /// @notice Send the named chain one gauge overwrite holding its full booked amount on
  ///         `DEALLOC_GAUGE`, returning what the Relay allocated there. One chain per call.
  /// @param _voter The Voter the pull-out is cast against.
  /// @param _tokenId The Relay's sAERO being evacuated.
  /// @param _chainId Chain whose full booked weight returns.
  /// @param _gasLimit Destination gas for the leaf message.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  function evacuate(
    IVoter _voter,
    uint256 _tokenId,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external {
    uint128 _booked = _voter.allocationChainAmounts(_tokenId, _chainId);
    if (_booked == 0) revert IRelay.NothingToEvacuate();

    IVoterCommon.GaugeAllocation[] memory _gauges = new IVoterCommon.GaugeAllocation[](1);
    _gauges[0] = IVoterCommon.GaugeAllocation({gauge: DEALLOC_GAUGE, allocated: _booked, data: ''});

    _voter.allocateGauges{value: msg.value}(_tokenId, _chainId, _gauges, _gasLimit, _refundRecipient);
  }
}
