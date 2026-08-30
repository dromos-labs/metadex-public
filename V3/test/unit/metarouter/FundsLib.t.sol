// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

import {FundsLibHarness} from 'V3-test/unit/metarouter/harnesses/FundsLibHarness.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Unit tests for the shared FundsLib funding and balance-resolution helpers.
contract UnitFundsLib is TestHelpers {
  /// @notice Native units per native ERC20 unit for the lower-decimals native ERC20 scenarios, the stablecoin-native shape
  ///         where a six-decimal ERC20 mirrors the eighteen-decimal native asset.
  uint256 internal constant _NATIVE_ERC20_SCALE = 1e12;

  /// @notice Logical sender the harness seeds, distinct from the execution (harness) address.
  address internal immutable _SENDER = makeAddr('logicalSender');

  FundsLibHarness internal _harness;
  /// @notice Shared mocked ERC20 the helpers move around.
  address internal _token;
  /// @notice Spend mode fixed by the spend-mode modifiers.
  IMetarouter.SpendMode internal _mode;
  /// @notice Whether the command requested external funding; set true by `givenThePayerIsExternal`.
  bool internal _payerIsUser;

  function setUp() public {
    _harness = new FundsLibHarness();
    _token = _mockContract('token');
  }

  // --- push ---

  function test_PushWhenTheRecipientIsAnyAddress(address _recipient, uint256 _amount) external {
    // Recipient is fuzzed across all valid addresses, including the execution address, to prove the push path never
    // tracks regardless of where it sends: pushing the router's own balance out never grows custody.
    _assumeFuzzable(_recipient);
    // it should transfer _amount to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, _amount);

    _harness.push(_token, _recipient, _amount);

    // it should not track _token
    assertEq(_harness.trackedTokens().length, 0);
  }

  /// @notice The native ERC20 resolves against the batch's own native, never the native ERC20's `balanceOf`, so one unit
  ///         above the batch balance is rejected before any transfer is attempted.
  function test_PushWhenTheNativeMirrorAmountExceedsTheBatchBalance() external {
    address _recipient = makeAddr('recipient');
    uint256 _nativeBalanceBefore = 1000;
    uint256 _batchBalance = 100;
    uint256 _amount = _batchBalance + 1;
    vm.deal(address(_harness), _nativeBalanceBefore + _batchBalance);
    _harness.seedNativeAccounting(_nativeBalanceBefore, _token, 1);
    // If the shared boundary did not reject the amount first, the token's transfer revert would surface instead.
    vm.mockCallRevert(_token, abi.encodeCall(IERC20.transfer, (_recipient, _amount)), bytes('transfer attempted'));

    // it should revert with InsufficientBalance for the native mirror token
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _harness.push(_token, _recipient, _amount);
  }

  /// @notice Pins the boundary of the strict comparator in `push`: an amount exactly equal to the batch-available
  ///         balance is not rejected and transfers in full.
  function test_PushWhenTheNativeMirrorAmountEqualsTheBatchBalance(
    address _recipient,
    uint256 _nativeBalanceBefore,
    uint256 _batchBalance
  ) external {
    _assumeFuzzable(_recipient);
    _nativeBalanceBefore = bound(_nativeBalanceBefore, 0, type(uint128).max);
    _batchBalance = bound(_batchBalance, 1, type(uint128).max);
    vm.deal(address(_harness), _nativeBalanceBefore + _batchBalance);
    _harness.seedNativeAccounting(_nativeBalanceBefore, _token, 1);

    // it should transfer the amount
    _mockAndExpectTokenTransfer(_token, _recipient, _batchBalance);
    _harness.push(_token, _recipient, _batchBalance);

    // it should not track the token
    assertEq(_harness.trackedTokens().length, 0);
  }

  /// @notice On a lower-decimals native ERC20 the batch's own native floors to the native ERC20 decimals, so one raw native ERC20 unit
  ///         above that floor is rejected even when a sub-raw-unit batch remainder is left over: the extra unit
  ///         would spend pre-batch native.
  function test_PushWhenALowerDecimalsMirrorAmountExceedsTheBatchNativeFlooredToTheMirrorDecimals(
    address _recipient,
    uint256 _preBatchWholeAmount,
    uint256 _preBatchRemainder,
    uint256 _batchAmount,
    uint256 _batchRemainder
  ) external {
    _assumeFuzzable(_recipient);
    _preBatchWholeAmount = bound(_preBatchWholeAmount, 0, type(uint64).max);
    // A sub-raw-unit pre-batch remainder proves the snapshot no longer rounds up to another raw native ERC20 unit.
    _preBatchRemainder = bound(_preBatchRemainder, 1, _NATIVE_ERC20_SCALE - 1);
    _batchAmount = bound(_batchAmount, 0, type(uint64).max);
    // A sub-raw-unit batch remainder is floored away and never unlocks another raw native ERC20 unit.
    _batchRemainder = bound(_batchRemainder, 0, _NATIVE_ERC20_SCALE - 1);
    uint256 _nativeBalanceBefore = _preBatchWholeAmount * _NATIVE_ERC20_SCALE + _preBatchRemainder;
    vm.deal(address(_harness), _nativeBalanceBefore + _batchAmount * _NATIVE_ERC20_SCALE + _batchRemainder);
    _harness.seedNativeAccounting(_nativeBalanceBefore, _token, _NATIVE_ERC20_SCALE);
    // One unit above the batch native floored to the native ERC20 decimals.
    uint256 _amount = _batchAmount + 1;
    // If the shared boundary did not reject the amount first, the token's transfer revert would surface instead.
    vm.mockCallRevert(_token, abi.encodeCall(IERC20.transfer, (_recipient, _amount)), bytes('transfer attempted'));

    // it should revert with InsufficientBalance for the native mirror token
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _harness.push(_token, _recipient, _amount);
  }

  /// @notice Every raw native ERC20 unit the batch's native introduced stays spendable through the boundary. With a
  ///         fractional pre-batch remainder this pins the fixed bug: the removed ceil-based accounting rounded the
  ///         snapshot up and hid one batch-introduced raw unit, which the floor of the batch native now keeps
  ///         spendable.
  function test_PushWhenALowerDecimalsMirrorAmountFitsTheBatchNativeFlooredToTheMirrorDecimals(
    address _recipient,
    uint256 _preBatchWholeAmount,
    uint256 _preBatchRemainder,
    uint256 _batchAmount,
    uint256 _batchRemainder
  ) external {
    _assumeFuzzable(_recipient);
    _preBatchWholeAmount = bound(_preBatchWholeAmount, 0, type(uint64).max);
    _preBatchRemainder = bound(_preBatchRemainder, 1, _NATIVE_ERC20_SCALE - 1);
    _batchAmount = bound(_batchAmount, 1, type(uint64).max);
    _batchRemainder = bound(_batchRemainder, 0, _NATIVE_ERC20_SCALE - 1);
    uint256 _nativeBalanceBefore = _preBatchWholeAmount * _NATIVE_ERC20_SCALE + _preBatchRemainder;
    vm.deal(address(_harness), _nativeBalanceBefore + _batchAmount * _NATIVE_ERC20_SCALE + _batchRemainder);
    _harness.seedNativeAccounting(_nativeBalanceBefore, _token, _NATIVE_ERC20_SCALE);

    // it should transfer the amount
    _mockAndExpectTokenTransfer(_token, _recipient, _batchAmount);
    _harness.push(_token, _recipient, _batchAmount);

    // it should not track the token
    assertEq(_harness.trackedTokens().length, 0);
  }

  // --- pull ---

  function test_PullWhenPullingFromTheLogicalSender(uint256 _amount) external {
    // it should pull _amount from the logical sender to the execution address
    _mockAndExpect(_token, abi.encodeCall(IERC20.transferFrom, (_SENDER, address(_harness), _amount)), abi.encode(true));

    _harness.pull(_SENDER, _token, _amount);

    // it should track _token
    address[] memory _tracked = _harness.trackedTokens();
    assertEq(_tracked.length, 1);
    assertEq(_tracked[0], _token);
  }

  // --- pay ---

  function test_PayWhenThePayerIsTheExecutionAddress(address _recipient, uint256 _amount) external {
    _assumeFuzzable(_recipient);
    // it should transfer _amount to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, _amount);

    _harness.pay(_SENDER, _token, address(_harness), _recipient, _amount);

    // it should not track _token
    assertEq(_harness.trackedTokens().length, 0);
  }

  function test_PayWhenThePayerIsTheLogicalSender(address _recipient, uint256 _amount) external {
    _assumeFuzzable(_recipient);
    // it should transfer _amount from the logical sender to _recipient
    _mockAndExpect(_token, abi.encodeCall(IERC20.transferFrom, (_SENDER, _recipient, _amount)), abi.encode(true));

    _harness.pay(_SENDER, _token, _SENDER, _recipient, _amount);

    // it should not track _token
    assertEq(_harness.trackedTokens().length, 0);
  }

  function test_PayWhenThePayerIsNeitherTheExecutionAddressNorTheLogicalSender(
    address _payer,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_payer);
    _payer = _boundNotEq(_payer, address(_harness));
    _payer = _boundNotEq(_payer, _SENDER);

    // it should revert with InvalidPayer
    vm.expectRevert(IMetarouter.InvalidPayer.selector);
    _harness.pay(_SENDER, _token, _payer, _recipient, _amount);
  }

  function test_PayWhenThePayerIsTheZeroAddressAndTheLogicalSenderIsUnset(
    address _recipient,
    uint256 _amount
  ) external {
    // An unset logical sender resolves to the zero address, which must never authorize a pull.
    // it should revert with InvalidPayer
    vm.expectRevert(IMetarouter.InvalidPayer.selector);
    _harness.pay(address(0), _token, address(0), _recipient, _amount);
  }

  // --- fund ---

  modifier givenThePayerIsExternal() {
    _payerIsUser = true;
    _;
  }

  function test_FundWhenTheSpendModeIsNotAmount(uint256 _value) external givenThePayerIsExternal {
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _value});

    // it should revert with InvalidSpendMode
    vm.expectRevert(IMetarouter.InvalidSpendMode.selector);
    _harness.fund(_SENDER, _token, _spend, _payerIsUser);
  }

  modifier givenTheSpendModeIsAmount() {
    _mode = IMetarouter.SpendMode.Amount;
    _;
  }

  function test_FundWhenTheTransferDeliversTheFullAmount(
    uint256 _value,
    uint256 _balanceBefore
  ) external givenThePayerIsExternal givenTheSpendModeIsAmount {
    _balanceBefore = bound(_balanceBefore, 0, type(uint256).max - _value);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    // The full requested amount lands: balance rises by exactly _value.
    _mockAndExpectTokenBalancesTwice(_token, address(_harness), [_balanceBefore, _balanceBefore + _value]);
    _mockAndExpect(_token, abi.encodeCall(IERC20.transferFrom, (_SENDER, address(_harness), _value)), abi.encode(true));

    // it should return _spend.value as _amount
    assertEq(_harness.fund(_SENDER, _token, _spend, _payerIsUser), _value);
  }

  function test_FundWhenTheTokenChargesAFeeOnTransfer(
    uint256 _value,
    uint256 _received,
    uint256 _balanceBefore
  ) external givenThePayerIsExternal givenTheSpendModeIsAmount {
    _value = bound(_value, 1, type(uint256).max);
    // A fee-on-transfer token delivers strictly less than requested.
    _received = bound(_received, 0, _value - 1);
    _balanceBefore = bound(_balanceBefore, 0, type(uint256).max - _received);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    _mockAndExpectTokenBalancesTwice(_token, address(_harness), [_balanceBefore, _balanceBefore + _received]);
    _mockAndExpect(_token, abi.encodeCall(IERC20.transferFrom, (_SENDER, address(_harness), _value)), abi.encode(true));

    // it should return the received balance delta as _amount
    assertEq(_harness.fund(_SENDER, _token, _spend, _payerIsUser), _received);
  }

  function test_FundWhenThePayerIsNotExternal(uint256 _balance, uint256 _value) external {
    _value = bound(_value, 0, _balance);
    IMetarouter.BalanceSpend memory _spend =
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _value});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should resolve _spend against the execution address balance as _amount
    assertEq(_harness.fund(_SENDER, _token, _spend, false), _value);
    // it should track _token
    address[] memory _tracked = _harness.trackedTokens();
    assertEq(_tracked.length, 1);
    assertEq(_tracked[0], _token);
  }

  // --- resolveSpend ---

  function test_ResolveSpendWhenTheRequestedValueExceedsTheBalance(
    uint256 _balance,
    uint256 _value
  ) external givenTheSpendModeIsAmount {
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _value = bound(_value, _balance + 1, type(uint256).max);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should revert with InsufficientBalance for _asset
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _harness.resolveSpend(_token, _spend);
  }

  function test_ResolveSpendWhenTheRequestedValueIsWithinTheBalance(
    uint256 _balance,
    uint256 _value
  ) external givenTheSpendModeIsAmount {
    _value = bound(_value, 0, _balance);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should return _spend.value as _amount
    assertEq(_harness.resolveSpend(_token, _spend), _value);
  }

  /// @notice Pins that `resolveSpend` resolves the native ERC20 against the batch's own native, never the native ERC20's
  ///         `balanceOf`: a request above the batch balance reverts even though the raw native ERC20 balance, which is the
  ///         whole native, covers it.
  function test_ResolveSpendWhenTheRequestedMirrorValueExceedsTheBatchBalanceWithinTheRawMirrorBalance(
    uint256 _preBatch,
    uint256 _batch,
    uint256 _value
  ) external givenTheSpendModeIsAmount {
    _preBatch = bound(_preBatch, 1, type(uint128).max);
    _batch = bound(_batch, 0, type(uint128).max);
    // The request overshoots the batch balance but stays within the raw native ERC20 balance (the whole native).
    _value = bound(_value, _batch + 1, _preBatch + _batch);
    vm.deal(address(_harness), _preBatch + _batch);
    _harness.seedNativeAccounting(_preBatch, _token, 1);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    // it should revert with InsufficientBalance for the native mirror token
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _harness.resolveSpend(_token, _spend);
  }

  /// @notice Pins the equality boundary of the native ERC20 resolution: requesting exactly the batch-available
  ///         balance succeeds and returns it.
  function test_ResolveSpendWhenTheRequestedMirrorValueEqualsTheBatchBalance(
    uint256 _preBatch,
    uint256 _batch
  ) external givenTheSpendModeIsAmount {
    _preBatch = bound(_preBatch, 1, type(uint128).max);
    _batch = bound(_batch, 0, type(uint128).max);
    vm.deal(address(_harness), _preBatch + _batch);
    _harness.seedNativeAccounting(_preBatch, _token, 1);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _batch});

    // it should return the batch balance as _amount
    assertEq(_harness.resolveSpend(_token, _spend), _batch);
  }

  modifier givenTheSpendModeIsPips() {
    _mode = IMetarouter.SpendMode.Pips;
    _;
  }

  function test_ResolveSpendWhenThePipValueExceedsTheDenominator(
    uint256 _balance,
    uint256 _value
  ) external givenTheSpendModeIsPips {
    _value = bound(_value, MAX_PIPS + 1, type(uint256).max);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should revert with InvalidPips for _spend.value
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPips.selector, _value));
    _harness.resolveSpend(_token, _spend);
  }

  modifier givenThePipValueIsWithinTheDenominator() {
    _;
  }

  function test_ResolveSpendWhenThePipProportionIsPositive(uint256 _balance)
    external
    givenTheSpendModeIsPips
    givenThePipValueIsWithinTheDenominator
  {
    // 50% of an even balance is exactly half — computed independently of the mulDiv formula.
    _balance = bound(_balance, 1, type(uint256).max / 2);
    _balance *= 2;
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: MAX_PIPS / 2});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should return the pip proportion of _balance as _amount
    assertEq(_harness.resolveSpend(_token, _spend), _balance / 2);
  }

  function test_ResolveSpendWhenThePipProportionRoundsDownToZero(
    uint256 _balance,
    uint256 _value
  ) external givenTheSpendModeIsPips givenThePipValueIsWithinTheDenominator {
    _value = bound(_value, 1, MAX_PIPS - 1);
    // balance * value < MAX_PIPS, so the floored proportion is zero.
    _balance = bound(_balance, 0, (MAX_PIPS - 1) / _value);
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: _value});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should return zero as _amount
    assertEq(_harness.resolveSpend(_token, _spend), 0);
  }

  function test_ResolveSpendWhenThePipValueEqualsTheDenominator(uint256 _balance)
    external
    givenTheSpendModeIsPips
    givenThePipValueIsWithinTheDenominator
  {
    // 100% selects the entire balance.
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: MAX_PIPS});

    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should return _balance as _amount
    assertEq(_harness.resolveSpend(_token, _spend), _balance);
  }

  function test_ResolveSpendWhenUsingAKnownRoundedDownExample()
    external
    givenTheSpendModeIsPips
    givenThePipValueIsWithinTheDenominator
  {
    // 333333 pips (33.3333%) of a balance of 1000: 1000 * 333333 / 1_000_000 = 333.333, floored to 333.
    IMetarouter.BalanceSpend memory _spend = IMetarouter.BalanceSpend({mode: _mode, value: 333_333});

    _mockAndExpectTokenBalance(_token, address(_harness), 1000);

    // it should return the hand computed floored proportion as _amount
    assertEq(_harness.resolveSpend(_token, _spend), 333);
  }
}
