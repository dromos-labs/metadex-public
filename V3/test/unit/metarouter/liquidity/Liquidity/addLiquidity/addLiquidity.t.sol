// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseLiquidity} from 'V3-test/unit/metarouter/liquidity/BaseLiquidity.sol';

/// @notice V2 add-liquidity command tests covering factory validation, optional pool creation, funding, reserve-ratio
///         trimming, minimums, minting, and closure sweeps. Every external dependency is mocked.
contract UnitLiquidityAddLiquidity is BaseLiquidity {
  function test_WhenTheRecipientIsTheZeroAddress(address _caller, address _factory) external {
    IMetarouter.AddLiquidityParams memory _params;
    // The factory is never touched: the zero-recipient guard reverts before validation, so it is fuzzed freely.
    _params.factory = _factory;
    _params.recipient = address(0);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice Constrains the recipient to a fuzzable non-zero address, the passing branch of the recipient guard.
  modifier givenTheRecipientIsNotTheZeroAddress(address _recipient) {
    _assumeFuzzable(_recipient);
    _;
  }

  function test_WhenTheFactoryIsNotApproved(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_FACTORY)), abi.encode(false)
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_addParams(0, 0, _recipient));

    // it should revert with FactoryNotApproved
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.FactoryNotApproved.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The FactoryRegistry approves the selected factory, the trust anchor for pool resolution.
  modifier givenTheFactoryIsApproved() {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_FACTORY)), abi.encode(true)
    );
    _;
  }

  function test_WhenTheResolvedPoolHoldsADifferentPair(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) givenTheFactoryIsApproved {
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.getPool, (_TOKEN0, _TOKEN1)), abi.encode(_POOL));
    // The resolved pool reports tokenB in token0's slot and an unrelated token in token1's slot. This asymmetric
    // mismatch proves either failed reverse-order correspondence is enough to reject the pool.
    address _otherToken = _mockContract('otherToken');
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(0), uint256(0), _TOKEN1, _otherToken)
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_addParams(0, 0, _recipient));

    // it should revert with PoolTokenMismatch
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.PoolTokenMismatch.selector, _POOL));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheFactoryHasNoPoolAndCreationIsNotRequested(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) givenTheFactoryIsApproved {
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.getPool, (_TOKEN0, _TOKEN1)), abi.encode(address(0)));
    // Creation stays opt-in, so the un-requested path never reaches the factory's createPool.
    vm.mockCallRevert(_FACTORY, abi.encodeWithSelector(IPoolFactory.createPool.selector), bytes('no create'));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_addParams(0, 0, _recipient));

    // it should revert with PoolNotFound
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.PoolNotFound.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheFactoryHasNoPoolAndCreationIsRequested(
    address _caller,
    address _recipient,
    uint256 _fundedA,
    uint256 _fundedB
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) givenTheFactoryIsApproved {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.getPool, (_TOKEN0, _TOKEN1)), abi.encode(address(0)));
    // it should create the pool through the factory
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.createPool, (_TOKEN0, _TOKEN1)), abi.encode(_POOL));
    // A freshly created pool is unseeded, so the funded amounts deposit unchanged.
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(0), uint256(0), _TOKEN0, _TOKEN1)
    );
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [_fundedA, uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [_fundedB, uint256(0)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push both funded amounts to the created pool
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, _fundedA);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, _fundedB);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    IMetarouter.AddLiquidityParams memory _params = _addParams(_fundedA, _fundedB, _recipient);
    _params.createPool = true;
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenAStableAndAVolatileFactoryEachResolveTheirOwnPool(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _stableFactory = _mockContract('StablePoolFactory');
    address _stablePool = _mockContract('StablePool');
    // Both variant factories are approved, and each resolves the same pair to its own pool.
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_FACTORY)), abi.encode(true)
    );
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_stableFactory)), abi.encode(true)
    );
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.getPool, (_TOKEN0, _TOKEN1)), abi.encode(_POOL));
    _mockAndExpect(_stableFactory, abi.encodeCall(IPoolFactory.getPool, (_TOKEN0, _TOKEN1)), abi.encode(_stablePool));
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(0), uint256(0), _TOKEN0, _TOKEN1)
    );
    _mockAndExpect(
      _stablePool,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(0), uint256(0), _TOKEN0, _TOKEN1)
    );
    // Three reads per token: one per command funding and one at closure with nothing left to sweep.
    uint256[] memory _balancesA = new uint256[](3);
    _balancesA[0] = 400;
    _balancesA[1] = 300;
    uint256[] memory _balancesB = new uint256[](3);
    _balancesB[0] = 600;
    _balancesB[1] = 400;
    _mockAndExpectTokenBalances(_TOKEN0, address(_metarouter), _balancesA);
    _mockAndExpectTokenBalances(_TOKEN1, address(_metarouter), _balancesB);
    // Neither LP is tracked: both mints go straight to the external recipient.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    vm.mockCallRevert(_stablePool, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should deposit into the pool of the selected factory
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 100);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 200);
    _mockAndExpectTokenTransfer(_TOKEN0, _stablePool, 300);
    _mockAndExpectTokenTransfer(_TOKEN1, _stablePool, 400);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));
    _mockAndExpect(_stablePool, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));

    IMetarouter.AddLiquidityParams memory _volatileParams = _addParams(100, 200, _recipient);
    IMetarouter.AddLiquidityParams memory _stableParams = _addParams(300, 400, _recipient);
    _stableParams.factory = _stableFactory;

    bytes memory _commands =
      abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)), bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](2);
    _inputs[0] = abi.encode(_volatileParams);
    _inputs[1] = abi.encode(_stableParams);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenThePairIsPassedInReversePoolOrder(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) givenTheFactoryIsApproved {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The pair is requested as (token1, token0); the factory resolves it regardless of the order.
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.getPool, (_TOKEN1, _TOKEN0)), abi.encode(_POOL));
    // Pool reserves are 100 token0 to 200 token1. In the caller's order they realign to 200 to 100, so the funded
    // 900 pool-tokenB re-quotes to 100 against the funded 50 pool-tokenA.
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(100), uint256(200), _TOKEN0, _TOKEN1)
    );
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [uint256(900), uint256(800)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [uint256(50), uint256(0)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push the trimmed amounts to the pool
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 100);
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 50);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, 800);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));

    IMetarouter.AddLiquidityParams memory _params = _addParams(900, 50, _recipient);
    _params.tokenA = _TOKEN1;
    _params.tokenB = _TOKEN0;
    // it should trim the deposit with the realigned reserves
    // Without the realignment the trim would commit 25 caller-order tokenA, below this minimum, and revert.
    _params.amountAMin = 100;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The selected factory reports an existing pool for the pair, so the command skips creation.
  modifier givenTheFactoryResolvesThePool() {
    _mockAndExpect(_FACTORY, abi.encodeCall(IPoolFactory.getPool, (_TOKEN0, _TOKEN1)), abi.encode(_POOL));
    _;
  }

  function test_WhenTokenAHasAnExternalPayerAndChargesAFeeOnTransfer(
    address _caller,
    address _recipient,
    uint256 _requestedA,
    uint256 _receivedA,
    uint256 _fundedB
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) givenTheFactoryIsApproved givenTheFactoryResolvesThePool {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _requestedA = bound(_requestedA, 2, type(uint256).max);
    _receivedA = bound(_receivedA, 1, _requestedA - 1);
    // An unseeded pool skips the ratio trim, so the measured received amount is exactly what reaches the pool.
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(0), uint256(0), _TOKEN0, _TOKEN1)
    );
    // The pull measures the received delta: zero before, the received amount after, and zero left at closure.
    uint256[] memory _balancesA = new uint256[](3);
    _balancesA[1] = _receivedA;
    _mockAndExpectTokenBalances(_TOKEN0, address(_metarouter), _balancesA);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [_fundedB, uint256(0)]);
    // it should pull the requested token A amount from _caller
    _mockAndExpect(
      _TOKEN0, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _requestedA)), abi.encode(true)
    );
    // it should push the measured received token A amount to the pool
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, _receivedA);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, _fundedB);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));

    IMetarouter.AddLiquidityParams memory _params = _addParams(_requestedA, _fundedB, _recipient);
    _params.payerAIsUser = true;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice An unseeded pool reports both reserves at zero, so the deposit takes the funded amounts unchanged.
  modifier givenThePoolIsUnseeded() {
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), uint256(0), uint256(0), _TOKEN0, _TOKEN1)
    );
    _;
  }

  function test_WhenTheFundedTokenAIsBelowItsMinimum(
    address _caller,
    address _recipient,
    uint256 _fundedA,
    uint256 _fundedB
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsUnseeded
  {
    _fundedA = bound(_fundedA, 0, type(uint256).max - 1);
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _fundedA);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _fundedB);

    IMetarouter.AddLiquidityParams memory _params = _addParams(_fundedA, _fundedB, _recipient);
    // The funded tokenA sits one unit below its minimum.
    _params.amountAMin = _fundedA + 1;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InsufficientAmount0
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InsufficientAmountA.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheFundedTokenBIsBelowItsMinimum(
    address _caller,
    address _recipient,
    uint256 _fundedA,
    uint256 _fundedB
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsUnseeded
  {
    _fundedB = bound(_fundedB, 0, type(uint256).max - 1);
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _fundedA);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _fundedB);

    IMetarouter.AddLiquidityParams memory _params = _addParams(_fundedA, _fundedB, _recipient);
    // The funded tokenB sits one unit below its minimum.
    _params.amountBMin = _fundedB + 1;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InsufficientAmount1
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InsufficientAmountB.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenBothFundedAmountsMeetTheirMinimums() {
    // Each test sets minimums against its fuzzed or hardcoded amounts, so nothing can be hoisted here.
    _;
  }

  function test_WhenTheRecipientIsTheRouter(
    address _caller,
    uint256 _fundedA,
    uint256 _fundedB
  )
    external
    givenTheRecipientIsNotTheZeroAddress(address(_metarouter))
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsUnseeded
    givenBothFundedAmountsMeetTheirMinimums
  {
    // The funded amounts are fully deposited, so nothing is left to sweep: both closure reads return zero.
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [_fundedA, uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [_fundedB, uint256(0)]);
    // it should push both funded amounts to the pool
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, _fundedA);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, _fundedB);
    // it should track the minted lp token
    _mockAndExpectTokenBalance(_POOL, address(_metarouter), 0);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (address(_metarouter))), abi.encode(uint256(1)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_addParams(_fundedA, _fundedB, address(_metarouter)));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheRecipientIsNotTheRouter(
    address _caller,
    address _recipient,
    uint256 _fundedA,
    uint256 _fundedB
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsUnseeded
    givenBothFundedAmountsMeetTheirMinimums
  {
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [_fundedA, uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [_fundedB, uint256(0)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push both funded amounts to the pool
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, _fundedA);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, _fundedB);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_addParams(_fundedA, _fundedB, _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @dev Seeds the pool's metadata with the test's hand-picked reserves, activating the reserve-ratio trim; each
  ///         test passes its own values so the trimmed amounts are independent hand computations rather than a replay
  ///         of the contract formula.
  modifier givenThePoolIsSeeded(uint256 _reserveA, uint256 _reserveB) {
    _mockAndExpect(
      _POOL,
      abi.encodeCall(IPool.metadata, ()),
      abi.encode(uint256(18), uint256(18), _reserveA, _reserveB, _TOKEN0, _TOKEN1)
    );
    _;
  }

  /// @notice Proves the add-liquidity command rejects a pool mint result below the caller's LP-token minimum.
  function test_WhenTheMintedLiquidityIsBelowItsMinimum(
    address _caller,
    address _recipient,
    uint256 _liquidity,
    uint256 _liquidityMin
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(100, 100)
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The pool reverts a zero mint itself, so the smallest short mint the router can observe is one.
    _liquidity = bound(_liquidity, 1, type(uint256).max - 1);
    _liquidityMin = bound(_liquidityMin, _liquidity + 1, type(uint256).max);
    // The revert aborts the batch before closure, so each token balance is read once and no sweep runs.
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), 100);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), 100);
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 100);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 100);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(_liquidity));

    IMetarouter.AddLiquidityParams memory _params = _addParams(100, 100, _recipient);
    _params.amountAMin = 100;
    _params.amountBMin = 100;
    _params.liquidityMin = _liquidityMin;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    // it should revert with InsufficientLiquidityMinted
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientLiquidityMinted.selector, _liquidityMin, _liquidity));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice Proves a pool mint result exactly equal to the caller's LP-token minimum is accepted.
  function test_WhenTheMintedLiquidityEqualsItsMinimum(
    address _caller,
    address _recipient,
    uint256 _liquidity
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(100, 100)
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _liquidity = bound(_liquidity, 1, type(uint256).max);
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [uint256(100), uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [uint256(100), uint256(0)]);
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 100);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 100);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(_liquidity));

    IMetarouter.AddLiquidityParams memory _params = _addParams(100, 100, _recipient);
    _params.amountAMin = 100;
    _params.amountBMin = 100;
    _params.liquidityMin = _liquidity;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should accept the minted liquidity
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheFullTokenBQuoteFitsUint() {
    // The hardcoded reserve and funding values keep the forward quote representable in every test under this branch.
    _;
  }

  modifier givenTheOptimalTokenBDoesNotExceedTheFundedTokenB() {
    // The reserve ratio and funded amounts are hardcoded per test to place the optimal tokenB within the funded tokenB.
    _;
  }

  function test_WhenTheFlooredTokenBQuoteEqualsTheFundedAmount(
    address _caller,
    address _recipient
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(2000, 2003)
    givenTheFullTokenBQuoteFitsUint
    givenTheOptimalTokenBDoesNotExceedTheFundedTokenB
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The exact tokenB ratio is 668.0005, but the established floor quote uses both funded amounts, 667 and 668.
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [uint256(667), uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [uint256(668), uint256(0)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push both funded amounts to the pool
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 667);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 668);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));

    IMetarouter.AddLiquidityParams memory _params = _addParams(667, 668, _recipient);
    _params.amountAMin = 667;
    _params.amountBMin = 668;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheOptimalTokenBIsBelowItsMinimum(
    address _caller,
    address _recipient
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(100, 200)
    givenTheFullTokenBQuoteFitsUint
    givenTheOptimalTokenBDoesNotExceedTheFundedTokenB
  {
    // Reserves 100:200 quote 50 tokenA to 100 tokenB, within the funded 1000 tokenB but below a 101 minimum.
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), 50);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), 1000);

    IMetarouter.AddLiquidityParams memory _params = _addParams(50, 1000, _recipient);
    _params.amountBMin = 101;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InsufficientAmount1
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InsufficientAmountB.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheOptimalTokenBMeetsItsMinimum(
    address _caller,
    address _recipient
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(100, 200)
    givenTheFullTokenBQuoteFitsUint
    givenTheOptimalTokenBDoesNotExceedTheFundedTokenB
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // Reserves 100:200 quote 50 tokenA to 100 tokenB; the funded 900 tokenB leaves 800 to sweep back to the caller.
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [uint256(50), uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [uint256(900), uint256(800)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push the funded token A and the optimal token B
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 50);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 100);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));
    // it should sweep the unspent token B to _caller at closure
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, 800);

    IMetarouter.AddLiquidityParams memory _params = _addParams(50, 900, _recipient);
    // The optimal tokenB of 100 sits exactly on the minimum, so it is accepted.
    _params.amountBMin = 100;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheOptimalTokenBExceedsTheFundedTokenB() {
    // The reserve ratio and funded amounts are hardcoded per test so the optimal tokenB exceeds the funded tokenB.
    _;
  }

  function test_WhenTheOptimalTokenAIsBelowItsMinimum(
    address _caller,
    address _recipient
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(200, 100)
    givenTheFullTokenBQuoteFitsUint
    givenTheOptimalTokenBExceedsTheFundedTokenB
  {
    // Reserves 200:100 quote 1000 tokenA to 500 tokenB (exceeds the funded 50), so tokenA is re-quoted to 100, below a
    // 101 minimum.
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), 1000);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), 50);

    IMetarouter.AddLiquidityParams memory _params = _addParams(1000, 50, _recipient);
    _params.amountAMin = 101;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InsufficientAmount0
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InsufficientAmountA.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheOptimalTokenAMeetsItsMinimum(
    address _caller,
    address _recipient
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(200, 100)
    givenTheFullTokenBQuoteFitsUint
    givenTheOptimalTokenBExceedsTheFundedTokenB
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // Reserves 200:100 re-quote the funded 50 tokenB to 100 tokenA; the funded 900 tokenA leaves 800 to sweep back.
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [uint256(900), uint256(800)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [uint256(50), uint256(0)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push the optimal token A and the funded token B
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 100);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, 50);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));
    // it should sweep the unspent token A to _caller at closure
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, 800);

    IMetarouter.AddLiquidityParams memory _params = _addParams(900, 50, _recipient);
    // The optimal tokenA of 100 sits exactly on the minimum, so it is accepted.
    _params.amountAMin = 100;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheFullTokenBQuoteExceedsUintMax(
    address _caller,
    address _recipient
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenTheFactoryIsApproved
    givenTheFactoryResolvesThePool
    givenThePoolIsSeeded(1, 1 << 128)
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    uint256 _fundedAmount = 1 << 128;
    // Spending all tokenA would quote 2^256 tokenB, but the funded tokenB correctly re-quotes to one tokenA.
    _mockAndExpectTokenBalancesTwice(_TOKEN0, address(_metarouter), [_fundedAmount, _fundedAmount - uint256(1)]);
    _mockAndExpectTokenBalancesTwice(_TOKEN1, address(_metarouter), [_fundedAmount, uint256(0)]);
    // The LP goes straight to an external recipient, so the router never reads its own LP balance to sweep it.
    vm.mockCallRevert(_POOL, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('lp not tracked'));
    // it should push the optimal token A and the funded token B
    _mockAndExpectTokenTransfer(_TOKEN0, _POOL, 1);
    _mockAndExpectTokenTransfer(_TOKEN1, _POOL, _fundedAmount);
    // it should mint to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.mint, (_recipient)), abi.encode(uint256(1)));
    // it should sweep the unspent token A to _caller at closure
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _fundedAmount - 1);

    IMetarouter.AddLiquidityParams memory _params = _addParams(_fundedAmount, _fundedAmount, _recipient);
    _params.amountAMin = 1;
    _params.amountBMin = _fundedAmount;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.ADD_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }
}
