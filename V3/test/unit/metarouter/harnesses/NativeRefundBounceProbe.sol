// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/// @title NativeRefundBounceProbe
/// @notice Batch caller that returns a closure refund to the Metarouter while the batch remains active.
contract NativeRefundBounceProbe {
  /// @notice Router whose closure refund the probe returns.
  IMetarouter internal immutable _ROUTER;

  /// @notice Wires the router the probe calls and refunds.
  /// @param _router Router under test.
  constructor(IMetarouter _router) {
    _ROUTER = _router;
  }

  /// @notice Returns the full closure refund to the router before the refund callback completes.
  receive() external payable {
    (bool _success,) = address(_ROUTER).call{value: msg.value}('');
    require(_success, 'router rejected refund');
  }

  /// @notice Opens a batch as its logical sender and captures whether execution completes or reverts.
  /// @param _value Native ETH introduced into the batch.
  /// @return _success Whether the batch completed.
  /// @return _returnData Return or revert data from the router.
  function execute(uint256 _value) external returns (bool _success, bytes memory _returnData) {
    bytes[] memory _inputs = new bytes[](0);
    (_success, _returnData) = address(_ROUTER).call{value: _value}(
      abi.encodeCall(IMetarouter.execute, (bytes(''), _inputs, type(uint256).max))
    );
  }
}
