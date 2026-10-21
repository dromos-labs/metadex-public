// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/**
 * @title FundsLib
 * @notice Shared token funding and balance-resolution helpers for the Metarouter command libraries.
 * @dev All functions are internal, so they inline into the command library (or the router) that uses them and
 *      operate on the router's own storage/transient context. Logical-sender resolution and custody tracking are
 *      delegated to `MetarouterState`.
 */
library FundsLib {
  using SafeERC20 for IERC20;

  /**
   * @notice Pushes tokens the execution address holds to a recipient.
   * @dev Moves the router's own balance out, so custody never grows and nothing is tracked. For the native ERC20
   *      token, the amount is bounded by the balance available to the batch so pre-batch native cannot be spent
   *      through its ERC20 entry point.
   * @param _token ERC20 to transfer.
   * @param _recipient Address receiving the tokens.
   * @param _amount Token amount to transfer.
   */
  function push(address _token, address _recipient, uint256 _amount) internal {
    if (_token == MetarouterState.nativeErc20() && _amount > MetarouterState.availableErc20Balance(_token)) {
      revert IMetarouter.InsufficientBalance(_token);
    }
    IERC20(_token).safeTransfer(_recipient, _amount);
  }

  /**
   * @notice Pulls tokens from the logical sender into the execution address.
   * @dev The source is always `msgSender()` and the destination is always the execution address, so no addresses are
   *      passed and no authorization check is needed. The token lands in custody, so it is tracked for the closure
   *      sweep.
   * @param _token ERC20 to transfer.
   * @param _amount Token amount to transfer.
   */
  function pull(address _token, uint256 _amount) internal {
    MetarouterState.trackERC20(_token);
    // slither-disable-next-line arbitrary-send-erc20
    IERC20(_token).safeTransferFrom(MetarouterState.msgSender(), address(this), _amount);
  }

  /**
   * @notice Pays a recipient from the execution address or the logical sender.
   * @dev Execution-address payments use the custody-protected `push` boundary. Logical-sender payments transfer
   *      directly from the authorized sender and do not spend router custody.
   * @param _token ERC20 to transfer.
   * @param _payer Authorized payer: the execution address or the logical sender.
   * @param _recipient Address receiving the payment.
   * @param _amount Token amount to transfer.
   */
  function pay(address _token, address _payer, address _recipient, uint256 _amount) internal {
    if (_payer == address(this)) {
      push(_token, _recipient, _amount);
      return;
    }
    // The zero check keeps an unset logical sender from ever authorizing a pull.
    if (_payer == address(0) || _payer != MetarouterState.msgSender()) revert IMetarouter.InvalidPayer();
    // slither-disable-next-line arbitrary-send-erc20
    IERC20(_token).safeTransferFrom(_payer, _recipient, _amount);
  }

  /**
   * @notice Resolves held funds or pulls an exact amount from the logical sender.
   * @dev External funding returns the received balance delta so fee-on-transfer inputs remain usable, and accepts
   *      `Amount` only. An external pull is bounded by the caller's ERC20 approval, so an exact amount is the
   *      meaningful unit; a percentage of a wallet has no clean meaning here. `Pips` applies only to the
   *      execution-address balance (the internal path); wallet-percentage funding, if ever needed, is `FUND_ERC20`.
   * @param _token ERC20 being funded.
   * @param _spend Selection applied when spending the execution address's balance.
   * @param _payerIsUser Whether to pull an exact amount from the logical sender instead of the execution balance.
   * @return _amount Amount available to the command after funding.
   */
  function fund(
    address _token,
    IMetarouter.BalanceSpend memory _spend,
    bool _payerIsUser
  ) internal returns (uint256 _amount) {
    if (_payerIsUser) {
      if (_spend.mode != IMetarouter.SpendMode.Amount) revert IMetarouter.InvalidSpendMode();
      uint256 _balanceBefore = IERC20(_token).balanceOf(address(this));
      pull(_token, _spend.value);
      _amount = IERC20(_token).balanceOf(address(this)) - _balanceBefore;
    } else {
      _amount = resolveSpend(_token, _spend);
      MetarouterState.trackERC20(_token);
    }
  }

  /**
   * @notice Resolves a spend against the execution address's token balance available to the batch.
   * @dev The available balance excludes the pre-batch native for the chain's native ERC20, whose `balanceOf`
   *      is the execution address's native balance; every other token resolves against its full balance.
   * @param _token ERC20 whose balance is being resolved.
   * @param _spend Balance selection mode and value.
   * @return _amount Token amount selected by the spend mode.
   */
  function resolveSpend(
    address _token,
    IMetarouter.BalanceSpend memory _spend
  ) internal view returns (uint256 _amount) {
    return resolveBalance(_token, MetarouterState.availableErc20Balance(_token), _spend);
  }

  /**
   * @notice Resolves a spend against a supplied asset balance.
   * @param _asset ERC20 address, or address(0) for native ETH.
   * @param _balance Current balance available to spend.
   * @param _spend Balance selection mode and value.
   * @return _amount Asset amount selected by the spend mode.
   */
  function resolveBalance(
    address _asset,
    uint256 _balance,
    IMetarouter.BalanceSpend memory _spend
  ) internal pure returns (uint256 _amount) {
    if (_spend.mode == IMetarouter.SpendMode.Amount) {
      if (_spend.value > _balance) {
        revert IMetarouter.InsufficientBalance(_asset);
      }
      return _spend.value;
    }
    // The only remaining variant is SpendMode.Pips; an out-of-range mode Panics when `_spend.mode` is read above.
    if (_spend.value > MAX_PIPS) revert IMetarouter.InvalidPips(_spend.value);
    return Math.mulDiv(_balance, _spend.value, MAX_PIPS);
  }
}
