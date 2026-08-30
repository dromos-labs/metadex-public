// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseAllocationLib} from 'V3-test/unit/relay/libraries/BaseAllocationLib.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/// @notice Unit tests for `AllocationLib.allocate`, driven through the harness — which also serves
///         the Relay self-calls the reserve is priced from (`principalToken`, `VOTING_ESCROW`,
///         `pendingWithdrawalShares`, `pendingDepositWeight`), since the delegatecall makes
///         `address(this)` the harness. Bounds keep every product inside uint256: supply and
///         claimable weight within uint96, the escrowed shares within the supply (escrow never
///         exceeds what exists) and the free weight within a uint128 (a VE-staked amount). The
///         reserve each branch prices is `pending * claimable / supply` at the call instant, where
///         the claimable weight is the stake net of the queued deposits; only the growth-versus-
///         budget comparison lives in the library, so the branches pivot on that comparison alone.
contract UnitAllocationLibAllocate is BaseAllocationLib {
  /// @notice Growth past the free weight above the reserve must revert: the queue is owed the
  ///         reserve before anything else leaves chain0.
  function test_WhenTheGrowthExceedsTheFreeWeightAboveTheReserve(
    address _caller,
    uint256 _supply,
    uint256 _pendingShares,
    uint256 _claimable,
    uint256 _free,
    uint256 _growth
  ) external {
    _assumeFuzzable(_caller);
    _supply = bound(_supply, 1, type(uint96).max);
    _pendingShares = bound(_pendingShares, 0, _supply);
    _claimable = bound(_claimable, 0, type(uint96).max);
    _seedPricing(_supply, _claimable, _pendingShares, 0);
    uint256 _reserve = (_pendingShares * _claimable) / _supply;
    _free = bound(_free, 0, type(uint96).max);
    uint256 _budget = _free > _reserve ? _free - _reserve : 0;
    _growth = bound(_growth, _budget + 1, type(uint128).max);
    _mockChainZeroFree(_free);

    // it should revert with InsufficientFreeWeight
    vm.expectRevert(IRelay.InsufficientFreeWeight.selector);
    vm.prank(_caller);
    _allocation.allocate(
      IVoter(_voter),
      _TOKEN_ID,
      // forge-lint: disable-next-line(unsafe-typecast)
      _chainDelta(uint128(_growth)),
      _noGauges(),
      _refundRecipient
    );
  }

  /// @notice Growth within the budget forwards the caller's dispatch arrays verbatim.
  function test_WhenTheGrowthFitsTheFreeWeightAboveTheReserve(
    address _caller,
    uint256 _supply,
    uint256 _pendingShares,
    uint256 _claimable,
    uint256 _free,
    uint256 _growth
  ) external {
    _assumeFuzzable(_caller);
    _supply = bound(_supply, 1, type(uint96).max);
    _pendingShares = bound(_pendingShares, 0, _supply);
    _claimable = bound(_claimable, 0, type(uint96).max);
    _seedPricing(_supply, _claimable, _pendingShares, 0);
    uint256 _reserve = (_pendingShares * _claimable) / _supply;
    _free = bound(_free, _reserve, type(uint128).max);
    _growth = bound(_growth, 0, _free - _reserve);
    _mockChainZeroFree(_free);

    // it should forward the dispatches to the voter
    // forge-lint: disable-next-line(unsafe-typecast)
    _expectVoterAllocate(_chainDelta(uint128(_growth)), _noGauges());
    vm.prank(_caller);
    _allocation.allocate(
      IVoter(_voter),
      _TOKEN_ID,
      // forge-lint: disable-next-line(unsafe-typecast)
      _chainDelta(uint128(_growth)),
      _noGauges(),
      _refundRecipient
    );
  }

  /// @notice A supply-zero pool owes nothing to the queue, so the growth may draw the whole free
  ///         weight even while escrowed shares and a stake are on the books.
  function test_WhenTheShareSupplyIsZero(
    address _caller,
    uint256 _pendingShares,
    uint256 _claimable,
    uint256 _free
  ) external {
    _assumeFuzzable(_caller);
    _pendingShares = bound(_pendingShares, 1, type(uint96).max);
    _claimable = bound(_claimable, 1, type(uint96).max);
    _free = bound(_free, 1, type(uint96).max);
    _seedPricing(0, _claimable, _pendingShares, 0);
    _mockChainZeroFree(_free);

    // it should reserve nothing and let the growth draw the full free weight
    // forge-lint: disable-next-line(unsafe-typecast)
    _expectVoterAllocate(_chainDelta(uint128(_free)), _noGauges());
    vm.prank(_caller);
    _allocation.allocate(
      IVoter(_voter),
      _TOKEN_ID,
      // forge-lint: disable-next-line(unsafe-typecast)
      _chainDelta(uint128(_free)),
      _noGauges(),
      _refundRecipient
    );
  }

  /// @notice A zero-growth call (shrinks and pokes) always passes, even while a fresh registration
  ///         holds the reserve above the free weight.
  function test_WhenTheDispatchesCarryNoGrowth(
    address _caller,
    uint256 _supply,
    uint256 _pendingShares,
    uint256 _claimable,
    uint256 _free
  ) external {
    _assumeFuzzable(_caller);
    _supply = bound(_supply, 1, type(uint96).max);
    _pendingShares = bound(_pendingShares, 1, _supply);
    _claimable = bound(_claimable, 1, type(uint96).max);
    _seedPricing(_supply, _claimable, _pendingShares, 0);
    uint256 _reserve = (_pendingShares * _claimable) / _supply;
    vm.assume(_reserve != 0);
    _free = bound(_free, 0, _reserve - 1);
    _mockChainZeroFree(_free);

    // it should forward even when the reserve exceeds the free weight
    _expectVoterAllocate(_chainDelta(0), _noGauges());
    vm.prank(_caller);
    _allocation.allocate(IVoter(_voter), _TOKEN_ID, _chainDelta(0), _noGauges(), _refundRecipient);
  }

  /// @notice The budget prices the whole call, not one dispatch: two deltas that each fit on their
  ///         own still exceed the budget once added, and a wider accumulator must hold the sum.
  function test_WhenTheDispatchesCarrySeveralDeltasAddingPastTheBudget(address _caller) external {
    _assumeFuzzable(_caller);
    // A supply of one with no escrowed shares prices the reserve at zero, so the budget is the
    // whole free chain0 weight: 340282366920938463463374607431768211455.
    _seedPricing(1, 0, 0, 0);
    _mockChainZeroFree(type(uint128).max);
    IVoter.ChainAllocationDispatch[] memory _dispatches = _twoChainDeltas(type(uint128).max, type(uint128).max);

    // it should revert with InsufficientFreeWeight
    // The two deltas add up to 680564733841876926926749214863536422910, past that budget.
    vm.expectRevert(IRelay.InsufficientFreeWeight.selector);
    vm.prank(_caller);
    _allocation.allocate(IVoter(_voter), _TOKEN_ID, _dispatches, _noGauges(), _refundRecipient);
  }

  /// @notice Queued deposits park their weight on the same stake, but no share owns it until the
  ///         drain admits it, so the reserve subtracts it back out. Half the supply is escrowed
  ///         here, so the queue is owed half of the claimable weight and the vote may spend the
  ///         rest, the parked deposits included. The supply cancels out of that half, so it stays
  ///         fixed while the two weights are fuzzed.
  function test_WhenTheStakeHoldsWeightForQueuedDeposits(
    address _caller,
    uint256 _claimable,
    uint256 _pendingDeposit
  ) external {
    _assumeFuzzable(_caller);
    // Even claimable weight: the queue owns exactly half the supply, so its half of that weight has
    // to be a whole number of wei.
    _claimable = 2 * bound(_claimable, 1, type(uint80).max);
    _pendingDeposit = bound(_pendingDeposit, 1, type(uint80).max);
    uint256 _supply = 100e18;
    _seedPricing(_supply, _claimable, _supply / 2, _pendingDeposit);

    // The stake carries both, and the free chain0 weight carries both with it.
    uint256 _free = _claimable + _pendingDeposit;
    uint256 _owed = _claimable / 2;
    _mockChainZeroFree(_free);

    // it should leave that weight out of the reserve
    // forge-lint: disable-next-line(unsafe-typecast)
    _expectVoterAllocate(_chainDelta(uint128(_free - _owed)), _noGauges());
    vm.prank(_caller);
    _allocation.allocate(
      IVoter(_voter),
      _TOKEN_ID,
      // forge-lint: disable-next-line(unsafe-typecast)
      _chainDelta(uint128(_free - _owed)),
      _noGauges(),
      _refundRecipient
    );

    // it should refuse the growth that reaches past it
    vm.expectRevert(IRelay.InsufficientFreeWeight.selector);
    vm.prank(_caller);
    _allocation.allocate(
      IVoter(_voter),
      _TOKEN_ID,
      // forge-lint: disable-next-line(unsafe-typecast)
      _chainDelta(uint128(_free - _owed + 1)),
      _noGauges(),
      _refundRecipient
    );
  }

  /// @notice The call's ETH pays the Voter's cross-chain dispatches, so the whole value must arrive.
  function test_WhenTheCallCarriesDispatchValue(address _caller, uint256 _value, uint256 _free) external {
    _assumeFuzzable(_caller);
    _value = bound(_value, 2, 10 ether);
    _free = bound(_free, 1, type(uint96).max);
    _seedPricing(1, 0, 0, 0);
    _mockChainZeroFree(_free);
    IVoter.ChainAllocationDispatch[] memory _dispatches = _chainDelta(0);

    // it should forward the whole call value to the voter
    _mockAndExpectWithValue(
      _voter,
      _value,
      abi.encodeCall(IVoter.allocate, (_TOKEN_ID, _dispatches, _noGauges(), _refundRecipient)),
      abi.encode()
    );
    hoax(_caller, _value);
    _allocation.allocate{value: _value}(IVoter(_voter), _TOKEN_ID, _dispatches, _noGauges(), _refundRecipient);
  }

  /// @dev Build a two-chain dispatch array carrying the given deltas.
  function _twoChainDeltas(
    uint128 _firstDelta,
    uint128 _secondDelta
  ) private pure returns (IVoter.ChainAllocationDispatch[] memory _dispatches) {
    _dispatches = new IVoter.ChainAllocationDispatch[](2);
    _dispatches[0] = IVoter.ChainAllocationDispatch({chainId: 10, delta: _firstDelta, gasLimit: 0, value: 0});
    _dispatches[1] = IVoter.ChainAllocationDispatch({chainId: 20, delta: _secondDelta, gasLimit: 0, value: 0});
  }
}
