// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

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

import {MockWETH} from 'V3-test/mocks/MockWETH.sol';
import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';

/// @notice Payments module tests: the router custodies assets and sweeps leftovers to its caller.
/// @dev The execution address is `address(_metarouter)`; a tracking handler makes `_endExecution` re-read the
///      balance and return it to the pranked caller, so tracking handlers mock `balanceOf` twice.
contract UnitPayments is BaseMetarouter {
  // --- sweep ---

  function test_SweepWhenTheRecipientIsTheZeroAddress(address _caller, address _token, uint256 _minAmount) external {
    _assumeFuzzable(_caller);
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_token, address(0), _minAmount));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_SweepWhenTheRecipientIsTheExecutionAddress(
    address _caller,
    address _token,
    uint256 _minAmount
  ) external {
    _assumeFuzzable(_caller);
    // Sweeping to the router itself is rejected: it is a no-op that would leave an untracked balance behind.
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_token, address(_metarouter), _minAmount));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheRecipientIsValid() {
    _;
  }

  function test_SweepWhenTheBalanceIsBelowTheMinimum(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _minAmount
  ) external givenTheRecipientIsValid {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minAmount = bound(_minAmount, _balance + 1, type(uint256).max);
    address _token = _mockContract('token');
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_token, _recipient, _minAmount));

    // it should revert with InsufficientBalance for _token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheBalanceMeetsTheMinimum() {
    _;
  }

  function test_SweepWhenTheBalanceIsPositive(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _minAmount
  ) external givenTheRecipientIsValid givenTheBalanceMeetsTheMinimum {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _balance = bound(_balance, 1, type(uint256).max);
    _minAmount = bound(_minAmount, 0, _balance);
    address _token = _mockContract('token');
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);
    // it should transfer the full _token balance to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_token, _recipient, _minAmount));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice On a chain whose native asset has an ERC20 entry point, the native ERC20 token's balance is the router's
  ///         whole native balance, so a sweep sends only the portion above the pre-batch snapshot: sweeping the full
  ///         balance would spend the pre-batch native mid-batch and revert the closure.
  function test_SweepWhenTheSweptTokenIsTheNativeMirrorToken(
    address _caller,
    address _recipient,
    uint256 _stranded,
    uint256 _batchNative,
    uint256 _minAmount
  ) external givenTheRecipientIsValid givenTheBalanceMeetsTheMinimum {
    _assumeFuzzable(_caller);
    // The caller receives the closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint256).max - 1);
    _batchNative = bound(_batchNative, 1, type(uint256).max - _stranded);
    _minAmount = bound(_minAmount, 0, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_caller, _batchNative);

    // The sweep resolves the native ERC20's available balance from the batch native, without reading its `balanceOf`.
    // it should transfer only the balance above the pre batch snapshot to _recipient
    _mockAndExpectTokenTransfer(_NATIVE_ERC20, _recipient, _batchNative);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_NATIVE_ERC20, _recipient, _minAmount));

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);

    // it should leave the pre batch native with the router at closure
    assertEq(address(_nativeErc20Metarouter).balance, _stranded);
  }

  /// @notice The sweep minimum is checked against the batch-available balance, so the stranded pre-batch native
  ///         does not count toward the minimum: a minimum only the pre-batch native can satisfy reverts instead of
  ///         spending the pre-batch native.
  function test_SweepWhenTheMirrorMinimumIsMetOnlyThroughThePreBatchNative(
    address _caller,
    address _recipient,
    uint256 _stranded,
    uint256 _batchNative,
    uint256 _minAmount
  ) external givenTheRecipientIsValid givenTheBalanceMeetsTheMinimum {
    _assumeFuzzable(_caller);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 0, type(uint128).max);
    // The whole native balance would meet the minimum, but the batch-available portion above the snapshot does not.
    _minAmount = bound(_minAmount, _batchNative + 1, _stranded + _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_caller, _batchNative);

    // An unexpected transfer of the pre-batch native surfaces as this marker revert instead of the expected error.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no transfer'));

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_NATIVE_ERC20, _recipient, _minAmount));

    // it should revert with InsufficientBalance for the native mirror token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);
  }

  function test_SweepWhenTheBalanceIsZero(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsValid givenTheBalanceMeetsTheMinimum {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _token = _mockContract('token');
    // A zero balance still meets the minimum only when the minimum is zero.
    _mockAndExpectTokenBalance(_token, address(_metarouter), 0);
    // it should not transfer _token
    vm.mockCallRevert(_token, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no transfer'));

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.SWEEP, abi.encode(_token, _recipient, uint256(0)));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- transfer ---

  function test_TransferWhenTheRecipientIsTheZeroAddress(address _caller, address _token, uint256 _value) external {
    _assumeFuzzable(_caller);
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.TRANSFER,
      abi.encode(_token, address(0), IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _value}))
    );

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_TransferWhenTheResolvedAmountIsPositive(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _value
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, _caller);
    // A positive spend that leaves a strictly positive remainder for the closure sweep.
    _balance = bound(_balance, 2, type(uint256).max);
    _value = bound(_value, 1, _balance - 1);
    address _token = _mockContract('token');
    // Read once in the handler, once at closure after the remainder shrank by _value.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_balance, _balance - _value]);
    // it should transfer _amount to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, _value);
    // it should return the remaining _token balance to _msgSender() at closure
    _mockAndExpectTokenTransfer(_token, _caller, _balance - _value);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.TRANSFER,
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _value}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_TransferWhenAPipsSpendResolvesAPositiveAmount(
    address _caller,
    address _recipient,
    uint256 _base,
    uint256 _pips
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, _caller);
    // Bound the base balance so `_base * _pips` cannot overflow, and keep the pip share strictly below the full
    // balance so a positive remainder is left for the closure sweep.
    _base = bound(_base, MAX_PIPS, type(uint256).max / MAX_PIPS);
    _pips = bound(_pips, 1, MAX_PIPS - 1);
    // Expected proportion computed with plain arithmetic, independent of the contract's `Math.mulDiv`.
    uint256 _expected = _base * _pips / MAX_PIPS;
    address _token = _mockContract('token');
    // Read once in the handler, once at closure after the remainder shrank by the pip proportion.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_base, _base - _expected]);
    // it should transfer the pip proportion to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, _expected);
    // it should return the remaining _token balance to _msgSender() at closure
    _mockAndExpectTokenTransfer(_token, _caller, _base - _expected);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.TRANSFER,
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_TransferWhenUsingAKnownRoundedDownPipProportion(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, _caller);
    // 33.3333% (333333 pips) of 1000 = 333.333, floored to 333; 667 remains. Hardcoded independently of Math.mulDiv.
    address _token = _mockContract('token');
    // Read once in the handler, once at closure after the remainder shrank by 333.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [uint256(1000), 667]);
    // it should transfer the hand computed floored proportion to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, 333);
    // it should return the hand computed remainder to _msgSender() at closure
    _mockAndExpectTokenTransfer(_token, _caller, 667);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.TRANSFER,
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: 333_333}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice A full proportional spend of the native ERC20 resolves only the balance above the pre-batch
  ///         snapshot: the native ERC20 balance is the router's whole native balance, so an uncapped resolution would spend
  ///         the pre-batch native mid-batch and revert the closure.
  function test_TransferWhenAFullPipsSpendSelectsTheNativeMirrorToken(
    address _caller,
    address _recipient,
    uint256 _stranded,
    uint256 _batchNative
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    // The caller receives the closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_nativeErc20Metarouter));
    _recipient = _boundNotEq(_recipient, _caller);
    _stranded = bound(_stranded, 1, type(uint256).max - 1);
    _batchNative = bound(_batchNative, 1, type(uint256).max - _stranded);
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_caller, _batchNative);

    // The transfer resolves the native ERC20's available balance from the batch native, without reading its `balanceOf`.
    // it should transfer only the balance above the pre batch snapshot to _recipient
    _mockAndExpectTokenTransfer(_NATIVE_ERC20, _recipient, _batchNative);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.TRANSFER,
      abi.encode(
        _NATIVE_ERC20, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS})
      )
    );

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);

    // it should leave the pre batch native with the router at closure
    assertEq(address(_nativeErc20Metarouter).balance, _stranded);
  }

  function test_TransferWhenTheResolvedAmountIsZero(
    address _caller,
    address _recipient,
    uint256 _balance
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, _caller);
    _balance = bound(_balance, 1, type(uint256).max);
    address _token = _mockContract('token');
    // The balance is untouched by the handler, so both reads return the same value.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_balance, _balance]);
    // it should not transfer _token
    vm.mockCallRevert(
      _token, abi.encodeWithSelector(IERC20.transfer.selector, _recipient), bytes('no transfer to recipient')
    );
    // it should return the remaining _token balance to _msgSender() at closure
    _mockAndExpectTokenTransfer(_token, _caller, _balance);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.TRANSFER,
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- transferNft ---

  function test_TransferNftWhenTheRecipientIsTheZeroAddress(
    address _caller,
    address _collection,
    uint256 _tokenId
  ) external {
    _assumeFuzzable(_caller);
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, _tokenId, address(0)));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_TransferNftWhenTheRecipientIsTheExecutionAddress(
    address _caller,
    address _collection,
    uint256 _tokenId
  ) external {
    _assumeFuzzable(_caller);
    // A self-transfer would leave the router as owner while the command reports the NFT delivered.
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, _tokenId, address(_metarouter)));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_TransferNftWhenTheZeroSentinelMatchesNoInFlightCollection(
    address _caller,
    address _collection,
    address _recipient
  ) external givenTheRecipientIsValid {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // An empty in-flight slot reads as collection zero, so any non-zero collection finds no match.
    _assumeFuzzable(_collection);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, uint256(0), _recipient));

    // it should revert with NoInFlightNft
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NoInFlightNft.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_TransferNftWhenTheNftIsNotInBatchCustody(
    address _caller,
    address _collection,
    uint256 _tokenId,
    address _recipient
  ) external givenTheRecipientIsValid {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // A non-zero token id skips the sentinel; nothing was tracked into custody this batch.
    _tokenId = bound(_tokenId, 1, type(uint256).max);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, _tokenId, _recipient));

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheNftEnteredCustodyDuringTheBatch() {
    _;
  }

  function test_TransferNftWhenTheTokenIdIsExplicit(
    address _caller,
    uint256 _tokenId,
    address _recipient
  ) external givenTheRecipientIsValid givenTheNftEnteredCustodyDuringTheBatch {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    address _collection = _mockContract('collection');
    // Transient custody persists across external calls within the test transaction, so the seed stands in for a
    // producer command earlier in the batch.
    _metarouter.seedNftCustody(_collection, _tokenId);
    // it should transfer the nft to _recipient
    _mockAndExpect(
      _collection,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );
    // it should close the batch with the custody check passing
    _mockAndExpect(_collection, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_recipient));

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, _tokenId, _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    assertEq(_metarouter.trackedNftLength(), 0, 'nft arrays not cleared');
    _assertTransientCleared();
  }

  function test_TransferNftWhenTheRecipientBurnsTheNftInItsReceiverHook(
    address _caller,
    uint256 _tokenId
  ) external givenTheRecipientIsValid givenTheNftEnteredCustodyDuringTheBatch {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    address _recipient = _mockContract('burningRecipient');
    _metarouter.seedNftCustody(_POSITION_MANAGER, _tokenId);
    // A successful safe transfer return means the recipient hook completed; in this scenario it burned the position.
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );
    bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_tokenId));
    vm.mockCallRevert(
      _POSITION_MANAGER,
      _ownerOfCall,
      abi.encodeWithSignature('Error(string)', 'ERC721: owner query for nonexistent token')
    );
    vm.expectCall(_POSITION_MANAGER, _ownerOfCall);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_POSITION_MANAGER, _tokenId, _recipient));

    // it should complete the batch
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the nft tracking
    assertEq(_metarouter.trackedNftLength(), 0, 'nft arrays not cleared');
    _assertTransientCleared();
  }

  function test_TransferNftWhenTheExplicitTokenIdMatchesTheInFlightNft(
    address _caller,
    uint256 _tokenId,
    address _recipient
  ) external givenTheRecipientIsValid givenTheNftEnteredCustodyDuringTheBatch {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    address _collection = _mockContract('collection');
    // The producer left this NFT in flight, and the plan names its id outright instead of using the sentinel. The
    // consume must still match on the pair, or the stale reference would survive and revert a later producer with
    // InFlightNftPresent.
    _metarouter.seedNftCustody(_collection, _tokenId);
    _metarouter.seedInFlightNft(_collection, _tokenId);
    // it should transfer the nft to _recipient
    _mockAndExpect(
      _collection,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );
    _mockAndExpect(_collection, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_recipient));

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, _tokenId, _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the in flight slots
    (address _inFlightCollection, uint256 _inFlightTokenId) = _metarouter.inFlightNft();
    assertEq(_inFlightCollection, address(0), 'in-flight collection not cleared');
    assertEq(_inFlightTokenId, 0, 'in-flight token id not cleared');
  }

  function test_TransferNftWhenTheTokenIdIsTheZeroSentinel(
    address _caller,
    uint256 _tokenId,
    address _recipient
  ) external givenTheRecipientIsValid givenTheNftEnteredCustodyDuringTheBatch {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // Token id zero is the sentinel, so a produced NFT always carries a non-zero id.
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    address _collection = _mockContract('collection');
    // A producer command tracks its output and publishes it in flight; seed both halves.
    _metarouter.seedNftCustody(_collection, _tokenId);
    _metarouter.seedInFlightNft(_collection, _tokenId);
    // it should transfer the in flight nft to _recipient
    _mockAndExpect(
      _collection,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );
    _mockAndExpect(_collection, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_recipient));

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, uint256(0), _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the in flight slots
    (address _inFlightCollection, uint256 _inFlightTokenId) = _metarouter.inFlightNft();
    assertEq(_inFlightCollection, address(0), 'in-flight collection not cleared');
    assertEq(_inFlightTokenId, 0, 'in-flight token id not cleared');
  }

  function test_TransferNftWhenTheTransferredNftIsNotTheInFlightOne(
    address _caller,
    uint256 _tokenId,
    uint256 _inFlightTokenId,
    address _recipient
  ) external givenTheRecipientIsValid givenTheNftEnteredCustodyDuringTheBatch {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _inFlightTokenId = bound(_inFlightTokenId, 1, type(uint256).max);
    address _collection = _mockContract('collection');
    // The in-flight NFT lives in another collection, as when an sAERO is in flight while a position is transferred.
    address _inFlightCollection = _mockContract('inFlightCollection');
    _metarouter.seedNftCustody(_collection, _tokenId);
    _metarouter.seedInFlightNft(_inFlightCollection, _inFlightTokenId);
    // it should transfer the nft to _recipient
    _mockAndExpect(
      _collection,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );
    _mockAndExpect(_collection, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_recipient));

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(Commands.TRANSFER_NFT, abi.encode(_collection, _tokenId, _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should keep the in flight slots set
    (address _keptCollection, uint256 _keptTokenId) = _metarouter.inFlightNft();
    assertEq(_keptCollection, _inFlightCollection, 'in-flight collection not kept');
    assertEq(_keptTokenId, _inFlightTokenId, 'in-flight token id not kept');
  }

  // --- fundErc20 ---

  function test_FundErc20WhenTheResolvedAmountIsPositive(
    address _caller,
    uint256 _senderBalance,
    uint256 _value
  ) external {
    _assumeFuzzable(_caller);
    // The logical sender and execution address must differ so their separately mocked `balanceOf` reads don't collide.
    _caller = _boundNotEq(_caller, address(_metarouter));
    _senderBalance = bound(_senderBalance, 1, type(uint256).max);
    _value = bound(_value, 1, _senderBalance);
    address _token = _mockContract('token');
    // it should resolve _spend against the _msgSender() balance as _amount
    _mockAndExpectTokenBalance(_token, _caller, _senderBalance);
    // it should pull _amount from _msgSender() into the execution address
    _mockAndExpect(
      _token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _value)), abi.encode(true)
    );
    // The lone FUND_ERC20 pulls in _value and nothing spends it, so the closure sweeps exactly that back.
    // it should return the remaining _token balance to _msgSender() at closure
    _mockAndExpectTokenBalance(_token, address(_metarouter), _value);
    _mockAndExpectTokenTransfer(_token, _caller, _value);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.FUND_ERC20,
      abi.encode(_token, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _value}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_FundErc20WhenAPipsSpendResolvesAPositiveAmount(address _caller, uint256 _base, uint256 _pips) external {
    _assumeFuzzable(_caller);
    // The logical sender and execution address must differ so their separately mocked `balanceOf` reads don't collide.
    _caller = _boundNotEq(_caller, address(_metarouter));
    // Bound the wallet balance so `_base * _pips` cannot overflow, and keep the pip share positive.
    _base = bound(_base, MAX_PIPS, type(uint256).max / MAX_PIPS);
    _pips = bound(_pips, 1, MAX_PIPS);
    // Expected proportion computed with plain arithmetic, independent of the contract's `Math.mulDiv`.
    uint256 _expected = _base * _pips / MAX_PIPS;
    address _token = _mockContract('token');
    // it should resolve the pip proportion of the _msgSender() balance as _amount
    _mockAndExpectTokenBalance(_token, _caller, _base);
    // it should pull the pip proportion from _msgSender() into the execution address
    _mockAndExpect(
      _token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _expected)), abi.encode(true)
    );
    // The lone FUND_ERC20 pulls in _expected and nothing spends it, so the closure sweeps exactly that back.
    // it should return the remaining _token balance to _msgSender() at closure
    _mockAndExpectTokenBalance(_token, address(_metarouter), _expected);
    _mockAndExpectTokenTransfer(_token, _caller, _expected);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.FUND_ERC20,
      abi.encode(_token, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_FundErc20WhenUsingAKnownRoundedDownPipProportion(address _caller) external {
    _assumeFuzzable(_caller);
    // The logical sender and execution address must differ so their separately mocked `balanceOf` reads don't collide.
    _caller = _boundNotEq(_caller, address(_metarouter));
    // 33.3333% (333333 pips) of 1000 = 333.333, floored to 333. Hardcoded independently of Math.mulDiv.
    address _token = _mockContract('token');
    // it should pull the hand computed floored proportion from _msgSender() into the execution address
    _mockAndExpectTokenBalance(_token, _caller, 1000);
    _mockAndExpect(_token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), 333)), abi.encode(true));
    // The lone FUND_ERC20 pulls in 333 and nothing spends it, so the closure sweeps exactly that back.
    // it should return the hand computed pulled proportion to _msgSender() at closure
    _mockAndExpectTokenBalance(_token, address(_metarouter), 333);
    _mockAndExpectTokenTransfer(_token, _caller, 333);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.FUND_ERC20,
      abi.encode(_token, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: 333_333}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_FundErc20WhenTheResolvedAmountIsZero(address _caller, uint256 _senderBalance) external {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _mockAndExpectTokenBalance(_token, _caller, _senderBalance);
    // it should not pull _token from _msgSender()
    vm.mockCallRevert(_token, abi.encodeWithSelector(IERC20.transferFrom.selector), bytes('no pull'));

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.FUND_ERC20,
      abi.encode(_token, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- wrapEth ---

  /// @notice A deployment without a wrapped-native token has nothing to wrap into: the command is disabled at
  ///         dispatch instead of calling the zero address.
  function test_WrapEthWhenTheDeploymentHasNoWrappedNative(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);
    MetarouterHarness _wethlessMetarouter = _deployWethlessMetarouter();
    _caller = _boundNotEq(_caller, address(_wethlessMetarouter));
    _amount = bound(_amount, 1, type(uint256).max);
    vm.deal(_caller, _amount);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.WRAP_ETH, abi.encode(IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}))
    );

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.WRAP_ETH));
    _wethlessMetarouter.execute{value: _amount}(_commands, _inputs, block.timestamp);
  }

  function test_WrapEthWhenTheResolvedAmountEqualsTheAvailableBalance(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint256).max);
    vm.deal(_caller, _amount);
    // it should deposit _amount into WETH
    _mockAndExpectWithValue(_WETH, _amount, abi.encodeCall(IWETH.deposit, ()), '');
    // it should return the remaining WETH balance to _msgSender() at closure
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _amount);
    _mockAndExpectTokenTransfer(_WETH, _caller, _amount);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.WRAP_ETH, abi.encode(IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: _amount}(_commands, _inputs, block.timestamp);
  }

  function test_WrapEthWhenTheResolvedAmountIsBelowTheAvailableBalance(
    address _caller,
    uint256 _available,
    uint256 _resolved
  ) external {
    _assumeFuzzable(_caller);
    // The caller receives the undeposited native leftover as the closure refund, so it must be a code-less account
    // that accepts ETH, and it must differ from WETH, which receives the deposited portion.
    _caller = _boundNotEq(_caller, _WETH);
    vm.assume(_caller.code.length == 0);
    _available = bound(_available, 2, type(uint256).max);
    _resolved = bound(_resolved, 1, _available - 1);
    vm.deal(_caller, _available);
    // it should deposit only the resolved amount into WETH
    _mockAndExpectWithValue(_WETH, _resolved, abi.encodeCall(IWETH.deposit, ()), '');
    // it should return the deposited WETH balance to _msgSender() at closure
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _resolved);
    _mockAndExpectTokenTransfer(_WETH, _caller, _resolved);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.WRAP_ETH, abi.encode(IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _resolved}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: _available}(_commands, _inputs, block.timestamp);

    // it should refund the undeposited native leftover to _msgSender() at closure
    assertEq(_caller.balance, _available - _resolved);
  }

  function test_WrapEthWhenAPipsSpendResolvesAPositiveAmount(
    address _caller,
    uint256 _available,
    uint256 _pips
  ) external {
    _assumeFuzzable(_caller);
    // The caller receives the undeposited native leftover as the closure refund, so it must be a code-less account
    // that accepts ETH, and it must differ from WETH, which receives the deposited portion.
    _caller = _boundNotEq(_caller, _WETH);
    vm.assume(_caller.code.length == 0);
    // Bound the available native balance so `_available * _pips` cannot overflow, and keep the pip share strictly
    // below the balance so a native leftover remains to refund.
    _available = bound(_available, MAX_PIPS, type(uint256).max / MAX_PIPS);
    _pips = bound(_pips, 1, MAX_PIPS - 1);
    // Expected proportion computed with plain arithmetic, independent of the contract's `Math.mulDiv`.
    uint256 _expected = _available * _pips / MAX_PIPS;
    vm.deal(_caller, _available);
    // it should deposit the pip proportion of the available native balance into WETH
    _mockAndExpectWithValue(_WETH, _expected, abi.encodeCall(IWETH.deposit, ()), '');
    // it should return the deposited WETH balance to _msgSender() at closure
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _expected);
    _mockAndExpectTokenTransfer(_WETH, _caller, _expected);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.WRAP_ETH, abi.encode(IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: _available}(_commands, _inputs, block.timestamp);

    // it should refund the undeposited native leftover to _msgSender() at closure
    assertEq(_caller.balance, _available - _expected);
  }

  function test_WrapEthWhenUsingAKnownRoundedDownPipProportion(address _caller) external {
    _assumeFuzzable(_caller);
    // The caller receives the undeposited native leftover as the closure refund, so it must be a code-less account
    // that accepts ETH, and it must differ from WETH, which receives the deposited portion.
    _caller = _boundNotEq(_caller, _WETH);
    vm.assume(_caller.code.length == 0);
    // 33.3333% (333333 pips) of 1000 = 333.333, floored to 333; 667 remains. Hardcoded independently of Math.mulDiv.
    vm.deal(_caller, 1000);
    // it should deposit the hand computed floored proportion into WETH
    _mockAndExpectWithValue(_WETH, 333, abi.encodeCall(IWETH.deposit, ()), '');
    // it should return the deposited WETH balance to _msgSender() at closure
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), 333);
    _mockAndExpectTokenTransfer(_WETH, _caller, 333);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.WRAP_ETH, abi.encode(IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: 333_333}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: 1000}(_commands, _inputs, block.timestamp);

    // it should refund the hand computed native leftover to _msgSender() at closure
    assertEq(_caller.balance, 667);
  }

  function test_WrapEthWhenTheResolvedAmountIsZero(address _caller) external {
    _assumeFuzzable(_caller);
    // it should not deposit into WETH
    vm.mockCallRevert(_WETH, abi.encodeCall(IWETH.deposit, ()), bytes('no deposit'));
    // it should not return WETH balance to _msgSender() at closure
    vm.mockCallRevert(_WETH, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no sweep'));

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.WRAP_ETH, abi.encode(IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- unwrapWeth ---

  /// @notice A deployment without a wrapped-native token has nothing to unwrap from: the command is disabled at
  ///         dispatch instead of calling the zero address.
  function test_UnwrapWethWhenTheDeploymentHasNoWrappedNative(
    address _caller,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    MetarouterHarness _wethlessMetarouter = _deployWethlessMetarouter();
    _caller = _boundNotEq(_caller, address(_wethlessMetarouter));

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(_recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}))
    );

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.UNWRAP_WETH));
    _wethlessMetarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnwrapWethWhenTheRecipientIsTheZeroAddress(address _caller, uint256 _value) external {
    _assumeFuzzable(_caller);
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(address(0), IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _value}))
    );

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnwrapWethWhenTheResolvedAmountIsZero(
    address _caller,
    address _recipient,
    uint256 _balance
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _balance);
    // it should not withdraw from WETH
    vm.mockCallRevert(_WETH, abi.encodeWithSelector(IWETH.withdraw.selector), bytes('no withdraw'));

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(_recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}))
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheResolvedAmountIsPositive() {
    _;
  }

  function test_UnwrapWethWhenTheRecipientIsTheExecutionAddress(
    address _caller,
    uint256 _balance,
    uint256 _amount
  ) external givenTheRecipientIsNotTheZeroAddress givenTheResolvedAmountIsPositive {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 1, type(uint128).max);
    _amount = bound(_amount, 1, _balance);
    MockWETH _weth = new MockWETH();
    Metarouter _router = new Metarouter(
      IWETH(address(_weth)),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
    _caller = _boundNotEq(_caller, address(_weth));
    _caller = _boundNotEq(_caller, address(_router));
    vm.assume(_caller.code.length == 0);
    vm.deal(_caller, 0);
    vm.deal(address(this), _balance);
    _weth.deposit{value: _balance}();
    _weth.transfer(address(_router), _balance);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(address(_router), IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}))
    );

    vm.prank(_caller);
    _router.execute(_commands, _inputs, block.timestamp);

    // it should withdraw _amount from WETH
    assertEq(_weth.balanceOf(address(_router)), _balance - _amount);
    // it should return the withdrawn native to _msgSender() at closure
    assertEq(_caller.balance, _amount);
    assertEq(address(_router).balance, 0);
  }

  modifier givenTheRecipientIsAnotherAddress() {
    _;
  }

  function test_UnwrapWethWhenTheNativeTransferSucceeds(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external givenTheRecipientIsNotTheZeroAddress givenTheResolvedAmountIsPositive givenTheRecipientIsAnotherAddress {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    // The recipient receives the forwarded native, so it must be a code-less account that accepts ETH, and it must
    // differ from the caller so the caller's msg.value send and the recipient's receipt stay separately observable.
    _recipient = _boundNotEq(_recipient, _caller);
    vm.assume(_recipient.code.length == 0);
    _balance = bound(_balance, 1, type(uint256).max);
    _amount = bound(_amount, 1, _balance);
    // The native leaves during the batch, so it enters as msg.value to keep the pre-batch snapshot at zero.
    vm.deal(_caller, _amount);
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _balance);
    // it should withdraw _amount from WETH
    _mockAndExpect(_WETH, abi.encodeCall(IWETH.withdraw, (_amount)), '');
    uint256 _recipientBalanceBefore = _recipient.balance;

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(_recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: _amount}(_commands, _inputs, block.timestamp);

    // it should send _amount to _recipient
    assertEq(_recipient.balance, _recipientBalanceBefore + _amount);
  }

  function test_UnwrapWethWhenAPipsSpendResolvesAPositiveAmount(
    address _caller,
    address _recipient,
    uint256 _base,
    uint256 _pips
  ) external givenTheRecipientIsNotTheZeroAddress givenTheResolvedAmountIsPositive givenTheRecipientIsAnotherAddress {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    // The recipient receives the forwarded native, so it must be a code-less account that accepts ETH, and it must
    // differ from the caller so the caller's msg.value send and the recipient's receipt stay separately observable.
    _recipient = _boundNotEq(_recipient, _caller);
    vm.assume(_recipient.code.length == 0);
    // Bound the WETH balance so `_base * _pips` cannot overflow, and keep the pip share positive.
    _base = bound(_base, MAX_PIPS, type(uint256).max / MAX_PIPS);
    _pips = bound(_pips, 1, MAX_PIPS);
    // Expected proportion computed with plain arithmetic, independent of the contract's `Math.mulDiv`.
    uint256 _expected = _base * _pips / MAX_PIPS;
    // The native leaves during the batch, so it enters as msg.value to keep the pre-batch snapshot at zero.
    vm.deal(_caller, _expected);
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _base);
    // it should withdraw the pip proportion from WETH
    _mockAndExpect(_WETH, abi.encodeCall(IWETH.withdraw, (_expected)), '');
    uint256 _recipientBalanceBefore = _recipient.balance;

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(_recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: _expected}(_commands, _inputs, block.timestamp);

    // it should send the pip proportion to _recipient
    assertEq(_recipient.balance, _recipientBalanceBefore + _expected);
  }

  function test_UnwrapWethWhenUsingAKnownRoundedDownPipProportion(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress givenTheResolvedAmountIsPositive givenTheRecipientIsAnotherAddress {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    // The recipient receives the forwarded native, so it must be a code-less account that accepts ETH, and it must
    // differ from the caller so the caller's msg.value send and the recipient's receipt stay separately observable.
    _recipient = _boundNotEq(_recipient, _caller);
    vm.assume(_recipient.code.length == 0);
    // 33.3333% (333333 pips) of 1000 = 333.333, floored to 333. Hardcoded independently of Math.mulDiv.
    // The native leaves during the batch, so it enters as msg.value to keep the pre-batch snapshot at zero.
    vm.deal(_caller, 333);
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), 1000);
    // it should withdraw the hand computed floored proportion from WETH
    _mockAndExpect(_WETH, abi.encodeCall(IWETH.withdraw, (333)), '');
    uint256 _recipientBalanceBefore = _recipient.balance;

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(_recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: 333_333}))
    );

    vm.prank(_caller);
    _metarouter.execute{value: 333}(_commands, _inputs, block.timestamp);

    // it should send the hand computed floored proportion to _recipient
    assertEq(_recipient.balance, _recipientBalanceBefore + 333);
  }

  function test_UnwrapWethWhenTheNativeTransferFails(
    address _caller,
    uint256 _balance,
    uint256 _amount
  ) external givenTheRecipientIsNotTheZeroAddress givenTheResolvedAmountIsPositive givenTheRecipientIsAnotherAddress {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 1, type(uint256).max);
    _amount = bound(_amount, 1, _balance);
    // A recipient whose receive hook always reverts with empty data.
    address _recipient = makeAddr('rejectingRecipient');
    vm.etch(_recipient, hex'60006000fd');
    vm.deal(_caller, _amount);
    _mockAndExpectTokenBalance(_WETH, address(_metarouter), _balance);
    _mockAndExpect(_WETH, abi.encodeCall(IWETH.withdraw, (_amount)), '');

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      Commands.UNWRAP_WETH,
      abi.encode(_recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}))
    );

    // it should revert with NativeTransferFailed with _data
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.NativeTransferFailed.selector, bytes('')));
    _metarouter.execute{value: _amount}(_commands, _inputs, block.timestamp);
  }

  // --- helpers ---

  /// @notice Builds a single-command batch from a command ID and its ABI-encoded input.
  /// @param _commandId Command ID placed in the one-byte command string.
  /// @param _input ABI-encoded arguments for the command.
  /// @return _commands One-byte command string.
  /// @return _inputs Single-element input array aligned with `_commands`.
  function _singleCommand(
    uint256 _commandId,
    bytes memory _input
  ) internal pure returns (bytes memory _commands, bytes[] memory _inputs) {
    _commands = abi.encodePacked(bytes1(uint8(_commandId)));
    _inputs = new bytes[](1);
    _inputs[0] = _input;
  }
}
