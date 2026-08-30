// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {LeafEmissionsHandler} from 'V3/handlers/LeafEmissionsHandler.sol';
import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';

contract UnitLeafEmissionsHandler is TestHelpers {
  address internal immutable _LEAF_VOTER = makeAddr('LeafVoter');
  address internal immutable _RECEIPT_TOKEN = makeAddr('ReceiptToken');

  LeafEmissionsHandler internal _handler;

  /*////////////////////////////////////////////////////////////
                              SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    vm.etch(_RECEIPT_TOKEN, hex'69');
    _handler = new LeafEmissionsHandler(_LEAF_VOTER, _RECEIPT_TOKEN);
  }

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenLeafVoterIsTheZeroAddress(address _receiptToken) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IEmissionsHandler.ZeroAddress.selector);
    new LeafEmissionsHandler(address(0), _receiptToken);
  }

  function test_ConstructorWhenReceiptTokenIsTheZeroAddress(address _leafVoter) external {
    _assumeFuzzable(_leafVoter);

    // it should revert with ZeroAddress
    vm.expectRevert(IEmissionsHandler.ZeroAddress.selector);
    new LeafEmissionsHandler(_leafVoter, address(0));
  }

  function test_ConstructorWhenAllInputsAreValid(address _leafVoter, address _receiptToken) external {
    _assumeFuzzable(_leafVoter);
    _assumeFuzzable(_receiptToken);

    _handler = new LeafEmissionsHandler(_leafVoter, _receiptToken);

    // it should set LEAF_VOTER to _leafVoter
    assertEq(_handler.LEAF_VOTER(), _leafVoter);

    // it should set RECEIPT_TOKEN to _receiptToken
    assertEq(address(_handler.RECEIPT_TOKEN()), _receiptToken);
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

    // it should not call transfer on the receipt token
    vm.mockCallRevert(_RECEIPT_TOKEN, abi.encodeWithSelector(IERC20.transfer.selector), 'unexpected transfer');

    _handler.handleEmissions(_recipients, _amounts);
  }

  function test_HandleEmissionsWhenSomeAmountsAreNonzero(
    address _recipientSeed,
    uint128 _firstNonzeroAmount,
    uint128 _secondNonzeroAmount
  ) external givenTheCallerIsTheLeafVoter {
    _firstNonzeroAmount = uint128(bound(_firstNonzeroAmount, 1, type(uint128).max));
    _secondNonzeroAmount = uint128(bound(_secondNonzeroAmount, 1, type(uint128).max));

    address[] memory _recipients = new address[](3);
    _recipients[0] = _recipientSeed;
    _recipients[1] = address(uint160(uint256(uint160(_recipientSeed)) + 1));
    _recipients[2] = address(uint160(uint256(uint160(_recipientSeed)) + 2));

    uint128[] memory _amounts = new uint128[](3);
    _amounts[0] = 0;
    _amounts[1] = _firstNonzeroAmount;
    _amounts[2] = _secondNonzeroAmount;

    // it should skip recipients with a zero amount
    vm.mockCallRevert(_RECEIPT_TOKEN, abi.encodeCall(IERC20.transfer, (_recipients[0], 0)), 'unexpected transfer');

    // it should call safeTransfer on the receipt token for each nonzero amount
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IERC20.transfer, (_recipients[1], _amounts[1])), abi.encode(true));
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IERC20.transfer, (_recipients[2], _amounts[2])), abi.encode(true));

    _handler.handleEmissions(_recipients, _amounts);
  }
}
