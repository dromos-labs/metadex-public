// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';
import {InertRelayTokenImplementation} from 'V3-test/unit/relay/harnesses/InertRelayTokenImplementation.sol';
import {PartialRelayTokenImplementation} from 'V3-test/unit/relay/harnesses/PartialRelayTokenImplementation.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MaxiRelay} from 'V3/relay/MaxiRelay.sol';
import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';

/// @notice Coverage of the initialization guards (RelayInitLib's validation and the seed
///         invariants), the constructor zero checks and the custom-period lock refresh.
contract UnitRelayInitialize is BaseRelay {
  /// @dev The lock horizon of a twenty-six week Relay at the fixture's base timestamp, computed by
  ///      hand: 1_000_000 seconds is one full week plus a remainder, so the week floor is 604_800
  ///      and the horizon lands twenty-six weeks later, at 27 * 604_800 = 16_329_600.
  uint48 internal constant _HORIZON_END = 16_329_600;

  /// @dev One week before `_HORIZON_END`: 16_329_600 - 604_800.
  uint48 internal constant _HORIZON_END_MINUS_ONE_WEEK = 15_724_800;

  /// @dev Deploy an uninitialized MaxiRelay against the mocked dependencies (the fixture's
  ///      `_deployMaxi` initializes immediately, which these guard tests must not).
  function _deployMaxiUninitialized() internal {
    _relay = new MaxiRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
  }

  /// @dev Expect `initialize` with `_params` to revert with `_err` on a freshly armed clone.
  function _expectInitializeRevert(IRelay.InitParams memory _params, bytes4 _err) internal {
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    vm.expectRevert(_err);
    _relay.initialize(_params);
  }

  /// @dev Stage what a compound of `_amount` needs beyond the lock roll: the un-accounted TOKEN bound
  ///      it draws against and the escrow's stake growth.
  function _armCompound(uint128 _amount) internal {
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)), abi.encode());
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(_amount));
    vm.mockCall(
      _votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, _amount)), abi.encode()
    );
  }

  /// @dev Deploy a Maxi and initialize it on a twenty-six week horizon, its decaying seed lock
  ///      ending at `_end`.
  function _initializeCustomPeriodRelay(uint48 _end) internal {
    _deployMaxiUninitialized();
    _mockInitializeChoreography();
    _mockRelayStakedDecaying(_SEED, _end);
    IRelay.InitParams memory _params = _defaultInitParams(true);
    _params.config.lockWeeks = 26;
    _relay.initialize(_params);
  }

  /// @notice The one-time guard: an implementation (or an initialized clone) can never run
  ///         `initialize` again.
  function test_WhenInitializingTwice() external {
    _deployProtocolUninitialized();
    // The constructor marks the implementation initialized; the flag is deliberately NOT cleared.
    vm.expectRevert(Ownable.AlreadyInitialized.selector);
    _relay.initialize(_defaultInitParams(false));

    // it should also refuse a second initialize on an armed and initialized clone: the flag must
    // be re-set by initialize itself, not inherited from the constructor
    _deployProtocolUninitialized();
    _initializeRelay(_defaultInitParams(false));
    vm.expectRevert(Ownable.AlreadyInitialized.selector);
    _relay.initialize(_defaultInitParams(false));
  }

  /// @notice The non-optional init inputs must be non-zero: admin, keeper, the bootstrap-share
  ///         owner, the VPM, the Governor and the vote adapter.
  function test_WhenAnOperatorInputIsZero() external {
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.admin = address(0);
    _expectInitializeRevert(_params, IRelay.ZeroAddress.selector);

    _params = _defaultInitParams(false);
    _params.keeper = address(0);
    _expectInitializeRevert(_params, IRelay.ZeroAddress.selector);

    _params = _defaultInitParams(false);
    _params.bootstrapOwner = address(0);
    _expectInitializeRevert(_params, IRelay.ZeroAddress.selector);

    _params = _defaultInitParams(false);
    _params.vpm = IVoterPaymentsModule(address(0));
    _expectInitializeRevert(_params, IRelay.ZeroAddress.selector);

    _params = _defaultInitParams(false);
    _params.governor = IGovernor(address(0));
    _expectInitializeRevert(_params, IRelay.ZeroAddress.selector);

    _params = _defaultInitParams(false);
    _params.voteAdapter = RelayVoteAdapter(address(0));
    _expectInitializeRevert(_params, IRelay.ZeroAddress.selector);
  }

  /// @notice The entrypoint roles are optional: a zero compounder is a documented input that skips
  ///         the grant instead of reverting, and it must never hand the role to the zero address.
  function test_WhenTheCompounderIsZero() external {
    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.compounder = address(0);
    _initializeRelay(_params);

    // it should leave the compounder role ungranted
    assertFalse(_relay.hasAnyRole(address(0), _relay.COMPOUNDER()));
    // it should still grant the converter lane named in the params
    assertTrue(_relay.hasAnyRole(_converter, _relay.CONVERTER()));

    // it should skip a zero converter the same way, never granting the role to the zero address
    _deployProtocolUninitialized();
    _params = _defaultInitParams(false);
    _params.converter = address(0);
    _initializeRelay(_params);
    assertFalse(_relay.hasAnyRole(address(0), _relay.CONVERTER()));
    assertTrue(_relay.hasAnyRole(_compounder, _relay.COMPOUNDER()));
  }

  /// @notice A Relay whose entrypoints are fixed at initialization must name at least one: with
  ///         none, nothing could ever process the rewards reaching it. An L2 start is exempt, it
  ///         attaches entrypoints through the timelocked flow.
  function test_WhenBothEntrypointsAreZero() external {
    // it should revert on a maxi relay which can never attach one
    _deployMaxiUninitialized();
    _mockInitializeChoreography();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.compounder = address(0);
    _params.converter = address(0);
    vm.expectRevert(IRelay.MissingEntrypoint.selector);
    _relay.initialize(_params);

    // it should revert on a protocol relay starting as level one
    _params = _defaultInitParams(false);
    _params.compounder = address(0);
    _params.converter = address(0);
    _expectInitializeRevert(_params, IRelay.MissingEntrypoint.selector);

    // it should initialize a protocol relay starting as level two which attaches later
    _deployProtocolUninitialized();
    _params = _defaultInitParams(false);
    _params.compounder = address(0);
    _params.converter = address(0);
    _params.startAsLevel2 = true;
    _initializeRelay(_params);
    assertTrue(_protocolRelay.isLevel2());
    assertFalse(_relay.hasAnyRole(address(0), _relay.COMPOUNDER()));
    assertFalse(_relay.hasAnyRole(address(0), _relay.CONVERTER()));
  }

  /// @notice The config floors: zero windows would void the liveness and closure guarantees, a zero
  ///         amount floor would admit a dust entry, and a zero entrypoint timelock would let an L2
  ///         admin attach an entrypoint with no exit window, so each is rejected up front.
  function test_WhenTheConfigIsDegenerate() external {
    // it should reject zero windows zero floors and a zero entrypoint timelock
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.config.evacuationWindow = 0;
    _expectInitializeRevert(_params, IRelay.InvalidEvacuationWindow.selector);

    _params = _defaultInitParams(false);
    _params.config.keeperWindow = 0;
    _expectInitializeRevert(_params, IRelay.InvalidKeeperWindow.selector);

    // A zero entrypoint timelock would let an L2 admin propose and attach an entrypoint in one block,
    // giving depositors no window to exit first.
    _params = _defaultInitParams(false);
    _params.config.entrypointTimelock = 0;
    _expectInitializeRevert(_params, IRelay.InvalidEntrypointTimelock.selector);

    // A zero withdrawal floor is the one that ends the Relay: `registerOnWithdrawQueue(0, ...)` clears
    // the floor (nothing is below zero) and clears the free-pair cover (every balance covers zero, so
    // an address holding no shares gets in), landing a zero-share entry in a FIFO whose entries cannot
    // be cancelled. The drain then reverts on it forever, and `evacuate` reads a zero exit as covered
    // rather than uncovered, so even the permissionless escape hatch is shut.
    _params = _defaultInitParams(false);
    _params.config.minWithdrawal = 0;
    _expectInitializeRevert(_params, IRelay.ZeroQueueFloor.selector);

    // The deposit floor is held to the same rule. There the damage stops at a wasted queue slot,
    // because the deposit drain tolerates an entry that mints zero shares.
    _params = _defaultInitParams(false);
    _params.config.minDeposit = 0;
    _expectInitializeRevert(_params, IRelay.ZeroQueueFloor.selector);
  }

  /// @notice The seed invariants: the clone must own its sAERO and the sAERO must carry a
  ///         non-zero stake whose permanence matches the configured lock horizon.
  function test_WhenASeedInvariantIsBroken() external {
    // it should revert when the relay does not own the sAERO
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    vm.mockCall(_votingEscrow, abi.encodeCall(IERC721.ownerOf, (_RELAY_TOKEN_ID)), abi.encode(users.alice));
    vm.expectRevert(IRelay.NotTokenOwner.selector);
    _relay.initialize(_defaultInitParams(false));

    // it should revert on a zero seed stake (the first-depositor inflation guard)
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    _mockRelayStaked(0);
    vm.expectRevert(IRelay.ZeroInitialDeposit.selector);
    _relay.initialize(_defaultInitParams(false));

    // it should revert when a permanent seed carries a non-zero lock horizon
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.config.lockWeeks = 26;
    vm.expectRevert(IRelay.LockWeeksMismatch.selector);
    _relay.initialize(_params);

    // it should revert when a decaying seed carries a permanent (zero) lock horizon
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    _mockRelayStakedDecaying(_SEED, uint48(block.timestamp + 26 weeks));
    vm.expectRevert(IRelay.LockWeeksMismatch.selector);
    _relay.initialize(_defaultInitParams(false));
  }

  /// @notice Creation holds the module to the same bar as rotation: the escrow refuses weight
  ///         moves from an unauthorized module, so an unvetted one is refused before the clone
  ///         goes live instead of reverting its first deposit.
  function test_WhenTheModuleIsNotAuthorized(address _caller) external {
    _assumeFuzzable(_caller);
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_vpm)), abi.encode(false));
    IRelay.InitParams memory _params = _defaultInitParams(false);

    // it should revert with ModuleNotAuthorized
    vm.expectRevert(IRelay.ModuleNotAuthorized.selector);
    vm.prank(_caller);
    _relay.initialize(_params);
  }

  /// @notice The base tier seam rejects an L2 start: only ProtocolRelay overrides it.
  function test_WhenAMaxiStartsAsLevelTwo() external {
    _deployMaxiUninitialized();
    _mockInitializeChoreography();
    IRelay.InitParams memory _params = _defaultInitParams(true);
    _params.startAsLevel2 = true;
    vm.expectRevert(IRelay.NotPromotable.selector);
    _relay.initialize(_params);
  }

  /// @notice The constructor rejects zero protocol dependencies (checked once per implementation).
  function test_WhenAConstructorDependencyIsZero() external {
    vm.expectRevert(IRelay.ZeroAddress.selector);
    new MaxiRelay(
      IVotingEscrow(address(0)),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
    vm.expectRevert(IRelay.ZeroAddress.selector);
    new MaxiRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(address(0)),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
    vm.expectRevert(IRelay.ZeroAddress.selector);
    new MaxiRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      address(0)
    );
  }

  /// @notice The satellite implementations are held to code, not just to non-zero: an EIP-1167 clone
  ///         of a codeless address answers every call with success and no data, so the clone's
  ///         `initialize` and the bootstrap mint would both look like they ran against nothing.
  /// @param _codeless Any address holding no code, an EOA or a never-deployed address alike.
  function test_WhenASatelliteImplementationHoldsNoCode(address _codeless) external {
    _assumeFuzzable(_codeless);
    vm.assume(_codeless.code.length == 0);

    // it should revert with ImplementationNotAContract for the principal implementation
    vm.expectRevert(IRelay.ImplementationNotAContract.selector);
    new MaxiRelay(IVotingEscrow(_votingEscrow), IVoter(_voter), _codeless, address(_relayTokenImplementation), _weth);

    // it should revert with ImplementationNotAContract for the yield implementation
    vm.expectRevert(IRelay.ImplementationNotAContract.selector);
    new MaxiRelay(
      IVotingEscrow(_votingEscrow), IVoter(_voter), address(_principalTokenImplementation), _codeless, _weth
    );

    // it should hold the zero address to the same rule, since it carries no code either
    vm.expectRevert(IRelay.ImplementationNotAContract.selector);
    new MaxiRelay(IVotingEscrow(_votingEscrow), IVoter(_voter), address(0), address(_relayTokenImplementation), _weth);
  }

  /// @notice The constructor check cannot cover an implementation that holds code and still wires
  ///         nothing, so initialization reads back the two fields the clone's `initialize` writes.
  ///         Without this the Relay would be created around satellites that mint nothing.
  function test_WhenASatelliteCloneComesOutUnwired() external {
    InertRelayTokenImplementation _inert = new InertRelayTokenImplementation();

    // it should revert with SatelliteNotInitialized when the clone never bound the relay
    _relay = new MaxiRelay(IVotingEscrow(_votingEscrow), IVoter(_voter), address(_inert), address(_inert), _weth);
    _mockInitializeChoreography();
    vm.expectRevert(IRelay.SatelliteNotInitialized.selector);
    _relay.initialize(_defaultInitParams(false));

    // it should revert with SatelliteNotInitialized when the clone dropped the transferability
    PartialRelayTokenImplementation _partial = new PartialRelayTokenImplementation();
    _relay = new MaxiRelay(IVotingEscrow(_votingEscrow), IVoter(_voter), address(_partial), address(_partial), _weth);
    _mockInitializeChoreography();
    vm.expectRevert(IRelay.SatelliteNotInitialized.selector);
    _relay.initialize(_defaultInitParams(true));
  }

  /// @notice Initialization grants the escrow a permanent max allowance over TOKEN, so `compound`
  ///         can add stake later without a new approval on every call, and it authorizes the VPM to
  ///         spend the Relay's own sAERO, which every withdraw drain needs.
  function test_WhenGrantingTheStandingCompoundAllowance() external {
    _deployProtocolUninitialized();
    _mockInitializeChoreography();

    // it should approve the escrow for the maximum TOKEN amount
    vm.expectCall(_token, abi.encodeCall(IERC20.approve, (_votingEscrow, type(uint256).max)));
    // it should approve the VPM as a spender of the Relay sAERO
    vm.expectCall(_votingEscrow, abi.encodeCall(IERC721.approve, (_vpm, _RELAY_TOKEN_ID)));
    _relay.initialize(_defaultInitParams(false));
  }

  /// @notice The registry never drops a token and the single-slot tiers close on the first one, so the
  ///         creator can name it at initialization instead of leaving the choice to a later KEEPER call,
  ///         which is also where the entrypoint it has to match is named.
  function test_WhenNamingTheRewardTokenAtInitialization() external {
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.rewardToken = _rewardToken;

    // it should register the named token
    vm.expectEmit(address(_relay));
    emit IRelay.RewardTokenAdded(_rewardToken);
    _relay.initialize(_params);
    assertTrue(_relay.isRewardToken(_rewardToken));
    assertEq(_relay.rewardTokens().length, 1);

    // it should close the single-slot registry on it, leaving the keeper nothing to add
    vm.prank(_keeper);
    vm.expectRevert(IRelay.RewardRegistryLocked.selector);
    _relay.addRewardToken(_token);

    // it should leave the registry empty when the creator names no token
    _deployProtocolUninitialized();
    _mockInitializeChoreography();
    _relay.initialize(_defaultInitParams(false));
    assertEq(_relay.rewardTokens().length, 0);
    assertFalse(_relay.isRewardToken(_rewardToken));
  }

  /// @notice A custom-period Relay refreshes its lock to the configured horizon, and only when the
  ///         current end actually falls short — a repeat call within the week must not revert.
  function test_WhenExtendingACustomPeriodLock() external {
    // initialize with a 26-week decaying seed
    _deployMaxiUninitialized();
    _mockInitializeChoreography();
    uint256 _target = (block.timestamp / 1 weeks) * 1 weeks + 26 weeks;
    _mockRelayStakedDecaying(_SEED, uint48(_target));
    IRelay.InitParams memory _params = _defaultInitParams(true);
    _params.config.lockWeeks = 26;
    // it should announce the satellite pair: the PT and YT clones are the relay's first two creates
    vm.expectEmit(address(_relay));
    emit IRelay.RelayTokensDeployed(
      vm.computeCreateAddress(address(_relay), 1), vm.computeCreateAddress(address(_relay), 2)
    );
    _relay.initialize(_params);

    // it should skip the escrow call while the end already holds the horizon
    _relay.extendLock();

    // it should refresh the staking period once the end falls short of the horizon
    _mockRelayStakedDecaying(_SEED, uint48(_target - 1 weeks));
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)), abi.encode());
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)));
    _relay.extendLock();
  }

  /// @notice The skip is not cosmetic: the real escrow rejects a period that does not move the end
  ///         forward, so a refresh while the horizon is already held would revert and block every
  ///         allocation until the week rolls over.
  function test_WhenTheLockAlreadyCoversTheHorizon() external {
    // the seed lock already ends at the twenty-six week horizon
    _initializeCustomPeriodRelay(_HORIZON_END);

    // it should never reach the escrow
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)), 0);
    _relay.extendLock();

    // it should also skip when the end already exceeds the horizon (a lock ahead of the config)
    _initializeCustomPeriodRelay(_HORIZON_END + 604_800);
    _relay.extendLock();
  }

  /// @notice A permanent Relay has no staking period to refresh. The escrow would revert on a
  ///         zero-week period, so the no-op must return before any external call.
  function test_WhenExtendingAPermanentLock() external {
    // the default config is permanent: lockWeeks is zero and the seed stake is permanent
    _deployProtocol(false);

    // it should never reach the escrow
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 0)), 0);
    _relay.extendLock();
  }

  /// @notice Every allocation refreshes a custom-period lock first, so the pooled lock never decays
  ///         below the locks of the depositors it represents.
  function test_WhenAllocatingWithACustomPeriodLock() external {
    _initializeCustomPeriodRelay(_HORIZON_END);
    // the end now falls one week short of the horizon
    _mockRelayStakedDecaying(_SEED, _HORIZON_END_MINUS_ONE_WEEK);
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)), abi.encode());
    vm.mockCall(
      _voter, abi.encodeCall(IVoter.allocationChainAmounts, (_RELAY_TOKEN_ID, 0)), abi.encode(type(uint128).max)
    );
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.allocate.selector), abi.encode());

    IVoter.ChainAllocationDispatch[] memory _pokes = new IVoter.ChainAllocationDispatch[](1);
    _pokes[0] = IVoter.ChainAllocationDispatch({chainId: 1, delta: 0, gasLimit: 0, value: 0});

    // it should refresh the staking period before the dispatch
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)));
    // it should emit the allocation
    vm.expectEmit(address(_relay));
    emit IRelay.Allocated(_allocator);
    vm.prank(_allocator);
    _relay.allocate(_pokes, new IVoter.GaugeAllocationDispatch[](0), address(0));
  }

  /// @notice Compound rolls the lock first, the same as an allocation. The escrow refuses to grow an
  ///         expired stake, so without the roll the compound lane would stay dead until somebody ran
  ///         `extendLock` by hand. It matters most on a closed Relay still draining its queue, where
  ///         compound is the only refresh that still runs on its own.
  function test_WhenCompoundingAfterACustomPeriodLockFellShort() external {
    _initializeCustomPeriodRelay(_HORIZON_END);
    // the end now falls one week short of the horizon
    _mockRelayStakedDecaying(_SEED, _HORIZON_END_MINUS_ONE_WEEK);
    _armCompound(30e18);

    // it should refresh the staking period before growing the stake
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)));
    vm.prank(_compounder);
    _relay.compound(30e18);
  }

  /// @notice Inside the week that anchored the current end the roll is a no-op, so an opportunistic
  ///         compound never pays for a refresh it does not need, and never trips the escrow's
  ///         must-move-forward rule either.
  function test_WhenCompoundingWhileTheLockStillHoldsTheHorizon() external {
    _initializeCustomPeriodRelay(_HORIZON_END);
    _armCompound(30e18);

    // it should skip the refresh
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakingPeriod, (_RELAY_TOKEN_ID, 26)), 0);
    vm.prank(_compounder);
    _relay.compound(30e18);
  }

  /// @notice The escrow week-floors the start before checking MAXTIME, so a horizon that overshoots by
  ///         less than that floor's remainder passes creation and then fails part of every later week.
  ///         209 weeks is that value, and it is refused at initialization rather than stamped.
  function test_WhenTheLockWeeksReachPastTheEscrowMaximum(uint48 _weeks) external {
    // 209 weeks is 1463 days against a 1460-day MAXTIME, so it and everything above it are rejected.
    _weeks = uint48(bound(_weeks, 209, type(uint48).max / uint48(1 weeks)));
    _deployMaxiUninitialized();
    _mockInitializeChoreography();
    _mockRelayStakedDecaying(_SEED, _HORIZON_END);
    IRelay.InitParams memory _params = _defaultInitParams(true);
    _params.config.lockWeeks = _weeks;

    // it should revert with LockWeeksTooLong
    vm.expectRevert(IRelay.LockWeeksTooLong.selector);
    _relay.initialize(_params);
  }

  /// @notice 208 weeks is 1456 days, inside MAXTIME whatever the week remainder is, so the boundary
  ///         value itself stays creatable.
  function test_WhenTheLockWeeksSitAtTheEscrowMaximum() external {
    _deployMaxiUninitialized();
    _mockInitializeChoreography();
    _mockRelayStakedDecaying(_SEED, _HORIZON_END);
    IRelay.InitParams memory _params = _defaultInitParams(true);
    _params.config.lockWeeks = 208;

    // it should accept the config
    _relay.initialize(_params);
    assertEq(_relay.relayConfig().lockWeeks, 208);
  }

  /// @notice The satellite implementations are locked at deploy: their constructors mark them
  ///         initialized, so only clones (born with zeroed storage) can ever run `initialize`.
  function test_WhenInitializingTheSatelliteImplementations() external {
    // it should refuse to initialize the yield token implementation
    vm.expectRevert(IRelayToken.AlreadyInitialized.selector);
    _relayTokenImplementation.initialize('n', 's', true);

    // it should refuse to initialize the checkpointed principal token implementation
    vm.expectRevert(IRelayToken.AlreadyInitialized.selector);
    _principalTokenImplementation.initialize('n', 's', false);
  }

  /// @notice Every RelayConfig field must survive the field-by-field copy into the clone's
  ///         storage: a field missing from the copy would silently zero on every clone.
  function test_WhenCopyingTheConfigIntoTheClone() external {
    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _initializeRelay(_params);

    // it should copy every field verbatim
    IRelay.RelayConfig memory _stored = _relay.relayConfig();
    assertEq(_stored.tokenId, _params.config.tokenId);
    assertEq(_stored.minDeposit, _params.config.minDeposit);
    assertEq(_stored.keeperWindow, _params.config.keeperWindow);
    assertEq(_stored.minWithdrawal, _params.config.minWithdrawal);
    assertEq(_stored.entrypointTimelock, _params.config.entrypointTimelock);
    assertEq(_stored.lockWeeks, _params.config.lockWeeks);
    assertEq(_stored.evacuationWindow, _params.config.evacuationWindow);
    assertEq(_stored.name, _params.config.name);
    assertEq(_stored.symbol, _params.config.symbol);
  }

  /// @dev Mock the Relay sAERO's stake as a decaying (non-permanent) balance with the given end.
  function _mockRelayStakedDecaying(uint256 _amount, uint48 _end) internal {
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.staked, (_RELAY_TOKEN_ID)),
      // forge-lint: disable-next-line(unsafe-typecast)
      abi.encode(IVotingEscrow.StakedBalance({amount: uint128(_amount), end: _end, isPermanent: false}))
    );
  }
}
