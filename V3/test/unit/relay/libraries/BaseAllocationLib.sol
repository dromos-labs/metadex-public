// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {AllocationLibHarness} from 'V3-test/unit/relay/harnesses/AllocationLibHarness.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/**
 * @title BaseAllocationLib
 * @notice Base for AllocationLib unit tests: the harness, a mocked Voter, the mocked escrow and
 *         principal token the reserve reads back through the harness, and the dispatch builders.
 */
abstract contract BaseAllocationLib is TestHelpers {
  /// @dev Fixed relay sAERO id used across tests; an opaque key with no arithmetic role.
  uint256 internal constant _TOKEN_ID = 7777;

  /// @dev Mirrors AllocationLib's `_CHAIN0`.
  uint256 internal constant _CHAIN0 = 0;

  AllocationLibHarness internal _allocation;
  address internal _voter;
  address internal _votingEscrow;
  address internal _principalToken;
  address internal _refundRecipient;

  function setUp() public virtual {
    _voter = _mockContract('Voter');
    _votingEscrow = _mockContract('VotingEscrow');
    _principalToken = _mockContract('PrincipalToken');
    _refundRecipient = makeAddr('refundRecipient');
    _allocation = new AllocationLibHarness(IVotingEscrow(_votingEscrow));
    _allocation.setPrincipalToken(IRelayToken(_principalToken));
  }

  /// @dev Preset everything the reserve prices against: the share supply, the weight the shares can
  ///      already claim (backing plus any donation waiting for `processDonations`), the escrowed
  ///      shares and the weight parked for queued deposits. The stake carries the last two together,
  ///      which is what the library subtracts back apart.
  function _seedPricing(uint256 _supply, uint256 _claimable, uint256 _pendingShares, uint256 _pendingDeposit) internal {
    vm.mockCall(_principalToken, abi.encodeCall(IRelayToken.totalSupply, ()), abi.encode(_supply));
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.staked, (_TOKEN_ID)),
      // forge-lint: disable-next-line(unsafe-typecast)
      abi.encode(
        IVotingEscrow.StakedBalance({amount: uint128(_claimable + _pendingDeposit), end: 0, isPermanent: true})
      )
    );
    _allocation.setQueueCounters(_pendingShares, _pendingDeposit);
  }

  /// @dev Mock (and expect) the Voter's free chain0 weight read.
  function _mockChainZeroFree(uint256 _free) internal {
    // forge-lint: disable-next-line(unsafe-typecast)
    _mockBookedWeight(_CHAIN0, uint128(_free));
  }

  /// @dev Build a single-chain dispatch carrying `_delta` growth.
  function _chainDelta(uint128 _delta) internal pure returns (IVoter.ChainAllocationDispatch[] memory _dispatches) {
    _dispatches = new IVoter.ChainAllocationDispatch[](1);
    _dispatches[0] = IVoter.ChainAllocationDispatch({chainId: 10, delta: _delta, gasLimit: 0, value: 0});
  }

  /// @dev An empty gauge phase.
  function _noGauges() internal pure returns (IVoter.GaugeAllocationDispatch[] memory _dispatches) {
    _dispatches = new IVoter.GaugeAllocationDispatch[](0);
  }

  /// @dev Mock (and expect) the composed `Voter.allocate` cast with the given phases.
  function _expectVoterAllocate(
    IVoter.ChainAllocationDispatch[] memory _chainDispatches,
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches
  ) internal {
    _mockAndExpect(
      _voter,
      abi.encodeCall(IVoter.allocate, (_TOKEN_ID, _chainDispatches, _gaugeDispatches, _refundRecipient)),
      abi.encode()
    );
  }

  /// @dev Mock (and expect) the booked-weight read of an evacuation's named chain.
  function _mockBookedWeight(uint256 _chainId, uint128 _booked) internal {
    _mockAndExpect(_voter, abi.encodeCall(IVoter.allocationChainAmounts, (_TOKEN_ID, _chainId)), abi.encode(_booked));
  }
}
