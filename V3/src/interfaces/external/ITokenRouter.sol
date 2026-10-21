// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ITokenRouter
 * @notice Minimal view of a Hyperlane warp route (`TokenRouter`) used by the Metarouter's bridge command: the
 *         value-transfer and quote surface plus the managed-token accessor.
 * @dev Hyperlane bundles `ITokenFee`/`ITokenBridge` in one file and declares `token()` only on the abstract
 *      `TokenRouter` contract, so the selectors the command needs are mirrored here as one self-contained interface
 *      instead of importing the bundled file.
 */
interface ITokenRouter {
  /**
   * @notice A token amount to approve and/or send for a transfer, as reported by `quoteTransferRemote`.
   * @param token Token to approve or send; the zero address denotes the native token.
   * @param amount Amount of `token` the transfer requires.
   */
  struct Quote {
    address token;
    uint256 amount;
  }

  /**
   * @notice Transfers `_amount` of the managed token to `_recipient` on `_destination`.
   * @param _destination Destination Hyperlane domain.
   * @param _recipient Recipient on the destination domain, as bytes32.
   * @param _amount Amount to transfer.
   * @return _messageId Hyperlane message id of the transfer.
   */
  function transferRemote(
    uint32 _destination,
    bytes32 _recipient,
    uint256 _amount
  ) external payable returns (bytes32 _messageId);

  /**
   * @notice Quotes the tokens to approve and/or send to transfer `_amount` to `_recipient` on `_destination`.
   * @param _destination Destination Hyperlane domain.
   * @param _recipient Recipient on the destination domain, as bytes32.
   * @param _amount Amount to transfer.
   * @return _quotes Tokens and amounts the transfer requires.
   */
  function quoteTransferRemote(
    uint32 _destination,
    bytes32 _recipient,
    uint256 _amount
  ) external view returns (Quote[] memory _quotes);

  /**
   * @notice Returns the token the warp route manages.
   * @dev Per Hyperlane's `TokenRouter`: the collateral ERC20 for a collateral route, `address(this)` for a synthetic
   *      route, or the zero address for a native route.
   * @return _token The managed token address.
   */
  function token() external view returns (address _token);
}
