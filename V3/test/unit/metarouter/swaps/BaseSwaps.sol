// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {V2SwapPoolProbe, V2SwapReceiptTokenProbe} from 'V3-test/unit/metarouter/harnesses/V2SwapReceiptProbe.sol';

/// @title BaseSwaps
/// @notice Shared mocked-pool setup and command encoders for focused Metarouter swap tests.
abstract contract BaseSwaps is BaseMetarouter {
  address internal immutable _TOKEN_A = _mockContract('tokenA');
  address internal immutable _TOKEN_B = _mockContract('tokenB');
  address internal immutable _V2_FACTORY = _mockContract('v2Factory');
  address internal immutable _CL_FACTORY = _mockContract('clFactory');
  address internal immutable _POOL = _mockContract('pool');
  address internal immutable _RECIPIENT = makeAddr('recipient');

  function _execute(uint256 _command, bytes memory _input) internal {
    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(_unflagged(_command), _input);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function _exactInput(
    address[] memory _pools,
    address _tokenIn,
    uint256 _amountIn,
    uint256 _minimumOut,
    address _recipient
  ) internal pure returns (bytes memory _input) {
    return _exactInputWithPayer(_pools, _tokenIn, _amountIn, _minimumOut, _recipient, false);
  }

  function _exactInputFromUser(
    address[] memory _pools,
    address _tokenIn,
    uint256 _amountIn,
    uint256 _minimumOut,
    address _recipient
  ) internal pure returns (bytes memory _input) {
    return _exactInputWithPayer(_pools, _tokenIn, _amountIn, _minimumOut, _recipient, true);
  }

  function _exactInputWithPayer(
    address[] memory _pools,
    address _tokenIn,
    uint256 _amountIn,
    uint256 _minimumOut,
    address _recipient,
    bool _payerIsUser
  ) private pure returns (bytes memory _input) {
    IMetarouter.BalanceSpend memory _spend =
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amountIn});
    _input = _exactInputWithSpend(_pools, _tokenIn, _spend, _payerIsUser, _minimumOut, _recipient);
  }

  function _exactInputWithSpend(
    address[] memory _pools,
    address _tokenIn,
    IMetarouter.BalanceSpend memory _spend,
    bool _payerIsUser,
    uint256 _minimumOut,
    address _recipient
  ) internal pure returns (bytes memory _input) {
    _input = abi.encode(
      IMetarouter.SwapExactInParams({
        pools: _pools,
        tokenIn: _tokenIn,
        amountIn: _spend,
        payerIsUser: _payerIsUser,
        minAmountOut: _minimumOut,
        recipient: _recipient
      })
    );
  }

  function _exactOutput(
    address[] memory _pools,
    address _tokenIn,
    uint256 _amountOut,
    uint256 _maximumIn,
    address _recipient
  ) internal pure returns (bytes memory _input) {
    return _exactOutputWithPayer(_pools, _tokenIn, _amountOut, _maximumIn, _recipient, false);
  }

  function _exactOutputFromUser(
    address[] memory _pools,
    address _tokenIn,
    uint256 _amountOut,
    uint256 _maximumIn,
    address _recipient
  ) internal pure returns (bytes memory _input) {
    return _exactOutputWithPayer(_pools, _tokenIn, _amountOut, _maximumIn, _recipient, true);
  }

  function _exactOutputWithPayer(
    address[] memory _pools,
    address _tokenIn,
    uint256 _amountOut,
    uint256 _maximumIn,
    address _recipient,
    bool _payerIsUser
  ) private pure returns (bytes memory _input) {
    _input = abi.encode(
      IMetarouter.SwapExactOutParams({
        pools: _pools,
        tokenIn: _tokenIn,
        amountOut: _amountOut,
        payerIsUser: _payerIsUser,
        maxAmountIn: _maximumIn,
        recipient: _recipient
      })
    );
  }

  function _callbackData(
    address _tokenIn,
    address _payer,
    uint256 _maxAmountIn
  ) internal pure returns (bytes memory _data) {
    _data = _callbackData(new address[](0), new bool[](0), 0, _tokenIn, _payer, _maxAmountIn);
  }

  function _callbackData(
    address[] memory _pools,
    bool[] memory _zeroForOne,
    uint256 _remaining,
    address _tokenIn,
    address _payer,
    uint256 _maxAmountIn
  ) internal pure returns (bytes memory _data) {
    _data = abi.encode(
      IMetarouter.ClSwapCallbackData({
        pools: _pools,
        zeroForOne: _zeroForOne,
        remaining: _remaining,
        tokenIn: _tokenIn,
        payer: _payer,
        maxAmountIn: _maxAmountIn
      })
    );
  }

  function _singlePool(address _pool) internal pure returns (address[] memory _pools) {
    _pools = new address[](1);
    _pools[0] = _pool;
  }

  /**
   * @dev Installs stateful probes that model the recurring output token balance across a three-hop route.
   * @param _intermediatePool Pool that receives both the first and final outputs.
   * @param _finalPool Pool that executes the final swap.
   * @param _recipientBalance Output-token balance held by the intermediate pool before the route.
   * @param _intermediateAmountOut Amount credited to the intermediate pool by the first swap.
   * @param _finalAmountReceived Amount credited to the intermediate pool by the final swap.
   */
  function _installReceiptProbes(
    address _intermediatePool,
    address _finalPool,
    uint256 _recipientBalance,
    uint256 _intermediateAmountOut,
    uint256 _finalAmountReceived
  ) internal {
    V2SwapReceiptTokenProbe _tokenProbe = new V2SwapReceiptTokenProbe();
    vm.etch(_TOKEN_B, address(_tokenProbe).code);
    V2SwapReceiptTokenProbe(_TOKEN_B).setBalance(_intermediatePool, _recipientBalance);

    V2SwapPoolProbe _poolProbe = new V2SwapPoolProbe();
    vm.etch(_POOL, address(_poolProbe).code);
    vm.etch(_intermediatePool, address(_poolProbe).code);
    vm.etch(_finalPool, address(_poolProbe).code);
    V2SwapPoolProbe(_POOL).configure(_TOKEN_B, _intermediateAmountOut);
    V2SwapPoolProbe(_intermediatePool).configure(address(0), 0);
    V2SwapPoolProbe(_finalPool).configure(_TOKEN_B, _finalAmountReceived);
  }
}
