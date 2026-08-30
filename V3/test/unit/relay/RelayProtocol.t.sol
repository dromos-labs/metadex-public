// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {Vm} from 'forge-std/Vm.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';
import {ProtocolRelaySeamsHarness} from 'V3-test/unit/relay/harnesses/ProtocolRelaySeamsHarness.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/// @notice Coverage of the Protocol tier: the soulbound-YT requirement at initialization, the
///         allow-list deposit gate and the kick story — settled rewards left claimable, the FULL
///         free pair escrowed into the withdraw queue and the drain completing the ejection.
/// @dev    Concrete stateful stories, mirroring the Maxi lifecycle suite; see its dev note for why
///         these are not fuzzed. `_assertPairInvariant` runs after every step.
contract UnitRelayProtocol is BaseRelay {
  function setUp() public override {
    super.setUp();
    _deployProtocol(false);
  }

  /// @notice The tier guard lives in `initialize` (not the factory): a ProtocolRelay deployed with
  ///         a transferable YT would make kick's allow-list eviction a no-op, so it must revert.
  function test_WhenTheYieldTokenWouldBeTransferable() external {
    _deployProtocolUninitialized();
    _mockInitializeChoreography();

    // it should revert with TransferableYieldTokenNotAllowed
    vm.expectRevert(IRelay.TransferableYieldTokenNotAllowed.selector);
    _relay.initialize(_defaultInitParams(true));
  }

  /// @notice Genesis wiring of the kicking tier: both satellites soulbound and the bootstrap-share
  ///         owner allow-listed so its seeded position works from the start.
  function test_GivenAFreshlyInitializedProtocolRelay() external view {
    // it should allow-list the bootstrap owner at genesis
    assertTrue(_protocolRelay.allowList(_bootstrapOwner));
    // it should deploy both satellites soulbound
    assertFalse(_principalToken.transferable());
    assertFalse(_yieldToken.transferable());
    // it should pair mint the bootstrap to the allow-listed owner
    assertEq(_principalToken.balanceOf(_bootstrapOwner), _SEED);
    assertEq(_yieldToken.balanceOf(_bootstrapOwner), _SEED);
    _assertPairInvariant();
  }

  /// @notice Initialization grants VOTER_ROLE to the named initial voter, so a fresh Relay can
  ///         allocate (and therefore admit deposits) without a second ADMIN transaction; a zero
  ///         voter skips the grant and ADMIN wires the role later.
  function test_WhenInitializingWithAndWithoutAVoter() external {
    // it should grant VOTER_ROLE to the initial voter at initialization
    assertTrue(_protocolRelay.hasAnyRole(_allocator, _protocolRelay.VOTER_ROLE()));

    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.voter = address(0);
    _relay.initialize(_params);

    // it should leave VOTER_ROLE ungranted when the initial voter is zero
    assertFalse(_relay.hasAnyRole(_allocator, _relay.VOTER_ROLE()));
    // it should never hand the role to the zero address itself (AccessControl would accept it)
    assertFalse(_relay.hasAnyRole(address(0), _relay.VOTER_ROLE()));
  }

  /// @notice The conservation floor survives L2: sweep may only move the un-accounted balance, so
  ///         rewards already notified (owed to claimants) can never leave through the escape hatch.
  function test_WhenSweepingOnLevelTwo() external {
    // promote to L2 and wire a sweeper (the owner grants SWEEPER once L2)
    vm.prank(_admin);
    _protocolRelay.promoteToLevel2(_admin);
    address _sweeper = makeAddr('sweeper');
    uint256 _sweeperRole = _protocolRelay.SWEEPER();
    vm.prank(_admin);
    _protocolRelay.grantRoles(_sweeper, _sweeperRole);

    // 100e18 of the reward token sit on the relay; 60e18 are notified, so owed to claimants
    _registerRewardToken();
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(100e18));
    vm.prank(_converter);
    _relay.notifyReward(_rewardToken, 60e18);

    IRelay.ERC20Sweep[] memory _legs = new IRelay.ERC20Sweep[](1);

    // it should revert when a leg would touch the accounted balance
    _legs[0] = IRelay.ERC20Sweep({token: _rewardToken, recipient: _sweeper, amount: 41e18});
    vm.prank(_sweeper);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _protocolRelay.sweep(_legs);

    // it should sweep any amount below the un-accounted balance (100e18 held, 60e18 owed, 40e18 free)
    _legs[0] = IRelay.ERC20Sweep({token: _rewardToken, recipient: _sweeper, amount: 10e18});
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_sweeper, 10e18)), abi.encode(true));
    vm.expectCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_sweeper, 10e18)));
    vm.prank(_sweeper);
    _protocolRelay.sweep(_legs);

    // it should sweep up to the un-accounted balance
    _legs[0] = IRelay.ERC20Sweep({token: _rewardToken, recipient: _sweeper, amount: 40e18});
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_sweeper, 40e18)), abi.encode(true));
    vm.expectCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_sweeper, 40e18)));
    vm.prank(_sweeper);
    _protocolRelay.sweep(_legs);

    // it should sweep a never-notified token in full: nothing is accounted, so all 7e18 are free
    address _stuckToken = _mockContract('stuckToken');
    vm.mockCall(_stuckToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(7e18));
    assertEq(_relay.accountedBalance(_stuckToken), 0);
    _legs[0] = IRelay.ERC20Sweep({token: _stuckToken, recipient: _sweeper, amount: 7e18});
    vm.mockCall(_stuckToken, abi.encodeCall(IERC20.transfer, (_sweeper, 7e18)), abi.encode(true));
    vm.expectCall(_stuckToken, abi.encodeCall(IERC20.transfer, (_sweeper, 7e18)));
    vm.prank(_sweeper);
    _protocolRelay.sweep(_legs);
  }

  /// @notice The promotion is one-way and hands the whole surface over with the ownership: no zero
  ///         admin, no repeat, and the tier answer follows the switch.
  function test_WhenPromotingToLevelTwo() external {
    assertEq(uint8(_protocolRelay.relayType()), uint8(IRelay.RelayType.ProtocolL1));

    // it should reject a zero level-two admin (an orphaned surface would be unrecoverable)
    vm.prank(_admin);
    vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
    _protocolRelay.promoteToLevel2(address(0));

    // it should promote and hand the ownership to the level-two admin
    address _admin2 = makeAddr('admin2');
    vm.expectEmit(address(_relay));
    emit IRelay.PromotedToLevel2(_admin2);
    vm.prank(_admin);
    _protocolRelay.promoteToLevel2(_admin2);
    assertTrue(_protocolRelay.isLevel2());
    assertEq(uint8(_protocolRelay.relayType()), uint8(IRelay.RelayType.ProtocolL2));
    assertEq(_protocolRelay.owner(), _admin2);

    // it should leave the outgoing admin nothing: the surface moved with the ownership
    vm.prank(_admin);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _protocolRelay.setAllowList(users.alice, true);

    // it should never promote twice
    vm.prank(_admin2);
    vm.expectRevert(IRelay.NotPromotable.selector);
    _protocolRelay.promoteToLevel2(_admin2);
  }

  /// @notice Entrypoints attach only through the timelock — the depositors' exit window — and
  ///         detach immediately, so a compromised entrypoint dies at once.
  function test_WhenAttachingEntrypointsOnLevelTwo() external {
    address _entrypoint = makeAddr('entrypoint');
    uint256 _compounderRole = _protocolRelay.COMPOUNDER();
    uint256 _keeperRole = _protocolRelay.KEEPER();

    // it should be unreachable on L1: the flow only opens with the level-two surface
    vm.prank(_admin);
    vm.expectRevert(IRelay.NotLevel2.selector);
    _protocolRelay.proposeEntrypoint(_compounderRole, _entrypoint);
    vm.prank(_admin);
    vm.expectRevert(IRelay.NotLevel2.selector);
    _protocolRelay.revokeEntrypoint(_compounderRole, _entrypoint);

    vm.prank(_admin);
    _protocolRelay.promoteToLevel2(_admin);

    // it should gate the flow to the owner
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _protocolRelay.proposeEntrypoint(_compounderRole, _entrypoint);

    // it should only attach the two entrypoint roles
    vm.prank(_admin);
    vm.expectRevert(IRelay.InvalidEntrypointRole.selector);
    _protocolRelay.proposeEntrypoint(_keeperRole, _entrypoint);
    vm.prank(_admin);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _protocolRelay.proposeEntrypoint(_compounderRole, address(0));

    // it should stamp the proposal clock and announce the executable time
    vm.expectEmit(address(_relay));
    emit IRelay.EntrypointProposed(_compounderRole, _entrypoint, block.timestamp + 2 days);
    vm.prank(_admin);
    _protocolRelay.proposeEntrypoint(_compounderRole, _entrypoint);
    assertEq(_protocolRelay.entrypointProposedAt(_compounderRole, _entrypoint), block.timestamp);

    // it should refuse execution before the timelock elapses, or of a pair never proposed
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointTimelockNotElapsed.selector);
    _protocolRelay.executeEntrypoint(_compounderRole, _entrypoint);
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointNotProposed.selector);
    _protocolRelay.executeEntrypoint(_compounderRole, makeAddr('neverProposed'));

    // it should grant the role once the exit window has passed
    vm.warp(block.timestamp + 2 days);
    vm.prank(_admin);
    _protocolRelay.executeEntrypoint(_compounderRole, _entrypoint);
    assertTrue(_protocolRelay.hasAnyRole(_entrypoint, _compounderRole));
    assertEq(_protocolRelay.entrypointProposedAt(_compounderRole, _entrypoint), 0);

    // it should detach immediately and cancel any pending proposal for the pair
    vm.prank(_admin);
    _protocolRelay.proposeEntrypoint(_compounderRole, _entrypoint);
    vm.prank(_admin);
    vm.expectRevert(IRelay.InvalidEntrypointRole.selector);
    _protocolRelay.revokeEntrypoint(_keeperRole, _entrypoint);
    vm.prank(_admin);
    _protocolRelay.revokeEntrypoint(_compounderRole, _entrypoint);
    assertFalse(_protocolRelay.hasAnyRole(_entrypoint, _compounderRole));
    assertEq(_protocolRelay.entrypointProposedAt(_compounderRole, _entrypoint), 0);
  }

  /// @notice The vetoer is seated at initialization or never: a named vetoer holds the bit from
  ///         genesis, a zero one leaves the timelock without a veto, and the empty seat can never
  ///         be filled later because the public grant path refuses the bit.
  function test_WhenInitializingWithAndWithoutAVetoer(address _vetoer) external {
    _assumeFuzzable(_vetoer);
    uint256 _vetoerRole = _protocolRelay.ENTRYPOINT_VETOER();

    // it should leave the seat empty when no vetoer is named
    assertFalse(_protocolRelay.hasAnyRole(_vetoer, _vetoerRole));

    // it should seat the named vetoer at initialization
    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.entrypointVetoer = _vetoer;
    _initializeRelay(_params);
    assertTrue(_protocolRelay.hasAnyRole(_vetoer, _vetoerRole));
  }

  /// @notice The veto is the timelock's second party: only the vetoer can cancel a pending
  ///         attachment, the cancellation kills the execution, and the owner keeps no path onto
  ///         the seat.
  function test_WhenVetoingAPendingEntrypoint(address _caller) external {
    _assumeFuzzable(_caller);
    address _vetoer = makeAddr('vetoer');
    address _entrypoint = makeAddr('entrypoint');
    vm.assume(_caller != _vetoer);

    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.entrypointVetoer = _vetoer;
    _initializeRelay(_params);
    uint256 _compounderRole = _protocolRelay.COMPOUNDER();

    // it should refuse a veto of a pair that was never proposed
    vm.prank(_vetoer);
    vm.expectRevert(IRelay.EntrypointNotProposed.selector);
    _protocolRelay.vetoEntrypoint(_compounderRole, _entrypoint);

    vm.prank(_admin);
    _protocolRelay.promoteToLevel2(_admin);
    vm.prank(_admin);
    _protocolRelay.proposeEntrypoint(_compounderRole, _entrypoint);

    // it should gate the veto to the vetoer, the owner included
    vm.prank(_caller);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _protocolRelay.vetoEntrypoint(_compounderRole, _entrypoint);

    // it should cancel the pending proposal and emit the veto
    vm.expectEmit(address(_relay));
    emit IRelay.EntrypointVetoed(_compounderRole, _entrypoint);
    vm.prank(_vetoer);
    _protocolRelay.vetoEntrypoint(_compounderRole, _entrypoint);
    assertEq(_protocolRelay.entrypointProposedAt(_compounderRole, _entrypoint), 0);

    // it should leave the vetoed pair unexecutable, elapsed timelock or not
    vm.warp(block.timestamp + 2 days);
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointNotProposed.selector);
    _protocolRelay.executeEntrypoint(_compounderRole, _entrypoint);

    // it should let the owner re-propose after a veto, restarting the clock
    vm.prank(_admin);
    _protocolRelay.proposeEntrypoint(_compounderRole, _entrypoint);
    assertEq(_protocolRelay.entrypointProposedAt(_compounderRole, _entrypoint), block.timestamp);
  }

  /// @notice The veto seat moves only by the sitting vetoer's own hand: the rotation names a
  ///         non-zero successor and takes the seat with it.
  function test_WhenTheVetoSeatMoves(address _successor) external {
    _assumeFuzzable(_successor);
    address _vetoer = makeAddr('vetoer');
    vm.assume(_successor != _vetoer);

    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.entrypointVetoer = _vetoer;
    _initializeRelay(_params);
    uint256 _vetoerRole = _protocolRelay.ENTRYPOINT_VETOER();

    // it should gate the rotation to the sitting vetoer
    vm.prank(_admin);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _protocolRelay.transferVetoer(_successor);

    // it should refuse a zero successor
    vm.prank(_vetoer);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _protocolRelay.transferVetoer(address(0));

    // it should hand the seat over in one rotation
    vm.prank(_vetoer);
    _protocolRelay.transferVetoer(_successor);
    assertTrue(_protocolRelay.hasAnyRole(_successor, _vetoerRole));
    assertFalse(_protocolRelay.hasAnyRole(_vetoer, _vetoerRole));
  }

  /// @notice The owner seat can never be vacated, only handed over: a renounce reverts and a
  ///         transfer moves the whole surface at once, so the owner-gated paths can never freeze
  ///         for good.
  function test_WhenManagingTheOwnership(address _newOwner) external {
    _assumeFuzzable(_newOwner);
    vm.assume(_newOwner != _admin);
    uint256 _keeperRole = _protocolRelay.KEEPER();

    // it should ban renouncing the ownership
    vm.prank(_admin);
    vm.expectRevert(IRelay.OwnershipRenounceDisabled.selector);
    _protocolRelay.renounceOwnership();

    // it should leave the owner gated surface intact after the refused renounce
    vm.prank(_admin);
    _protocolRelay.setName('Still Administrable');
    assertEq(_protocolRelay.relayConfig().name, 'Still Administrable');

    // it should refuse a transfer from anyone but the owner
    vm.prank(_newOwner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _protocolRelay.transferOwnership(_newOwner);

    // it should hand the whole surface over in one transfer
    vm.prank(_admin);
    _protocolRelay.transferOwnership(_newOwner);
    assertEq(_protocolRelay.owner(), _newOwner);
    vm.prank(_admin);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _protocolRelay.setName('No Longer Mine');

    // it should let any role holder renounce its bits normally
    vm.prank(_keeper);
    _protocolRelay.renounceRoles(_keeperRole);
    assertFalse(_protocolRelay.hasAnyRole(_keeper, _keeperRole));
  }

  /// @notice The public role paths move only the operator bits: the entrypoint bits would bypass
  ///         the timelocked attachment window (or attach on a tier with no flow at all), so both
  ///         the grant and the revoke refuse them, alone or mixed into a batch.
  function test_WhenMovingRolesOnThePublicPaths(address _account) external {
    _assumeFuzzable(_account);
    uint256 _keeperRole = _protocolRelay.KEEPER();
    uint256 _compounderRole = _protocolRelay.COMPOUNDER();
    uint256 _converterRole = _protocolRelay.CONVERTER();

    // it should let the owner grant and revoke the operator bits
    vm.prank(_admin);
    _protocolRelay.grantRoles(_account, _keeperRole);
    assertTrue(_protocolRelay.hasAnyRole(_account, _keeperRole));
    vm.prank(_admin);
    _protocolRelay.revokeRoles(_account, _keeperRole);
    assertFalse(_protocolRelay.hasAnyRole(_account, _keeperRole));

    // it should refuse the entrypoint bits on grant, which would bypass the timelock
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.grantRoles(_account, _compounderRole);

    // it should refuse the entrypoint bits mixed into a batch
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.grantRoles(_account, _keeperRole | _converterRole);

    // it should refuse the entrypoint bits on revoke, mirroring the grant
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.revokeRoles(_account, _converterRole);

    // it should refuse the vetoer bit on both paths, which only initialize seats
    uint256 _vetoerRole = _protocolRelay.ENTRYPOINT_VETOER();
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.grantRoles(_account, _vetoerRole);
    vm.prank(_admin);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.revokeRoles(_account, _vetoerRole);
  }

  /// @notice A restricted bit leaves its holder only through the flow that seats it: the L2
  ///         detachment for the entrypoints, `transferVetoer` for the veto. Solady lets any holder
  ///         drop any bit it carries, and the grant path refuses to seat these ones again, so an
  ///         unguarded renounce would empty a seat that nothing can fill.
  function test_WhenARestrictedRoleHolderRenouncesItsOwnBit(address _vetoer) external {
    _assumeFuzzable(_vetoer);
    vm.assume(_vetoer != _compounder && _vetoer != _converter);
    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.entrypointVetoer = _vetoer;
    _initializeRelay(_params);
    uint256 _keeperRole = _protocolRelay.KEEPER();
    uint256 _compounderRole = _protocolRelay.COMPOUNDER();
    uint256 _converterRole = _protocolRelay.CONVERTER();
    uint256 _vetoerRole = _protocolRelay.ENTRYPOINT_VETOER();

    // it should refuse the compounder its own bit
    vm.prank(_compounder);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.renounceRoles(_compounderRole);

    // it should refuse a batch that mixes an operator bit with a restricted one
    vm.prank(_converter);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.renounceRoles(_keeperRole | _converterRole);

    // it should refuse the sitting vetoer, leaving transferVetoer the only exit
    vm.prank(_vetoer);
    vm.expectRevert(IRelay.EntrypointRoleRestricted.selector);
    _protocolRelay.renounceRoles(_vetoerRole);

    // it should leave every restricted seat filled after the refused renounces
    assertTrue(_protocolRelay.hasAnyRole(_compounder, _compounderRole));
    assertTrue(_protocolRelay.hasAnyRole(_converter, _converterRole));
    assertTrue(_protocolRelay.hasAnyRole(_vetoer, _vetoerRole));
  }

  /// @notice Kick has no special cases left: a share mint cannot name the Relay and its principal
  ///         never transfers, so kicking it or any empty account settles to a zero-share ejection.
  function test_WhenKickingTheRelayOrAnEmptyAccount() external {
    _registerRewardToken();

    // it should eject the relay itself as a zero-share kick: it can never hold a pair
    vm.prank(_admin);
    _protocolRelay.kick(address(_protocolRelay));
    assertEq(_relay.pendingWithdrawalShares(), 0);

    // it should eject an account with no free pair as a zero-share kick
    address _empty = makeAddr('empty');
    vm.recordLogs();
    vm.prank(_admin);
    _protocolRelay.kick(_empty);
    assertEq(_relay.pendingWithdrawalShares(), 0);

    // it should emit the kick alone: the account was never listed and holds nothing to settle
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics[0], IRelay.Kicked.selector);

    // it should evict behind a long withdraw queue, which can no longer refuse the ejection
    vm.startPrank(_bootstrapOwner);
    for (uint256 _i; _i < 10; ++_i) {
      _relay.registerOnWithdrawQueue(1e18, _MINT_SENTINEL);
    }
    vm.stopPrank();
    uint256 _escrowedBefore = _relay.escrowedShares(_bootstrapOwner);
    vm.prank(_admin);
    _protocolRelay.kick(_bootstrapOwner);
    assertGt(_relay.escrowedShares(_bootstrapOwner), _escrowedBefore);
  }

  /// @notice The seams no deployable configuration reaches, exercised through a harness so their
  ///         guards stay covered: the allow-list transfer gate (the tier's YT is always soulbound,
  ///         so the token gate fires first) and sweep's defensive level check (SWEEPER only exists
  ///         once L2).
  function test_GivenTheUnreachableSeamsHarness() external {
    ProtocolRelaySeamsHarness _harness = new ProtocolRelaySeamsHarness(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );

    // it should require BOTH transfer ends allow-listed
    _harness.exposed_setAllowed(users.alice, true);
    vm.expectRevert(IRelay.NotAllowed.selector);
    _harness.exposed_authorizeTransfer(users.alice, users.bob);
    vm.expectRevert(IRelay.NotAllowed.selector);
    _harness.exposed_authorizeTransfer(users.bob, users.alice);
    _harness.exposed_setAllowed(users.bob, true);
    _harness.exposed_authorizeTransfer(users.alice, users.bob);

    // it should reject sweep below L2 even for a SWEEPER holder
    address _sweeper = makeAddr('seamSweeper');
    _harness.exposed_grantRoles(_sweeper, _harness.SWEEPER());
    vm.prank(_sweeper);
    vm.expectRevert(IRelay.NotLevel2.selector);
    _harness.sweep(new IRelay.ERC20Sweep[](0));
  }

  /// @notice The deposit gate authorizes the source sAERO's OWNER (the share recipient): a request
  ///         whose owner is off the allow list reverts before any weight moves.
  function test_WhenTheDepositOwnerIsNotAllowListed() external {
    _mockDepositAuthorization(users.alice, 2);

    // it should revert with NotAllowed
    vm.expectRevert(IRelay.NotAllowed.selector);
    vm.prank(users.alice);
    _relay.requestDeposit(2, 50e18);
  }

  /// @notice An allow-listed owner passes the gate and the admission pair-mints at the seed ratio.
  function test_WhenTheDepositOwnerIsAllowListed() external {
    // it should emit the allow-list update
    vm.expectEmit(address(_relay));
    emit IRelay.AllowListSet(users.alice, true);
    vm.prank(_admin);
    _protocolRelay.setAllowList(users.alice, true);

    // it should stay silent when the entry already holds that value
    vm.recordLogs();
    vm.prank(_admin);
    _protocolRelay.setAllowList(users.alice, true);
    assertEq(vm.getRecordedLogs().length, 0);
    assertTrue(_protocolRelay.allowList(users.alice));

    uint256 _shares = _admitDeposit(users.alice, 2, 50e18);

    // it should admit the deposit and pair mint at the one-to-one seed ratio
    assertEq(_shares, 50e18);
    assertEq(_principalToken.balanceOf(users.alice), 50e18);
    assertEq(_yieldToken.balanceOf(users.alice), 50e18);
    _assertPairInvariant();
  }

  /// @notice Characterizes the accepted gap: the allow list is checked when a deposit is requested,
  ///         never again at admission, so a recipient removed mid-flight still receives its pair. The
  ///         position is contained afterwards, since it cannot be transferred and ADMIN can kick it.
  /// @dev Pinned by a test because it is a documented decision (see audit.md), not an accident: a
  ///      drain that reverted on a de-listed recipient would wedge the shared FIFO head.
  function test_WhenTheAllowListIsRemovedBeforeProcessing() external {
    vm.prank(_admin);
    _protocolRelay.setAllowList(users.alice, true);
    _requestDeposit(users.alice, 2, 50e18);

    vm.prank(_admin);
    _protocolRelay.setAllowList(users.alice, false);

    // it should still mint the pair to the delisted recipient
    _processPending(1);
    assertEq(_principalToken.balanceOf(users.alice), 50e18);
    assertEq(_yieldToken.balanceOf(users.alice), 50e18);
    _assertPairInvariant();

    // it should keep the minted position from moving on: this tier's pair is soulbound
    vm.prank(users.alice);
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    _yieldToken.transfer(_bootstrapOwner, 1e18);

    // it should let admin eject the delisted holder, the remedy the tier provides
    vm.prank(_admin);
    _protocolRelay.kick(users.alice);
    assertEq(_relay.escrowedShares(users.alice), 50e18);
  }

  /// @notice The kick story: the rewards settle and stay claimable, the account drops off the
  ///         allow list, the FULL free pair escrows into the withdraw queue and the drain completes
  ///         the ejection with a pair burn.
  function test_WhenKickingAHolderWithRewards() external {
    vm.prank(_admin);
    _protocolRelay.setAllowList(users.alice, true);
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, alice accrues 100e18.
    _notifyReward(200e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);

    // it should drop the account from the allow list and emit the kick, with no reward transfer
    vm.expectEmit(address(_relay));
    emit IRelay.AllowListSet(users.alice, false);
    vm.expectEmit(address(_relay));
    emit IRelay.Kicked(users.alice, 100e18);
    vm.prank(_admin);
    _protocolRelay.kick(users.alice);

    assertFalse(_protocolRelay.allowList(users.alice));
    // it should settle the accrual into the pending balance and keep it accounted
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);
    assertEq(_relay.accountedBalance(_rewardToken), 200e18);
    // it should escrow the FULL free pair in place: balances untouched until the drain burns them
    assertEq(_relay.escrowedShares(users.alice), 100e18);
    assertEq(_relay.pendingWithdrawalShares(), 100e18);
    assertEq(_principalToken.balanceOf(users.alice), 100e18);
    assertEq(_yieldToken.balanceOf(users.alice), 100e18);
    _assertPairInvariant();

    _mockWithdrawRoute(users.alice, 100e18, 777);
    _relay.processWithdrawals(1);

    // it should complete the drain: the ejected pair burns and the escrow zeroes
    assertEq(_principalToken.balanceOf(users.alice), 0);
    assertEq(_yieldToken.balanceOf(users.alice), 0);
    assertEq(_relay.escrowedShares(users.alice), 0);
    assertEq(_relay.pendingWithdrawalShares(), 0);
    // it should never settle the zero address on the drain's burns (the hook skips the zero end)
    assertEq(_relay.userCheckpoint(address(0), _rewardToken), 0);
    // it should debit the supply and the backing back to the seed
    assertEq(_principalToken.totalSupply(), 100e18);
    assertEq(_relay.totalBacking(), 100e18);
    _assertPairInvariant();

    // it should leave the rewards claimable after the eviction, to any destination
    _mockAndExpectTokenTransfer(_rewardToken, users.bob, 100e18);
    vm.expectEmit(address(_relay));
    emit IRelay.RewardClaimed(users.alice, _rewardToken, users.bob, 100e18);
    vm.prank(users.alice);
    _relay.claim(_rewardToken, users.bob);
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 0);
    assertEq(_relay.accountedBalance(_rewardToken), 100e18);
  }

  /// @notice A kick on top of an exit the holder queued itself: the entry already in the queue
  ///         stays untouched and only the remaining free pair is added on top of it.
  function test_WhenKickingAHolderWithSharesAlreadyQueued() external {
    vm.prank(_admin);
    _protocolRelay.setAllowList(users.alice, true);
    _admitDeposit(users.alice, 2, 100e18);

    // alice queues 40e18 of her 100e18 pair herself, leaving 60e18 free
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(40e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(users.alice), 40e18);
    assertEq(_relay.pendingWithdrawalShares(), 40e18);

    // it should queue only the free remainder: 100e18 held minus the 40e18 already escrowed
    vm.expectEmit(address(_relay));
    emit IRelay.WithdrawRegistered(users.alice, 60e18, _MINT_SENTINEL, 2);
    vm.expectEmit(address(_relay));
    emit IRelay.Kicked(users.alice, 60e18);
    vm.prank(_admin);
    _protocolRelay.kick(users.alice);

    // it should add the ejection on top of the standing totals: 40e18 + 60e18 on both counters
    assertEq(_relay.escrowedShares(users.alice), 100e18);
    assertEq(_relay.pendingWithdrawalShares(), 100e18);
    assertEq(_principalToken.balanceOf(users.alice), 100e18);
    assertEq(_yieldToken.balanceOf(users.alice), 100e18);
    _assertPairInvariant();
  }

  /// @notice A deposit admitted after the closure mints the principal alone, so the ejection cannot
  ///         price the free position against the yield side there: with no yield the pair minimum
  ///         reads zero, which queues nothing, and underflows outright once part of the principal is
  ///         already escrowed. After closure the free principal is the whole position.
  function test_WhenKickingAPrincipalOnlyHolderAfterTheClosure() external {
    vm.startPrank(_admin);
    _protocolRelay.setAllowList(users.alice, true);
    _protocolRelay.setAllowList(users.bob, true);
    vm.stopPrank();
    _requestDeposit(users.alice, 2, 50e18);
    _requestDeposit(users.bob, 3, 50e18);

    vm.prank(_keeper);
    _relay.close();
    // The keeper drains directly: `_processPending` calls `allocate`, which a closed Relay rejects.
    vm.prank(_keeper);
    _relay.processPending(2);
    assertEq(_yieldToken.balanceOf(users.alice), 0, 'the closed admission minted a yield side');

    // it should queue the whole principal of a holder that never held a yield side
    vm.expectEmit(address(_relay));
    emit IRelay.Kicked(users.alice, 50e18);
    vm.prank(_admin);
    _protocolRelay.kick(users.alice);
    assertEq(_relay.escrowedShares(users.alice), 50e18, 'the kick queued no principal');

    // bob queues part of his principal himself before the kick, which is what underflowed the
    // pair-minimum subtraction
    vm.prank(users.bob);
    _relay.registerOnWithdrawQueue(20e18, _MINT_SENTINEL);

    // it should queue the free remainder when part of the principal is already escrowed
    vm.expectEmit(address(_relay));
    emit IRelay.Kicked(users.bob, 30e18);
    vm.prank(_admin);
    _protocolRelay.kick(users.bob);
    assertEq(_relay.escrowedShares(users.bob), 50e18, 'the kick did not queue the free remainder');
  }
}
