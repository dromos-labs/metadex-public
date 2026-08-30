// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseAllocationLib} from 'V3-test/unit/relay/libraries/BaseAllocationLib.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {DEALLOC_GAUGE} from 'V3/libraries/ProtocolConstants.sol';

/// @notice Unit tests for `AllocationLib.evacuate`, the single-chain pull-out dispatch, driven
///         through the harness so `msg.value` inside the library is the value sent to the wrapper.
///         Every dispatching scenario names one chain and expects one `allocateGauges` cast
///         carrying a single full-amount `DEALLOC_GAUGE` overwrite — the gauge lane reads the stake
///         without requiring it live, so an expired stake can still wind down. The closing gate
///         lives in `requireUncoveredHead` and has its own suite.
contract UnitAllocationLibEvacuate is BaseAllocationLib {
  /// @dev Fixed allocated chain the dispatching scenarios pull out of.
  uint256 internal constant _CHAIN_ID = 10;

  /// @dev Fixed destination gas for the leaf message.
  uint256 internal constant _GAS_LIMIT = 100_000;

  /// @notice A chain holding no weight for the token has nothing to pull back. Chain0 is inside
  ///         the range: with nothing booked it is this same branch, and with free weight booked the
  ///         Voter rejects it as an unregistered chain (covered in integration).
  function test_WhenTheNamedChainHoldsNoBookedWeight(address _caller, uint256 _chainId) external {
    _assumeFuzzable(_caller);
    _mockBookedWeight(_chainId, 0);

    // it should revert with NothingToEvacuate
    vm.expectRevert(IRelay.NothingToEvacuate.selector);
    vm.prank(_caller);
    _allocation.evacuate(IVoter(_voter), _TOKEN_ID, _chainId, _GAS_LIMIT, _refundRecipient);
  }

  /// @notice The named chain's whole booked weight moves onto the deallocation sentinel through
  ///         one gauge-lane cast.
  function test_WhenTheNamedChainHoldsBookedWeight(address _caller, uint128 _booked) external {
    _assumeFuzzable(_caller);
    _booked = uint128(bound(_booked, 1, type(uint128).max));
    _mockBookedWeight(_CHAIN_ID, _booked);

    // it should send the chain a full dealloc gauge overwrite
    _mockAndExpect(
      _voter,
      abi.encodeCall(
        IVoter.allocateGauges, (_TOKEN_ID, _CHAIN_ID, _deallocGauges(_booked), _GAS_LIMIT, _refundRecipient)
      ),
      abi.encode()
    );
    vm.prank(_caller);
    _allocation.evacuate(IVoter(_voter), _TOKEN_ID, _CHAIN_ID, _GAS_LIMIT, _refundRecipient);
  }

  /// @notice The call's ETH pays the pull-out dispatch, so the whole value must reach the Voter.
  function test_WhenTheCallCarriesDispatchValue(address _caller, uint128 _booked, uint256 _value) external {
    _assumeFuzzable(_caller);
    _booked = uint128(bound(_booked, 1, type(uint128).max));
    _value = bound(_value, 2, 10 ether);
    _mockBookedWeight(_CHAIN_ID, _booked);

    // it should forward the whole call value to the voter
    _mockAndExpectWithValue(
      _voter,
      _value,
      abi.encodeCall(
        IVoter.allocateGauges, (_TOKEN_ID, _CHAIN_ID, _deallocGauges(_booked), _GAS_LIMIT, _refundRecipient)
      ),
      abi.encode()
    );
    hoax(_caller, _value);
    _allocation.evacuate{value: _value}(IVoter(_voter), _TOKEN_ID, _CHAIN_ID, _GAS_LIMIT, _refundRecipient);
  }

  /// @dev The single gauge overwrite the dispatch must compose: one entry on the deallocation
  ///      sentinel holding the chain's whole booked amount.
  function _deallocGauges(uint128 _booked) private pure returns (IVoterCommon.GaugeAllocation[] memory _gauges) {
    _gauges = new IVoterCommon.GaugeAllocation[](1);
    _gauges[0] = IVoterCommon.GaugeAllocation({gauge: DEALLOC_GAUGE, allocated: _booked, data: ''});
  }
}
