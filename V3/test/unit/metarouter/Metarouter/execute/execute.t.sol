// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {Metarouter} from 'V3/metarouter/Metarouter.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseMetarouter, MetarouterHarness} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {ExecutionProbe} from 'V3-test/unit/metarouter/harnesses/ExecutionProbe.sol';
import {NativeErc20TransferProbe} from 'V3-test/unit/metarouter/harnesses/NativeErc20TransferProbe.sol';
import {NativeRefundBounceProbe} from 'V3-test/unit/metarouter/harnesses/NativeRefundBounceProbe.sol';
import {NftRefundProbe} from 'V3-test/unit/metarouter/harnesses/NftRefundProbe.sol';

/// @notice Lifecycle tests for the `execute` entrypoint, reusing the shared `setUp` from `BaseMetarouter`.
/// @dev Driving `execute()` also covers the internal steps that have no standalone tree: `_beginExecution`,
///      `_dispatch`, `_executeCommands`, and `_decode`.
///      The branchy ones map to nodes below: `_endExecution` (closure) to the batch-completes tests,
///      `_availableNativeBalance` to the pre-batch-native-spent test, `_checkExecutionContext` to delegatecall.
contract UnitMetarouterExecute is BaseMetarouter {
  function test_WhenReachedThroughDelegatecall(bytes memory _commands, bytes[] memory _inputs) external {
    // Delegatecalling `execute` from this test contract runs the guard in a foreign context, so `address(this)`
    // no longer equals the implementation address baked in at construction and the direct-call check rejects it.
    // The low-level delegatecall swallows the revert, so we assert on the returned selector.
    (bool _success, bytes memory _returnData) =
      address(_metarouter).delegatecall(abi.encodeCall(IMetarouter.execute, (_commands, _inputs, block.timestamp)));

    // it should revert with DirectCallRequired
    assertFalse(_success);
    assertEq(bytes4(_returnData), IMetarouter.DirectCallRequired.selector);
  }

  modifier givenReachedThroughADirectCall() {
    _;
  }

  function test_WhenTheCommandsOutnumberTheInputs(address _caller) external givenReachedThroughADirectCall {
    _assumeFuzzable(_caller);
    // One command byte, zero inputs: the lengths cannot align.
    bytes memory _commands = abi.encodePacked(_unflagged(Commands.BALANCE_CHECK));
    bytes[] memory _inputs = new bytes[](0);

    // it should revert with LengthMismatch
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.LengthMismatch.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheInputsOutnumberTheCommands(address _caller) external givenReachedThroughADirectCall {
    _assumeFuzzable(_caller);
    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = '';

    // it should revert with LengthMismatch
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.LengthMismatch.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheCommandsAndInputsLengthsMatch() {
    _;
  }

  function test_WhenTheDeadlineHasPassed(
    address _caller,
    uint256 _deadline
  ) external givenReachedThroughADirectCall givenTheCommandsAndInputsLengthsMatch {
    _assumeFuzzable(_caller);
    vm.warp(365 days);
    _deadline = bound(_deadline, 0, block.timestamp - 1);

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should revert with Expired
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.Expired.selector);
    _metarouter.execute(_commands, _inputs, _deadline);
  }

  modifier givenTheDeadlineHasNotPassed() {
    _;
  }

  modifier givenTheBatchIsActive() {
    _;
  }

  function test_WhenAnExternalCallerReenters(
    address _caller,
    address _recipient
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsActive
  {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // A probe used as the SWEEP token reenters `execute` from its own address while the batch is active. The
    // implementation only permits its own child frames, so a foreign reentrant caller is rejected.
    ExecutionProbe _probe = new ExecutionProbe(_metarouter, true);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.SWEEP), abi.encode(address(_probe), _recipient, uint256(0)));

    // it should revert with ContractLocked
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.ContractLocked.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheExecutionAddressReentersThroughAChildFrame(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsActive
  {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _minBalance = bound(_minBalance, 0, _balance);
    // A flagged command runs in a self-call child frame that reenters with the router as its own caller; it passes
    // the lock and runs the child commands without opening a second custody frame (no extra begin/end, one emit).
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_flagged(Commands.BALANCE_CHECK), _balanceCheckInput(_token, _owner, _minBalance));

    // it should run the child commands without opening a new frame
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  function test_WhenAChildFrameCommandReadsTheLogicalSender(
    address _caller,
    uint256 _senderBalance,
    uint256 _value
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsActive
  {
    _assumeFuzzable(_caller);
    // Distinct from the execution address so the payer read and the closure read mock as separate `balanceOf` calls.
    _caller = _boundNotEq(_caller, address(_metarouter));
    _senderBalance = bound(_senderBalance, 1, type(uint256).max);
    _value = bound(_value, 1, _senderBalance);
    address _token = _mockContract('token');
    // A flagged FUND_ERC20 pulls inside the self-call child frame. `msgSender()` there still resolves to the outer
    // caller because the nested frame does not re-run `_beginExecution`, so `LOCKER` is untouched and the pull is
    // drawn from `_caller`.
    _mockAndExpectTokenBalance(_token, _caller, _senderBalance);
    // it should resolve _msgSender() to the outer caller
    _mockAndExpect(
      _token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _value)), abi.encode(true)
    );
    // The pulled amount is tracked, so closure sweeps exactly it back to the outer caller.
    _mockAndExpectTokenBalance(_token, address(_metarouter), _value);
    _mockAndExpectTokenTransfer(_token, _caller, _value);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      _flagged(Commands.FUND_ERC20),
      abi.encode(_token, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _value}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_token);
  }

  modifier givenTheBatchIsNotActive() {
    _;
  }

  function test_WhenTheCommandListIsEmpty(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
  {
    _assumeFuzzable(_caller);
    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should not dispatch any command
    // it should emit BatchExecuted with _sender
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  modifier givenTheBatchTrackedAPosition() {
    // The custody precondition is seeded per-test against the fuzzed token id, so it cannot be hoisted here.
    _;
  }

  function test_WhenATrackedPositionStillBelongsToTheRouterAtClosure(
    address _caller,
    uint256 _tokenId
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheBatchTrackedAPosition
  {
    _assumeFuzzable(_caller);
    // A position tracked into custody that the router still owns at closure means the route left it stranded.
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should revert with NftNotCleared
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotCleared.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenAnInFlightPositionIsLeftUnconsumedAtClosure(
    address _caller,
    uint256 _tokenId
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheBatchTrackedAPosition
  {
    _assumeFuzzable(_caller);
    // A mint to the metarouter both tracks the position and sets it in flight. If no command sends it out, the
    // position is still router-owned at closure, so the tracked-nft check rejects it: the in-flight slots being left
    // set needs no separate closure guard.
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _metarouter.setInFlightNft(_POSITION_MANAGER, _tokenId);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should revert with NftNotCleared
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotCleared.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenATrackedPositionHasLeftTheRouterAtClosure(
    address _caller,
    address _newOwner,
    uint256 _tokenId
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheBatchTrackedAPosition
  {
    _assumeFuzzable(_caller);
    _newOwner = _boundNotEq(_newOwner, address(_metarouter));
    // The tracked position is owned by someone other than the router at closure, so the route completed.
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_newOwner));

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should complete the batch
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
    // it should clear the nft tracking
    assertEq(_metarouter.trackedNftLength(), 0);
  }

  function test_WhenATrackedPositionWasBurnedBeforeClosure(
    address _caller,
    uint256 _tokenId
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheBatchTrackedAPosition
  {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.seedNftCustody(_POSITION_MANAGER, _tokenId);
    bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_tokenId));
    // A burned canonical position no longer has an owner, so its ERC721 implementation reverts on `ownerOf`.
    vm.mockCallRevert(
      _POSITION_MANAGER,
      _ownerOfCall,
      abi.encodeWithSignature('Error(string)', 'ERC721: owner query for nonexistent token')
    );
    vm.expectCall(_POSITION_MANAGER, _ownerOfCall);

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should complete the batch
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
    // it should clear the nft tracking
    assertEq(_metarouter.trackedNftLength(), 0);
    _assertTransientCleared();
  }

  function test_WhenTheSamePositionIsTrackedByALaterBatchInTheSameTransaction(
    address _caller,
    address _newOwner,
    uint256 _tokenId
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheBatchTrackedAPosition
  {
    _assumeFuzzable(_caller);
    _newOwner = _boundNotEq(_newOwner, address(_metarouter));
    bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_tokenId));
    vm.mockCall(_POSITION_MANAGER, _ownerOfCall, abi.encode(_newOwner));
    vm.expectCall(_POSITION_MANAGER, _ownerOfCall, 2);
    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should check the same position again at the later batch closure
    // it should clear the nft tracking
    assertEq(_metarouter.trackedNftLength(), 0);
  }

  modifier givenTheCommandListIsNotEmpty() {
    _;
  }

  modifier givenARootOnlyCommandRunsOnALeafDeployment() {
    _;
  }

  function test_WhenTheRootOnlyCommandIsCreateStake(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenARootOnlyCommandRunsOnALeafDeployment
  {
    // The suite's router is a leaf (IS_ROOT false), so the root-only CREATE_STAKE is rejected at the dispatch gate
    // before its handler runs; the input is irrelevant because the gate precedes decoding.
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.CREATE_STAKE), '');

    // it should revert with NotRoot for _commandType
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.NotRoot.selector, Commands.CREATE_STAKE));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheRootOnlyCommandIsDepositRelay(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenARootOnlyCommandRunsOnALeafDeployment
  {
    // Same leaf gate for the other root-only command; DEPOSIT_RELAY has its own dispatch guard.
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.DEPOSIT_RELAY), '');

    // it should revert with NotRoot for _commandType
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.NotRoot.selector, Commands.DEPOSIT_RELAY));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice Verifies that the leaf-only redeem command is rejected on a root Metarouter deployment.
  function test_WhenTheLeafOnlyRedeemCommandRunsOnARootDeployment(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
  {
    _assumeFuzzable(_caller);
    // The leaf-only gate: root holds no receipt to redeem, and its emission token is the canonical TOKEN rather than the
    // leaf receipt token, so the command is rejected before decoding its input.
    MetarouterHarness _rootMetarouter = _deployRootMetarouter();
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.REDEEM), '');

    // it should revert with NotLeaf for _commandType
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.NotLeaf.selector, Commands.REDEEM));
    _rootMetarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenACommandIsUnflagged() {
    _;
  }

  function test_WhenTheCommandIdIsUndefinedAboveTheDefinedRange(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenACommandIsUnflagged
  {
    _assumeFuzzable(_caller);
    // 0x7f has no dispatch branch and its high bit is clear, so it decodes to an undefined unflagged command.
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(_UNDEFINED_COMMAND), '');

    // it should revert the whole batch with InvalidCommandType for _commandType
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidCommandType.selector, _UNDEFINED_COMMAND));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheCommandIdIsUndefinedInsideACommandGap(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenACommandIsUnflagged
  {
    _assumeFuzzable(_caller);
    // 0x02 sits between the CL swap and V2 swap command ranges, proving gaps do not alias an adjacent command.
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(_UNDEFINED_GAP_COMMAND), '');

    // it should revert the whole batch with InvalidCommandType for _commandType
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidCommandType.selector, _UNDEFINED_GAP_COMMAND));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheCommandReverts(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenACommandIsUnflagged
  {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    // A failing balance check is a representative unflagged command; any unflagged revert bubbles the same way.
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(_token, _owner, _minBalance));

    // it should revert the whole batch and bubble the command failure
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenAFlaggedCommandReverts(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
  {
    _assumeFuzzable(_caller);
    address _failingToken = _mockContract('failingToken');
    address _passingToken = _mockContract('passingToken');
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    // The flagged check reverts inside its catchable child frame; the following unflagged check must still run.
    _mockAndExpectTokenBalance(_failingToken, _owner, _balance);
    _mockAndExpectTokenBalance(_passingToken, _owner, _minBalance);

    bytes1[] memory _commandBytes = new bytes1[](2);
    _commandBytes[0] = _flagged(Commands.BALANCE_CHECK);
    _commandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _batchInputs = new bytes[](2);
    _batchInputs[0] = _balanceCheckInput(_failingToken, _owner, _minBalance);
    _batchInputs[1] = _balanceCheckInput(_passingToken, _owner, _minBalance);
    (bytes memory _commands, bytes[] memory _inputs) = _batch(_commandBytes, _batchInputs);

    // it should revert only the inner call
    // it should continue the batch with the next command
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  function test_WhenAFlaggedCommandIdIsUndefined(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
  {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _minBalance = bound(_minBalance, 0, _balance);
    // The flagged undefined command reverts with InvalidCommandType inside its catchable child frame; the flag
    // swallows that dispatch-level revert just as it would a handler revert, so the following unflagged check still
    // runs. The expectCall on the passing balance check is what proves the batch continued past the swallowed frame.
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    bytes1[] memory _commandBytes = new bytes1[](2);
    _commandBytes[0] = _flagged(_UNDEFINED_COMMAND);
    _commandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _batchInputs = new bytes[](2);
    _batchInputs[0] = '';
    _batchInputs[1] = _balanceCheckInput(_token, _owner, _minBalance);
    (bytes memory _commands, bytes[] memory _inputs) = _batch(_commandBytes, _batchInputs);

    // it should swallow the InvalidCommandType revert and continue the batch
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  function test_WhenAFlaggedCommandSucceeds(
    address _caller,
    address _recipient,
    uint256 _balance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
  {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _token = _mockContract('token');
    _balance = bound(_balance, 1, type(uint256).max);
    // A flagged (allow-revert) TRANSFER runs in a catchable child frame; on success its tracking must persist into
    // the outer frame so the token is swept at closure. A mutation that discarded the successful child frame's
    // effects (staticcall, or ignoring the committed state) would drop the tracking and skip this sweep.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_balance, _balance]);
    // it should persist its tracked token into the closure sweep
    _mockAndExpectTokenTransfer(_token, _caller, _balance);

    bytes memory _transferInput =
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}));
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_flagged(Commands.TRANSFER), _transferInput);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_token);
  }

  modifier givenTheBatchCompletes() {
    _;
  }

  modifier givenTheBatchTrackedTokens() {
    _;
  }

  function test_WhenATrackedTokenHoldsABalance(
    address _caller,
    address _recipient,
    uint256 _balance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheBatchTrackedTokens
  {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _token = _mockContract('token');
    _balance = bound(_balance, 1, type(uint256).max);
    // A zero-value TRANSFER tracks the token without moving it; the closure then finds a positive balance to sweep.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_balance, _balance]);
    // it should return that _token balance to _sender
    _mockAndExpectTokenTransfer(_token, _caller, _balance);

    bytes memory _transferInput =
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}));
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.TRANSFER), _transferInput);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_token);
  }

  function test_WhenATrackedTokenHoldsNoBalance(
    address _caller,
    address _recipient,
    uint256 _handlerBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheBatchTrackedTokens
  {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _token = _mockContract('token');
    // The token is tracked but holds nothing at closure, so the closing sweep skips it.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_handlerBalance, uint256(0)]);
    // it should not transfer that _token
    vm.mockCallRevert(_token, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no sweep'));

    bytes memory _transferInput =
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}));
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.TRANSFER), _transferInput);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_token);
  }

  function test_WhenTheSameTokenIsTrackedByALaterBatchInTheSameTransaction(
    address _caller,
    address _recipient,
    uint256 _balance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheBatchTrackedTokens
  {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _token = _mockContract('token');
    _balance = bound(_balance, 1, type(uint256).max);
    // The first batch tracks the token with a zero balance (no sweep); its closure must `untrack` the dedup flag so
    // the second batch in the SAME transaction re-tracks the token and sweeps its now-positive balance. If `untrack`
    // is dropped, the stale flag makes the second `track` a no-op, the token is never swept, and the transfer below
    // never fires. Reads: batch 1 [handler, closure] then batch 2 [handler, closure].
    uint256[] memory _balances = new uint256[](4);
    _balances[0] = 0;
    _balances[1] = 0;
    _balances[2] = _balance;
    _balances[3] = _balance;
    _mockAndExpectTokenBalances(_token, address(_metarouter), _balances);
    // it should sweep that _token again at the later batch closure
    _mockAndExpectTokenTransfer(_token, _caller, _balance);

    bytes memory _transferInput =
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}));
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.TRANSFER), _transferInput);

    vm.startPrank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
    _metarouter.execute(_commands, _inputs, block.timestamp);
    vm.stopPrank();

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_token);
  }

  /// @notice On a chain whose native asset has an ERC20 entry point, the closing sweep never moves the tracked
  ///         native ERC20 through that entry point: some implementations reject a zero-value `transfer`. The batch's
  ///         portion is native value, so the native refund returns it instead.
  function test_WhenATrackedNativeMirrorTokenHoldsMoreThanThePreBatchNative(
    address _caller,
    address _recipient,
    uint256 _stranded,
    uint256 _batchNative
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheBatchTrackedTokens
  {
    _assumeFuzzable(_caller);
    // The caller receives the closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint256).max - 1);
    _batchNative = bound(_batchNative, 1, type(uint256).max - _stranded);
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_caller, _batchNative);

    // The native ERC20's `balanceOf` is never read: the handler resolves the spend from the batch's own native and the
    // closing sweep skips the token before any balance read.
    // it should not transfer the token through its entry point
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no sweep'));

    bytes memory _transferInput = abi.encode(
      _NATIVE_ERC20, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)})
    );
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.TRANSFER), _transferInput);

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);

    // it should refund the batch portion through the native refund
    assertEq(_caller.balance, _batchNative);
    // it should keep the pre batch native in the router
    assertEq(address(_nativeErc20Metarouter).balance, _stranded);
    // it should clear the transient execution slots at closure
    assertEq(_nativeErc20Metarouter.msgSender(), address(0), 'locker slot not cleared');
    assertEq(_nativeErc20Metarouter.nativeBalanceBefore(), 0, 'native-balance-before slot not cleared');
    assertEq(_nativeErc20Metarouter.trackedLength(), 0, 'tracked-array length not cleared');
    assertEq(_nativeErc20Metarouter.tracked(_NATIVE_ERC20), 0, 'tracked flag not cleared');
  }

  /// @notice A tracked native ERC20 whose balance is only the pre-batch native has nothing the batch
  ///         introduced: the closing sweep skips its entry point and the native refund finds nothing to return.
  function test_WhenATrackedNativeMirrorTokenHoldsOnlyThePreBatchNative(
    address _caller,
    address _recipient,
    uint256 _stranded
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheBatchTrackedTokens
  {
    _assumeFuzzable(_caller);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint256).max);
    vm.deal(address(_nativeErc20Metarouter), _stranded);

    // The native ERC20's `balanceOf` is never read: the handler resolves the spend from the batch's own native and the
    // closing sweep skips the token before any balance read.
    // it should not transfer the token through its entry point
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no sweep'));

    bytes memory _transferInput = abi.encode(
      _NATIVE_ERC20, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)})
    );
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(Commands.TRANSFER), _transferInput);

    vm.prank(_caller);
    _nativeErc20Metarouter.execute(_commands, _inputs, block.timestamp);

    // it should keep the pre batch native in the router
    assertEq(address(_nativeErc20Metarouter).balance, _stranded);
    // it should clear the transient execution slots at closure
    assertEq(_nativeErc20Metarouter.msgSender(), address(0), 'locker slot not cleared');
    assertEq(_nativeErc20Metarouter.nativeBalanceBefore(), 0, 'native-balance-before slot not cleared');
    assertEq(_nativeErc20Metarouter.trackedLength(), 0, 'tracked-array length not cleared');
    assertEq(_nativeErc20Metarouter.tracked(_NATIVE_ERC20), 0, 'tracked flag not cleared');
  }

  modifier givenTheNativeBalanceIsNotSpent() {
    _;
  }

  function test_WhenNativeEthWasIntroduced(
    address _caller,
    uint256 _value
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _assumeFuzzable(_caller);
    // The caller receives the full closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    _value = bound(_value, 1, type(uint256).max);
    // `msg.value` enters the batch and nothing spends it, so the whole amount is refunded to the caller at closure.
    vm.deal(_caller, _value);

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should refund _nativeRefund to _sender
    vm.prank(_caller);
    _metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
    assertEq(_caller.balance, _value);
    assertEq(address(_metarouter).balance, 0);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  function test_WhenTheRefundRecipientReturnsNativeEth(uint256 _value)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, type(uint256).max);
    // The probe is the logical sender and closure recipient. Its receive hook immediately sends the full refund back
    // while the batch locker remains active, so `Metarouter.receive` accepts the returned ETH.
    NativeRefundBounceProbe _probe = new NativeRefundBounceProbe(_metarouter);
    vm.deal(address(_probe), _value);
    uint256 _preBatchBalance = address(_metarouter).balance;

    (bool _success, bytes memory _returnData) = _probe.execute(_value);

    // it should revert with NativeBalanceNotCleared
    assertFalse(_success);
    assertEq(bytes4(_returnData), IMetarouter.NativeBalanceNotCleared.selector);
    // it should leave no residual native eth
    assertEq(address(_metarouter).balance, _preBatchBalance);
  }

  function test_WhenAPositionArrivesWhileTheRefundIsSent(
    uint256 _tokenId,
    uint256 _value
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, type(uint256).max);
    // The refund is the last point a batch hands control to an outside address, and the batch is still active there, so
    // the recipient tries to push a position into custody tracking. The probe is both that recipient and the router's
    // position manager, so it clears the collection check, but no command armed it as an expected sender: the router
    // solicited no position, so the hook rejects it. The rejection reverts the probe's `receive`, which fails the
    // refund transfer, so closure surfaces it wrapped in `NativeTransferFailed`.
    NftRefundProbe _probe = new NftRefundProbe(_tokenId);
    IMetarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(address(_probe)),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
    _probe.setRouter(_router);
    vm.deal(address(_probe), _value);

    // it should revert with NativeTransferFailed wrapping UnexpectedNftSender
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetarouter.NativeTransferFailed.selector, abi.encodeWithSelector(IMetarouter.UnexpectedNftSender.selector)
      )
    );
    _probe.execute(_value);
  }

  function test_WhenTheNativeRefundFails(uint256 _value)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, type(uint256).max);
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should revert with NativeTransferFailed with _data
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.NativeTransferFailed.selector, bytes('')));
    _metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
  }

  /// @notice A caller that rejects native value still gets the batch native back on a native ERC20 deployment: the failed
  ///         refund falls back to the native ERC20's ERC20 entry point, which credits the same native without running the
  ///         recipient's code.
  /// @dev A mocked native ERC20 cannot move real native, so the closure's residual check still fires here. Reaching
  ///      `NativeBalanceNotCleared` past a failed native send proves the fallback ran with exactly the refund
  ///      arguments: only that exact transfer is mocked as succeeding, every other transfer reverts. On a real
  ///      native ERC20 the transfer moves the native, the residual check passes, and the batch closes clean.
  function test_WhenTheNativeRefundFailsOnAMirrorDeployment(uint256 _value)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, type(uint256).max);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingMirrorCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    // it should deliver the refund through the mirror entry point
    // The longest-prefix mock wins: only the exact-argument transfer succeeds, so reaching the residual check below
    // proves the fallback delivered precisely the refund to the caller.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), 'unexpected transfer arguments');
    vm.mockCall(_NATIVE_ERC20, abi.encodeCall(IERC20.transfer, (_caller, _value)), abi.encode(true));

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NativeBalanceNotCleared.selector);
    _nativeErc20Metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
  }

  /// @notice The whole fallback path against a native ERC20 that really moves native: the rejected refund is
  ///         delivered through the entry point, the residual check finds nothing left, and the batch closes.
  /// @dev Success-path complement of `test_WhenTheNativeRefundFailsOnAMirrorDeployment`, whose mocked token cannot
  ///      move native and so can only prove the fallback was attempted. The router's pre-batch native is seeded
  ///      nonzero: it must survive, which pins the debit to the batch's own native.
  function test_WhenTheMirrorTransferDeliversTheRejectedRefund(
    uint256 _value,
    uint256 _preBatchBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, type(uint64).max);
    _preBatchBalance = bound(_preBatchBalance, 1, type(uint64).max);
    // Eighteen decimals: the entry point shares native's raw units, so the whole refund is expressible.
    NativeErc20TransferProbe _nativeErc20 = new NativeErc20TransferProbe(18);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(address(_nativeErc20));
    vm.deal(address(_nativeErc20Metarouter), _preBatchBalance);
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingMirrorCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should close the batch with no native left behind
    vm.expectCall(address(_nativeErc20), abi.encodeCall(IERC20.transfer, (_caller, _value)));
    _expectEmit(address(_nativeErc20Metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
    assertEq(address(_nativeErc20Metarouter).balance, _preBatchBalance);

    // it should credit the refund through the mirror entry point
    // The caller sent its whole balance as `msg.value` and its own code rejects native, so holding it again can
    // only come from the entry point.
    assertEq(_caller.balance, _value);
  }

  /// @notice On a lower-decimals native ERC20 the fallback refund floors to the native ERC20 decimals: the token cannot
  ///         move a partial token, so only the floored amount is delivered through the entry point.
  /// @dev A mocked native ERC20 cannot move real native, so the closure's residual check still fires here. Reaching
  ///      `NativeBalanceNotCleared` past a failed native send proves the fallback ran with exactly the floored
  ///      amount: only that exact transfer is mocked as succeeding, every other transfer returns false and would
  ///      surface as `NativeTransferFailed`. On a real native ERC20 the transfer moves the floored amount of native, the
  ///      remainder stays within the tolerated dust, and the batch closes clean.
  function test_WhenTheNativeRefundFailsOnALowerDecimalsMirrorDeployment(
    uint256 _refundAmount,
    uint256 _remainder
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _refundAmount = bound(_refundAmount, 1, type(uint64).max);
    // A sub-unit remainder proves the flooring: the delivered amount excludes it.
    _remainder = bound(_remainder, 1, _NATIVE_ERC20_SCALE - 1);
    uint256 _value = _refundAmount * _NATIVE_ERC20_SCALE + _remainder;
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20_DECIMALS);
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingMirrorCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    // it should deliver the refund floored to the mirror decimals
    // The longest-prefix mock wins: only the floored-amount transfer succeeds, so reaching the residual check below
    // proves the fallback delivered precisely the whole units to the caller.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), 'unexpected transfer arguments');
    vm.mockCall(_NATIVE_ERC20, abi.encodeCall(IERC20.transfer, (_caller, _refundAmount)), abi.encode(true));

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NativeBalanceNotCleared.selector);
    _nativeErc20Metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
  }

  /// @notice The whole fallback path on a lower-decimals deployment: the entry point delivers the whole units of the
  ///         rejected refund, the sub-unit remainder stays behind as tolerated dust, and the batch closes.
  /// @dev Success-path complement of `test_WhenTheNativeRefundFailsOnALowerDecimalsMirrorDeployment`, whose mocked
  ///      token cannot move native and so can only prove the floored transfer was attempted.
  function test_WhenTheMirrorTransferDeliversAFlooredRefundOnALowerDecimalsDeployment(
    uint256 _refundAmount,
    uint256 _remainder,
    uint256 _preBatchBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _refundAmount = bound(_refundAmount, 1, type(uint64).max);
    // A sub-unit remainder proves the flooring: the delivered amount excludes it.
    _remainder = bound(_remainder, 1, _NATIVE_ERC20_SCALE - 1);
    _preBatchBalance = bound(_preBatchBalance, 1, type(uint64).max);
    uint256 _value = _refundAmount * _NATIVE_ERC20_SCALE + _remainder;
    NativeErc20TransferProbe _nativeErc20 = new NativeErc20TransferProbe(_NATIVE_ERC20_DECIMALS);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(address(_nativeErc20));
    vm.deal(address(_nativeErc20Metarouter), _preBatchBalance);
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingMirrorCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should close the batch leaving the untransferable remainder
    vm.expectCall(address(_nativeErc20), abi.encodeCall(IERC20.transfer, (_caller, _refundAmount)));
    _expectEmit(address(_nativeErc20Metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
    assertEq(address(_nativeErc20Metarouter).balance, _preBatchBalance + _remainder);

    // it should credit the floored refund through the mirror entry point
    // The caller sent its whole balance as `msg.value`, so what it holds again is exactly what the entry point
    // delivered: the batch native minus the sub-unit remainder the token cannot express.
    assertEq(_caller.balance, _value - _remainder);
  }

  /// @notice A failed refund below one raw native ERC20 unit has nothing the token can express: the fallback skips the
  ///         transfer, the remainder stays in the router as tolerated dust, and the batch still closes.
  function test_WhenTheFailedRefundIsBelowOneRawMirrorUnit(uint256 _value)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, _NATIVE_ERC20_SCALE - 1);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20_DECIMALS);
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingMirrorCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    // it should skip the mirror transfer
    // Any transfer attempt returns false and would surface as `NativeTransferFailed`, so a clean close proves the
    // fallback never called the entry point for the sub-raw-unit refund.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), 'no transfer');

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);

    // it should close the batch leaving the untransferable remainder
    assertEq(address(_nativeErc20Metarouter).balance, _value);
    assertEq(_caller.balance, 0);

    // it should clear the transient execution slots at closure
    assertEq(_nativeErc20Metarouter.msgSender(), address(0), 'locker slot not cleared');
    assertEq(_nativeErc20Metarouter.nativeBalanceBefore(), 0, 'native-balance-before slot not cleared');
    assertEq(_nativeErc20Metarouter.trackedLength(), 0, 'tracked-array length not cleared');
  }

  /// @notice A native ERC20 that rejects the fallback transfer leaves no second route: the closure re-raises the native
  ///         failure so the recipient's own revert data surfaces instead of the token's opaque error.
  function test_WhenTheMirrorFallbackTransferFails(uint256 _value)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _value = bound(_value, 1, type(uint256).max);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    // The caller (and refund recipient) rejects native ETH with empty revert data, so the closure refund fails.
    address _caller = makeAddr('rejectingMirrorCaller');
    vm.etch(_caller, hex'60006000fd');
    vm.deal(_caller, _value);

    // The native ERC20 rejects the fallback transfer, so no ERC20 route exists either.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), 'native erc20 rejects');

    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should revert with NativeTransferFailed with the native data
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.NativeTransferFailed.selector, bytes('')));
    _nativeErc20Metarouter.execute{value: _value}(_commands, _inputs, block.timestamp);
  }

  function test_WhenNoNativeEthWasIntroduced(address _caller)
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
    givenTheNativeBalanceIsNotSpent
  {
    _assumeFuzzable(_caller);
    // Start from a known zero balance so "no refund" is observable regardless of any preset fuzz-address balance.
    vm.deal(_caller, 0);
    // No pre-batch balance and no `msg.value`: the refund amount is zero, so no transfer is attempted.
    bytes memory _commands = '';
    bytes[] memory _inputs = new bytes[](0);

    // it should not refund _sender
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
    assertEq(_caller.balance, 0);
    assertEq(address(_metarouter).balance, 0);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  function test_WhenTheOuterFrameSettles(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  )
    external
    givenReachedThroughADirectCall
    givenTheCommandsAndInputsLengthsMatch
    givenTheDeadlineHasNotPassed
    givenTheBatchIsNotActive
    givenTheCommandListIsNotEmpty
    givenTheBatchCompletes
  {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _minBalance = bound(_minBalance, 0, _balance);
    // A non-empty batch that completes cleanly settles its outer frame and emits once for the logical sender.
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(_token, _owner, _minBalance));

    // it should emit BatchExecuted with _sender
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }
}
