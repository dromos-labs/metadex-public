// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';

/// @notice CL position command tests. Every dependency is mocked, the position manager included, and the in-flight and
///         custody state is read through the harness views.
contract UnitClPosition is BaseMetarouter {
  /// @notice First pool token of the exercised positions.
  address internal immutable _TOKEN0 = _mockContract('token0');
  /// @notice Second pool token of the exercised positions.
  address internal immutable _TOKEN1 = _mockContract('token1');

  // ============================== mintClPosition ==============================

  function test_MintClPositionWhenTheRecipientIsTheZeroAddress(
    address _caller,
    uint256 _amount0,
    uint256 _amount1
  ) external {
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.MINT_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeMint(address(0), _amount0, _amount1, false, false);

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_MintClPositionWhenTheRecipientIsTheExecutionAddress(
    address _caller,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external {
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _amount0 = bound(_amount0, 0, type(uint256).max - 1);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance0 = bound(_balance0, _amount0 + 1, type(uint256).max);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // it should fund both pool tokens
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _balance0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    // it should approve the position manager for both funded amounts
    // it should clear the position manager allowance for both tokens
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should mint the position to the execution address
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.mint, (_expectedMintParams(address(_metarouter), _amount0, _amount1))),
      abi.encode(_tokenId, uint128(0), _amount0, _amount1)
    );
    // it should take the minted position into custody
    // it should set the minted position in flight
    // The closing ownership read only happens for a position in custody, so expecting it proves the tracking.
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(makeAddr('newPositionOwner'))
    );
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.MINT_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeMint(address(_metarouter), _amount0, _amount1, false, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should set the minted position in flight
    // Closure never touches the in-flight slots.
    (address _collection, uint256 _inFlightId) = _metarouter.inFlightNft();
    assertEq(_collection, _POSITION_MANAGER, 'in-flight collection');
    assertEq(_inFlightId, _tokenId, 'in-flight token id');
  }

  /// @notice A recipient the router is not, so the position never enters custody.
  /// @dev Bounded per-test against the fuzzed value, so it cannot be hoisted here.
  modifier givenTheRecipientIsAnExternalAddress() {
    _;
  }

  function test_MintClPositionWhenBothPoolTokensAreFundedFromTheExecutionBalance(
    address _caller,
    address _recipient,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external givenTheRecipientIsAnExternalAddress {
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _amount0 = bound(_amount0, 0, type(uint256).max - 1);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance0 = bound(_balance0, _amount0 + 1, type(uint256).max);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _balance0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should mint the position to the recipient
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.mint, (_expectedMintParams(_recipient, _amount0, _amount1))),
      abi.encode(_tokenId, uint128(0), _amount0, _amount1)
    );
    // The position never reaches the router, so an ownership read would mean the handler tracked what it does not hold.
    vm.mockCallRevert(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), bytes('no ownership read'));
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.MINT_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeMint(_recipient, _amount0, _amount1, false, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should not take the minted position into custody
    assertEq(_metarouter.trackedNftLength(), 0, 'position tracked');
    // it should not set the minted position in flight
    (address _inFlight,) = _metarouter.inFlightNft();
    assertEq(_inFlight, address(0), 'in-flight set');
  }

  function test_MintClPositionWhenTheLogicalSenderPaysForBothPoolTokens(
    address _caller,
    address _recipient,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external givenTheRecipientIsAnExternalAddress {
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // A pull takes the exact amount, so only the swept balance matters here.
    _balance0 = bound(_balance0, 1, type(uint256).max);
    _balance1 = bound(_balance1, 1, type(uint256).max);
    _assumeFuzzable(_caller);
    // The pull reads the execution balance, so the payer must not be the router.
    _caller = _boundNotEq(_caller, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // it should pull both pool tokens from the logical sender
    uint256[] memory _pulled0 = new uint256[](3);
    _pulled0[1] = _amount0;
    _pulled0[2] = _balance0;
    _mockAndExpectTokenBalances(_TOKEN0, address(_metarouter), _pulled0);
    _mockAndExpect(
      _TOKEN0, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _amount0)), abi.encode(true)
    );
    uint256[] memory _pulled1 = new uint256[](3);
    _pulled1[1] = _amount1;
    _pulled1[2] = _balance1;
    _mockAndExpectTokenBalances(_TOKEN1, address(_metarouter), _pulled1);
    _mockAndExpect(
      _TOKEN1, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _amount1)), abi.encode(true)
    );
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should mint with both pulled amounts
    // A payer flag on the wrong token would resolve the other token's amount and miss this expectation.
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.mint, (_expectedMintParams(_recipient, _amount0, _amount1))),
      abi.encode(_tokenId, uint128(0), _amount0, _amount1)
    );
    vm.mockCallRevert(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), bytes('no ownership read'));
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.MINT_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeMint(_recipient, _amount0, _amount1, true, true);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_MintClPositionWhenThePoolTokensHaveDifferentPayers(
    address _caller,
    address _recipient,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external givenTheRecipientIsAnExternalAddress {
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // A pull takes the exact amount, so only the swept balance matters here.
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _balance0 = bound(_balance0, 1, type(uint256).max);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    // The pull reads the execution balance, so the payer must not be the router.
    _caller = _boundNotEq(_caller, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // it should pull token zero from the logical sender
    uint256[] memory _pulled0 = new uint256[](3);
    _pulled0[1] = _amount0;
    _pulled0[2] = _balance0;
    _mockAndExpectTokenBalances(_TOKEN0, address(_metarouter), _pulled0);
    _mockAndExpect(
      _TOKEN0, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _amount0)), abi.encode(true)
    );
    // it should fund token one from the execution balance
    // A payer flag on the wrong token would ask the router for a balance it never held.
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should mint with both resolved amounts
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.mint, (_expectedMintParams(_recipient, _amount0, _amount1))),
      abi.encode(_tokenId, uint128(0), _amount0, _amount1)
    );
    vm.mockCallRevert(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), bytes('no ownership read'));
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.MINT_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeMint(_recipient, _amount0, _amount1, true, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== increaseClLiquidity ==============================

  function test_IncreaseClLiquidityWhenTheTokenIdIsTheInFlightSentinel(
    address _caller,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external {
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _amount0 = bound(_amount0, 0, type(uint256).max - 1);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance0 = bound(_balance0, _amount0 + 1, type(uint256).max);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // Seed the position a producer command would leave, always both in custody and in flight.
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _metarouter.setInFlightNft(_POSITION_MANAGER, _tokenId);
    // The closing ownership read reports a new owner, modelling the position leaving. It only happens for a position in
    // custody, so expecting it proves the tracking.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), _encodePositions()
    );
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _balance0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should increase the liquidity of the in flight position
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.increaseLiquidity, (_expectedIncreaseParams(_tokenId, _amount0, _amount1))
      ),
      abi.encode(uint128(0), _amount0, _amount1)
    );
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.INCREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeIncrease(0, _amount0, _amount1, false, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The router owns the position, so only custody tracking separates one this batch took from a stranded one.
  /// @dev Seeded per-test: one branch reverts before closure and the other runs through it.
  modifier givenThePositionIsAlreadyInCustody() {
    _;
  }

  function test_IncreaseClLiquidityWhenTheCustodiedPositionWasNotTrackedThisBatch(
    address _caller,
    uint256 _tokenId
  ) external givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));
    _assumeFuzzable(_caller);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.INCREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeIncrease(_tokenId, 0, 0, false, false);

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_IncreaseClLiquidityWhenTheCustodiedPositionWasTrackedThisBatch(
    address _caller,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    // The closing ownership read reports a new owner, modelling the position leaving. It only happens for a position in
    // custody, so expecting it proves the tracking.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _amount0 = bound(_amount0, 0, type(uint256).max - 1);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance0 = bound(_balance0, _amount0 + 1, type(uint256).max);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), _encodePositions()
    );
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _balance0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should increase the liquidity of the held position
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.increaseLiquidity, (_expectedIncreaseParams(_tokenId, _amount0, _amount1))
      ),
      abi.encode(uint128(0), _amount0, _amount1)
    );
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.INCREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeIncrease(_tokenId, _amount0, _amount1, false, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The router does not own the position, so the owner comparison decides. The increase path has no such
  ///         comparison, so a stranger's position takes it too.
  /// @dev Seeded per-test against the fuzzed token id and owner.
  modifier givenThePositionIsNotAlreadyInCustody() {
    _;
  }

  function test_IncreaseClLiquidityWhenBothPoolTokensAreFundedFromTheExecutionBalance(
    address _caller,
    address _owner,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _amount0 = bound(_amount0, 0, type(uint256).max - 1);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance0 = bound(_balance0, _amount0 + 1, type(uint256).max);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // it should read the position pool tokens
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), _encodePositions()
    );
    // it should fund both pool tokens
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _balance0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    // it should approve the position manager for both funded amounts
    // it should clear the position manager allowance for both tokens
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should increase the position liquidity
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.increaseLiquidity, (_expectedIncreaseParams(_tokenId, _amount0, _amount1))
      ),
      abi.encode(uint128(0), _amount0, _amount1)
    );
    // The remainder returns to the sender who paid, not to the position's owner.
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.INCREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeIncrease(_tokenId, _amount0, _amount1, false, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_IncreaseClLiquidityWhenThePoolTokensHaveDifferentPayers(
    address _caller,
    address _owner,
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _balance0,
    uint256 _balance1
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // A pull takes the exact amount, so only the swept balance matters here.
    // The balance must cover the spend and stay above zero, so the sweep proving the token was tracked still fires.
    _balance0 = bound(_balance0, 1, type(uint256).max);
    _amount1 = bound(_amount1, 0, type(uint256).max - 1);
    _balance1 = bound(_balance1, _amount1 + 1, type(uint256).max);
    _assumeFuzzable(_caller);
    // The pull reads the execution balance, so the payer must not be the router.
    _caller = _boundNotEq(_caller, address(_metarouter));
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), _encodePositions()
    );
    // it should pull token zero from the logical sender
    uint256[] memory _pulled0 = new uint256[](3);
    _pulled0[1] = _amount0;
    _pulled0[2] = _balance0;
    _mockAndExpectTokenBalances(_TOKEN0, address(_metarouter), _pulled0);
    _mockAndExpect(
      _TOKEN0, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _amount0)), abi.encode(true)
    );
    // it should fund token one from the execution balance
    // A payer flag on the wrong token would ask the router for a balance it never held.
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _balance1);
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount0)), abi.encode(true));
    _mockAndExpect(_TOKEN0, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, _amount1)), abi.encode(true));
    _mockAndExpect(_TOKEN1, abi.encodeCall(IERC20.approve, (_POSITION_MANAGER, 0)), abi.encode(true));
    // it should increase the position liquidity with both resolved amounts
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.increaseLiquidity, (_expectedIncreaseParams(_tokenId, _amount0, _amount1))
      ),
      abi.encode(uint128(0), _amount0, _amount1)
    );
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _balance0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _balance1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.INCREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeIncrease(_tokenId, _amount0, _amount1, true, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== decreaseClLiquidity ==============================

  function test_DecreaseClLiquidityWhenTheTokenIdIsTheInFlightSentinel(
    address _caller,
    uint256 _tokenId,
    uint128 _liquidity
  ) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // Seed the position a producer command would leave, always both in custody and in flight.
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _metarouter.setInFlightNft(_POSITION_MANAGER, _tokenId);
    // The closing ownership read reports a new owner, modelling the position leaving. It only happens for a position in
    // custody, so expecting it proves the tracking.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    // it should decrease the liquidity of the in flight position
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.decreaseLiquidity, (_expectedDecreaseParams(_tokenId, _liquidity))),
      abi.encode(uint256(0), uint256(0))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(0, _liquidity);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DecreaseClLiquidityWhenTheCustodiedPositionWasNotTrackedThisBatch(
    address _caller,
    uint256 _tokenId,
    uint128 _liquidity
  ) external givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));
    _assumeFuzzable(_caller);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(_tokenId, _liquidity);

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DecreaseClLiquidityWhenTheCustodiedPositionWasTrackedThisBatch(
    address _caller,
    uint256 _tokenId,
    uint128 _liquidity
  ) external givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    // The closing ownership read reports a new owner, modelling the position leaving. It only happens for a position in
    // custody, so expecting it proves the tracking.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    _assumeFuzzable(_caller);
    // it should decrease the liquidity of the held position
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.decreaseLiquidity, (_expectedDecreaseParams(_tokenId, _liquidity))),
      abi.encode(uint256(0), uint256(0))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(_tokenId, _liquidity);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DecreaseClLiquidityWhenTheOwnerIsNotTheLogicalSender(
    address _caller,
    address _owner,
    uint256 _tokenId,
    uint128 _liquidity
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // The comparison fails only when the batch runs as someone else.
    _caller = _boundNotEq(_caller, _owner);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(_tokenId, _liquidity);

    // it should revert with NotPositionOwner
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NotPositionOwner.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DecreaseClLiquidityWhenTheOwnerIsTheLogicalSender(
    address _owner,
    uint256 _tokenId,
    uint128 _liquidity
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // The comparison passes only when the batch runs as the owner.
    // it should decrease the requested position liquidity
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.decreaseLiquidity, (_expectedDecreaseParams(_tokenId, _liquidity))),
      abi.encode(uint256(0), uint256(0))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(_tokenId, _liquidity);

    vm.prank(_owner);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DecreaseClLiquidityWhenTheOwnerIsTheLogicalSenderAndAllLiquidityIsRequested(
    address _owner,
    uint256 _tokenId,
    uint128 _preparedLiquidity,
    uint128 _donatedLiquidity
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _preparedLiquidity = uint128(bound(_preparedLiquidity, 0, type(uint128).max - 1));
    _donatedLiquidity = uint128(bound(_donatedLiquidity, 1, type(uint128).max - _preparedLiquidity));
    uint128 _currentLiquidity = _preparedLiquidity + _donatedLiquidity;
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // it should read the current position liquidity
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)),
      _encodePositions(_currentLiquidity)
    );
    // Revert explicitly if the handler uses the stale prepared liquidity instead of the live position liquidity.
    vm.mockCallRevert(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.decreaseLiquidity, (_expectedDecreaseParams(_tokenId, _preparedLiquidity))
      ),
      bytes('stale liquidity')
    );
    // it should decrease the current position liquidity
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.decreaseLiquidity, (_expectedDecreaseParams(_tokenId, _currentLiquidity))
      ),
      abi.encode(uint256(0), uint256(0))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(_tokenId, _preparedLiquidity, true);

    vm.prank(_owner);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DecreaseClLiquidityWhenTheOwnerIsTheLogicalSenderAndAllLiquidityIsRequestedOnAnEmptyPosition(
    address _owner,
    uint256 _tokenId,
    uint128 _requestedLiquidity
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), _encodePositions(0)
    );
    // it should skip the decrease
    // The manager rejects a zero-liquidity decrease, so any decrease call would abort the batch.
    vm.mockCallRevert(
      _POSITION_MANAGER,
      abi.encodeWithSelector(INonfungiblePositionManager.decreaseLiquidity.selector),
      bytes('no decrease call')
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DECREASE_CL_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _encodeDecrease(_tokenId, _requestedLiquidity, true);

    vm.prank(_owner);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== collectClFees ==============================

  function test_CollectClFeesWhenTheRecipientIsTheZeroAddress(
    address _caller,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) external {
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: _tokenId, recipient: address(0), amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheRecipientIsValid() {
    _;
  }

  function test_CollectClFeesWhenTheTokenIdIsTheInFlightSentinel(
    address _caller,
    address _recipient,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) external givenTheRecipientIsValid {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // Seed the position a producer command would leave, always both in custody and in flight.
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _metarouter.setInFlightNft(_POSITION_MANAGER, _tokenId);
    // The closing ownership read reports a new owner, modelling the position leaving. It only happens for a position in
    // custody, so expecting it proves the tracking.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    // it should collect from the in flight position
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.collect, (_expectedCollectParams(_tokenId, _recipient, _amount0Max, _amount1Max))
      ),
      abi.encode(uint256(_amount0Max), uint256(_amount1Max))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: uint256(0), recipient: _recipient, amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CollectClFeesWhenTheCustodiedPositionWasNotTrackedThisBatch(
    address _caller,
    address _recipient,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) external givenTheRecipientIsValid givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: _tokenId, recipient: _recipient, amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CollectClFeesWhenTheCustodiedPositionWasTrackedThisBatch(
    address _caller,
    address _recipient,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) external givenTheRecipientIsValid givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    // The closing ownership read reports a new owner, modelling the position leaving. It only happens for a position in
    // custody, so expecting it proves the tracking.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // it should collect from the held position
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.collect, (_expectedCollectParams(_tokenId, _recipient, _amount0Max, _amount1Max))
      ),
      abi.encode(uint256(_amount0Max), uint256(_amount1Max))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: _tokenId, recipient: _recipient, amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CollectClFeesWhenTheOwnerIsNotTheLogicalSender(
    address _caller,
    address _owner,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) external givenTheRecipientIsValid givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // The comparison fails only when the batch runs as someone else.
    _caller = _boundNotEq(_caller, _owner);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: _tokenId, recipient: _caller, amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    // it should revert with NotPositionOwner
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NotPositionOwner.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The batch runs as the position's owner, the outcome the owner comparison lets through.
  modifier givenTheOwnerIsTheLogicalSender() {
    _;
  }

  function test_CollectClFeesWhenTheRecipientIsTheExecutionAddress(
    address _owner,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max,
    uint256 _fee0,
    uint256 _fee1
  ) external givenTheRecipientIsValid givenThePositionIsNotAlreadyInCustody givenTheOwnerIsTheLogicalSender {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    _fee0 = bound(_fee0, 1, type(uint256).max);
    _fee1 = bound(_fee1, 1, type(uint256).max);
    // it should track both pool tokens
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), _encodePositions()
    );
    // it should collect to the execution address
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.collect,
        (_expectedCollectParams(_tokenId, address(_metarouter), _amount0Max, _amount1Max))
      ),
      abi.encode(uint256(_amount0Max), uint256(_amount1Max))
    );
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _fee0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _fee1);
    _mockAndExpectTokenTransfer(_TOKEN0, _owner, _fee0);
    _mockAndExpectTokenTransfer(_TOKEN1, _owner, _fee1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: _tokenId, recipient: address(_metarouter), amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    vm.prank(_owner);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CollectClFeesWhenTheRecipientIsAnyOtherAddress(
    address _owner,
    address _recipient,
    uint256 _tokenId,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) external givenTheRecipientIsValid givenThePositionIsNotAlreadyInCustody givenTheOwnerIsTheLogicalSender {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // it should collect to the recipient
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeCall(
        INonfungiblePositionManager.collect, (_expectedCollectParams(_tokenId, _recipient, _amount0Max, _amount1Max))
      ),
      abi.encode(uint256(_amount0Max), uint256(_amount1Max))
    );
    // it should not track the pool tokens
    // Nothing lands in the execution address, so the pool tokens are never read and the closure has nothing to sweep.
    vm.mockCallRevert(
      _POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.positions, (_tokenId)), bytes('no tracking')
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.COLLECT_CL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      INonfungiblePositionManager.CollectParams({
        tokenId: _tokenId, recipient: _recipient, amount0Max: _amount0Max, amount1Max: _amount1Max
      })
    );

    vm.prank(_owner);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== burnClPosition ==============================

  function test_BurnClPositionWhenTheTokenIdIsTheInFlightSentinel(address _caller, uint256 _tokenId) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // Seed the position a producer command would leave, always both in custody and in flight.
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _metarouter.setInFlightNft(_POSITION_MANAGER, _tokenId);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));
    // it should burn the in flight position

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.BURN_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(uint256(0));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the in flight slots
    (address _inFlight,) = _metarouter.inFlightNft();
    assertEq(_inFlight, address(0), 'in-flight not cleared');
  }

  function test_BurnClPositionWhenTheCustodiedPositionWasNotTrackedThisBatch(
    address _caller,
    uint256 _tokenId
  ) external givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));
    _assumeFuzzable(_caller);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.BURN_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId);

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_BurnClPositionWhenTheCustodiedPositionWasTrackedThisBatch(
    address _caller,
    uint256 _tokenId
  ) external givenThePositionIsAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    // The burn drops the id from custody, so the closure loop skips it and never reads the owner again.
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));
    _assumeFuzzable(_caller);
    // it should burn the position

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.BURN_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId);

    // it should let the batch close on the burned token id
    // A mock cannot forget the token, so the batch closing at all is what proves the burn untracked it.
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should remove the position from custody
    assertEq(_metarouter.trackedNftLength(), 0, 'position still tracked');
  }

  function test_BurnClPositionWhenTheOwnerIsNotTheLogicalSender(
    address _caller,
    address _owner,
    uint256 _tokenId
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // The comparison fails only when the batch runs as someone else.
    _caller = _boundNotEq(_caller, _owner);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.BURN_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId);

    // it should revert with NotPositionOwner
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NotPositionOwner.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_BurnClPositionWhenTheOwnerIsTheLogicalSender(
    address _owner,
    uint256 _tokenId
  ) external givenThePositionIsNotAlreadyInCustody {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _owner = _boundNotEq(_owner, address(_metarouter));
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
    // The comparison passes only when the batch runs as the owner.
    // it should burn the position
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(INonfungiblePositionManager.burn, (_tokenId)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.BURN_CL_POSITION)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId);

    vm.prank(_owner);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== helpers ==============================

  /// @notice The `DecreaseLiquidityParams` the handler builds.
  /// @param _tokenId Resolved position.
  /// @param _liquidity Liquidity to remove.
  /// @return _params Expected `DecreaseLiquidityParams`.
  function _expectedDecreaseParams(
    uint256 _tokenId,
    uint128 _liquidity
  ) internal view returns (INonfungiblePositionManager.DecreaseLiquidityParams memory _params) {
    _params = INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: _tokenId, liquidity: _liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
      });
  }

  /// @notice The `CollectParams` the handler builds.
  /// @param _tokenId Resolved position.
  /// @param _recipient Resolved recipient.
  /// @param _amount0Max Maximum `token0` to collect.
  /// @param _amount1Max Maximum `token1` to collect.
  /// @return _params Expected `CollectParams`.
  function _expectedCollectParams(
    uint256 _tokenId,
    address _recipient,
    uint128 _amount0Max,
    uint128 _amount1Max
  ) internal pure returns (INonfungiblePositionManager.CollectParams memory _params) {
    _params = INonfungiblePositionManager.CollectParams({
      tokenId: _tokenId, recipient: _recipient, amount0Max: _amount0Max, amount1Max: _amount1Max
    });
  }

  /// @notice The `IncreaseLiquidityParams` the handler builds.
  /// @param _tokenId Resolved position.
  /// @param _amount0 Funded `token0` amount.
  /// @param _amount1 Funded `token1` amount.
  /// @return _params Expected `IncreaseLiquidityParams`.
  function _expectedIncreaseParams(
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1
  ) internal view returns (INonfungiblePositionManager.IncreaseLiquidityParams memory _params) {
    _params = INonfungiblePositionManager.IncreaseLiquidityParams({
        tokenId: _tokenId,
        amount0Desired: _amount0,
        amount1Desired: _amount1,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
      });
  }

  /// @notice An empty position tuple carrying only the two pool tokens.
  /// @return _positions ABI-encoded `positions` return, every other field zero.
  function _encodePositions() internal view returns (bytes memory _positions) {
    return _encodePositions(0);
  }

  /// @notice A position tuple carrying the two pool tokens and its liquidity.
  /// @param _liquidity Current position liquidity.
  /// @return _positions ABI-encoded `positions` return, every other field zero.
  function _encodePositions(uint128 _liquidity) internal view returns (bytes memory _positions) {
    _positions = abi.encode(
      uint96(0),
      address(0),
      _TOKEN0,
      _TOKEN1,
      int24(0),
      int24(0),
      int24(0),
      _liquidity,
      uint256(0),
      uint256(0),
      uint128(0),
      uint128(0)
    );
  }

  /// @notice The mint command input.
  /// @param _recipient Mint recipient, or zero for the execution address.
  /// @param _amount0 Exact `token0` amount to fund.
  /// @param _amount1 Exact `token1` amount to fund.
  /// @param _payerIsUser0 Whether `token0` is pulled from the sender instead of the execution balance.
  /// @param _payerIsUser1 Whether `token1` is pulled from the sender instead of the execution balance.
  /// @return _input ABI-encoded `MintClParams`.
  function _encodeMint(
    address _recipient,
    uint256 _amount0,
    uint256 _amount1,
    bool _payerIsUser0,
    bool _payerIsUser1
  ) internal view returns (bytes memory _input) {
    _input = abi.encode(
      IMetarouter.MintClParams({
        token0: _TOKEN0,
        token1: _TOKEN1,
        tickSpacing: 0,
        tickLower: 0,
        tickUpper: 0,
        spend0: IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount0),
        spend1: IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount1),
        payerIsUser0: _payerIsUser0,
        payerIsUser1: _payerIsUser1,
        amount0Min: 0,
        amount1Min: 0,
        recipient: _recipient,
        sqrtPriceX96: 0,
        deadline: block.timestamp
      })
    );
  }

  /// @notice The `MintParams` the handler builds, with the resolved recipient.
  /// @param _recipient Resolved mint recipient.
  /// @param _amount0 Funded `token0` amount.
  /// @param _amount1 Funded `token1` amount.
  /// @return _params Expected `MintParams`.
  function _expectedMintParams(
    address _recipient,
    uint256 _amount0,
    uint256 _amount1
  ) internal view returns (INonfungiblePositionManager.MintParams memory _params) {
    _params = INonfungiblePositionManager.MintParams({
      token0: _TOKEN0,
      token1: _TOKEN1,
      tickSpacing: 0,
      tickLower: 0,
      tickUpper: 0,
      amount0Desired: _amount0,
      amount1Desired: _amount1,
      amount0Min: 0,
      amount1Min: 0,
      recipient: _recipient,
      deadline: block.timestamp,
      sqrtPriceX96: 0
    });
  }

  /// @notice The increase command input.
  /// @param _tokenId Position to increase, or zero for the in-flight one.
  /// @param _amount0 Exact `token0` amount to fund.
  /// @param _amount1 Exact `token1` amount to fund.
  /// @param _payerIsUser0 Whether `token0` is pulled from the sender instead of the execution balance.
  /// @param _payerIsUser1 Whether `token1` is pulled from the sender instead of the execution balance.
  /// @return _input ABI-encoded `IncreaseClParams`.
  function _encodeIncrease(
    uint256 _tokenId,
    uint256 _amount0,
    uint256 _amount1,
    bool _payerIsUser0,
    bool _payerIsUser1
  ) internal view returns (bytes memory _input) {
    _input = abi.encode(
      IMetarouter.IncreaseClParams({
        tokenId: _tokenId,
        spend0: IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount0),
        spend1: IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount1),
        payerIsUser0: _payerIsUser0,
        payerIsUser1: _payerIsUser1,
        amount0Min: 0,
        amount1Min: 0,
        deadline: block.timestamp
      })
    );
  }

  /// @notice The decrease command input.
  /// @param _tokenId Position to decrease, or zero for the in-flight one.
  /// @param _liquidity Liquidity to remove.
  /// @return _input ABI-encoded `(DecreaseLiquidityParams, false)`.
  function _encodeDecrease(uint256 _tokenId, uint128 _liquidity) internal view returns (bytes memory _input) {
    return _encodeDecrease(_tokenId, _liquidity, false);
  }

  /// @notice The decrease command input.
  /// @param _tokenId Position to decrease, or zero for the in-flight one.
  /// @param _liquidity Exact liquidity to remove when `_decreaseAllLiquidity` is false.
  /// @param _decreaseAllLiquidity Whether to resolve all current liquidity at execution time.
  /// @return _input ABI-encoded `(DecreaseLiquidityParams, bool)`.
  function _encodeDecrease(
    uint256 _tokenId,
    uint128 _liquidity,
    bool _decreaseAllLiquidity
  ) internal view returns (bytes memory _input) {
    _input = abi.encode(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: _tokenId, liquidity: _liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
      }),
      _decreaseAllLiquidity
    );
  }
}
