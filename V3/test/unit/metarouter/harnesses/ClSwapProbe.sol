// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ICLPool} from 'V3/interfaces/pools/ICLPool.sol';

contract ClSwapProbe is ICLPool {
  bytes32 public constant override POOL_TYPE = 'CL';

  address private immutable _FACTORY;
  address private immutable _TOKEN0;
  address private immutable _TOKEN1;

  bool public callbackEnabled;
  bool public positiveReturnedOutput;
  uint256 public callbackAmountIn;
  uint256 public returnedAmountOut;
  uint256 public swapCalls;
  address public lastRecipient;
  bool public lastZeroForOne;
  int256 public lastAmountSpecified;
  uint160 public lastSqrtPriceLimitX96;

  constructor(address _factory, address _token0, address _token1) {
    _FACTORY = _factory;
    _TOKEN0 = _token0;
    _TOKEN1 = _token1;
  }

  function configure(bool _callbackEnabled, uint256 _callbackAmountIn, uint256 _returnedAmountOut) external {
    callbackEnabled = _callbackEnabled;
    callbackAmountIn = _callbackAmountIn;
    returnedAmountOut = _returnedAmountOut;
  }

  function setPositiveReturnedOutput(bool _positiveReturnedOutput) external {
    positiveReturnedOutput = _positiveReturnedOutput;
  }

  function factory() external view override returns (address _factory) {
    return _FACTORY;
  }

  function token0() external view override returns (address _token0) {
    return _TOKEN0;
  }

  function token1() external view override returns (address _token1) {
    return _TOKEN1;
  }

  function swap(
    address _recipient,
    bool _zeroForOne,
    int256 _amountSpecified,
    uint160 _sqrtPriceLimitX96,
    bytes calldata _data
  ) external returns (int256 _amount0, int256 _amount1) {
    ++swapCalls;
    lastRecipient = _recipient;
    lastZeroForOne = _zeroForOne;
    lastAmountSpecified = _amountSpecified;
    lastSqrtPriceLimitX96 = _sqrtPriceLimitX96;

    if (_zeroForOne) {
      (_amount0, _amount1) = (int256(callbackAmountIn), -int256(returnedAmountOut));
    } else {
      (_amount0, _amount1) = (-int256(returnedAmountOut), int256(callbackAmountIn));
    }

    if (callbackEnabled) IMetarouter(msg.sender).uniswapV3SwapCallback(_amount0, _amount1, _data);

    if (positiveReturnedOutput) {
      if (_zeroForOne) _amount1 = int256(returnedAmountOut);
      else _amount0 = int256(returnedAmountOut);
    }
  }
}
