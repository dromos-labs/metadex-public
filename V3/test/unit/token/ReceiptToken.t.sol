// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@solady/tokens/ERC20.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';
import {IBaseTokenExtensions} from 'V3/interfaces/token/IBaseTokenExtensions.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';
import {ReceiptToken} from 'V3/token/ReceiptToken.sol';

contract UnitReceiptToken is TestHelpers {
  address internal constant _PERMIT_TWO = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
  uint256 internal constant _PERMIT_OWNER_PK = 0xB0B;
  bool internal constant _UPDATE_SUPPLY = true;
  string internal constant _TOKEN_NAME = 'AERO Test Receipt Token';
  string internal constant _TOKEN_SYMBOL = 'tAERO';

  address internal immutable _LEAF_VOTER = makeAddr('Leaf Voter');

  ReceiptToken internal _receiptToken;
  address internal _permitOwner;

  function setUp() external {
    _receiptToken = new ReceiptToken(_LEAF_VOTER, _TOKEN_NAME, _TOKEN_SYMBOL);
    _permitOwner = vm.addr(_PERMIT_OWNER_PK);
    vm.label(_permitOwner, 'Receipt Permit Owner');
  }

  function test_ConstructorWhenLeafVoterIsZeroAddress(string calldata _name, string calldata _symbol) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    new ReceiptToken(address(0), _name, _symbol);
  }

  // solhint-disable-next-line ordering
  function test_ConstructorWhenParametersAreValid() external view {
    // it should set the LEAF_VOTER immutable to _leafVoter
    assertEq(_receiptToken.LEAF_VOTER(), _LEAF_VOTER);
    // it should set the name to _name
    assertEq(_receiptToken.name(), _TOKEN_NAME);
    // it should set the symbol to _symbol
    assertEq(_receiptToken.symbol(), _TOKEN_SYMBOL);
    // it should set the name hash to a hash of _name bytes
    assertEq(_receiptToken.DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(_receiptToken), _TOKEN_NAME));
  }

  // solhint-disable-next-line ordering
  function test_MintWhenCallerIsNotLeafVoter(address _caller, address _recipient, uint256 _amount) external {
    _caller = _boundNotEq(_caller, _LEAF_VOTER);
    _assumeFuzzable(_caller);

    // it should revert with NotLeafVoter
    vm.expectRevert(IReceiptToken.NotLeafVoter.selector);
    vm.prank(_caller);
    _receiptToken.mint(_recipient, _amount);
  }

  function test_MintWhenCallerIsLeafVoterAndRecipientIsZeroAddress(uint256 _amount) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    vm.prank(_LEAF_VOTER);
    _receiptToken.mint(address(0), _amount);
  }

  function test_MintWhenCallerIsLeafVoterAndTotalSupplyOverflows(address _recipient) external {
    _assumeFuzzable(_recipient);
    deal(address(_receiptToken), _recipient, type(uint256).max, _UPDATE_SUPPLY);

    // it should revert with TotalSupplyOverflow
    vm.expectRevert(ERC20.TotalSupplyOverflow.selector);
    vm.prank(_LEAF_VOTER);
    _receiptToken.mint(_recipient, 1);
  }

  function test_MintWhenCallerIsLeafVoterAndRecipientIsValid(
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, type(uint256).max - _balance);
    deal(address(_receiptToken), _recipient, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with address(0), _recipient, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(address(0), _recipient, _amount);

    vm.prank(_LEAF_VOTER);
    _receiptToken.mint(_recipient, _amount);

    // it should mint tokens to the recipient
    assertEq(_receiptToken.balanceOf(_recipient), _balance + _amount);
    // it should increase total supply by the amount
    assertEq(_receiptToken.totalSupply(), _balance + _amount);
  }

  function test_BurnWhenCallerIsNotLeafVoter(address _caller, address _from, uint256 _amount) external {
    _caller = _boundNotEq(_caller, _LEAF_VOTER);
    _assumeFuzzable(_caller);

    // it should revert with NotLeafVoter
    vm.expectRevert(IReceiptToken.NotLeafVoter.selector);
    vm.prank(_caller);
    _receiptToken.burn(_from, _amount);
  }

  function test_BurnWhenCallerIsLeafVoterAndAccountHasInsufficientBalance(address _account, uint256 _amount) external {
    _assumeFuzzable(_account);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_LEAF_VOTER);
    _receiptToken.burn(_account, _amount);
  }

  function test_BurnWhenCallerIsLeafVoterAndAccountHasEnoughBalance(
    address _account,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_account);
    _amount = bound(_amount, 0, _balance);
    deal(address(_receiptToken), _account, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _account, address(0), _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_account, address(0), _amount);

    vm.prank(_LEAF_VOTER);
    _receiptToken.burn(_account, _amount);

    // it should burn tokens from the account
    assertEq(_receiptToken.balanceOf(_account), _balance - _amount);
    // it should decrease total supply by the amount
    assertEq(_receiptToken.totalSupply(), _balance - _amount);
  }

  function test_TransferWhenRecipientIsZeroAddress(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    vm.prank(_caller);
    _receiptToken.transfer(address(0), _amount);
  }

  function test_TransferWhenCallerHasInsufficientBalance(
    address _caller,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_caller);
    _receiptToken.transfer(_recipient, _amount);
  }

  function test_TransferWhenCallerHasEnoughBalance(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, _caller);
    _amount = bound(_amount, 0, _balance);
    deal(address(_receiptToken), _caller, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _caller, _recipient, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_caller, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_receiptToken.transfer(_recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_receiptToken.balanceOf(_caller), _balance - _amount);
    assertEq(_receiptToken.balanceOf(_recipient), _amount);
    // it should keep total supply unchanged
    assertEq(_receiptToken.totalSupply(), _balance);
  }

  function test_TransferWhenRecipientIsCaller(address _caller, uint256 _balance, uint256 _amount) external {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 0, _balance);
    deal(address(_receiptToken), _caller, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _caller, _caller, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_caller, _caller, _amount);

    vm.prank(_caller);
    assertTrue(_receiptToken.transfer(_caller, _amount));

    // it should keep the caller balance unchanged
    assertEq(_receiptToken.balanceOf(_caller), _balance);
    // it should keep total supply unchanged
    assertEq(_receiptToken.totalSupply(), _balance);
  }

  function test_TransferFromWhenRecipientIsZeroAddress(address _caller, address _from, uint256 _amount) external {
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    vm.prank(_caller);
    _receiptToken.transferFrom(_from, address(0), _amount);
  }

  function test_TransferFromWhenFromAddressHasInsufficientBalance(
    address _caller,
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);
    _mockApprove(address(_receiptToken), _from, _caller, _amount);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_caller);
    _receiptToken.transferFrom(_from, _recipient, _amount);
  }

  function test_TransferFromWhenCallerHasInsufficientAllowance(
    address _caller,
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientAllowance
    vm.expectRevert(ERC20.InsufficientAllowance.selector);
    vm.prank(_caller);
    _receiptToken.transferFrom(_from, _recipient, _amount);
  }

  function test_TransferFromWhenCallerIsPermitTwoAndNoApprovalHasBeenGiven(
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientAllowance
    vm.expectRevert(ERC20.InsufficientAllowance.selector);
    vm.prank(_PERMIT_TWO);
    _receiptToken.transferFrom(_from, _recipient, _amount);
  }

  modifier whenCallerHasFiniteAllowance() {
    _;
  }

  function test_TransferFromWhenFiniteAllowanceRecipientIsNotFrom(
    address _caller,
    address _from,
    address _recipient,
    uint256 _balance,
    uint256 _allowance,
    uint256 _amount
  ) external whenCallerHasFiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != _from);
    _allowance = bound(_allowance, 0, type(uint256).max - 1);
    uint256 _maxAmount = _balance < _allowance ? _balance : _allowance;
    _amount = bound(_amount, 0, _maxAmount);
    deal(address(_receiptToken), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_receiptToken), _from, _caller, _allowance);

    // it should emit Transfer with _from, _recipient, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_from, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_receiptToken.transferFrom(_from, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_receiptToken.balanceOf(_from), _balance - _amount);
    assertEq(_receiptToken.balanceOf(_recipient), _amount);
    // it should decrease the caller allowance
    assertEq(_receiptToken.allowance(_from, _caller), _allowance - _amount);
    // it should keep total supply unchanged
    assertEq(_receiptToken.totalSupply(), _balance);
  }

  function test_TransferFromWhenFiniteAllowanceRecipientIsFrom(
    address _caller,
    address _from,
    uint256 _balance,
    uint256 _allowance,
    uint256 _amount
  ) external whenCallerHasFiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _allowance = bound(_allowance, 0, type(uint256).max - 1);
    uint256 _maxAmount = _balance < _allowance ? _balance : _allowance;
    _amount = bound(_amount, 0, _maxAmount);
    deal(address(_receiptToken), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_receiptToken), _from, _caller, _allowance);

    // it should emit Transfer with _from, _from, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_from, _from, _amount);

    vm.prank(_caller);
    assertTrue(_receiptToken.transferFrom(_from, _from, _amount));

    // it should keep the from balance unchanged
    assertEq(_receiptToken.balanceOf(_from), _balance);
    // it should decrease the caller allowance
    assertEq(_receiptToken.allowance(_from, _caller), _allowance - _amount);
    // it should keep total supply unchanged
    assertEq(_receiptToken.totalSupply(), _balance);
  }

  modifier whenCallerHasInfiniteAllowance() {
    _;
  }

  function test_TransferFromWhenInfiniteAllowanceRecipientIsNotFrom(
    address _caller,
    address _from,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external whenCallerHasInfiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != _from);
    _amount = bound(_amount, 0, _balance);
    deal(address(_receiptToken), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_receiptToken), _from, _caller, type(uint256).max);

    // it should emit Transfer with _from, _recipient, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_from, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_receiptToken.transferFrom(_from, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_receiptToken.balanceOf(_from), _balance - _amount);
    assertEq(_receiptToken.balanceOf(_recipient), _amount);
    // it should keep the caller allowance unchanged
    assertEq(_receiptToken.allowance(_from, _caller), type(uint256).max);
    // it should keep total supply unchanged
    assertEq(_receiptToken.totalSupply(), _balance);
  }

  function test_TransferFromWhenInfiniteAllowanceRecipientIsFrom(
    address _caller,
    address _from,
    uint256 _balance,
    uint256 _amount
  ) external whenCallerHasInfiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _amount = bound(_amount, 0, _balance);
    deal(address(_receiptToken), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_receiptToken), _from, _caller, type(uint256).max);

    // it should emit Transfer with _from, _from, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Transfer(_from, _from, _amount);

    vm.prank(_caller);
    assertTrue(_receiptToken.transferFrom(_from, _from, _amount));

    // it should keep the from balance unchanged
    assertEq(_receiptToken.balanceOf(_from), _balance);
    // it should keep the caller allowance unchanged
    assertEq(_receiptToken.allowance(_from, _caller), type(uint256).max);
    // it should keep total supply unchanged
    assertEq(_receiptToken.totalSupply(), _balance);
  }

  function test_ApproveWhenCalled(address _owner, address _spender, uint256 _amount) external {
    _assumeFuzzable(_owner);

    // it should emit Approval with _owner, _spender, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Approval(_owner, _spender, _amount);

    vm.prank(_owner);
    _receiptToken.approve(_spender, _amount);

    // it should approve the spender
    assertEq(_receiptToken.allowance(_owner, _spender), _amount);
  }

  function test_ApproveWhenSpenderIsPermitTwo(address _owner, uint256 _amount) external {
    _assumeFuzzable(_owner);

    // it should emit Approval with _owner, PermitTwo, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Approval(_owner, _PERMIT_TWO, _amount);

    vm.prank(_owner);
    _receiptToken.approve(_PERMIT_TWO, _amount);

    // it should approve PermitTwo
    assertEq(_receiptToken.allowance(_owner, _PERMIT_TWO), _amount);
  }

  // solhint-disable-next-line ordering
  function test_AllowanceWhenSpenderIsPermitTwoAndNoApprovalHasBeenGiven(address _owner) external view {
    // it should return zero
    assertEq(_receiptToken.allowance(_owner, _PERMIT_TWO), 0);
  }

  function test_AllowanceWhenSpenderIsPermitTwoAndApprovalHasBeenGiven(address _owner, uint256 _amount) external {
    _mockApprove(address(_receiptToken), _owner, _PERMIT_TWO, _amount);

    // it should return its allowance
    assertEq(_receiptToken.allowance(_owner, _PERMIT_TWO), _amount);
  }

  function test_AllowanceWhenSpenderIsAnyNonPermitTwoAddressAndNoApprovalHasBeenGiven(
    address _owner,
    address _spender
  ) external {
    _spender = _boundNotEq(_spender, _PERMIT_TWO);

    // it should return zero
    assertEq(_receiptToken.allowance(_owner, _spender), 0);
  }

  function test_AllowanceWhenSpenderIsAnyNonPermitTwoAddressAndApprovalHasBeenGiven(
    address _owner,
    address _spender,
    uint256 _amount
  ) external {
    _spender = _boundNotEq(_spender, _PERMIT_TWO);
    _mockApprove(address(_receiptToken), _owner, _spender, _amount);

    // it should return its allowance
    assertEq(_receiptToken.allowance(_owner, _spender), _amount);
  }

  function test_PermitWhenDeadlineHasExpired(address _spender, uint256 _amount, uint256 _deadline) external {
    vm.warp(1 days);
    _deadline = bound(_deadline, 0, block.timestamp - 1);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_receiptToken), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    // it should revert with PermitExpired
    vm.expectRevert(ERC20.PermitExpired.selector);
    _receiptToken.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);
  }

  function test_PermitWhenSignatureIsInvalid(
    address _spender,
    address _invalidSpender,
    uint256 _amount,
    uint256 _deadline
  ) external {
    _invalidSpender = _boundNotEq(_invalidSpender, _spender);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_receiptToken), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    // it should revert with InvalidPermit
    vm.expectRevert(ERC20.InvalidPermit.selector);
    _receiptToken.permit(_permitOwner, _invalidSpender, _amount, _deadline, _v, _r, _s);
  }

  function test_PermitWhenSignatureIsReplayed(address _spender, uint256 _amount, uint256 _deadline) external {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_receiptToken), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    _receiptToken.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);

    // it should revert with InvalidPermit
    vm.expectRevert(ERC20.InvalidPermit.selector);
    _receiptToken.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);
  }

  function test_PermitWhenSpenderIsPermitTwoAndSignatureIsValid(uint256 _amount, uint256 _deadline) external {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_receiptToken), _PERMIT_OWNER_PK, _permitOwner, _PERMIT_TWO, _amount, _deadline);

    // it should emit Approval with _permitOwner, PermitTwo, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Approval(_permitOwner, _PERMIT_TWO, _amount);

    _receiptToken.permit(_permitOwner, _PERMIT_TWO, _amount, _deadline, _v, _r, _s);

    // it should approve PermitTwo
    assertEq(_receiptToken.allowance(_permitOwner, _PERMIT_TWO), _amount);
    // it should increment the owner nonce
    assertEq(_receiptToken.nonces(_permitOwner), 1);
  }

  function test_PermitWhenSpenderIsNotPermitTwoAndSignatureIsValid(
    address _spender,
    uint256 _amount,
    uint256 _deadline
  ) external {
    _spender = _boundNotEq(_spender, _PERMIT_TWO);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_receiptToken), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    // it should emit Approval with _permitOwner, _spender, _amount
    _expectEmit(address(_receiptToken));
    emit IERC20.Approval(_permitOwner, _spender, _amount);

    _receiptToken.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);

    // it should approve the spender
    assertEq(_receiptToken.allowance(_permitOwner, _spender), _amount);
    // it should increment the owner nonce
    assertEq(_receiptToken.nonces(_permitOwner), 1);
  }

  function test_DOMAIN_SEPARATORWhenCalled() external view {
    // it should return the expected domain separator
    assertEq(_receiptToken.DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(_receiptToken), _TOKEN_NAME));
  }

  function test_NameWhenCalled() external view {
    // it should return the token name
    assertEq(_receiptToken.name(), _TOKEN_NAME);
  }

  function test_SymbolWhenCalled() external view {
    // it should return the token symbol
    assertEq(_receiptToken.symbol(), _TOKEN_SYMBOL);
  }
}
