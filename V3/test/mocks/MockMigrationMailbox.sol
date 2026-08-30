// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';

contract MockMigrationMailbox {
  uint256 internal immutable _MESSAGE_FEE;

  constructor(uint256 _fee) {
    _MESSAGE_FEE = _fee;
  }

  /// @dev Returns the mocked local Hyperlane domain
  function localDomain() external pure returns (uint32) {
    return 10;
  }

  /// @dev Returns the mocked Hyperlane dispatch fee
  function quoteDispatch(uint32, bytes32, bytes calldata, bytes calldata) external view returns (uint256) {
    return _MESSAGE_FEE;
  }

  function dispatch(uint32, bytes32, bytes calldata, bytes calldata _metadata) external payable returns (bytes32) {
    uint256 _surplus = msg.value - _MESSAGE_FEE;
    if (_surplus > 0) {
      address _refundRecipient = StandardHookMetadata.refundAddress(_metadata, msg.sender);
      (bool _success, bytes memory _returnData) = payable(_refundRecipient).call{value: _surplus}('');
      if (!_success) {
        assembly ('memory-safe') {
          revert(add(_returnData, 0x20), mload(_returnData))
        }
      }
    }

    return bytes32(0);
  }
}
