// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MaxiRelay} from 'V3/relay/MaxiRelay.sol';
import {ProtocolRelay} from 'V3/relay/ProtocolRelay.sol';
import {RelayBase} from 'V3/relay/RelayBase.sol';
import {RelayToken} from 'V3/relay/RelayToken.sol';
import {RelayTokenVotes} from 'V3/relay/RelayTokenVotes.sol';
import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';

/**
 * @title BaseRelay
 * @notice Shared fixture for the PT/YT split Relay tests: mocked protocol dependencies
 *         (VotingEscrow / VPM / Voter), a real RelayToken implementation deployed with `new`, and a
 *         real Relay initialized through the production path so the PT/YT satellites are real
 *         EIP-1167 clones bound to the Relay.
 * @dev    Unlike the solitary relay unit suites, these tests exercise the Relay together with its
 *         satellite tokens (the pair invariant lives across the three contracts), so only the
 *         protocol dependencies are mocked. The choreography helpers mirror the exact external
 *         calls RelayInitLib/QueueLib make. `_requestDeposit` simulates no module fee (net == gross);
 *         `_requestDepositWithFee` is the variant that separates the two.
 */
abstract contract BaseRelay is TestHelpers {
  /// @dev Base timestamp warped to at setUp so timestamp-zero artifacts never appear.
  uint256 internal constant _INITIAL_TIMESTAMP = 1_000_000;

  /// @dev The Relay's own sAERO id, fixed by the default config.
  uint256 internal constant _RELAY_TOKEN_ID = 1;

  /// @dev Seed stake behind the bootstrap pair mint (genesis price/share is exactly 1).
  uint256 internal constant _SEED = 100e18;

  /// @dev Withdraw destination sentinel: route the weight to a freshly minted sAERO.
  uint256 internal constant _MINT_SENTINEL = type(uint256).max;

  /// @dev `keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')`.
  bytes32 internal constant _PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

  /// @dev `keccak256('Delegation(address delegatee,uint256 nonce,uint256 expiry)')`.
  bytes32 internal constant _DELEGATION_TYPEHASH =
    keccak256('Delegation(address delegatee,uint256 nonce,uint256 expiry)');

  /// @dev Allowance every signed permit in these suites asks for.
  uint256 internal constant _PERMIT_VALUE = 1e18;

  /// @dev Slot of RelayBase's private `_initialized` flag, its first declared variable (solady's
  ///      OwnableRoles keeps no ordinary storage). Raw slot on purpose: no view function reads the
  ///      flag. Cleared so a relay deployed with `new` (whose constructor marks the implementation
  ///      initialized) can run the real `initialize` path, as a fresh clone's storage would allow.
  uint256 internal constant _SLOT_INITIALIZED = 0;

  /// @dev Mocked protocol dependencies, etched with bytecode so un-mocked calls revert loudly.
  address internal _votingEscrow;
  address internal _vpm;
  address internal _voter;

  /// @dev Mocked Governor address the relay's governance passthrough forwards casts to.
  address internal _governor;
  address internal _token;
  address internal _rewardToken;

  /// @dev Named operators wired at initialization.
  address internal _admin;
  address internal _keeper;
  address internal _allocator;
  address internal _compounder;
  address internal _converter;
  address internal _bootstrapOwner;

  /// @dev Real RelayToken implementation the Relay clones twice at initialization.
  RelayToken internal _relayTokenImplementation;

  /// @dev Checkpointed RelayToken implementation every PT clone runs.
  RelayTokenVotes internal _principalTokenImplementation;

  /// @dev The canonical vote adapter (stateless), deployed real like the satellite implementations.
  RelayVoteAdapter internal _voteAdapter;

  /// @dev The wrapped native the relay wraps every native inflow into.
  address internal _weth;

  /// @dev The relay under test; subclasses bind it via `_deployMaxi`/`_deployProtocol` (or their
  ///      own deploy helper).
  RelayBase internal _relay;

  /// @dev Protocol-typed view of `_relay`, bound by `_deployProtocol` so tier-only surface
  ///      (allow list, kick) is reachable without casts in the tests.
  ProtocolRelay internal _protocolRelay;

  /// @dev The satellite clones, read back from the relay after initialization. Typed as the
  ///      concrete RelayToken so tests reach the full ERC-20 surface (transfer, name, ...).
  RelayTokenVotes internal _principalToken;
  RelayToken internal _yieldToken;

  /// @dev Tracked staked amount of the Relay sAERO, evolved by the mock helpers so sequential
  ///      `staked()` reads stay consistent across lifecycle steps.
  uint256 internal _relayStaked;

  /// @dev Tracked reward-token balance sitting on the relay, grown by `_notifyReward` so the
  ///      notify's un-accounted-balance guard prices against a consistent `balanceOf`.
  uint256 internal _rewardOnRelay;

  function setUp() public virtual {
    vm.warp(_INITIAL_TIMESTAMP);
    _votingEscrow = _mockContract('VotingEscrow');
    _vpm = _mockContract('VoterPaymentsModule');
    _voter = _mockContract('Voter');
    _governor = _mockContract('Governor');
    _token = _mockContract('Token');
    _rewardToken = _mockContract('RewardToken');
    _admin = makeAddr('admin');
    _keeper = makeAddr('keeper');
    _allocator = makeAddr('allocator');
    _compounder = makeAddr('compounder');
    _converter = makeAddr('converter');
    _bootstrapOwner = makeAddr('bootstrapOwner');

    // `VOTING_ESCROW.TOKEN()` is read by every relay constructor; must precede any deployment.
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.TOKEN, ()), abi.encode(_token));

    // Real implementations, deployed with `new` — the production wiring the relay clones from. The
    // PT clones the checkpointed variant (governance weight is the principal balance), the YT the
    // plain one.
    _relayTokenImplementation = new RelayToken();
    _principalTokenImplementation = new RelayTokenVotes();
    _voteAdapter = new RelayVoteAdapter();
    _weth = _deployWrappedNative();
  }

  /// @dev The wrapped native bound into every relay deployed by this fixture. Mocked, like the rest
  ///      of the protocol dependencies; suites that need real wrapping override it.
  function _deployWrappedNative() internal virtual returns (address _wrappedNative) {
    _wrappedNative = _mockContract('WrappedNative');
  }

  /// @dev Constrain a fuzzed address to an account that can take a fresh share position. On top of
  ///      `_assumeFuzzable` (precompiles, zero, forge addresses) it excludes the relay and its two
  ///      satellites, banned as share recipients, and the bootstrap owner, which already holds the
  ///      seeded pair. The fuzzer's dictionary picks up addresses out of the deployed state, so
  ///      without this a run lands on the yield clone and reverts `InvalidRecipient`, or on the
  ///      bootstrap owner and doubles the balance the test prices against.
  function _assumeFreshHolder(address _holder) internal view {
    _assumeFuzzable(_holder);
    vm.assume(_holder != address(_relay));
    vm.assume(_holder != address(_principalToken) && _holder != address(_yieldToken));
    vm.assume(_holder != _bootstrapOwner);
  }

  /// @dev THE pair invariant: PT and YT supplies stay equal at all times. Call after every step.
  function _assertPairInvariant() internal view {
    assertEq(_principalToken.totalSupply(), _yieldToken.totalSupply(), 'pair invariant: ptSupply == ytSupply');
  }

  /// @dev Deploy a real MaxiRelay with `new` against the mocked dependencies and initialize it
  ///      through the real path, so the satellites are real clones.
  function _deployMaxi(bool _ytTransferable) internal {
    _relay = new MaxiRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
    _initializeRelay(_defaultInitParams(_ytTransferable));
  }

  /// @dev Deploy a real ProtocolRelay with `new` against the mocked dependencies and initialize it
  ///      through the real path, binding both the base and the Protocol-typed handles.
  function _deployProtocol(bool _ytTransferable) internal {
    _deployProtocolUninitialized();
    _initializeRelay(_defaultInitParams(_ytTransferable));
  }

  /// @dev Deploy a real ProtocolRelay with `new` WITHOUT initializing it, for tests that drive (or
  ///      expect to revert) `initialize` themselves.
  function _deployProtocolUninitialized() internal {
    _protocolRelay = new ProtocolRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
    _relay = _protocolRelay;
  }

  /// @dev Run the real `initialize` on `_relay`: arm the initialize choreography, run it, then bind
  ///      the satellite clones the init deployed.
  function _initializeRelay(IRelay.InitParams memory _params) internal {
    _mockInitializeChoreography();

    _relay.initialize(_params);

    _principalToken = RelayTokenVotes(address(_relay.principalToken()));
    _yieldToken = RelayToken(address(_relay.yieldToken()));
    _assertPairInvariant();
  }

  /// @dev Arm `_relay` for a real `initialize` call: clear the constructor's initialized flag (the
  ///      clone-storage recipe) and mock the seed validation reads plus the standing compound
  ///      approval. Exposed separately so revert-path tests can call `initialize` bare.
  function _mockInitializeChoreography() internal {
    vm.store(address(_relay), bytes32(_SLOT_INITIALIZED), bytes32(0));

    // Seed invariants (RelayInitLib.setUp): the relay owns its sAERO and it carries the seed stake.
    _mockRelayStaked(_SEED);
    vm.mockCall(_votingEscrow, abi.encodeCall(IERC721.ownerOf, (_RELAY_TOKEN_ID)), abi.encode(address(_relay)));
    // The module authorization creation checks before approving the VPM as the sAERO spender.
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_vpm)), abi.encode(true));
    // Standing max approval of TOKEN to the VotingEscrow for `compound`.
    vm.mockCall(_token, abi.encodeCall(IERC20.approve, (_votingEscrow, type(uint256).max)), abi.encode(true));
  }

  /// @dev Default configuration for the relay under test.
  function _defaultConfig() internal pure returns (IRelay.RelayConfig memory _config) {
    _config = IRelay.RelayConfig({
      tokenId: _RELAY_TOKEN_ID,
      minDeposit: 1e18,
      keeperWindow: 1 days,
      minWithdrawal: 1e18,
      entrypointTimelock: 2 days,
      lockWeeks: 0,
      evacuationWindow: 7 days,
      name: 'Test Relay',
      symbol: 'tREL'
    });
  }

  /// @dev Default initialization inputs: named operators, both entrypoint lanes wired and the
  ///      caller-chosen YT transferability switch.
  function _defaultInitParams(bool _ytTransferable) internal view returns (IRelay.InitParams memory _params) {
    _params = IRelay.InitParams({
      admin: _admin,
      keeper: _keeper,
      voter: _allocator,
      compounder: _compounder,
      converter: _converter,
      bootstrapOwner: _bootstrapOwner,
      rewardToken: address(0),
      entrypointVetoer: address(0),
      vpm: IVoterPaymentsModule(_vpm),
      governor: IGovernor(_governor),
      voteAdapter: _voteAdapter,
      startAsLevel2: false,
      ytTransferable: _ytTransferable,
      config: _defaultConfig()
    });
  }

  /// @dev Request an async deposit as `_owner`, mocking QueueLib.registerDeposit's choreography:
  ///      source authorization, owner resolution, the VPM weight move and the staked sandwich
  ///      measuring the net amount (no VPM fee: net == `_amount`).
  function _requestDeposit(address _owner, uint256 _sourceTokenId, uint256 _amount) internal {
    _requestDepositWithFee(_owner, _sourceTokenId, _amount, _amount);
  }

  /// @dev A deposit request the module charges a protocol fee on: `_gross` leaves the source and only
  ///      `_net` lands on the Relay sAERO. The Relay never sees the rate, it measures the difference
  ///      across its own staked balance, so the fee is simulated by the staked delta alone.
  function _requestDepositWithFee(address _owner, uint256 _sourceTokenId, uint256 _gross, uint256 _net) internal {
    _mockDepositAuthorization(_owner, _sourceTokenId);
    _mockDepositIntoNFT(_sourceTokenId, _gross);
    _mockRelayStakedDelta(_net);

    vm.prank(_owner);
    _relay.requestDeposit(_sourceTokenId, _gross);
  }

  /// @dev Mock the source-sAERO reads `requestDeposit` performs before any weight moves: caller
  ///      authorization and owner resolution (the owner is who the tier deposit gate authorizes).
  function _mockDepositAuthorization(address _owner, uint256 _sourceTokenId) internal {
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorized, (_owner, _sourceTokenId)), abi.encode(true));
    _mockSourceOwner(_sourceTokenId, _owner);
  }

  /// @dev Mock the owner of a source sAERO, read by the two-arg `requestDeposit` to name the share
  ///      recipient at request time.
  function _mockSourceOwner(uint256 _sourceTokenId, address _owner) internal {
    vm.mockCall(_votingEscrow, abi.encodeCall(IERC721.ownerOf, (_sourceTokenId)), abi.encode(_owner));
  }

  /// @dev Walk the deposit queue as the keeper and process up to `_maxEntries` entries.
  function _processPending(uint256 _maxEntries) internal {
    _mockFreeChainZero();
    vm.prank(_keeper);
    _relay.processPending(_maxEntries);
  }

  /// @dev Full admission: request then drain one entry, returning the shares actually pair-minted
  ///      (measured as the PT balance delta, not recomputed from the pricing formula).
  function _admitDeposit(address _owner, uint256 _sourceTokenId, uint256 _amount) internal returns (uint256 _shares) {
    _requestDeposit(_owner, _sourceTokenId, _amount);
    uint256 _balanceBefore = _principalToken.balanceOf(_owner);
    _processPending(1);
    _shares = _principalToken.balanceOf(_owner) - _balanceBefore;
    _assertPairInvariant();
  }

  /// @dev Land a leaf claim recipient through the real path: propose it, wait out the delay the
  ///      re-point pays, then execute. Both legs are ADMIN-gated.
  function _landLeafRecipient(uint256 _chainId, address _recipient) internal {
    uint256 _timelock = _relay.relayConfig().entrypointTimelock;
    vm.startPrank(_admin);
    _relay.proposeLeafRecipient(_chainId, _recipient);
    skip(_timelock);
    _relay.executeLeafRecipient(_chainId);
    vm.stopPrank();
  }

  /// @dev Register the single reward token the accumulator settles (keeper-gated).
  function _registerRewardToken() internal {
    vm.prank(_keeper);
    _relay.addRewardToken(_rewardToken);
  }

  /// @dev Notify a reward batch as the converter, growing the mocked reward balance sitting on the
  ///      relay so the un-accounted guard sees the batch as arrived.
  function _notifyReward(uint256 _amount) internal {
    _rewardOnRelay += _amount;
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(_rewardOnRelay));
    vm.prank(_converter);
    _relay.notifyReward(_rewardToken, _amount);
  }

  /// @dev Mock QueueLib.processWithdrawals' routing for one mint-sentinel exit: the VPM route out
  ///      and the fresh sAERO's staked read measuring the delivered amount (no VPM fee). Also
  ///      re-mocks the Relay sAERO's staked amount at the post-drain value, so later reads
  ///      (donations, the vote reserve, the next deposit sandwich) never see the pre-drain stake.
  ///      Safe to arm before the drain: the sentinel route never reads `staked(relayTokenId)`.
  function _mockWithdrawRoute(address _holder, uint256 _amount, uint256 _mintedId) internal {
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta({
      tokenId: _MINT_SENTINEL,
      // forge-lint: disable-next-line(unsafe-typecast)
      amount: uint128(_amount),
      recipient: _holder
    });
    uint256[] memory _mintedIds = new uint256[](1);
    _mintedIds[0] = _mintedId;
    _mockAndExpect(
      _vpm, abi.encodeCall(IVoterPaymentsModule.withdrawToNFT, (_RELAY_TOKEN_ID, _destinations)), abi.encode(_mintedIds)
    );
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.staked, (_mintedId)), abi.encode(_stakedBalance(_amount)));
    _mockRelayStaked(_relayStaked - _amount);
  }

  /// @dev Mock the Relay sAERO's staked amount at a fixed value (persists for repeated reads).
  function _mockRelayStaked(uint256 _amount) internal {
    vm.mockCall(
      _votingEscrow, abi.encodeCall(IVotingEscrow.staked, (_RELAY_TOKEN_ID)), abi.encode(_stakedBalance(_amount))
    );
    _relayStaked = _amount;
  }

  /// @dev Mock the two `staked(relayTokenId)` reads sandwiching a VPM deposit move so the relay
  ///      observes exactly `_net` credited; the second value persists for later reads.
  function _mockRelayStakedDelta(uint256 _net) internal {
    bytes memory _calldata = abi.encodeCall(IVotingEscrow.staked, (_RELAY_TOKEN_ID));
    bytes[] memory _returns = new bytes[](2);
    _returns[0] = abi.encode(_stakedBalance(_relayStaked));
    _returns[1] = abi.encode(_stakedBalance(_relayStaked + _net));
    vm.mockCalls(_votingEscrow, _calldata, _returns);
    _relayStaked += _net;
  }

  /// @dev Mock (and expect) the VPM weight move of a deposit request: one source delta into the
  ///      Relay sAERO, no mint (recipient zero).
  function _mockDepositIntoNFT(uint256 _sourceTokenId, uint256 _amount) internal {
    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](1);
    // forge-lint: disable-next-line(unsafe-typecast)
    _sources[0] = IVotingEscrow.SourceDelta({tokenId: _sourceTokenId, amount: uint128(_amount)});
    _mockAndExpect(
      _vpm,
      abi.encodeCall(IVoterPaymentsModule.depositIntoNFT, (_sources, _RELAY_TOKEN_ID, address(0))),
      abi.encode(new uint256[](0))
    );
  }

  /// @dev Mock the free chain0 weight unbounded, plus the cast itself: that reading prices every
  ///      withdraw drain these lifecycles reach after admitting a deposit.
  function _mockFreeChainZero() internal {
    vm.mockCall(
      _voter, abi.encodeCall(IVoter.allocationChainAmounts, (_RELAY_TOKEN_ID, 0)), abi.encode(type(uint128).max)
    );
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.allocate.selector), abi.encode());
  }

  /// @dev Build a permanent StakedBalance of `_amount` (the shape every mocked staked read returns).
  function _stakedBalance(uint256 _amount) internal pure returns (IVotingEscrow.StakedBalance memory _balance) {
    // forge-lint: disable-next-line(unsafe-typecast)
    _balance = IVotingEscrow.StakedBalance({amount: uint128(_amount), end: 0, isPermanent: true});
  }

  /// @dev Sign an EIP-2612 permit the way a wallet would: against the domain the clone itself
  ///      reports, at the owner's current nonce, never expiring. Solady derives that domain from
  ///      `name()` on every call, so signing against the live value is what makes these signatures a
  ///      real test of whether the domain moved.
  function _signPermit(
    RelayToken _relayToken,
    uint256 _key,
    address _owner,
    address _spender
  ) internal view returns (uint8 _v, bytes32 _r, bytes32 _s) {
    bytes32 _structHash = keccak256(
      abi.encode(_PERMIT_TYPEHASH, _owner, _spender, _PERMIT_VALUE, _relayToken.nonces(_owner), type(uint256).max)
    );
    (_v, _r, _s) = vm.sign(_key, keccak256(abi.encodePacked('\x19\x01', _relayToken.DOMAIN_SEPARATOR(), _structHash)));
  }

  /// @dev Sign an ERC-5805 delegation against the same domain, at a caller-chosen nonce. The nonce is
  ///      explicit because callers need to name the exact one a permit would have spent.
  function _signDelegation(
    RelayToken _relayToken,
    uint256 _key,
    address _delegatee,
    uint256 _nonce
  ) internal view returns (uint8 _v, bytes32 _r, bytes32 _s) {
    bytes32 _structHash = keccak256(abi.encode(_DELEGATION_TYPEHASH, _delegatee, _nonce, type(uint256).max));
    (_v, _r, _s) = vm.sign(_key, keccak256(abi.encodePacked('\x19\x01', _relayToken.DOMAIN_SEPARATOR(), _structHash)));
  }
}
