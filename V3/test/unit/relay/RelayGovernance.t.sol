// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {Ownable} from '@solady/auth/Ownable.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';
import {MaliciousVoteAdapter} from 'V3-test/unit/relay/harnesses/MaliciousVoteAdapter.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken, IRelayTokenHook} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {RelayBase} from 'V3/relay/RelayBase.sol';
import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';
import {RelayGovernanceLib, VOTE_TYPE_FRACTIONAL} from 'V3/relay/libraries/RelayGovernanceLib.sol';

/// @notice Governance as a LINKED LIBRARY over a MaxiRelay with a transferable yield token.
///         The Relay exposes one permissionless `expressVote`, keeps the consumption ledger in its own
///         storage and delegatecalls `RelayGovernanceLib` for the slice arithmetic, the booking and
///         the Governor's fractional encoding.
/// @dev    The headline property is `test_SellingTheYieldTokenMovesNoVote`: governance follows the
///         principal, so the yield can trade without the vote trading with it. The shape-specific
///         payoffs are `test_GovernanceLaneIsLiveFromTheFirstBlock` (no attach step, no role) and
///         `test_TheConsumptionLedgerLivesOnTheRelay` (relinking the library cannot reset a holder's
///         spend). Concrete stateful stories, hand-computed from the seeded 1:1 genesis (seed 100e18).
contract UnitRelayGovernance is BaseRelay {
  using stdStorage for StdStorage;

  /// @dev Proposal the suite votes on, and the snapshot its reads anchor to.
  uint256 internal constant _PROPOSAL_ID = 42;

  /// @dev The Relay sAERO's governance weight at the snapshot, carved into holder slices.
  uint256 internal constant _RELAY_WEIGHT = 1000e18;

  /// @dev Unbacked principal a hostile adapter's mint payload tries to conjure.
  uint256 internal constant _UNBACKED_MINT = 1e30;

  /// @dev Snapshot timestamp every governance read anchors to.
  uint256 internal _snapshot;

  /// @dev Role ids cached once: reading them off the Relay is an external call, which would consume
  ///      a pending `vm.prank` when used inline as an argument.
  /// @dev Solady's owner slot (`Ownable._OWNER_SLOT`), a fixed constant immune to layout drift.
  bytes32 internal constant _OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;

  uint256 internal _voterRole;
  uint256 internal _keeperRole;

  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
    // Blanket cast mock (any calldata for this selector) so the library always decodes a return
    // value; each test still pins the exact forwarded calldata with `vm.expectCall`.
    vm.mockCall(
      _governor, abi.encodeWithSelector(IGovernor.castVoteWithReasonAndParams.selector), abi.encode(uint256(0))
    );
    _voterRole = _relay.VOTER_ROLE();
    _keeperRole = _relay.KEEPER();
  }

  /// @notice Admission checkpoints the PT and self-delegates the depositor, with no manual
  ///         `delegate` call, while the YT carries no checkpoint surface at all.
  function test_WhenADepositIsAdmitted() external {
    // it should report both legs of the pair mint to the relay hook: the PT and the YT each mint
    // 50e18 to alice, so the relay hears the same move exactly twice
    vm.expectCall(
      address(_relay), abi.encodeCall(IRelayTokenHook.onRelayTokenTransfer, (address(0), users.alice, 50e18)), 2
    );

    uint256 _shares = _admitDeposit(users.alice, 1, 50e18);
    assertEq(_shares, 50e18);

    // it should self-delegate the depositor on first receipt
    assertEq(_principalToken.delegates(users.alice), users.alice);

    // it should checkpoint the depositor's principal and the principal total supply
    _warpPastSnapshot();
    assertEq(_principalToken.getPastVotes(users.alice, block.timestamp - 1), 50e18);
    assertEq(_principalToken.getPastVotesTotalSupply(block.timestamp - 1), _SEED + 50e18);

    // it should leave the yield token with no voting units: governance is the principal balance
    assertEq(_yieldToken.balanceOf(users.alice), 50e18);
    assertEq(RelayGovernanceLib.getPastTotalSupply(address(_relay), block.timestamp - 1), _SEED + 50e18);
    _assertPairInvariant();
  }

  /// @notice `expressVote` sizes each cast to the holder's snapshot slice of the Relay weight and
  ///         books it, so two holders spend proportionally and neither can overspend.
  function test_WhenHoldersExpressNominalVotes() external {
    _admitDeposit(users.alice, 1, 100e18);
    _admitDeposit(users.bob, 2, 100e18);
    _admitDeposit(users.charlie, 3, 100e18);
    _armGovernanceSnapshot();

    // Supply at the snapshot is 400e18 (100e18 bootstrap plus three 100e18 admissions), so each
    // depositor's slice is a quarter of the Relay's 1000e18 weight.
    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 400e18;

    _expectCast(_expectedSlice, 1, 'for');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'for');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), _expectedSlice);

    // it should let a second holder spend their own slice independently
    _expectCast(_expectedSlice, 0, 'against');
    vm.prank(users.bob);
    _relay.expressVote(_PROPOSAL_ID, 0, '', 'against');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.bob), _expectedSlice);

    // it should refuse a second cast once the slice is spent
    vm.prank(users.alice);
    vm.expectRevert(IRelay.AlreadyVoted.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'again');

    // it should refuse a fractional split larger than the remaining slice
    bytes memory _params = abi.encodePacked(uint128(0), uint128(_RELAY_WEIGHT), uint128(0));
    vm.prank(users.charlie);
    vm.expectRevert(IRelay.ExceedsRemainingSlice.selector);
    _relay.expressVote(_PROPOSAL_ID, VOTE_TYPE_FRACTIONAL, _params, 'too much');

    // it should accept abstain (support 2) and spend the whole slice in that direction
    _expectCast(_expectedSlice, 2, 'abstain');
    vm.prank(users.charlie);
    _relay.expressVote(_PROPOSAL_ID, 2, '', 'abstain');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.charlie), _expectedSlice);
  }

  /// @notice `expressVote` emits the holder's preference from the RELAY's address, since the library
  ///         runs by delegatecall, so an indexer follows one contract per Relay.
  function test_WhenAVoteIsExpressed() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();

    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;

    // it should emit VoteExpressed with the Relay as the log source
    vm.expectEmit(address(_relay));
    emit IRelay.VoteExpressed(_PROPOSAL_ID, users.alice, 1, _expectedSlice, '');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'for');
  }

  /// @notice The UI reads: the library answers "how much can this holder vote" and "how much is
  ///         left" for any Relay address, so a front end never reproduces the slice formula, and gets
  ///         zero (rather than a revert) for an address with no principal.
  function test_WhenTheUiPricesASlice() external {
    _admitDeposit(users.alice, 1, 100e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 100e18));
    _armGovernanceSnapshot();

    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;

    // it should price the holder's whole slice before any cast
    assertEq(RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.alice), _expectedSlice);
    assertEq(RelayGovernanceLib.remainingVotingPower(address(_relay), _PROPOSAL_ID, users.alice), _expectedSlice);

    // it should return zero for the yield buyer instead of reverting
    assertEq(RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.bob), 0);
    assertEq(RelayGovernanceLib.remainingVotingPower(address(_relay), _PROPOSAL_ID, users.bob), 0);

    // it should subtract a partial spend from the budget: a 60e18 split off a 500e18 slice leaves
    // 440e18, while the total budget stays the same
    vm.prank(users.alice);
    _relay.expressVote(
      _PROPOSAL_ID, VOTE_TYPE_FRACTIONAL, abi.encodePacked(uint128(0), uint128(60e18), uint128(0)), 'partial'
    );
    assertEq(RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.alice), _expectedSlice);
    assertEq(RelayGovernanceLib.remainingVotingPower(address(_relay), _PROPOSAL_ID, users.alice), 440e18);

    // it should drop the remaining budget to zero once the slice is spent
    _expectCast(440e18, 1, 'for');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'for');
    assertEq(RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.alice), _expectedSlice);
    assertEq(RelayGovernanceLib.remainingVotingPower(address(_relay), _PROPOSAL_ID, users.alice), 0);

    // it should clamp the budget at zero when the ledger reads above the slice
    vm.mockCall(
      address(_relay),
      abi.encodeCall(_relay.usedGovernanceWeight, (_governor, _PROPOSAL_ID, users.alice)),
      abi.encode(_expectedSlice + 1)
    );
    assertEq(RelayGovernanceLib.remainingVotingPower(address(_relay), _PROPOSAL_ID, users.alice), 0);
  }

  /// @notice The same views answer a plain CALL at the library's own deployed address, which is what
  ///         lets a UI price a slice without the Relay carrying any view bytecode.
  function test_WhenTheLibraryViewsAreCalledDirectly() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();

    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;
    address _lib = deployCode('RelayGovernanceLib.sol:RelayGovernanceLib');

    // it should answer votingPower over a staticcall to the library address
    (bool _ok, bytes memory _returned) = _lib.staticcall(
      abi.encodeWithSelector(RelayGovernanceLib.votingPower.selector, address(_relay), _PROPOSAL_ID, users.alice)
    );
    assertTrue(_ok, 'votingPower not callable at the library address');
    assertEq(abi.decode(_returned, (uint256)), _expectedSlice);

    // it should answer remainingVotingPower the same way
    (_ok, _returned) = _lib.staticcall(
      abi.encodeWithSelector(
        RelayGovernanceLib.remainingVotingPower.selector, address(_relay), _PROPOSAL_ID, users.alice
      )
    );
    assertTrue(_ok, 'remainingVotingPower not callable at the library address');
    assertEq(abi.decode(_returned, (uint256)), _expectedSlice);
  }

  /// @notice THE property the PT/YT split exists for: selling every yield token moves no vote. The
  ///         seller keeps their full checkpointed weight and can still express it; the buyer gets
  ///         none and cannot vote at all.
  function test_WhenTheYieldTokenIsSold() external {
    _admitDeposit(users.alice, 1, 100e18);

    // Alice sells her entire yield position to Bob, who holds no principal.
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 100e18));
    assertEq(_yieldToken.balanceOf(users.alice), 0);
    assertEq(_yieldToken.balanceOf(users.bob), 100e18);
    assertEq(_principalToken.balanceOf(users.bob), 0);
    _assertPairInvariant();

    _armGovernanceSnapshot();

    // it should leave the seller's checkpointed votes untouched and equal to their principal
    assertEq(_principalToken.getPastVotes(users.alice, _snapshot), 100e18);
    assertEq(_principalToken.balanceOf(users.alice), 100e18);

    // it should give the yield buyer no voting power at all
    assertEq(_principalToken.getPastVotes(users.bob, _snapshot), 0);
    vm.prank(users.bob);
    vm.expectRevert(IRelay.NoVotingPower.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'bought the yield');

    // it should still let the seller express their whole slice
    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;
    _expectCast(_expectedSlice, 1, 'sold the yield, kept the vote');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'sold the yield, kept the vote');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), _expectedSlice);
  }

  /// @notice The vote-bearing token cannot be bought: the PT is soulbound even on a Relay whose YT
  ///         trades freely.
  function test_WhenBuyingThePrincipalToken() external {
    _admitDeposit(users.alice, 1, 100e18);

    vm.prank(users.alice);
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    _principalToken.transfer(users.bob, 100e18);

    vm.prank(users.alice);
    assertTrue(_principalToken.approve(users.bob, 100e18));
    vm.prank(users.bob);
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    _principalToken.transferFrom(users.alice, users.bob, 100e18);
  }

  /// @notice Exiting removes the voting weight: the drain's principal burn drops both the holder's
  ///         checkpointed votes and the checkpointed total supply.
  function test_WhenAHolderWithdraws() external {
    _admitDeposit(users.alice, 1, 100e18);

    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(100e18, _MINT_SENTINEL);
    _mockWithdrawRoute(users.alice, 100e18, 777);
    _relay.processWithdrawals(1);

    assertEq(_principalToken.balanceOf(users.alice), 0);
    assertEq(_principalToken.totalSupply(), _SEED);
    _assertPairInvariant();

    _armGovernanceSnapshot();

    // it should drop the exited holder's checkpointed votes and shrink the checkpointed supply
    assertEq(_principalToken.getPastVotes(users.alice, _snapshot), 0);
    assertEq(_principalToken.getPastVotesTotalSupply(_snapshot), _SEED);

    // it should leave the exited holder unable to vote
    vm.prank(users.alice);
    vm.expectRevert(IRelay.NoVotingPower.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'already exited');
  }

  /// @notice The library shape's first payoff: there is nothing to attach. A Relay minted seconds ago
  ///         votes immediately, with no module deploy, no role grant and no genesis parameter.
  function test_GivenAFreshlyInitializedRelay() external {
    // A brand new Relay, initialized with no governance input of any kind.
    _deployMaxi(true);
    uint256 _shares = _admitDeposit(users.alice, 1, 100e18);
    assertEq(_shares, 100e18);
    _armGovernanceSnapshot();

    // it should cast on the first ask, from the Relay's own address
    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;
    _expectCast(_expectedSlice, 1, 'live at birth');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'live at birth');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), _expectedSlice);
  }

  /// @notice The library shape's second payoff: the consumption ledger is Relay storage, not library
  ///         storage, so relinking the lane on a future implementation cannot hand a holder a second
  ///         spend. Each Relay also keeps its own ledger.
  function test_GivenTheConsumptionLedgerIsRead() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();
    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;

    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'for');

    // it should record the spend on the Relay, readable without the library
    RelayBase _spent = _relay;
    assertEq(_spent.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), _expectedSlice);

    // it should leave a second Relay's ledger untouched by the first Relay's spend
    _deployMaxi(true);
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), 0);
    assertEq(_spent.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), _expectedSlice);
  }

  /// @notice The entrypoint is permissionless, and the slice is the only gate: an account with no
  ///         checkpointed principal is refused, and reaching `expressVote` grants no other power.
  function test_WhenACallerHoldsNoSnapshotPrincipal() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();

    // it should refuse an account that never held principal
    vm.prank(users.owner);
    vm.expectRevert(IRelay.NoVotingPower.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'never deposited');

    // it should refuse support values the counting module does not define
    vm.prank(users.alice);
    vm.expectRevert(IRelay.InvalidSupport.selector);
    _relay.expressVote(_PROPOSAL_ID, 3, '', 'not a direction');

    // it should refuse nominal support carrying params
    vm.prank(users.alice);
    vm.expectRevert(IRelay.InvalidSupport.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, abi.encodePacked(uint128(1), uint128(0), uint128(0)), 'mixed shapes');

    // it should give a voting holder no power over the Relay's other lanes
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.allocate(new IVoter.ChainAllocationDispatch[](0), new IVoter.GaugeAllocationDispatch[](0), address(0));

    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.processPending(1);
  }

  /// @notice A fractional cast forwards the holder's own three-way split verbatim and books its
  ///         sum, so a holder can spread one slice across directions and calls.
  function test_WhenExpressingAFractionalSplit() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();

    // it should forward the split untouched and consume its sum
    bytes memory _params = abi.encodePacked(uint128(10e18), uint128(30e18), uint128(20e18));
    vm.expectCall(
      _governor,
      abi.encodeCall(
        IGovernor.castVoteWithReasonAndParams, (_PROPOSAL_ID, _RELAY_TOKEN_ID, VOTE_TYPE_FRACTIONAL, 'split', _params)
      )
    );
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, VOTE_TYPE_FRACTIONAL, _params, 'split');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), 60e18);

    // it should size a later nominal cast to what the split left, not to the whole slice: the
    // 500e18 slice minus the 60e18 already spent is 440e18, and the ledger closes at 500e18
    _expectCast(440e18, 1, 'rest');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'rest');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), 500e18);
  }

  /// @notice The counting-module shape is enforced: a fractional cast must carry exactly three
  ///         packed uint128 weights.
  function test_WhenTheFractionalPayloadIsMalformed() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();

    // it should reject a fractional payload that is not exactly 0x30 bytes
    vm.prank(users.alice);
    vm.expectRevert(IRelay.InvalidSupport.selector);
    _relay.expressVote(_PROPOSAL_ID, VOTE_TYPE_FRACTIONAL, abi.encodePacked(uint128(1), uint128(2)), 'short');

    // it should reject a payload longer than 0x30 bytes too, not just a short one: this one carries
    // the three weights plus one trailing byte
    vm.prank(users.alice);
    vm.expectRevert(IRelay.InvalidSupport.selector);
    _relay.expressVote(
      _PROPOSAL_ID, VOTE_TYPE_FRACTIONAL, abi.encodePacked(uint128(1), uint128(2), uint128(3), uint8(0)), 'long'
    );
  }

  /// @notice A slice wider than the counting module's uint128 components spends in capped bites:
  ///         the nominal cast books exactly uint128.max and the remainder stays spendable.
  function test_WhenTheSlicePassesTheComponentWidth() external {
    _admitDeposit(users.alice, 1, 100e18);
    _warpPastSnapshot();
    _snapshot = block.timestamp - 1;
    vm.mockCall(_governor, abi.encodeCall(IGovernor.proposalSnapshot, (_PROPOSAL_ID)), abi.encode(_snapshot));
    // Relay weight of four component-widths: alice's half-slice still overflows uint128.
    uint256 _hugeWeight = uint256(type(uint128).max) * 4;
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.getPastVotes, (address(_relay), _RELAY_TOKEN_ID, _snapshot)),
      abi.encode(_hugeWeight)
    );

    // it should forward exactly uint128.max and book the same amount
    _expectCast(uint256(type(uint128).max), 1, 'cap');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'cap');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), type(uint128).max);
  }

  /// @notice A deposit still queued at the snapshot holds no principal, yet its weight already sits
  ///         inside the Relay's sAERO. The holders already in divide that weight like any other,
  ///         which is how the gauge side already spends it, so no part of the Relay's vote is
  ///         parked for the length of the queue.
  function test_WhenADepositIsStillPendingAtTheSnapshot() external {
    _admitDeposit(users.alice, 1, 100e18);
    // Bob's request moves 100e18 into the Relay sAERO without minting: the backing stays at 200e18
    // (the 100e18 seed plus alice's admitted 100e18) and the queued counter carries 100e18.
    _requestDeposit(users.bob, 2, 100e18);
    _armGovernanceSnapshot();

    // The whole 1000e18 Relay weight is divided by the principal supply, and the queue does not
    // change either side: alice holds 100e18 of the 200e18 supply, so half of it.
    uint256 _expectedSlice = 500e18;

    // it should divide the queued weight among the holders already in
    assertEq(RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.alice), _expectedSlice);

    // it should cast that whole slice, queue open or not
    _expectCast(_expectedSlice, 1, 'queue is open');
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'queue is open');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), _expectedSlice);

    // it should never let the holders together outspend what the Governor granted the Relay
    assertLe(_expectedSlice + RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.bob), _RELAY_WEIGHT);
  }

  /// @notice The boundary of the overspend guard: a split that sums to exactly the remaining slice
  ///         is legitimate and spends the whole budget in one call.
  function test_WhenAFractionalSplitSpendsTheWholeSlice() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();

    // Supply at the snapshot is 200e18, so alice's slice is half of the 1000e18 Relay weight. The
    // split below sums to 200e18 + 300e18 = 500e18, exactly that slice.
    bytes memory _params = abi.encodePacked(uint128(200e18), uint128(300e18), uint128(0));

    // it should accept a split that sums to the whole remaining slice
    vm.expectCall(
      _governor,
      abi.encodeCall(
        IGovernor.castVoteWithReasonAndParams, (_PROPOSAL_ID, _RELAY_TOKEN_ID, VOTE_TYPE_FRACTIONAL, 'all in', _params)
      )
    );
    vm.prank(users.alice);
    _relay.expressVote(_PROPOSAL_ID, VOTE_TYPE_FRACTIONAL, _params, 'all in');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, users.alice), 500e18);

    // it should refuse anything further once the slice is exactly spent
    vm.prank(users.alice);
    vm.expectRevert(IRelay.AlreadyVoted.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'more');
  }

  /// @notice Nobody held principal before the Relay existed, so a proposal whose snapshot predates
  ///         it prices an empty slice and never reaches the division.
  function test_WhenTheSnapshotPredatesTheRelay() external {
    // `setUp` initialized the Relay at `_INITIAL_TIMESTAMP`, so nobody held principal before it.
    _warpPastSnapshot();

    // it should price a zero slice instead of reverting
    vm.mockCall(_governor, abi.encodeCall(IGovernor.proposalSnapshot, (_PROPOSAL_ID)), abi.encode(uint256(0)));
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.getPastVotes, (address(_relay), _RELAY_TOKEN_ID, uint256(0))),
      abi.encode(_RELAY_WEIGHT)
    );
    assertEq(RelayGovernanceLib.votingPower(address(_relay), _PROPOSAL_ID, users.alice), 0);
  }

  /// @notice Self-delegation only fills an empty slot. A holder who pointed their principal at
  ///         someone else keeps that delegate when more principal is minted to them.
  function test_WhenAHolderDelegatedElsewhereReceivesMorePrincipal() external {
    _admitDeposit(users.alice, 1, 50e18);

    vm.prank(users.alice);
    _principalToken.delegate(users.bob);
    assertEq(_principalToken.delegates(users.alice), users.bob);

    // Price per share is still 1, so the second admission mints another 50e18 to alice.
    _admitDeposit(users.alice, 2, 50e18);

    // it should keep the holder's chosen delegate across the second mint
    assertEq(_principalToken.delegates(users.alice), users.bob);

    // it should credit both mints to that delegate and leave the holder with no votes
    _warpPastSnapshot();
    assertEq(_principalToken.getPastVotes(users.bob, block.timestamp - 1), 100e18);
    assertEq(_principalToken.getPastVotes(users.alice, block.timestamp - 1), 0);
  }

  /// @notice `setGovernor` rotates the Governor/adapter pair: ADMIN-gated, non-zero Governor.
  function test_WhenTheGovernorIsRotated() external {
    address _newGovernor = _mockContract('NewGovernor');
    RelayVoteAdapter _adapter = new RelayVoteAdapter();

    // it should gate the rotation to the admin
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(users.alice);
    _relay.setGovernor(IGovernor(_newGovernor), _adapter);

    // it should reject a zero governor
    vm.prank(_admin);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _relay.setGovernor(IGovernor(address(0)), _adapter);

    // it should reject a zero adapter
    vm.prank(_admin);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _relay.setGovernor(IGovernor(_newGovernor), RelayVoteAdapter(address(0)));

    // it should store the pair and emit the event
    vm.expectEmit(address(_relay));
    emit IRelay.GovernorSet(_newGovernor, address(_adapter));
    vm.prank(_admin);
    _relay.setGovernor(IGovernor(_newGovernor), _adapter);
    assertEq(address(_relay.governor()), _newGovernor);
    assertEq(address(_relay.voteAdapter()), address(_adapter));
  }

  /// @notice Proposal ids hash the proposal's actions, never the Governor's address, so a rotation
  ///         can land on a colliding id. The consumption ledger is keyed by Governor: the holder
  ///         gets a fresh slice on the new Governor and the old spend stays booked where it was.
  /// @dev The voter and the rotating admin are fuzzed; the ownership is seeded straight into
  ///      solady's owner slot, so the test never runs the transfer path.
  function test_WhenARotatedGovernorReusesAProposalId(address _holder, address _rotator) external {
    // The bootstrap owner already holds seed shares, which would skew the hand-computed slice, and
    // the satellites refuse the protocol addresses as mint recipients.
    _assumeFreshHolder(_holder);
    _assumeFuzzable(_rotator);
    _admitDeposit(_holder, 1, 100e18);
    _armGovernanceSnapshot();
    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;

    _expectCast(_expectedSlice, 1, 'old governor');
    vm.prank(_holder);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'old governor');
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, _holder), _expectedSlice);

    address _newGovernor = _mockContract('CollidingGovernor');
    vm.store(address(_relay), _OWNER_SLOT, bytes32(uint256(uint160(_rotator))));
    vm.prank(_rotator);
    _relay.setGovernor(IGovernor(_newGovernor), _voteAdapter);
    vm.mockCall(_newGovernor, abi.encodeCall(IGovernor.proposalSnapshot, (_PROPOSAL_ID)), abi.encode(_snapshot));
    vm.mockCall(
      _newGovernor, abi.encodeWithSelector(IGovernor.castVoteWithReasonAndParams.selector), abi.encode(uint256(0))
    );

    // it should let the holder spend a fresh slice on the colliding proposal
    _expectCastOn(_newGovernor, _expectedSlice, 1, 'new governor');
    vm.prank(_holder);
    _relay.expressVote(_PROPOSAL_ID, 1, '', 'new governor');

    // it should book the fresh spend under the new governor
    assertEq(_relay.usedGovernanceWeight(_newGovernor, _PROPOSAL_ID, _holder), _expectedSlice);

    // it should leave the old governor ledger untouched
    assertEq(_relay.usedGovernanceWeight(_governor, _PROPOSAL_ID, _holder), _expectedSlice);
  }

  /// @notice The Relay sends the adapter's bytes to its stored Governor from its own context, so those
  ///         bytes are authority-bearing: it owns the pooled sAERO and is the only minter of its
  ///         satellites. An adapter that encodes the principal clone's Relay-only `mint` cannot reach
  ///         it, because the cast pins the selector.
  /// @dev The Governor slot is aimed at the Relay's own principal clone, whose `mint` accepts only the
  ///      Relay as caller, which is exactly who the cast would arrive as.
  function test_WhenTheAdapterEncodesAMintCall(address _holder, address _attacker) external {
    _assumeFreshHolder(_holder);
    _assumeFreshHolder(_attacker);
    vm.assume(_holder != _attacker);

    _admitDeposit(_holder, 1, 100e18);
    _rotateOnto(address(_principalToken), abi.encodeCall(IRelayToken.mint, (_attacker, _UNBACKED_MINT)));

    // it should refuse to send calldata whose selector is not the fractional cast
    vm.prank(_holder);
    vm.expectRevert(IRelay.UnexpectedCastSelector.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', '');

    // it should mint no unbacked principal
    assertEq(_principalToken.balanceOf(_attacker), 0, 'the mint payload minted principal');
    // it should leave the pair and the backing counter as they were
    assertEq(_principalToken.totalSupply(), _SEED + 100e18, 'the principal supply moved');
    assertEq(_relay.totalBacking(), _SEED + 100e18, 'the backing counter moved');
    _assertPairInvariant();
  }

  /// @notice The same pin keeps a rotated Governor from being a custody primitive: an adapter that
  ///         encodes an sAERO transfer of the pooled stake never reaches the escrow.
  function test_WhenTheAdapterEncodesAnArbitraryExternalCall(address _holder, address _attacker) external {
    _assumeFreshHolder(_holder);
    _assumeFreshHolder(_attacker);
    vm.assume(_holder != _attacker);

    _admitDeposit(_holder, 1, 100e18);
    bytes memory _theft = abi.encodeCall(IERC721.transferFrom, (address(_relay), _attacker, _RELAY_TOKEN_ID));
    _rotateOnto(_votingEscrow, _theft);

    // it should never reach the escrow with the transfer
    vm.expectCall(_votingEscrow, _theft, 0);

    // it should refuse to send calldata whose selector is not the fractional cast
    vm.prank(_holder);
    vm.expectRevert(IRelay.UnexpectedCastSelector.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', '');
  }

  /// @notice The canonical adapter is unaffected by the pin: a fractional cast still reaches a rotated
  ///         Governor, so the containment costs the legitimate rotation nothing.
  function test_WhenTheRotatedPairEncodesTheFractionalCast(address _holder) external {
    _assumeFreshHolder(_holder);

    _admitDeposit(_holder, 1, 100e18);
    address _newGovernor = _mockContract('NewGovernor');
    vm.prank(_admin);
    _relay.setGovernor(IGovernor(_newGovernor), _voteAdapter);

    _armGovernanceSnapshot();
    vm.mockCall(_newGovernor, abi.encodeCall(IGovernor.proposalSnapshot, (_PROPOSAL_ID)), abi.encode(_snapshot));
    vm.mockCall(
      _newGovernor, abi.encodeWithSelector(IGovernor.castVoteWithReasonAndParams.selector), abi.encode(uint256(0))
    );
    uint256 _expectedSlice = (_RELAY_WEIGHT * 100e18) / 200e18;

    // it should forward the fractional cast to the rotated governor
    _expectCastOn(_newGovernor, _expectedSlice, 1, '');
    vm.prank(_holder);
    _relay.expressVote(_PROPOSAL_ID, 1, '', '');

    // it should book the spent slice
    assertEq(
      _relay.usedGovernanceWeight(_newGovernor, _PROPOSAL_ID, _holder), _expectedSlice, 'the spend was not booked'
    );
  }

  /// @notice The pin loads the word holding the selector AND the high bytes of the first argument, so
  ///         it has to compare the selector alone: a proposal id filling those bytes must still cast.
  /// @dev The id is fuzzed on purpose. Every other test here uses a small counter-shaped id whose high
  ///      bytes are zero, which would hide a comparison that never masked them away; a real Governor
  ///      derives proposal ids by hashing, so in production those bytes are nonzero.
  function test_WhenTheProposalIdFillsTheSelectorWord(address _holder, uint256 _proposalId) external {
    _assumeFreshHolder(_holder);

    _admitDeposit(_holder, 1, 100e18);
    _armGovernanceSnapshot();
    vm.mockCall(_governor, abi.encodeCall(IGovernor.proposalSnapshot, (_proposalId)), abi.encode(_snapshot));

    // it should forward the cast whatever the argument bytes share the selector word
    vm.expectCall(_governor, abi.encodeWithSelector(IGovernor.castVoteWithReasonAndParams.selector));
    vm.prank(_holder);
    _relay.expressVote(_proposalId, 1, '', '');

    // it should book the spend
    assertGt(_relay.usedGovernanceWeight(_governor, _proposalId, _holder), 0, 'the cast was not booked');
  }

  /// @notice An adapter handing back a payload too short to hold a selector is rejected outright, so
  ///         the check never compares against memory past the end of the returned bytes.
  /// @dev Pins behavior rather than proving a fix: before the length guard the load read whatever
  ///      followed the empty array, which reverted here too, only by accident rather than by rule.
  function test_WhenTheAdapterReturnsCalldataTooShortForASelector(address _holder) external {
    _assumeFreshHolder(_holder);

    _admitDeposit(_holder, 1, 100e18);
    _rotateOnto(_governor, '');

    // it should refuse a payload that carries no selector at all
    vm.prank(_holder);
    vm.expectRevert(IRelay.UnexpectedCastSelector.selector);
    _relay.expressVote(_PROPOSAL_ID, 1, '', '');
  }

  /// @notice A Governor revert reaches the caller verbatim through the adapter-encoded raw call.
  function test_WhenTheGovernorRevertsTheCast() external {
    _admitDeposit(users.alice, 1, 100e18);
    _armGovernanceSnapshot();
    vm.mockCallRevert(
      _governor,
      abi.encodeWithSelector(IGovernor.castVoteWithReasonAndParams.selector),
      abi.encodeWithSignature('Error(string)', 'governor says no')
    );

    // it should rebubble the governor revert verbatim
    vm.prank(users.alice);
    vm.expectRevert('governor says no');
    _relay.expressVote(_PROPOSAL_ID, 1, '', '');
  }

  /// @dev Arm the Governor reads every `expressVote` performs: the proposal snapshot (one second in
  ///      the past, so the checkpoint lookups are valid) and the Relay's snapshot sAERO weight.
  function _armGovernanceSnapshot() internal {
    _warpPastSnapshot();
    _snapshot = block.timestamp - 1;
    vm.mockCall(_governor, abi.encodeCall(IGovernor.proposalSnapshot, (_PROPOSAL_ID)), abi.encode(_snapshot));
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.getPastVotes, (address(_relay), _RELAY_TOKEN_ID, _snapshot)),
      abi.encode(_RELAY_WEIGHT)
    );
  }

  /// @dev Move past the mints so a checkpoint lookup one second back is in the past and settled.
  function _warpPastSnapshot() internal {
    vm.warp(block.timestamp + 1 hours);
  }

  /// @dev Rotate the Relay onto `_target` as Governor with a hostile adapter armed to hand back
  ///      `_payload`, and arm the snapshot reads the vote performs. The adapter reports the snapshot
  ///      itself, since both reads the Relay makes on it are STATICCALLs.
  function _rotateOnto(address _target, bytes memory _payload) internal {
    MaliciousVoteAdapter _adapter = new MaliciousVoteAdapter();
    _adapter.setPayload(_payload);
    vm.prank(_admin);
    _relay.setGovernor(IGovernor(_target), _adapter);
    _armGovernanceSnapshot();
    _adapter.setSnapshot(_snapshot);
  }

  /// @dev Expect the Relay to forward exactly `_weight` in the `_support` direction, as a fractional
  ///      cast carrying `_reason`, with the Relay's own tokenId.
  function _expectCast(uint256 _weight, uint8 _support, string memory _reason) internal {
    _expectCastOn(_governor, _weight, _support, _reason);
  }

  /// @dev Same pin, aimed at an explicit Governor: a rotation test must prove the cast reached the
  ///      NEW governor, since a blanket mock on the old one would silently absorb a misdirected cast.
  function _expectCastOn(address _target, uint256 _weight, uint8 _support, string memory _reason) internal {
    uint128[3] memory _weights;
    // forge-lint: disable-next-line(unsafe-typecast)
    _weights[_support] = uint128(_weight);
    bytes memory _params = abi.encodePacked(_weights[0], _weights[1], _weights[2]);
    vm.expectCall(
      _target,
      abi.encodeCall(
        IGovernor.castVoteWithReasonAndParams, (_PROPOSAL_ID, _RELAY_TOKEN_ID, VOTE_TYPE_FRACTIONAL, _reason, _params)
      )
    );
  }
}
