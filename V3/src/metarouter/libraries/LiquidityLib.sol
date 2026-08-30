// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

/**
 * @title LiquidityLib
 * @notice V2 liquidity command handlers for the Metarouter.
 * @dev Deployed as a standalone library; the router calls each handler through `DELEGATECALL`, so the code lives
 *      outside the router's bytecode while executing in the router's storage context. Funding, tracking, and
 *      logical-sender resolution go through `FundsLib` / `MetarouterState`; the `FactoryRegistry` is passed in because
 *      a library cannot read the router's immutables.
 *
 *      `addLiquidity` takes an approved factory and the token pair, resolving or creating the pool through the
 *      factory itself; `removeLiquidity` takes the pool by address and validates it through the `FactoryRegistry`,
 *      the single path shared by legacy and V3 V2 pools. Volatile and stable variants differ only by deploying
 *      factory, so no stability flag is read: the proportional reserve quote and the per-token minimums are
 *      variant-agnostic. The pools are push-first, so tokens are transferred in before `mint`/`burn` is called.
 */
library LiquidityLib {
  /**
   * @notice Adds liquidity to the pair's pool of an approved factory and mints LP tokens to the recipient.
   * @dev Resolves the pool through the approved factory, creating it when the pair has none and the caller opted in,
   *      and rejects a resolved pool that does not hold the requested pair. Every `A`/`B` input refers to the token
   *      the caller supplied under that letter, so a pair given in the pool's reverse order only realigns the
   *      reserves. Amounts are adjusted to the pool's current reserve ratio; unused tokens are returned at the end of
   *      the batch. The pool's mint result must meet the caller's LP minimum. LP tokens minted to the Metarouter can
   *      be used by a later command or returned at batch end.
   * @param _input ABI-encoded `AddLiquidityParams`.
   * @param _factoryRegistry Factory registry that validates the selected factory (the router's immutable).
   */
  function addLiquidity(bytes calldata _input, IFactoryRegistry _factoryRegistry) external {
    IMetarouter.AddLiquidityParams memory _params = abi.decode(_input, (IMetarouter.AddLiquidityParams));
    if (_params.recipient == address(0)) revert IMetarouter.InvalidRecipient();

    if (!_factoryRegistry.isTargetFactoryApproved(_params.factory)) {
      revert IMetarouter.FactoryNotApproved();
    }

    address _pool = IPoolFactory(_params.factory).getPool(_params.tokenA, _params.tokenB);
    if (_pool == address(0)) {
      // Revert unless the caller explicitly allows creating and seeding a new pool.
      if (!_params.createPool) revert IMetarouter.PoolNotFound();
      _pool = IPoolFactory(_params.factory).createPool(_params.tokenA, _params.tokenB);
    }

    // slither-disable-next-line unused-return
    (,, uint256 _reserveA, uint256 _reserveB, address _poolToken0, address _poolToken1) = IPool(_pool).metadata();
    if (_params.tokenA != _poolToken0 || _params.tokenB != _poolToken1) {
      if (_params.tokenA != _poolToken1 || _params.tokenB != _poolToken0) {
        revert IMetarouter.PoolTokenMismatch(_pool);
      }
      // The pair arrived in reverse pool order; realign the reserves so the quotes follow the caller's order.
      (_reserveA, _reserveB) = (_reserveB, _reserveA);
    }

    uint256 _amountA = FundsLib.fund(_params.tokenA, _params.spendA, _params.payerAIsUser);
    uint256 _amountB = FundsLib.fund(_params.tokenB, _params.spendB, _params.payerBIsUser);

    // A seeded pool trims one side to the live ratio; the smaller quote wins so neither side
    // exceeds what was funded.
    if (_reserveA != 0 && _reserveB != 0) {
      // Preserve the established floored forward quote whenever its quotient fits uint256. `mulDiv` can represent
      // that quotient iff the product's high word is below the denominator. Otherwise quoting first would revert even
      // though the imbalanced pool can accept a valid tokenB-limited deposit, so calculate only the reverse quote.
      // The low word is intentionally unused: the quotient's representability depends only on the high word.
      // slither-disable-next-line unused-return
      (uint256 _amountBQuoteHigh,) = Math.mul512(_amountA, _reserveB);
      if (_amountBQuoteHigh < _reserveA) {
        uint256 _amountBOptimal = Math.mulDiv(_amountA, _reserveB, _reserveA);
        if (_amountBOptimal <= _amountB) _amountB = _amountBOptimal;
        else _amountA = Math.mulDiv(_amountB, _reserveA, _reserveB);
      } else {
        _amountA = Math.mulDiv(_amountB, _reserveA, _reserveB);
      }
    }

    // The minimums bound the amount the router commits to the pool.
    if (_amountA < _params.amountAMin) revert IMetarouter.InsufficientAmountA();
    if (_amountB < _params.amountBMin) revert IMetarouter.InsufficientAmountB();

    FundsLib.push(_params.tokenA, _pool, _amountA);
    FundsLib.push(_params.tokenB, _pool, _amountB);

    if (_params.recipient == address(this)) MetarouterState.trackERC20(_pool);
    uint256 _liquidity = IPool(_pool).mint(_params.recipient);
    if (_liquidity < _params.liquidityMin) {
      revert IMetarouter.InsufficientLiquidityMinted(_params.liquidityMin, _liquidity);
    }
  }

  /**
   * @notice Burns LP tokens of a validated V2 pool and sends the underlying tokens to the recipient.
   * @dev A router recipient tracks both pool tokens so a later command can consume them and closure sweeps leftovers.
   * @param _input ABI-encoded `RemoveLiquidityParams`.
   * @param _factoryRegistry Factory registry that validates the pool target (the router's immutable).
   */
  function removeLiquidity(bytes calldata _input, IFactoryRegistry _factoryRegistry) external {
    IMetarouter.RemoveLiquidityParams memory _params = abi.decode(_input, (IMetarouter.RemoveLiquidityParams));
    if (_params.recipient == address(0)) revert IMetarouter.InvalidRecipient();

    if (!_factoryRegistry.isTargetFactoryApproved(_factoryRegistry.targetToFactory(_params.pool))) {
      revert IMetarouter.PoolNotRegistered();
    }

    uint256 _liquidity = FundsLib.fund(_params.pool, _params.lpSpend, _params.payerIsUser);

    if (_params.recipient == address(this)) {
      (address _token0, address _token1) = IPool(_params.pool).tokens();
      MetarouterState.trackERC20(_token0);
      MetarouterState.trackERC20(_token1);
    }

    FundsLib.push(_params.pool, _params.pool, _liquidity);
    (uint256 _amount0, uint256 _amount1) = IPool(_params.pool).burn(_params.recipient);

    if (_amount0 < _params.amount0Min) revert IMetarouter.InsufficientAmount0();
    if (_amount1 < _params.amount1Min) revert IMetarouter.InsufficientAmount1();
  }
}
