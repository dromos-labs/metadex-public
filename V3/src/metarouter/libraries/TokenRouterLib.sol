// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {ICrossCollateralTokenRouter} from 'V3/interfaces/external/ICrossCollateralTokenRouter.sol';
import {ITokenRouter} from 'V3/interfaces/external/ITokenRouter.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/**
 * @title TokenRouterLib
 * @notice Stateless adapter for default and explicitly targeted Hyperlane token routers.
 * @dev These internal functions use the calling contract's balances and allowances. Bridge calls originate from
 *      that contract. The caller checks available funds, chooses the recipient and fee limits, and refunds unused
 *      funds. This library does not derive an ICA or read Metarouter state.
 */
library TokenRouterLib {
  using SafeERC20 for IERC20;

  /**
   * @notice A resolved asset route and its final beneficiary.
   * @param sourceToken Source ERC20, or zero for native collateral through the default API.
   * @param sourceRouter Source token router holding or burning the asset.
   * @param destination Destination Hyperlane domain, independent of the EVM chain id.
   * @param recipient Final beneficiary encoded into the token message.
   * @param targetRouter Explicit destination token router, or zero to use the source router's enrolled route for
   *        the destination domain.
   */
  struct Route {
    address sourceToken;
    address sourceRouter;
    uint32 destination;
    bytes32 recipient;
    bytes32 targetRouter;
  }

  /**
   * @notice Sends a validated transfer with a bounded temporary ERC20 approval and clears that approval afterward.
   * @dev The caller validates the route and checks that principal plus token fees and the native value fit its
   *      available balances. If the ERC20 spends the same balance as native currency, their combined spend must
   *      fit that balance. ERC20 approval equals principal plus the authorized token fee; the bridge calculates
   *      its actual fee during transfer. Native routes grant no approval and ignore `_tokenFee`. A failed transfer
   *      propagates its revert and rolls back approval changes.
   * @param _route Validated asset route and resolved beneficiary.
   * @param _tokenAmount Source-token principal passed to the selected transfer API before destination scaling.
   * @param _tokenFee Fees authorized in the source ERC20 in addition to principal; unused for native collateral.
   * @param _nativeValue Native currency forwarded: the route's quote for the principal for native token routes, or
   *        the message fee for ERC20 routes.
   * @return _messageId Hyperlane message identifier returned by the selected token router.
   */
  function transferRemote(
    Route memory _route,
    uint256 _tokenAmount,
    uint256 _tokenFee,
    uint256 _nativeValue
  ) internal returns (bytes32 _messageId) {
    if (_route.sourceToken != address(0)) {
      IERC20(_route.sourceToken).forceApprove(_route.sourceRouter, _tokenAmount + _tokenFee);
    }
    _messageId = _dispatch(_route, _tokenAmount, _nativeValue);
    if (_route.sourceToken != address(0)) IERC20(_route.sourceToken).forceApprove(_route.sourceRouter, 0);
  }

  /**
   * @notice Rejects explicit targets for the zero-address native token or the source router's own domain.
   * @dev Default routes skip these checks and never read `localDomain`. The source CCR enforces target enrollment
   *      during transfer. The target is the destination token router, not the beneficiary or ICA router.
   * @param _route Asset route whose explicit mode is being validated.
   */
  function validateTargetRouter(Route memory _route) internal view {
    // The default route for the destination domain needs no explicit-target validation.
    if (_route.targetRouter == bytes32(0)) return;
    if (_route.sourceToken == address(0)) revert IMetarouter.UnsupportedCrossCollateralToken();
    if (ICrossCollateralTokenRouter(_route.sourceRouter).localDomain() == _route.destination) {
      revert IMetarouter.SameDomainCrossCollateralTransfer();
    }
  }

  /**
   * @notice Requires the source router to report the asset the caller intends to transfer.
   * @dev This compatibility check does not authenticate a caller-selected router or certify its delivery behavior.
   * @param _route Asset route whose source-token identity is being validated.
   */
  function validateInputTokenMatches(Route memory _route) internal view {
    if (ITokenRouter(_route.sourceRouter).token() != _route.sourceToken) revert IMetarouter.BridgeTokenMismatch();
  }

  /**
   * @notice Quotes the selected route and returns the source-token amount it requires.
   * @dev Sums every entry in `sourceToken` and rejects nonzero entries in other ERC20 tokens. On ERC20 routes, native
   *      entries are skipped: the quote prices the budget while dispatch sends the smaller principal, so the native
   *      value forwarded with the transfer is checked by the bridge instead.
   * @param _route Asset route and final beneficiary used for both quoting and dispatch.
   * @param _amount Source-token transfer amount being quoted.
   * @return _total Total source-token amount required by the quote, including the transfer amount and token fees.
   */
  function quote(Route memory _route, uint256 _amount) internal view returns (uint256 _total) {
    ITokenRouter.Quote[] memory _quotes = _route.targetRouter == bytes32(0)
      ? ITokenRouter(_route.sourceRouter).quoteTransferRemote(_route.destination, _route.recipient, _amount)
      : ICrossCollateralTokenRouter(_route.sourceRouter)
        .quoteTransferRemoteTo(_route.destination, _route.recipient, _amount, _route.targetRouter);

    uint256 _length = _quotes.length;
    for (uint256 _i; _i < _length; ++_i) {
      ITokenRouter.Quote memory _quote = _quotes[_i];
      if (_quote.token == _route.sourceToken) {
        _total += _quote.amount;
      } else if (_quote.token != address(0)) {
        if (_quote.amount != 0) revert IMetarouter.UnsupportedBridgeFeeToken(_quote.token);
      }
    }
    if (_total < _amount) revert IMetarouter.InvalidBridgeQuote();
  }

  /**
   * @notice Calls exactly the API selected for the route, without substituting a default route on failure.
   * @param _route Asset route and resolved beneficiary.
   * @param _tokenAmount Source-token amount passed to the router.
   * @param _nativeValue Caller-authorized native value forwarded with the transfer.
   * @return _messageId Identifier returned by the selected transfer API.
   */
  function _dispatch(
    Route memory _route,
    uint256 _tokenAmount,
    uint256 _nativeValue
  ) private returns (bytes32 _messageId) {
    if (_route.targetRouter == bytes32(0)) {
      // slither-disable-next-line arbitrary-send-eth
      return ITokenRouter(_route.sourceRouter).transferRemote{value: _nativeValue}(
        _route.destination, _route.recipient, _tokenAmount
      );
    }

    // slither-disable-next-line arbitrary-send-eth
    return ICrossCollateralTokenRouter(_route.sourceRouter).transferRemoteTo{value: _nativeValue}(
      _route.destination, _route.recipient, _tokenAmount, _route.targetRouter
    );
  }
}
