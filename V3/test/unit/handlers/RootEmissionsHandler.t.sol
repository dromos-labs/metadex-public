// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';
import {Vm} from 'forge-std/Test.sol';

import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';
import {IRootEmissionsHandler} from 'V3/interfaces/handlers/IRootEmissionsHandler.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {RootEmissionsHandler} from 'V3/handlers/RootEmissionsHandler.sol';

contract UnitRootEmissionsHandler is TestHelpers {
  using stdStorage for StdStorage;

  address internal immutable _LEAF_VOTER = makeAddr('LeafVoter');

  /// @dev Mirrors `LeafVoter.MIN_REDEEM_AMOUNT` (`MAX_PIPS` = 1e6).
  uint256 internal constant _MIN_REDEEM_AMOUNT = 1_000_000;

  RootEmissionsHandler internal _handler;

  /*////////////////////////////////////////////////////////////
                              SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    vm.etch(_LEAF_VOTER, hex'69');
    vm.mockCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.MIN_REDEEM_AMOUNT, ()), abi.encode(_MIN_REDEEM_AMOUNT));
    _handler = new RootEmissionsHandler(_LEAF_VOTER);
  }

  /**
   * @notice Seeds `pendingRedeems[_recipient]` directly to keep the test isolated from `handleEmissions` writes.
   */
  function _seedPendingRedeems(address _recipient, uint256 _pendingAmount) internal {
    stdstore.target(address(_handler)).sig(IRootEmissionsHandler.pendingRedeems.selector).with_key(_recipient)
      .checked_write(_pendingAmount);
  }

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenLeafVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IEmissionsHandler.ZeroAddress.selector);
    new RootEmissionsHandler(address(0));
  }

  function test_ConstructorWhenLeafVoterIsAValidAddress(address _leafVoter) external {
    _assumeFuzzable(_leafVoter);

    _handler = new RootEmissionsHandler(_leafVoter);

    // it should set LEAF_VOTER to _leafVoter
    assertEq(_handler.LEAF_VOTER(), _leafVoter);
  }

  /*////////////////////////////////////////////////////////////
                         HANDLE EMISSIONS
  ////////////////////////////////////////////////////////////*/

  function test_HandleEmissionsWhenTheCallerIsNotTheLeafVoter(
    address _caller,
    address[] calldata _recipients,
    uint128[] calldata _amounts
  ) external {
    _caller = _boundNotEq(_caller, _LEAF_VOTER);

    // it should revert with CallerNotLeafVoter
    vm.expectRevert(IEmissionsHandler.CallerNotLeafVoter.selector);

    vm.prank(_caller);
    _handler.handleEmissions(_recipients, _amounts);
  }

  modifier givenTheCallerIsTheLeafVoter() {
    vm.startPrank(_LEAF_VOTER);
    _;
    vm.stopPrank();
  }

  function test_HandleEmissionsWhenEveryAmountIsZero(
    uint8 _arrayLen,
    address _recipientSeed
  ) external givenTheCallerIsTheLeafVoter {
    _arrayLen = uint8(bound(_arrayLen, 0, 5));
    address[] memory _recipients = new address[](_arrayLen);
    uint128[] memory _amounts = new uint128[](_arrayLen);
    for (uint256 _i; _i < _arrayLen; ++_i) {
      _recipients[_i] = address(uint160(uint256(uint160(_recipientSeed)) + _i));
    }

    // it should read the minimum redeem amount from the leaf voter
    vm.expectCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.MIN_REDEEM_AMOUNT, ()), 1);

    // it should not call redeem on the leaf voter
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.redeem.selector), 0);

    // it should not emit RedeemDeferred
    vm.recordLogs();

    _handler.handleEmissions(_recipients, _amounts);

    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 0);

    // it should not store any pending amount
    for (uint256 _i; _i < _arrayLen; ++_i) {
      assertEq(_handler.pendingRedeems(_recipients[_i]), 0);
    }
  }

  modifier whenThePendingTotalStaysBelowTheRedeemFloor() {
    _;
  }

  function test_HandleEmissionsGivenTheRecipientHasNoPendingAmount(
    address _recipient,
    uint128 _amount
  ) external givenTheCallerIsTheLeafVoter whenThePendingTotalStaysBelowTheRedeemFloor {
    _assumeFuzzable(_recipient);
    _amount = uint128(bound(_amount, 1, _MIN_REDEEM_AMOUNT - 1));

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;

    // it should not call redeem on the leaf voter
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.redeem.selector), 0);

    // it should emit RedeemDeferred
    _expectEmit(address(_handler));
    emit IRootEmissionsHandler.RedeemDeferred(_recipient, _amount, _amount);

    _handler.handleEmissions(_recipients, _amounts);

    // it should store the leg amount as the recipient pending amount
    assertEq(_handler.pendingRedeems(_recipient), _amount);
  }

  function test_HandleEmissionsGivenTheRecipientAlreadyHasAPendingAmount(
    address _recipient,
    uint256 _pendingAmount,
    uint128 _amount
  ) external givenTheCallerIsTheLeafVoter whenThePendingTotalStaysBelowTheRedeemFloor {
    _assumeFuzzable(_recipient);
    _pendingAmount = bound(_pendingAmount, 1, _MIN_REDEEM_AMOUNT - 2);
    _amount = uint128(bound(_amount, 1, _MIN_REDEEM_AMOUNT - 1 - _pendingAmount));
    _seedPendingRedeems(_recipient, _pendingAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;

    // it should not call redeem on the leaf voter
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.redeem.selector), 0);

    // it should emit RedeemDeferred with the running total
    _expectEmit(address(_handler));
    emit IRootEmissionsHandler.RedeemDeferred(_recipient, _amount, _pendingAmount + _amount);

    _handler.handleEmissions(_recipients, _amounts);

    // it should accumulate the leg amount into the recipient pending amount
    assertEq(_handler.pendingRedeems(_recipient), _pendingAmount + _amount);
  }

  function test_HandleEmissionsWhenThePendingTotalReachesExactlyTheRedeemFloor(
    address _recipient,
    uint256 _pendingAmount
  ) external givenTheCallerIsTheLeafVoter {
    _assumeFuzzable(_recipient);
    _pendingAmount = bound(_pendingAmount, 1, _MIN_REDEEM_AMOUNT - 1);
    uint128 _amount = uint128(_MIN_REDEEM_AMOUNT - _pendingAmount);
    _seedPendingRedeems(_recipient, _pendingAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;

    // it should call redeem with the pending total
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_MIN_REDEEM_AMOUNT, _recipient, 0, address(0))), '');

    _handler.handleEmissions(_recipients, _amounts);

    // it should clear the recipient pending amount
    assertEq(_handler.pendingRedeems(_recipient), 0);
  }

  function test_HandleEmissionsWhenTheLegAmountIsAtOrAboveTheRedeemFloor(
    address _recipientSeed,
    uint128 _firstAmount,
    uint128 _secondAmount
  ) external givenTheCallerIsTheLeafVoter {
    _firstAmount = uint128(bound(_firstAmount, _MIN_REDEEM_AMOUNT, type(uint128).max));
    _secondAmount = uint128(bound(_secondAmount, _MIN_REDEEM_AMOUNT, type(uint128).max));

    address[] memory _recipients = new address[](3);
    _recipients[0] = _recipientSeed;
    _recipients[1] = address(uint160(uint256(uint160(_recipientSeed)) + 1));
    _recipients[2] = address(uint160(uint256(uint160(_recipientSeed)) + 2));

    uint128[] memory _amounts = new uint128[](3);
    _amounts[0] = 0;
    _amounts[1] = _firstAmount;
    _amounts[2] = _secondAmount;

    // it should skip recipients with a zero amount
    vm.mockCallRevert(
      _LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (0, _recipients[0], 0, address(0))), 'unexpected redeem'
    );

    // it should call redeem on the leaf voter for each leg with zero gas limit and zero refund recipient
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_amounts[1], _recipients[1], 0, address(0))), '');
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_amounts[2], _recipients[2], 0, address(0))), '');

    _handler.handleEmissions(_recipients, _amounts);

    // it should not store any pending amount
    assertEq(_handler.pendingRedeems(_recipients[1]), 0);
    assertEq(_handler.pendingRedeems(_recipients[2]), 0);
  }

  function test_HandleEmissionsWhenALegPushesTheRecipientPendingAmountOverTheRedeemFloor(
    address _recipient,
    uint256 _pendingAmount,
    uint128 _amount
  ) external givenTheCallerIsTheLeafVoter {
    _assumeFuzzable(_recipient);
    _pendingAmount = bound(_pendingAmount, 1, _MIN_REDEEM_AMOUNT - 1);
    _amount = uint128(bound(_amount, _MIN_REDEEM_AMOUNT - _pendingAmount, type(uint128).max));
    _seedPendingRedeems(_recipient, _pendingAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;

    // it should call redeem with the pending amount plus the leg amount
    _mockAndExpect(
      _LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_pendingAmount + _amount, _recipient, 0, address(0))), ''
    );

    _handler.handleEmissions(_recipients, _amounts);

    // it should clear the recipient pending amount
    assertEq(_handler.pendingRedeems(_recipient), 0);
  }

  function test_HandleEmissionsWhenTheBatchMixesADustLegAndAFullLeg(
    address _recipientSeed,
    uint128 _dustAmount,
    uint128 _fullAmount
  ) external givenTheCallerIsTheLeafVoter {
    _assumeFuzzable(_recipientSeed);
    _dustAmount = uint128(bound(_dustAmount, 1, _MIN_REDEEM_AMOUNT - 1));
    _fullAmount = uint128(bound(_fullAmount, _MIN_REDEEM_AMOUNT, type(uint128).max));

    address _dustRecipient = _recipientSeed;
    address _fullRecipient = address(uint160(uint256(uint160(_recipientSeed)) + 1));

    address[] memory _recipients = new address[](2);
    _recipients[0] = _dustRecipient;
    _recipients[1] = _fullRecipient;

    uint128[] memory _amounts = new uint128[](2);
    _amounts[0] = _dustAmount;
    _amounts[1] = _fullAmount;

    // it should defer the dust leg
    vm.mockCallRevert(
      _LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_dustAmount, _dustRecipient, 0, address(0))), 'unexpected redeem'
    );
    _expectEmit(address(_handler));
    emit IRootEmissionsHandler.RedeemDeferred(_dustRecipient, _dustAmount, _dustAmount);

    // it should redeem the full leg
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_fullAmount, _fullRecipient, 0, address(0))), '');

    _handler.handleEmissions(_recipients, _amounts);

    // it should store only the dust leg as a pending amount
    assertEq(_handler.pendingRedeems(_dustRecipient), _dustAmount);
    assertEq(_handler.pendingRedeems(_fullRecipient), 0);
  }

  function test_HandleEmissionsWhenSameRecipientDustLegsCrossTheRedeemFloor(
    address _recipient,
    uint128 _firstAmount,
    uint128 _secondAmount
  ) external givenTheCallerIsTheLeafVoter {
    _assumeFuzzable(_recipient);
    _firstAmount = uint128(bound(_firstAmount, 1, _MIN_REDEEM_AMOUNT - 1));
    _secondAmount = uint128(bound(_secondAmount, _MIN_REDEEM_AMOUNT - _firstAmount, _MIN_REDEEM_AMOUNT - 1));

    address[] memory _recipients = new address[](2);
    _recipients[0] = _recipient;
    _recipients[1] = _recipient;

    uint128[] memory _amounts = new uint128[](2);
    _amounts[0] = _firstAmount;
    _amounts[1] = _secondAmount;

    // it should defer the first leg
    _expectEmit(address(_handler));
    emit IRootEmissionsHandler.RedeemDeferred(_recipient, _firstAmount, _firstAmount);

    // it should redeem both legs together when the second leg crosses the floor
    _mockAndExpect(
      _LEAF_VOTER, abi.encodeCall(ILeafVoter.redeem, (_firstAmount + _secondAmount, _recipient, 0, address(0))), ''
    );

    _handler.handleEmissions(_recipients, _amounts);

    // it should clear the recipient pending amount
    assertEq(_handler.pendingRedeems(_recipient), 0);
  }
}
