// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';
import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {ITokenRouter} from 'V3/interfaces/external/ITokenRouter.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title CrosschainLib
 * @notice Cross-chain command handlers for the Metarouter: bridging a held token, dispatching a destination plan, and
 *         redeeming held `ReceiptToken` for `TOKEN` on root.
 */
library CrosschainLib {
  using SafeERC20 for IERC20;

  /// @notice Length of the hook metadata's fixed prefix, per `StandardHookMetadata`: `[0:2]` variant, `[2:34]`
  ///         msgValue, `[34:66]` gasLimit, `[66:86]` refund address. Optional fields follow, so this is both the
  ///         shortest metadata carrying a refund address and the offset of the first optional field.
  uint256 private constant _HOOK_METADATA_PREFIX_LENGTH = 86;

  /**
   * @notice Bridges a selected token or native balance to the logical sender's destination interchain account, or to
   *         a caller-chosen recipient.
   * @dev `token == address(0)` selects native. Any other token selects ERC20. The Warp Route must report the same
   *      token.
   *
   *      The selected amount is the total bridge budget, not the delivered amount. The quoted fee is deducted from
   *      this budget, while `maxFee` limits the deduction. The limit is absolute for `Amount` spends and proportional
   *      to the resolved amount for `Pips` spends.
   *
   *      Native bridges resolve the spend against the batch's available ETH and forward the full budget as
   *      `msg.value`, which covers the delivered amount, fees and gas. `messageFee` is ignored. ERC20 bridges grant
   *      the Warp Route a temporary approval for the budget and forward `messageFee` separately, bounded by the
   *      batch's own native. The chain's native ERC20 resolves its spend against the batch native remaining
   *      after `messageFee`, since the pull and the fee draw from the same balance; a full-pips spend therefore
   *      leaves the fee funded instead of double-committing it. The token is tracked so any amount left in the
   *      Metarouter returns with the batch's other unused funds.
   *
   *      With a zero `recipient`, funds go to the ICA derived from the destination domain, logical sender, router and
   *      ISM. An empty ICA configuration uses the enrolled router and ISM, while a custom configuration uses the
   *      supplied values. This command and every later execution must use the same domain and configuration to reach
   *      the funded account.
   *
   *      A non-zero `recipient` receives the funds directly and skips the interchain account router, so this path also
   *      works on a lite deployment without one. It cannot fund a destination `EXECUTE_CROSS_CHAIN` plan, rejects a
   *      custom ICA configuration, must be able to receive the asset on the destination chain, and must not be the
   *      Metarouter, whose out-of-batch custody is publicly sweepable.
   *
   *      An ICA with balance sentinel support can forward its entire native balance with `type(uint256).max`. To spend
   *      this bridge's output, reveal after the Warp transfer finalizes or begin the destination plan with an unflagged
   *      `BALANCE_CHECK` on the execution address's native balance. Otherwise the call may forward only an older ICA
   *      balance and consume the commitment before the bridged funds arrive.
   * @param _input ABI-encoded `IMetarouter.BridgeTokenParams`.
   * @param _icaRouter Interchain account router used to derive the destination account.
   */
  function bridgeToken(bytes calldata _input, IInterchainAccountRouter _icaRouter) external {
    IMetarouter.BridgeTokenParams memory _params = abi.decode(_input, (IMetarouter.BridgeTokenParams));

    bytes32 _recipient;
    if (_params.recipient != address(0)) {
      // Destination custody outside a batch is publicly sweepable, so the router itself is never a valid target.
      if (_params.recipient == address(this)) revert IMetarouter.InvalidRecipient();
      // A custom ICA configuration only exists to derive the account this path does not use.
      if (_params.icaConfig.router != address(0) || _params.icaConfig.ism != address(0)) {
        revert IMetarouter.InvalidInterchainAccountConfig();
      }

      _recipient = _addressToBytes32(_params.recipient);
    } else {
      // The derivation path needs the interchain account router; a lite deployment has none.
      if (address(_icaRouter) == address(0)) revert IMetarouter.CommandDisabled(Commands.BRIDGE_TOKEN);

      bool _usesCustomConfig = _usesCustomIcaConfig(_params.icaConfig);
      if (!_usesCustomConfig && _icaRouter.routers(_params.domain) == bytes32(0)) {
        revert IMetarouter.UnregisteredDomain();
      }
      bytes32 _userSalt = _addressToBytes32(MetarouterState.msgSender());
      address _recipientAccount = _usesCustomConfig
        ? _icaRouter.getRemoteInterchainAccount(
          address(this), _params.icaConfig.router, _params.icaConfig.ism, _userSalt
        )
        : _icaRouter.getRemoteInterchainAccount(_params.domain, address(this), _userSalt);
      _recipient = _addressToBytes32(_recipientAccount);
    }

    // A native bridge funds the fee from the resolved spend, which is already bounded; an ERC20 bridge pays it on top.
    if (_params.token != address(0)) {
      if (_params.messageFee > MetarouterState.availableNativeBalance()) {
        revert IMetarouter.InsufficientBalance(address(0));
      }
    }

    if (ITokenRouter(_params.bridge).token() != _params.token) revert IMetarouter.BridgeTokenMismatch();

    bool _isNative = _params.token == address(0);
    uint256 _amount;
    if (_isNative) {
      _amount = FundsLib.resolveBalance(address(0), MetarouterState.availableNativeBalance(), _params.spend);
    } else if (_params.token == MetarouterState.nativeErc20()) {
      // A native ERC20 pull and the message fee draw from the same batch native, so the fee is reserved from that
      // native before the spend resolves against its native ERC20 decimals conversion.
      _amount = FundsLib.resolveBalance(
        _params.token, MetarouterState.availableErc20BalanceAfterMessageFee(_params.messageFee), _params.spend
      );
    } else {
      _amount = FundsLib.resolveSpend(_params.token, _params.spend);
    }
    if (_amount == 0) revert IMetarouter.ZeroAmount();
    if (_params.spend.mode == IMetarouter.SpendMode.Pips) {
      if (_params.maxFee > MAX_PIPS) revert IMetarouter.InvalidPips(_params.maxFee);
      // Rounded up so truncation loosens the bound the caller accepted rather than tightening it.
      _params.maxFee = Math.mulDiv(_amount, _params.maxFee, MAX_PIPS, Math.Rounding.Ceil);
    }

    ITokenRouter.Quote[] memory _quotes =
      ITokenRouter(_params.bridge).quoteTransferRemote(_params.domain, _recipient, _amount);
    uint256 _total = 0;
    uint256 _length = _quotes.length;
    for (uint256 _i; _i < _length; ++_i) {
      if (_quotes[_i].token == _params.token) _total += _quotes[_i].amount;
    }
    if (_total < _amount) revert IMetarouter.InvalidBridgeQuote();
    uint256 _fee = _total - _amount;
    if (_fee > _params.maxFee) revert IMetarouter.TokenFeeExceedsMax();
    // Checked before subtracting: an absolute bound does not cap the fee at the amount the way a pip bound does.
    if (_fee >= _amount) revert IMetarouter.TokenFeeExceedsAmount();
    uint256 _bridgeAmount = _amount - _fee;

    if (_isNative) {
      // slither-disable-next-line arbitrary-send-eth,unused-return
      ITokenRouter(_params.bridge).transferRemote{value: _amount}(_params.domain, _recipient, _bridgeAmount);
    } else {
      MetarouterState.trackERC20(_params.token);
      IERC20(_params.token).forceApprove(_params.bridge, _amount);
      // slither-disable-next-line arbitrary-send-eth,unused-return
      ITokenRouter(_params.bridge).transferRemote{value: _params.messageFee}(_params.domain, _recipient, _bridgeAmount);
      IERC20(_params.token).forceApprove(_params.bridge, 0);
    }
  }

  /**
   * @notice Dispatches a destination-plan commitment through the logical sender's interchain account.
   * @dev The reveal service builds the opaque commitment off-chain from the destination plan and a secret.
   *      `BRIDGE_TOKEN` and this command reach the same ICA only when the destination domain, logical sender, router,
   *      and ISM match. An empty ICA configuration uses the enrolled router and ISM, while a custom configuration uses
   *      the supplied values. A zero custom ISM remains part of account derivation and selects Hyperlane's default
   *      verifier during processing.
   *
   *      Hook metadata must include at least the 86-byte standard prefix and refund address field. A nonzero token at
   *      bytes `[86:106]` selects ERC20 fees; an absent or zero field selects native fees. `tokenFee` caps how much the
   *      ICA router can pull. Any amount it does not pull remains in the Metarouter and is returned with the batch's
   *      other unused funds. For the chain's native ERC20 the cap must also fit the batch's native remaining
   *      after `messageFee` commits, since a native ERC20 pull spends that same native; a larger cap reverts with
   *      `InsufficientBalance` so a fee pull can never reach the pre-batch balance.
   *
   *      ERC20 fees require a deployed ICA router implementing Hyperlane v11.3.1's commit-reveal fee token flow and a
   *      compatible hook chain. When paying fees in ERC20, `messageFee` must be zero and every fee-charging hook must
   *      use the metadata token. This library does not validate those conditions, so incompatible combinations revert
   *      downstream. `messageFee` is bounded by the batch's own native so a dispatch cannot transiently spend what
   *      the router held before it.
   * @param _input ABI-encoded `IMetarouter.ExecuteCrosschainParams`.
   * @param _icaRouter Interchain account router that dispatches the commitment.
   */
  function executeCrosschain(bytes calldata _input, IInterchainAccountRouter _icaRouter) external {
    IMetarouter.ExecuteCrosschainParams memory _params = abi.decode(_input, (IMetarouter.ExecuteCrosschainParams));

    if (_params.messageFee > MetarouterState.availableNativeBalance()) {
      revert IMetarouter.InsufficientBalance(address(0));
    }

    bool _usesCustomConfig = _usesCustomIcaConfig(_params.icaConfig);
    bytes32 _router;
    if (_usesCustomConfig) {
      _router = _addressToBytes32(_params.icaConfig.router);
    } else {
      _router = _icaRouter.routers(_params.domain);
      if (_router == bytes32(0)) revert IMetarouter.UnregisteredDomain();
    }
    if (_params.hookMetadata.length < _HOOK_METADATA_PREFIX_LENGTH) revert IMetarouter.InvalidHookMetadata();
    bytes32 _ism = _usesCustomConfig ? _addressToBytes32(_params.icaConfig.ism) : _icaRouter.isms(_params.domain);

    address _token;
    bytes memory _hookMetadata = _params.hookMetadata;
    if (_hookMetadata.length >= _HOOK_METADATA_PREFIX_LENGTH + 20) {
      assembly ('memory-safe') {
        // Skip the length word, seek the field, then drop the 12 trailing bytes the word overshoots into.
        _token := shr(96, mload(add(add(_hookMetadata, 0x20), _HOOK_METADATA_PREFIX_LENGTH)))
      }
    }
    if (_token != address(0)) {
      // A native ERC20 fee pull spends the same native the message fee commits below, so the grant must fit the
      // batch native remaining after that fee, converted to the native ERC20's decimals. Other tokens need no check: a
      // pull beyond the balance reverts inside the token.
      if (
        _token == MetarouterState.nativeErc20()
          && _params.tokenFee > MetarouterState.availableErc20BalanceAfterMessageFee(_params.messageFee)
      ) {
        revert IMetarouter.InsufficientBalance(_token);
      }
      MetarouterState.trackERC20(_token);
      IERC20(_token).forceApprove(address(_icaRouter), _params.tokenFee);
    }

    // slither-disable-next-line arbitrary-send-eth,unused-return
    _icaRouter.callRemoteCommitReveal{value: _params.messageFee}(
      _params.domain,
      _router,
      _ism,
      _params.hookMetadata,
      _params.hook,
      _addressToBytes32(MetarouterState.msgSender()),
      _params.commitment
    );

    if (_token != address(0)) IERC20(_token).forceApprove(address(_icaRouter), 0);
  }

  /**
   * @notice Burns held `ReceiptToken` through the leaf Voter, dispatching the message that mints `TOKEN` to the
   *         recipient on root.
   * @dev The voter burns the receipt from this router, so no approval is needed. `messageFee` is bounded by the
   *      batch's own native so a redeem cannot transiently spend what the router held before it. Nothing on the leaf
   *      quotes or checks the fee beyond that bound, so an underfunded `messageFee` reverts inside the transport. A
   *      zero `refundRecipient` resolves to this router here, since the transport rejects a zero refund address once
   *      it has an overpayment to return.
   * @param _input ABI-encoded `IMetarouter.RedeemParams`.
   * @param _leafVoter Leaf Voter that burns the receipt and dispatches the message.
   * @param _receiptToken `ReceiptToken` the leaf Voter burns, this deployment's emission token.
   */
  function redeem(bytes calldata _input, ILeafVoter _leafVoter, IERC20 _receiptToken) external {
    IMetarouter.RedeemParams memory _params = abi.decode(_input, (IMetarouter.RedeemParams));

    if (_params.recipient == address(this)) revert IMetarouter.InvalidRecipient();
    if (_params.messageFee > MetarouterState.availableNativeBalance()) {
      revert IMetarouter.InsufficientBalance(address(0));
    }

    uint256 _amount = FundsLib.fund(address(_receiptToken), _params.spend, _params.payerIsUser);

    address _refundRecipient = _params.refundRecipient == address(0) ? address(this) : _params.refundRecipient;

    // The voter rejects a zero recipient and an amount below `MIN_REDEEM_AMOUNT`, which covers a zero amount too.
    // slither-disable-next-line arbitrary-send-eth
    _leafVoter.redeem{value: _params.messageFee}(_amount, _params.recipient, _params.gasLimit, _refundRecipient);
  }

  /**
   * @notice Returns whether a command supplies a custom destination ICA configuration.
   * @dev The all-zero configuration is the default sentinel. Once a custom router is supplied, the ISM may remain
   *      zero intentionally; an ISM without a router is rejected so zero-router inputs cannot be interpreted two ways.
   * @param _icaConfig Optional custom destination ICA router and ISM.
   * @return _usesCustom Whether the command supplied a custom destination router.
   */
  function _usesCustomIcaConfig(IMetarouter.IcaConfig memory _icaConfig) private pure returns (bool _usesCustom) {
    if (_icaConfig.router != address(0)) return true;
    if (_icaConfig.ism != address(0)) revert IMetarouter.InvalidInterchainAccountConfig();
    return false;
  }

  /**
   * @notice Left-pads an address into a bytes32 word.
   * @param _account Address to convert.
   * @return _word The address in the low 20 bytes of a bytes32.
   */
  function _addressToBytes32(address _account) private pure returns (bytes32 _word) {
    return bytes32(uint256(uint160(_account)));
  }
}
