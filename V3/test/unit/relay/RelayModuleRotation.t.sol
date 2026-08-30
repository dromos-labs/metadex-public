// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

/// @notice Every unit of weight enters and leaves a Relay through the VoterPaymentsModule, and the
///         escrow authorizes modules by role, so the module a Relay was deployed on can stop being
///         one and take the deposit and withdrawal lanes with it. The keeper can move the Relay to
///         another module the escrow authorizes; it never decides what is authorized.
contract UnitRelayModuleRotation is BaseRelay {
  address internal _newVpm;

  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
    _newVpm = _mockContract('ReplacementModule');
    _mockModuleAuthorization(_newVpm, true);
  }

  /// @notice The lane is keeper-gated, like the other operational paths on the Relay.
  function test_WhenTheCallerIsNotTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _keeper);

    // it should revert with Unauthorized
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(_caller);
    _relay.setVoterPaymentsModule(IVoterPaymentsModule(_newVpm));
  }

  /// @notice Zero would make both lanes fail on the next call, so it is refused ahead of the escrow read.
  function test_WhenTheNamedModuleIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IRelay.ZeroAddress.selector);
    vm.prank(_keeper);
    _relay.setVoterPaymentsModule(IVoterPaymentsModule(address(0)));
  }

  /// @notice The escrow's authorization set is what bounds the keeper's choice.
  function test_WhenTheEscrowDoesNotAuthorizeTheNamedModule(address _module) external {
    _assumeFuzzable(_module);
    // Naming the module already in use returns before any check, so it is a different branch.
    vm.assume(_module != _vpm);
    _mockModuleAuthorization(_module, false);

    // it should revert with ModuleNotAuthorized
    vm.expectRevert(IRelay.ModuleNotAuthorized.selector);
    vm.prank(_keeper);
    _relay.setVoterPaymentsModule(IVoterPaymentsModule(_module));
  }

  /// @notice Re-naming the module in use is a no-op, so it never re-approves or re-emits.
  function test_WhenTheNamedModuleIsTheOneAlreadyInUse() external {
    // it should leave the approval untouched
    vm.expectCall(_votingEscrow, abi.encodeCall(IERC721.approve, (_vpm, _RELAY_TOKEN_ID)), 0);
    vm.prank(_keeper);
    _relay.setVoterPaymentsModule(IVoterPaymentsModule(_vpm));

    assertEq(address(_relay.VPM()), _vpm);
  }

  /// @notice The move hands the spending right over and every later weight move follows it. The
  ///         escrow's approval holds one address, so the outgoing module loses it in the same call.
  function test_WhenTheKeeperMovesToAnAuthorizedModule() external {
    // it should hand the new module the sAERO approval
    _mockAndExpect(_votingEscrow, abi.encodeCall(IERC721.approve, (_newVpm, _RELAY_TOKEN_ID)), bytes(''));

    // it should emit VoterPaymentsModuleSet
    _expectEmit(address(_relay));
    emit IRelay.VoterPaymentsModuleSet(_newVpm);

    vm.prank(_keeper);
    _relay.setVoterPaymentsModule(IVoterPaymentsModule(_newVpm));

    assertEq(address(_relay.VPM()), _newVpm);

    // it should route later deposits through the new module
    _vpm = _newVpm;
    _admitDeposit(users.alice, 1, 100e18);
    assertEq(_principalToken.balanceOf(users.alice), 100e18);
  }

  /// @dev Mock the escrow's verdict on a payment module.
  function _mockModuleAuthorization(address _module, bool _authorized) internal {
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_module)), abi.encode(_authorized));
  }
}
