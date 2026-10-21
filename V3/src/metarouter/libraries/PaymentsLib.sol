// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/**
 * @title PaymentsLib
 * @notice Payment command handlers for the Metarouter.
 * @dev Deployed as a standalone library; the router calls each handler through `DELEGATECALL`, so the code lives
 *      outside the router's bytecode while executing in the router's storage context. Funding, tracking, and
 *      logical-sender resolution go through `FundsLib`; the wrapped native token is passed in because a library
 *      cannot read the router's immutables.
 */
library PaymentsLib {
  using SafeERC20 for IERC20;

  /**
   * @notice Sends the execution address's full token balance available to the batch to a recipient.
   * @dev The execution address is rejected as recipient: sweeping to self is a no-op, and unlike `transfer` this
   *      command does not track the token, so the balance would linger untracked and never reach the caller at closure.
   *      The available balance excludes the pre-batch native for the chain's native ERC20, whose `balanceOf`
   *      is the execution address's native balance.
   * @param _input ABI-encoded token, recipient, and minimum amount.
   */
  function sweep(bytes calldata _input) external {
    (address _token, address _recipient, uint256 _minAmount) = abi.decode(_input, (address, address, uint256));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();
    if (_recipient == address(this)) revert IMetarouter.InvalidRecipient();
    uint256 _balance = MetarouterState.availableErc20Balance(_token);
    if (_balance < _minAmount) revert IMetarouter.InsufficientBalance(_token);
    if (_balance > 0) IERC20(_token).safeTransfer(_recipient, _balance);
  }

  /**
   * @notice Sends a selected portion of an execution-address token balance.
   * @dev Resolves the portion against the router's own balance, then pushes it out via `FundsLib.push`. The token is
   *      tracked so any residual left after a partial send is swept back to the sender at closure.
   * @param _input ABI-encoded token, recipient, and balance spend mode.
   */
  function transfer(bytes calldata _input) external {
    (address _token, address _recipient, IMetarouter.BalanceSpend memory _spend) =
      abi.decode(_input, (address, address, IMetarouter.BalanceSpend));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();
    uint256 _amount = FundsLib.resolveSpend(_token, _spend);
    MetarouterState.trackERC20(_token);
    if (_amount > 0) FundsLib.push(_token, _recipient, _amount);
  }

  /**
   * @notice Sends an NFT held in batch custody to a recipient.
   * @dev Leaves the custody flag set so batch closure verifies the router no longer owns the NFT, and consumes any
   *      matching in-flight reference.
   * @param _input ABI-encoded `(address collection, uint256 tokenId, address recipient)`, where token id zero selects
   *        the in-flight NFT of `collection`.
   */
  function transferNft(bytes calldata _input) external {
    (address _collection, uint256 _tokenId, address _recipient) = abi.decode(_input, (address, uint256, address));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();
    // A self-transfer is a no-op.
    if (_recipient == address(this)) revert IMetarouter.InvalidRecipient();

    _tokenId = MetarouterState.resolvePositionId(_collection, _tokenId);
    if (!MetarouterState.isNftInCustody(_collection, _tokenId)) revert IMetarouter.NftNotInCustody();

    IERC721(_collection).safeTransferFrom(address(this), _recipient, _tokenId);
    MetarouterState.consumeInFlightNft(_collection, _tokenId);
  }

  /**
   * @notice Pulls a selected portion of the logical sender's token balance into the execution address's custody.
   * @dev Resolves the portion against the sender's wallet balance (so `Pips` means a share of the wallet), then pulls
   *      it in via `FundsLib.pull`. Unlike `FundsLib.fund`, which pulls an exact amount and returns the received delta
   *      for a handler to consume, this command measures nothing: the amount surfaces through the closure sweep and
   *      later live-balance reads.
   * @param _input ABI-encoded token and balance spend mode.
   */
  function fundErc20(bytes calldata _input) external {
    (address _token, IMetarouter.BalanceSpend memory _spend) = abi.decode(_input, (address, IMetarouter.BalanceSpend));
    uint256 _amount = FundsLib.resolveBalance(_token, IERC20(_token).balanceOf(MetarouterState.msgSender()), _spend);
    if (_amount > 0) FundsLib.pull(_token, _amount);
  }

  /**
   * @notice Wraps native ETH available to the current batch.
   * @param _input ABI-encoded balance spend mode.
   * @param _weth Wrapped native token to deposit into.
   */
  function wrapEth(bytes calldata _input, IWETH _weth) external {
    IMetarouter.BalanceSpend memory _spend = abi.decode(_input, (IMetarouter.BalanceSpend));
    uint256 _amount = FundsLib.resolveBalance(address(0), MetarouterState.availableNativeBalance(), _spend);
    if (_amount > 0) {
      MetarouterState.trackERC20(address(_weth));
      // Destination is the immutable WETH, not an arbitrary address; the deposit wraps the caller's own native.
      // slither-disable-next-line arbitrary-send-eth
      _weth.deposit{value: _amount}();
    }
  }

  /**
   * @notice Unwraps a selected portion of the WETH balance and sends native ETH to a recipient.
   * @param _input ABI-encoded recipient and balance spend mode.
   * @param _weth Wrapped native token to withdraw from.
   */
  function unwrapWeth(bytes calldata _input, IWETH _weth) external {
    (address _recipient, IMetarouter.BalanceSpend memory _spend) =
      abi.decode(_input, (address, IMetarouter.BalanceSpend));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();
    // No `trackERC20` here: WETH reaches custody only through producers that already track it, so a residual left
    // by a partial unwrap is still swept at closure.
    uint256 _amount = FundsLib.resolveSpend(address(_weth), _spend);
    if (_amount > 0) {
      _weth.withdraw(_amount);
      if (_recipient != address(this)) {
        // Sweeps the caller's own unwrapped balance to the caller-chosen recipient.
        // slither-disable-next-line arbitrary-send-eth
        (bool _success, bytes memory _data) = _recipient.call{value: _amount}('');
        if (!_success) revert IMetarouter.NativeTransferFailed(_data);
      }
    }
  }
}
