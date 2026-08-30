// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';

/// @notice Shared fixture and parameter builders for the V2 liquidity command suites.
abstract contract BaseLiquidity is BaseMetarouter {
  /// @notice Pool factory the registry reports as the pool's deployer.
  address internal immutable _FACTORY = _mockContract('PoolFactory');
  /// @notice Pool target the liquidity commands act on; also its own LP token.
  address internal immutable _POOL = _mockContract('Pool');
  /// @notice Lower-address pool token funded, pushed, and swept by the add and remove tests.
  address internal immutable _TOKEN0 = _mockContract('token0');
  /// @notice Higher-address pool token funded, pushed, and swept by the add and remove tests.
  address internal immutable _TOKEN1 = _mockContract('token1');

  /// @notice Builds add params that fund both sides from the execution balance with an exact amount and no minimums.
  /// @param _amountA Exact tokenA amount to fund.
  /// @param _amountB Exact tokenB amount to fund.
  /// @param _recipient Recipient of the minted LP.
  /// @return _params The assembled add-liquidity params.
  function _addParams(
    uint256 _amountA,
    uint256 _amountB,
    address _recipient
  ) internal view returns (IMetarouter.AddLiquidityParams memory _params) {
    _params.factory = _FACTORY;
    _params.tokenA = _TOKEN0;
    _params.tokenB = _TOKEN1;
    _params.spendA = IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amountA);
    _params.spendB = IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amountB);
    _params.recipient = _recipient;
  }

  /// @notice Builds remove params spending an exact LP amount, internally or pulled from the caller, with no minimums.
  /// @param _liquidity Exact LP amount to burn.
  /// @param _payerIsUser Whether the LP is pulled from the caller instead of the execution balance.
  /// @param _recipient Recipient of the underlying tokens.
  /// @return _params The assembled remove-liquidity params.
  function _removeParams(
    uint256 _liquidity,
    bool _payerIsUser,
    address _recipient
  ) internal view returns (IMetarouter.RemoveLiquidityParams memory _params) {
    _params.pool = _POOL;
    _params.lpSpend = IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _liquidity);
    _params.payerIsUser = _payerIsUser;
    _params.recipient = _recipient;
  }
}
