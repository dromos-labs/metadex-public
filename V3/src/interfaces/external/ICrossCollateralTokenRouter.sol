// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ITokenRouter} from 'V3/interfaces/external/ITokenRouter.sol';

/**
 * @title ICrossCollateralTokenRouter
 * @notice Hyperlane ERC20 collateral route supporting an explicitly selected destination token router.
 * @dev Mirrors `CrossCollateralRouter` from `@hyperlane-xyz/core@11.3.1` (hyperlane-monorepo commit
 *      `49bdf9c6bd978a56aa308f07170a6e160fdf7469`) without importing it; the pinned 10.1.3 dependency predates it.
 *      The asset router is independent of the final beneficiary and the destination interchain account router.
 */
interface ICrossCollateralTokenRouter is ITokenRouter {
  /**
   * @notice Transfers collateral to a beneficiary through the selected enrolled destination token router.
   * @param _destination Destination Hyperlane domain.
   * @param _recipient Final beneficiary on the destination domain.
   * @param _amount Amount in source collateral token units.
   * @param _targetRouter Destination token router receiving the transfer message.
   * @return _messageId Identifier of the dispatched Hyperlane message.
   */
  function transferRemoteTo(
    uint32 _destination,
    bytes32 _recipient,
    uint256 _amount,
    bytes32 _targetRouter
  ) external payable returns (bytes32 _messageId);

  /**
   * @notice Quotes the collateral and messaging payments for the same explicitly selected route as the transfer.
   * @param _destination Destination Hyperlane domain.
   * @param _recipient Final beneficiary on the destination domain.
   * @param _amount Amount in source collateral token units.
   * @param _targetRouter Destination token router receiving the transfer message.
   * @return _quotes Required payments, which may contain multiple entries in the same denomination.
   */
  function quoteTransferRemoteTo(
    uint32 _destination,
    bytes32 _recipient,
    uint256 _amount,
    bytes32 _targetRouter
  ) external view returns (Quote[] memory _quotes);

  /**
   * @notice Returns the origin Hyperlane domain used to distinguish remote from synchronous local transfers.
   * @return _domain Origin Hyperlane domain.
   */
  function localDomain() external view returns (uint32 _domain);
}
