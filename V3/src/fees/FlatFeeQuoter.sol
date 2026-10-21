// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IExactOutFeeQuoter} from 'V3/interfaces/fees/IExactOutFeeQuoter.sol';

/// @title FlatFeeQuoter
/// @notice Exact output fee quoter for factories whose fee and MEV tax modules do not depend on the input amount
contract FlatFeeQuoter is IExactOutFeeQuoter {
  /// @inheritdoc IExactOutFeeQuoter
  IPoolFactory public immutable FACTORY;

  /// @notice Quoter constructor
  /// @param _factory The pool factory
  constructor(address _factory) {
    FACTORY = IPoolFactory(_factory);
  }

  /// @inheritdoc IExactOutFeeQuoter
  function getFeeForAmountIn(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256 _fee) {
    // slither-disable-next-line unused-return
    (_fee,,) = FACTORY.getFee(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1);
  }
}
