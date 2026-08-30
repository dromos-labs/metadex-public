// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

contract MockLeafVoter {
  TestERC20 public immutable RECEIPT_TOKEN;

  constructor(TestERC20 _receiptToken) {
    RECEIPT_TOKEN = _receiptToken;
  }

  function mintEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external {
    for (uint256 _i; _i < _recipients.length; _i++) {
      RECEIPT_TOKEN.mint(_recipients[_i], _amounts[_i]);
    }
  }
}
