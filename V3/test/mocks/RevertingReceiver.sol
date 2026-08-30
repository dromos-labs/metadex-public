// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @notice Reverts on any ETH receipt, used to force ETH transfer failures. Carrying code but no `onERC721Received`,
 *         it also stands in as an invalid ERC721 receiver.
 */
contract RevertingReceiver {
  receive() external payable {
    revert('no ether');
  }
}
