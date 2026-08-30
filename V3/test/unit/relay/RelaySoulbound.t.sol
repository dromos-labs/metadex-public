// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/// @notice Coverage of a MaxiRelay deployed with `ytTransferable = false`: both satellites are
///         soulbound (every holder-initiated move reverts, `permit` included), while the
///         relay-driven lifecycle — deposit admission, withdraw escrow and the drain's pair burn —
///         keeps working untouched.
/// @dev    Concrete stateful stories, mirroring the transferable lifecycle suite; see its dev note
///         for why these are not fuzzed. `_assertPairInvariant` runs after every step. The one case
///         that redeploys transferable is the control the two soulbound `permit` cases are read
///         against: it is what shows the gate follows the switch instead of banning permits outright.
contract UnitRelaySoulbound is BaseRelay {
  function setUp() public override {
    super.setUp();
    _deployMaxi(false);
  }

  /// @notice The deploy switch lands on the clones: with `ytTransferable = false` both satellites
  ///         read back soulbound.
  function test_GivenASoulboundDeployment() external view {
    // it should deploy the PT soulbound (always) and the YT soulbound (the deploy switch)
    assertFalse(_principalToken.transferable());
    assertFalse(_yieldToken.transferable());
    // it should still pair mint the bootstrap
    assertEq(_principalToken.balanceOf(_bootstrapOwner), _SEED);
    assertEq(_yieldToken.balanceOf(_bootstrapOwner), _SEED);
    _assertPairInvariant();
  }

  /// @notice Every holder-initiated YT move reverts on the soulbound clone, `transferFrom`
  ///         included (Permit2's standing infinite allowance is no bypass: the gate runs first).
  function test_WhenTransferringTheSoulboundYieldToken() external {
    _admitDeposit(users.alice, 2, 100e18);

    // it should revert with TokenNotTransferable on transfer
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    vm.prank(users.alice);
    _yieldToken.transfer(users.bob, 1e18);

    // it should revert with TokenNotTransferable on transferFrom
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    vm.prank(users.bob);
    _yieldToken.transferFrom(users.alice, users.bob, 1e18);
  }

  /// @notice The PT never transfers holder-to-holder, on this tier like on every other.
  function test_WhenTransferringTheSoulboundPrincipalToken() external {
    _admitDeposit(users.alice, 2, 100e18);

    // it should revert with TokenNotTransferable on transfer
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    vm.prank(users.alice);
    _principalToken.transfer(users.bob, 1e18);

    // it should revert with TokenNotTransferable on transferFrom
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    vm.prank(users.bob);
    _principalToken.transferFrom(users.alice, users.bob, 1e18);
  }

  /// @notice A permit for a soulbound clone would grant an allowance nothing can spend, so the gate
  ///         costs nobody anything. Letting it through would not be free, though: Solady keeps one
  ///         nonce counter per owner and spends it from both `permit` and `delegateBySig`.
  function test_WhenPermittingTheSoulboundYieldToken() external {
    (address _holder, uint256 _key) = makeAddrAndKey('ytHolder');
    address _spender = makeAddr('ytSpender');
    (uint8 _v, bytes32 _r, bytes32 _s) = _signPermit(_yieldToken, _key, _holder, _spender);

    // it should revert with TokenNotTransferable
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    _yieldToken.permit(_holder, _spender, _PERMIT_VALUE, type(uint256).max, _v, _r, _s);
  }

  /// @notice The PT is where the shared nonce bites: it is soulbound on every deployment, so its
  ///         permits are always dead, and its nonce is the one `delegateBySig` spends. A permit that
  ///         went through would cancel an outstanding delegation, which makes a signature that looks
  ///         inert into a phishing lever. The gate leaves the nonce where governance needs it.
  function test_WhenPermittingTheSoulboundPrincipalToken() external {
    (address _holder, uint256 _key) = makeAddrAndKey('ptHolder');
    address _spender = makeAddr('ptSpender');
    address _delegatee = makeAddr('delegatee');
    uint256 _nonce = _principalToken.nonces(_holder);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signPermit(_principalToken, _key, _holder, _spender);

    // it should revert with TokenNotTransferable
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    _principalToken.permit(_holder, _spender, _PERMIT_VALUE, type(uint256).max, _v, _r, _s);

    // it should leave the shared nonce untouched
    assertEq(_principalToken.nonces(_holder), _nonce);

    // it should leave a delegation signed at that nonce spendable
    (uint8 _dv, bytes32 _dr, bytes32 _ds) = _signDelegation(_principalToken, _key, _delegatee, _nonce);
    _principalToken.delegateBySig(_delegatee, _nonce, type(uint256).max, _dv, _dr, _ds);
    assertEq(_principalToken.delegates(_holder), _delegatee);
  }

  /// @notice The control case: the gate reads the switch, it is not a blanket ban. On a transferable
  ///         clone the allowance a permit grants is one `transferFrom` can actually spend, so the
  ///         call goes through and EIP-2612 keeps working.
  function test_WhenPermittingATransferableYieldToken() external {
    _deployMaxi(true);
    (address _holder, uint256 _key) = makeAddrAndKey('ytHolder');
    address _spender = makeAddr('ytSpender');
    (uint8 _v, bytes32 _r, bytes32 _s) = _signPermit(_yieldToken, _key, _holder, _spender);

    // it should set the allowance
    _yieldToken.permit(_holder, _spender, _PERMIT_VALUE, type(uint256).max, _v, _r, _s);
    assertEq(_yieldToken.allowance(_holder, _spender), _PERMIT_VALUE);
  }

  /// @notice The relay-driven lifecycle is untouched by the soulbound switch: mint/burn are
  ///         relay-only paths, so deposit -> withdraw still flows end to end.
  function test_WhenRunningTheLifecycleSoulbound() external {
    // Admission at the 1:1 seed ratio pair-mints 40e18 to bob.
    uint256 _shares = _admitDeposit(users.bob, 2, 40e18);
    assertEq(_shares, 40e18);
    assertEq(_principalToken.balanceOf(users.bob), 40e18);
    assertEq(_yieldToken.balanceOf(users.bob), 40e18);

    // Escrow a partial exit; the pair stays on the holder, locked in place.
    vm.prank(users.bob);
    _relay.registerOnWithdrawQueue(30e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(users.bob), 30e18);
    _assertPairInvariant();

    // Drain: 30e18 shares at the 1:1 ratio leave for a freshly minted sAERO.
    _mockWithdrawRoute(users.bob, 30e18, 888);
    _relay.processWithdrawals(1);

    // it should pair burn the escrowed shares and zero the escrow
    assertEq(_principalToken.balanceOf(users.bob), 10e18);
    assertEq(_yieldToken.balanceOf(users.bob), 10e18);
    assertEq(_relay.escrowedShares(users.bob), 0);
    assertEq(_relay.pendingWithdrawalShares(), 0);
    // it should debit the supply and the backing by the drained amount
    assertEq(_principalToken.totalSupply(), 110e18);
    assertEq(_relay.totalBacking(), 110e18);
    _assertPairInvariant();
  }
}
