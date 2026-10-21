// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {ICustomFeeModule, IFeeModule} from 'V3/interfaces/fees/ICustomFeeModule.sol';

/// @title Aerodrome Superchain Custom Fee Module
/// @notice Used to set custom fees on Aerodrome Pools
contract CustomFeeModule is ICustomFeeModule {
  /// @inheritdoc IFeeModule
  IPoolFactory public immutable factory;
  /// @inheritdoc ICustomFeeModule
  uint256 public constant MAX_FEE = 300; // 3%
  /// @inheritdoc ICustomFeeModule
  uint256 public constant ZERO_FEE_INDICATOR = 420;
  /// @inheritdoc ICustomFeeModule
  mapping(address => uint24) public customFee; // override for custom fees

  constructor(address _factory) {
    factory = IPoolFactory(_factory);
  }

  /// @inheritdoc ICustomFeeModule
  function setCustomFee(address _pool, uint24 _fee) external {
    if (msg.sender != factory.feeManager()) revert NotFeeManager();
    if (_fee > MAX_FEE && _fee != ZERO_FEE_INDICATOR) revert FeeTooHigh();
    if (!factory.isPool(_pool)) revert InvalidPool();

    customFee[_pool] = _fee;
    emit SetCustomFee({pool: _pool, fee: _fee});
  }

  /// @inheritdoc IFeeModule
  function getFee(address _pool, address, uint256, uint256, uint256, uint256) external view returns (uint24) {
    uint24 _customFee = customFee[_pool];
    if (_customFee == ZERO_FEE_INDICATOR) return 0;
    if (_customFee != 0) return _customFee;
    revert NoCustomFee();
  }
}
