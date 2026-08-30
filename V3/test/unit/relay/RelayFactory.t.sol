// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {InertRelayImplementation} from 'V3-test/unit/relay/harnesses/InertRelayImplementation.sol';

import {MaxiRelay} from 'V3/relay/MaxiRelay.sol';
import {ProtocolRelay} from 'V3/relay/ProtocolRelay.sol';
import {RelayFactory} from 'V3/relay/RelayFactory.sol';
import {RelayToken} from 'V3/relay/RelayToken.sol';
import {RelayTokenVotes} from 'V3/relay/RelayTokenVotes.sol';
import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';

/// @notice Coverage of the factory choreography: seed the stake, transfer it to the PREDICTED
///         clone address, clone there and initialize — so the clone is born owning its seed.
/// @dev    Real tier implementations and real satellite clones; only the protocol dependencies
///         (VotingEscrow / TOKEN) are mocked, mirroring the BaseRelay fixture style.
contract UnitRelayFactory is TestHelpers {
  uint128 internal constant _SEED = 100e18;

  address internal _votingEscrow;
  address internal _token;
  address internal _voter;
  address internal _creator;
  address internal _vpm;
  address internal _governor;
  RelayVoteAdapter internal _voteAdapter;

  RelayFactory internal _factory;
  MaxiRelay internal _maxiImplementation;
  ProtocolRelay internal _protocolImplementation;

  function setUp() public {
    vm.warp(1_000_000);
    _votingEscrow = _mockContract('VotingEscrow');
    _token = _mockContract('Token');
    _creator = makeAddr('creator');

    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.TOKEN, ()), abi.encode(_token));

    // Nobody holds RELAY_DEPLOYER_ROLE unless a test says so: the catch-all answers false and the
    // per-address mocks registered by `_grantDeployer` take precedence over it.
    _voter = _mockContract('Voter');
    vm.mockCall(_voter, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    _grantDeployer(_creator);

    _vpm = _mockContract('VoterPaymentsModule');
    _governor = _mockContract('Governor');
    _voteAdapter = new RelayVoteAdapter();
    RelayTokenVotes _principalTokenImplementation = new RelayTokenVotes();
    RelayToken _relayTokenImplementation = new RelayToken();
    address _weth = _mockContract('WrappedNative');
    _maxiImplementation = new MaxiRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
    _protocolImplementation = new ProtocolRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );

    _factory = _newFactory(_votingEscrow, _voter, address(_maxiImplementation), address(_protocolImplementation));
  }

  /// @dev Give `_account` RELAY_DEPLOYER_ROLE on the mocked Voter. Registered with the full calldata,
  ///      so it wins over the catch-all `hasRole` mock that answers false for everyone else.
  function _grantDeployer(address _account) internal {
    vm.mockCall(_voter, abi.encodeCall(IAccessControl.hasRole, (Roles.RELAY_DEPLOYER_ROLE, _account)), abi.encode(true));
  }

  /// @notice The constructor binds the escrow, reads TOKEN from it and rejects zero dependencies.
  function test_WhenConstructingTheFactory() external {
    // it should bind the escrow, the token and both implementations
    assertEq(address(_factory.VOTING_ESCROW()), _votingEscrow);
    assertEq(_factory.TOKEN(), _token);
    assertEq(_factory.VOTER(), _voter);
    assertEq(_factory.MAXI_IMPLEMENTATION(), address(_maxiImplementation));
    assertEq(_factory.PROTOCOL_IMPLEMENTATION(), address(_protocolImplementation));
    assertEq(address(_factory.VPM()), _vpm);
    assertEq(address(_factory.GOVERNOR()), _governor);
    assertEq(address(_factory.VOTE_ADAPTER()), address(_voteAdapter));

    // it should answer every dependency through the interface
    // A consumer holding only IRelayFactory, such as the MetaRouter reading `isRelay`, has to be able
    // to resolve the rest of the wiring off the same handle instead of importing the concrete factory.
    IRelayFactory _handle = IRelayFactory(address(_factory));
    assertEq(address(_handle.VOTING_ESCROW()), _votingEscrow);
    assertEq(_handle.TOKEN(), _token);
    assertEq(_handle.VOTER(), _voter);
    assertEq(_handle.MAXI_IMPLEMENTATION(), address(_maxiImplementation));
    assertEq(_handle.PROTOCOL_IMPLEMENTATION(), address(_protocolImplementation));
    assertEq(address(_handle.VPM()), _vpm);
    assertEq(address(_handle.GOVERNOR()), _governor);
    assertEq(address(_handle.VOTE_ADAPTER()), address(_voteAdapter));

    // it should revert with ZeroAddress for each missing dependency
    address _maxi = address(_maxiImplementation);
    address _protocol = address(_protocolImplementation);
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    _newFactory(address(0), _voter, _maxi, _protocol);
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    _newFactory(_votingEscrow, address(0), _maxi, _protocol);
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    _newFactory(_votingEscrow, _voter, address(0), _protocol);
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    _newFactory(_votingEscrow, _voter, _maxi, address(0));
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    new RelayFactory(
      IVotingEscrow(_votingEscrow),
      _voter,
      _maxi,
      _protocol,
      IVoterPaymentsModule(address(0)),
      IGovernor(_governor),
      _voteAdapter
    );
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    new RelayFactory(
      IVotingEscrow(_votingEscrow),
      _voter,
      _maxi,
      _protocol,
      IVoterPaymentsModule(_vpm),
      IGovernor(address(0)),
      _voteAdapter
    );
    vm.expectRevert(IRelayFactory.ZeroAddress.selector);
    new RelayFactory(
      IVotingEscrow(_votingEscrow),
      _voter,
      _maxi,
      _protocol,
      IVoterPaymentsModule(_vpm),
      IGovernor(_governor),
      RelayVoteAdapter(address(0))
    );
  }

  /// @notice A codeless implementation is rejected at construction: a clone of it would delegatecall
  ///         to nothing, so `initialize` would return success without running and the seed sAERO
  ///         transferred to the predicted address would be stuck in an inert proxy.
  /// @param _codeless Any address holding no code, an EOA or a never-deployed address alike.
  function test_WhenAnImplementationHoldsNoCode(address _codeless) external {
    _assumeFuzzable(_codeless);
    vm.assume(_codeless.code.length == 0);

    // it should revert with ImplementationNotAContract for either tier
    vm.expectRevert(IRelayFactory.ImplementationNotAContract.selector);
    _newFactory(_votingEscrow, _voter, _codeless, address(_protocolImplementation));
    vm.expectRevert(IRelayFactory.ImplementationNotAContract.selector);
    _newFactory(_votingEscrow, _voter, address(_maxiImplementation), _codeless);
  }

  /// @notice The creation path also checks the clone came out wired, so an implementation that holds
  ///         code but initializes to nothing cannot be recorded as a Relay with the seed inside it.
  /// @dev The inert implementation reproduces what a codeless one would leave behind, which the
  ///      constructor check alone cannot cover once an implementation is already stored.
  function test_WhenACreatedRelayComesOutUninitialized() external {
    InertRelayImplementation _inert = new InertRelayImplementation();
    _factory = _newFactory(_votingEscrow, _voter, address(_inert), address(_protocolImplementation));
    IRelayFactory.CreateParams memory _params = _createParams(bytes32('inert'), true, 0);
    _armCreate(_creator, _params, 7, address(_inert));

    // it should revert with RelayInitializationFailed
    vm.prank(_creator);
    vm.expectRevert(IRelayFactory.RelayInitializationFailed.selector);
    _factory.createMaxiRelay(_params);

    // it should record no relay
    assertEq(_factory.allRelaysLength(), 0, 'an inert relay was recorded');
  }

  /// @dev Factory constructor with the fixture's VPM and Governor filled in.
  function _newFactory(
    address _escrow,
    address _roleVoter,
    address _maxiImpl,
    address _protocolImpl
  ) internal returns (RelayFactory _built) {
    _built = new RelayFactory(
      IVotingEscrow(_escrow),
      _roleVoter,
      _maxiImpl,
      _protocolImpl,
      IVoterPaymentsModule(_vpm),
      IGovernor(_governor),
      _voteAdapter
    );
  }

  /// @notice Creation is restricted to RELAY_DEPLOYER_ROLE on the Voter, on both tiers. The gate runs
  ///         before anything else, so an unauthorized caller moves no seed and mints no sAERO.
  /// @param _stranger Any caller without the role.
  function test_WhenTheCallerDoesNotHoldTheDeployerRole(address _stranger) external {
    _assumeFuzzable(_stranger);
    vm.assume(_stranger != _creator);

    IRelayFactory.CreateParams memory _params = _createParams(bytes32('ungated'), true, 0);

    // it should read the role from the voter
    vm.expectCall(_voter, abi.encodeCall(IAccessControl.hasRole, (Roles.RELAY_DEPLOYER_ROLE, _stranger)));

    // it should revert with NotAuthorized on both tiers
    vm.prank(_stranger);
    vm.expectRevert(IRelayFactory.NotAuthorized.selector);
    _factory.createMaxiRelay(_params);

    vm.prank(_stranger);
    vm.expectRevert(IRelayFactory.NotAuthorized.selector);
    _factory.createProtocolRelay(_params, false);

    // The rejected calls left no trace: no seed was pulled, so nothing was created either.
    assertEq(_factory.allRelaysLength(), 0, 'a rejected creation recorded a relay');

    // Granting the role is all that changes, and the same caller then creates.
    _armCreate(_stranger, _params, 40, address(_maxiImplementation));
    vm.prank(_stranger);
    (address _relay,) = _factory.createMaxiRelay(_params);
    assertTrue(_factory.isRelay(_relay), 'the authorized creation was not recorded');
  }

  /// @notice A Maxi creation runs the full choreography: seed pulled from the caller, sAERO minted
  ///         and transferred to the predicted address, clone born there and initialized.
  function test_WhenCreatingAMaxiRelay() external {
    uint256 _tokenId = 7;
    IRelayFactory.CreateParams memory _params = _createParams(bytes32('maxi'), true, 0);
    address _predicted = _armCreate(_creator, _params, _tokenId, address(_maxiImplementation));

    // it should pull the seed from the caller and approve the escrow for the stake
    vm.expectCall(_token, abi.encodeCall(IERC20.transferFrom, (_creator, address(_factory), _SEED)));
    vm.expectCall(_token, abi.encodeCall(IERC20.approve, (_votingEscrow, _SEED)));
    // it should hand the minted sAERO to the predicted address before the clone's birth
    vm.expectCall(_votingEscrow, abi.encodeCall(IERC721.transferFrom, (address(_factory), _predicted, _tokenId)));

    // it should emit RelayCreated with the predicted clone and the minted sAERO
    vm.expectEmit(address(_factory));
    emit IRelayFactory.RelayCreated(_predicted, _tokenId, IRelay.RelayType.Maxi);

    vm.prank(_creator);
    (address _relay, uint256 _mintedId) = _factory.createMaxiRelay(_params);

    // it should deploy the clone at the predicted address
    assertEq(_relay, _predicted);
    assertEq(_mintedId, _tokenId);
    assertEq(uint8(MaxiRelay(payable(_relay)).relayType()), uint8(IRelay.RelayType.Maxi));

    // it should stamp the minted sAERO and the permanent lock horizon into the config
    IRelay.RelayConfig memory _config = MaxiRelay(payable(_relay)).relayConfig();
    assertEq(_config.tokenId, _tokenId);
    assertEq(_config.lockWeeks, 0);

    // it should wire the named operators, the initial voter included
    MaxiRelay _born = MaxiRelay(payable(_relay));
    assertEq(_born.owner(), makeAddr('admin'));
    assertTrue(_born.hasAnyRole(makeAddr('keeper'), _born.KEEPER()));
    assertTrue(_born.hasAnyRole(makeAddr('voter'), _born.VOTER_ROLE()));
    assertTrue(_born.hasAnyRole(makeAddr('compounder'), _born.COMPOUNDER()));
    assertTrue(_born.hasAnyRole(makeAddr('converter'), _born.CONVERTER()));

    // it should pair mint the bootstrap against the seed
    assertEq(_born.principalToken().balanceOf(makeAddr('bootstrapOwner')), _SEED);
    assertEq(_born.yieldToken().balanceOf(makeAddr('bootstrapOwner')), _SEED);

    // it should ignore the entrypoint vetoer on the maxi tier
    assertFalse(_born.hasAnyRole(makeAddr('vetoer'), _born.ENTRYPOINT_VETOER()));
  }

  /// @notice A time-locked seed stamps its staking weeks as the lock horizon, so `extendLock`
  ///         refreshes to the same end the seed was created with.
  function test_WhenCreatingWithATimeLockedSeed() external {
    uint256 _tokenId = 8;
    IRelayFactory.CreateParams memory _params = _createParams(bytes32('locked'), false, 26);
    address _predicted = _armCreate(_creator, _params, _tokenId, address(_maxiImplementation));

    // it should forward the seed stake type to VotingEscrow
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.createStake, (_SEED, 26, false)));

    vm.prank(_creator);
    (address _relay,) = _factory.createMaxiRelay(_params);
    assertEq(_relay, _predicted);

    // it should stamp lockWeeks from the seed's staking weeks
    assertEq(MaxiRelay(payable(_relay)).relayConfig().lockWeeks, 26);
  }

  /// @notice A permanent seed ignores the staking weeks it was created with: the lock horizon is
  ///         always zero, the only value the clone's initialize accepts for a permanent stake.
  function test_WhenCreatingWithAPermanentSeedAndNonzeroStakingWeeks() external {
    uint256 _tokenId = 14;
    IRelayFactory.CreateParams memory _params = _createParams(bytes32('permweeks'), true, 26);
    address _predicted = _armCreate(_creator, _params, _tokenId, address(_maxiImplementation));

    // it should forward the staking weeks to VotingEscrow untouched
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.createStake, (_SEED, 26, true)));

    vm.prank(_creator);
    (address _relay,) = _factory.createMaxiRelay(_params);
    assertEq(_relay, _predicted);

    // it should stamp a zero lock horizon instead of the seed staking weeks
    assertEq(MaxiRelay(payable(_relay)).relayConfig().lockWeeks, 0);
  }

  /// @notice Protocol creations pick the tier from the level flag: L1 keeps the allow-list start,
  ///         L2 starts with the admin already owning the L2 surface.
  function test_WhenCreatingProtocolRelaysOnBothLevels() external {
    // L1 start (the kicking tier requires a soulbound YT, so the switch stays off)
    uint256 _tokenId = 9;
    IRelayFactory.CreateParams memory _params = _createParams(bytes32('l1'), true, 0);
    _params.ytTransferable = false;
    address _predicted = _armCreate(_creator, _params, _tokenId, address(_protocolImplementation));
    // it should emit RelayCreated with the L1 tier tag
    vm.expectEmit(address(_factory));
    emit IRelayFactory.RelayCreated(_predicted, _tokenId, IRelay.RelayType.ProtocolL1);
    vm.prank(_creator);
    (address _relay,) = _factory.createProtocolRelay(_params, false);
    assertEq(_relay, _predicted);
    assertEq(uint8(ProtocolRelay(payable(_relay)).relayType()), uint8(IRelay.RelayType.ProtocolL1));
    assertFalse(ProtocolRelay(payable(_relay)).isLevel2());
    // it should seat the named entrypoint vetoer on the protocol tier
    ProtocolRelay _bornL1 = ProtocolRelay(payable(_relay));
    assertTrue(_bornL1.hasAnyRole(makeAddr('vetoer'), _bornL1.ENTRYPOINT_VETOER()));

    // L2-direct start, from a different creator so the salt cannot collide
    address _creator2 = makeAddr('creator2');
    uint256 _tokenId2 = 10;
    address _predicted2 = _armCreate(_creator2, _params, _tokenId2, address(_protocolImplementation));
    // it should emit RelayCreated with the L2 tier tag
    vm.expectEmit(address(_factory));
    emit IRelayFactory.RelayCreated(_predicted2, _tokenId2, IRelay.RelayType.ProtocolL2);
    vm.prank(_creator2);
    (address _relay2,) = _factory.createProtocolRelay(_params, true);
    assertEq(_relay2, _predicted2);

    ProtocolRelay _born = ProtocolRelay(payable(_relay2));
    assertEq(uint8(_born.relayType()), uint8(IRelay.RelayType.ProtocolL2));
    assertTrue(_born.isLevel2());
    // it should leave the ownership with the admin on an L2-direct start
    assertEq(_born.owner(), makeAddr('admin'));
  }

  /// @notice The membership check consumers gate on (the MetaRouter rejects a route whose Relay this
  ///         returns false for), so what matters is that it is true for exactly the Relays this
  ///         factory created and false for everything else.
  /// @param _stranger Any address the factory did not create.
  function test_WhenCheckingWhetherAnAddressIsARelay(address _stranger) external {
    _assumeFuzzable(_stranger);

    // it should reject an address it did not create
    assertFalse(_factory.isRelay(_stranger), 'an uncreated address reads as a relay');
    assertFalse(_factory.isRelay(address(0)), 'the zero address reads as a relay');
    assertFalse(_factory.isRelay(address(_maxiImplementation)), 'the maxi implementation reads as a relay');
    assertFalse(_factory.isRelay(address(_protocolImplementation)), 'the protocol implementation reads as a relay');
    assertFalse(_factory.isRelay(address(_factory)), 'the factory reads as a relay');

    IRelayFactory.CreateParams memory _maxiParams = _createParams(bytes32('checked'), true, 0);
    address _predicted = _armCreate(_creator, _maxiParams, 30, address(_maxiImplementation));

    // The clone's address is known before it exists, so the check must not answer for it yet.
    assertFalse(_factory.isRelay(_predicted), 'the predicted address reads as a relay before its creation');

    vm.prank(_creator);
    (address _maxi,) = _factory.createMaxiRelay(_maxiParams);

    // it should recognize every relay it created on both tiers
    assertEq(_maxi, _predicted);
    assertTrue(_factory.isRelay(_maxi), 'a created maxi relay is not recognized');

    IRelayFactory.CreateParams memory _protocolParams = _createParams(bytes32('checkedToo'), true, 0);
    _protocolParams.ytTransferable = false;
    _armCreate(_creator, _protocolParams, 31, address(_protocolImplementation));
    vm.prank(_creator);
    (address _protocol,) = _factory.createProtocolRelay(_protocolParams, true);
    assertTrue(_factory.isRelay(_protocol), 'a created protocol relay is not recognized');

    // The fuzzer reaching either deterministic clone address would make the assertion below a lie.
    vm.assume(_stranger != _maxi && _stranger != _protocol);
    assertFalse(_factory.isRelay(_stranger), 'an uncreated address reads as a relay after creations');

    // A second factory over the same implementations answers only for its own deployments, so a
    // consumer gating on one factory cannot be satisfied by a Relay another factory created.
    RelayFactory _otherFactory =
      _newFactory(_votingEscrow, _voter, address(_maxiImplementation), address(_protocolImplementation));
    assertFalse(_otherFactory.isRelay(_maxi), 'a foreign factory recognizes a relay it did not create');
    assertFalse(_otherFactory.isRelay(_protocol), 'a foreign factory recognizes a relay it did not create');
  }

  /// @notice The factory keeps every Relay it created in an append-only list, so an on-chain reader can
  ///         discover them without an indexer, a subgraph, or replaying events.
  /// @dev The page bounds are clamped rather than checked, which is what lets a caller walk fixed-size
  ///      pages off the end without reading the length first.
  function test_WhenEnumeratingTheCreatedRelays() external {
    assertEq(_factory.allRelaysLength(), 0, 'a fresh factory already lists relays');
    assertEq(_factory.allRelays(0, 10).length, 0, 'a fresh factory returns a non-empty page');

    // Three Relays across both tiers and two creators, because the salt is scoped to the caller.
    IRelayFactory.CreateParams memory _maxiParams = _createParams(bytes32('first'), true, 0);
    _armCreate(_creator, _maxiParams, 20, address(_maxiImplementation));
    vm.prank(_creator);
    (address _first,) = _factory.createMaxiRelay(_maxiParams);
    // it should append on creation
    assertEq(_factory.allRelaysLength(), 1, 'the first relay was not recorded');

    IRelayFactory.CreateParams memory _protocolParams = _createParams(bytes32('second'), true, 0);
    _protocolParams.ytTransferable = false;
    _armCreate(_creator, _protocolParams, 21, address(_protocolImplementation));
    vm.prank(_creator);
    (address _second,) = _factory.createProtocolRelay(_protocolParams, false);

    address _otherCreator = makeAddr('otherCreator');
    IRelayFactory.CreateParams memory _thirdParams = _createParams(bytes32('third'), true, 0);
    _armCreate(_otherCreator, _thirdParams, 22, address(_maxiImplementation));
    vm.prank(_otherCreator);
    (address _third,) = _factory.createMaxiRelay(_thirdParams);

    assertEq(_factory.allRelaysLength(), 3, 'the length does not match the relays created');

    // it should append every created relay in creation order
    address[] memory _all = _factory.allRelays(0, 3);
    assertEq(_all.length, 3, 'the full page is the wrong size');
    assertEq(_all[0], _first, 'the first relay is out of order');
    assertEq(_all[1], _second, 'the second relay is out of order');
    assertEq(_all[2], _third, 'the third relay is out of order');

    // it should page with the start inclusive and the end exclusive
    address[] memory _firstPage = _factory.allRelays(0, 2);
    assertEq(_firstPage.length, 2, 'the first page is the wrong size');
    assertEq(_firstPage[0], _first, 'the first page starts at the wrong relay');
    assertEq(_firstPage[1], _second, 'the first page ends at the wrong relay');

    address[] memory _secondPage = _factory.allRelays(2, 4);
    assertEq(_secondPage.length, 1, 'the trailing page was not clamped to the length');
    assertEq(_secondPage[0], _third, 'the trailing page holds the wrong relay');

    // it should clamp a page that runs past the end instead of reverting
    assertEq(_factory.allRelays(0, type(uint256).max).length, 3, 'an unbounded end was not clamped');
    assertEq(_factory.allRelays(3, 10).length, 0, 'a start at the length returned something');
    assertEq(_factory.allRelays(99, 100).length, 0, 'a start past the end returned something');

    // it should return an empty page for an empty or inverted range
    assertEq(_factory.allRelays(1, 1).length, 0, 'an empty range returned something');
    assertEq(_factory.allRelays(2, 1).length, 0, 'an inverted range returned something');
  }

  /// @notice The salt is scoped to the caller: reusing a (caller, salt) pair on the same tier
  ///         reverts on the CREATE2 collision, while another caller can use the same salt freely.
  function test_WhenReusingACreationSalt() external {
    IRelayFactory.CreateParams memory _params = _createParams(bytes32('shared'), true, 0);
    _armCreate(_creator, _params, 11, address(_maxiImplementation));
    vm.prank(_creator);
    _factory.createMaxiRelay(_params);

    // it should revert when the same caller reuses the salt on the same tier
    _armCreate(_creator, _params, 12, address(_maxiImplementation));
    vm.prank(_creator);
    vm.expectRevert();
    _factory.createMaxiRelay(_params);

    // it should deploy at a different address for a different caller with the same salt
    address _creator2 = makeAddr('creator2');
    address _predicted2 = _armCreate(_creator2, _params, 13, address(_maxiImplementation));
    vm.prank(_creator2);
    (address _relay2,) = _factory.createMaxiRelay(_params);
    assertEq(_relay2, _predicted2);
  }

  /// @dev Build default creation inputs; the config's tokenId is deliberately garbage (the factory
  ///      overwrites it with the minted sAERO).
  function _createParams(
    bytes32 _salt,
    bool _isPermanent,
    uint48 _stakingWeeks
  ) internal returns (IRelayFactory.CreateParams memory _params) {
    _params = IRelayFactory.CreateParams({
      admin: makeAddr('admin'),
      keeper: makeAddr('keeper'),
      voter: makeAddr('voter'),
      compounder: makeAddr('compounder'),
      converter: makeAddr('converter'),
      bootstrapOwner: makeAddr('bootstrapOwner'),
      rewardToken: address(0),
      entrypointVetoer: makeAddr('vetoer'),
      seedAmount: _SEED,
      isPermanent: _isPermanent,
      ytTransferable: true,
      stakingWeeks: _stakingWeeks,
      salt: _salt,
      config: IRelay.RelayConfig({
        tokenId: 424_242,
        minDeposit: 1e18,
        keeperWindow: 1 days,
        minWithdrawal: 1e18,
        entrypointTimelock: 2 days,
        lockWeeks: 99, // overwritten by the factory from the seed stake type
        evacuationWindow: 7 days,
        name: 'Factory Relay',
        symbol: 'fREL'
      })
    });
  }

  /// @dev Arm every mock one creation performs, in call order: the deployer role read, the seed pull
  ///      and approve, the sAERO mint, the transfer to the predicted address and the clone's
  ///      initialize reads.
  /// @return _predicted The deterministic clone address the seed is parked at.
  function _armCreate(
    address _caller,
    IRelayFactory.CreateParams memory _params,
    uint256 _tokenId,
    address _implementation
  ) internal returns (address _predicted) {
    bytes32 _salt = keccak256(abi.encodePacked(_caller, _params.salt));
    _predicted = Clones.predictDeterministicAddress(_implementation, _salt, address(_factory));

    // Creation is role-gated, so a caller that is expected to succeed has to hold the role.
    _grantDeployer(_caller);

    // Seed pull and stake (RelayFactory._seedStake).
    vm.mockCall(
      _token,
      abi.encodeCall(IERC20.transferFrom, (_caller, address(_factory), uint256(_params.seedAmount))),
      abi.encode(true)
    );
    vm.mockCall(_token, abi.encodeCall(IERC20.approve, (_votingEscrow, uint256(_params.seedAmount))), abi.encode(true));
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.createStake, (_params.seedAmount, _params.stakingWeeks, _params.isPermanent)),
      abi.encode(_tokenId)
    );

    // Seed parked at the predicted address before the clone exists.
    vm.mockCall(
      _votingEscrow, abi.encodeCall(IERC721.transferFrom, (address(_factory), _predicted, _tokenId)), abi.encode()
    );

    // The clone's initialize (RelayInitLib.setUp): seed invariants and the standing allowance.
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.staked, (_tokenId)),
      abi.encode(
        IVotingEscrow.StakedBalance({
          amount: _params.seedAmount,
          end: _params.isPermanent ? 0 : uint48(block.timestamp + uint256(_params.stakingWeeks) * 1 weeks),
          isPermanent: _params.isPermanent
        })
      )
    );
    vm.mockCall(_votingEscrow, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_predicted));
    vm.mockCall(_token, abi.encodeCall(IERC20.approve, (_votingEscrow, type(uint256).max)), abi.encode(true));
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_vpm)), abi.encode(true));
  }
}
