// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {MAX_PIPS, PRECISION} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';

import {ISplitter} from 'V3/interfaces/splitter/ISplitter.sol';

/**
 * @title Splitter
 * @notice Accrues the `Minter`'s team share across a configured recipient list and pays each recipient its slice
 *         when claimed. TOKEN arrives passively, with no callback at mint time, and is split across the active
 *         recipients in proportion to their PIPS shares.
 */
contract Splitter is ISplitter {
  using SafeERC20 for IERC20;

  /// @inheritdoc ISplitter
  uint256 public constant MAX_RECIPIENTS = 50;

  /// @inheritdoc ISplitter
  address public immutable TOKEN;
  /// @inheritdoc ISplitter
  address public immutable VOTER;

  /// @inheritdoc ISplitter
  uint256 public globalAccrualIndex;
  /// @inheritdoc ISplitter
  uint256 public accountedBalance;
  /// @inheritdoc ISplitter
  address[] public recipients;

  /// @inheritdoc ISplitter
  mapping(address _recipient => RecipientState _state) public recipientState;

  /**
   * @notice Validates a proposed list: recipients and shares must share a non-zero length within `MAX_RECIPIENTS`.
   * @param _recipientsLength Number of proposed recipients.
   * @param _sharesLength Number of proposed shares.
   */
  modifier validListLength(uint256 _recipientsLength, uint256 _sharesLength) {
    if (_recipientsLength != _sharesLength) revert LengthMismatch();
    if (_recipientsLength == 0) revert EmptyRecipients();
    if (_recipientsLength > MAX_RECIPIENTS) revert TooManyRecipients();
    _;
  }

  /**
   * @notice Deploys the `Splitter` and seeds the initial recipient list so inflows are accounted for from the
   *         moment the contract exists.
   * @param _token TOKEN the `Minter` mints into the `Splitter` and the only token paid out on claim.
   * @param _voter `Voter` whose `SPLITTER_CONFIG_ROLE` gates privileged calls.
   * @param _initialRecipients Initial recipient addresses, in insertion order.
   * @param _initialShares Initial shares in PIPS, aligned by index with `_initialRecipients` and summing to
   *        `MAX_PIPS`.
   */
  constructor(
    address _token,
    address _voter,
    address[] memory _initialRecipients,
    uint256[] memory _initialShares
  ) validListLength(_initialRecipients.length, _initialShares.length) {
    if (_token == address(0)) revert ZeroAddress();
    if (_voter == address(0)) revert ZeroAddress();

    TOKEN = _token;
    VOTER = _voter;

    _writeRecipients(_initialRecipients, _initialShares);
  }

  /// @inheritdoc ISplitter
  function claim(address _recipient) external returns (uint256 _amount) {
    _accrueGlobal();
    _settle(_recipient);

    _amount = recipientState[_recipient].claimable;
    if (_amount == 0) return _amount;

    // Decrementing `accountedBalance` so the next accrual observes the post-transfer
    // balance and does not re-credit the amount just paid out.
    recipientState[_recipient].claimable = 0;
    accountedBalance -= _amount;
    IERC20(TOKEN).safeTransfer(_recipient, _amount);

    emit Claimed(_recipient, _amount);
  }

  /// @inheritdoc ISplitter
  function setRecipients(
    address[] calldata _newRecipients,
    uint256[] calldata _newShares
  ) external validListLength(_newRecipients.length, _newShares.length) {
    if (!IAccessControl(VOTER).hasRole(Roles.SPLITTER_CONFIG_ROLE, msg.sender)) {
      revert UnauthorizedCaller();
    }

    _accrueGlobal();

    // Settle each old recipient at its old share to lock its accrual into its `claimable`, then clear its share.
    uint256 _currentRecipientsLength = recipients.length;
    for (uint256 _i; _i < _currentRecipientsLength; ++_i) {
      address _recipient = recipients[_i];
      _settle(_recipient);
      recipientState[_recipient].sharePips = 0;
    }
    delete recipients;

    _writeRecipients(_newRecipients, _newShares);

    emit RecipientsSet(_newRecipients, _newShares);
  }

  /// @inheritdoc ISplitter
  function earned(address _recipient) external view returns (uint256 _earned) {
    (uint256 _projectedIndex,) = _projectGlobalAccrual();
    RecipientState storage _state = recipientState[_recipient];
    uint256 _unsettledAccrual = (_state.sharePips * (_projectedIndex - _state.lastSettledIndex)) / PRECISION;
    _earned = _state.claimable + _unsettledAccrual;
  }

  /// @inheritdoc ISplitter
  function allRecipients() external view returns (address[] memory _recipientList) {
    _recipientList = recipients;
  }

  /**
   * @notice Accounts for TOKEN received since the last accrual.
   * @dev Updates `globalAccrualIndex` and marks the new inflow as accounted. Individual recipient balances are
   *      calculated in `_settle`. The whole pending inflow folds into `globalAccrualIndex`
   *      (`PRECISION` is an exact multiple of `MAX_PIPS`), so the accounted
   *      balance advances to the full current balance with no remainder.
   */
  function _accrueGlobal() internal {
    (uint256 _projectedIndex, uint256 _currentBalance) = _projectGlobalAccrual();
    if (_projectedIndex == globalAccrualIndex) return;

    globalAccrualIndex = _projectedIndex;
    accountedBalance = _currentBalance;
  }

  /**
   * @notice Folds a recipient's whole-wei accrual since its last settlement into its `claimable`, advancing its
   *         `lastSettledIndex` to `globalAccrualIndex` only once at least one wei is credited.
   * @dev No-op when the recipient's `lastSettledIndex` already equals `globalAccrualIndex`, or when the accrual
   *      still floors to zero. Leaving `lastSettledIndex` behind in the sub-wei case carries the fraction forward
   *      into later settlements instead of discarding it, so frequent settlement (e.g. anyone calling `claim`)
   *      cannot grind a recipient's entitlement down to dust. A credited settlement still strands less than one
   *      wei. Assumes `_accrueGlobal` ran first.
   * @param _recipient Recipient to settle.
   */
  function _settle(address _recipient) internal {
    RecipientState storage _state = recipientState[_recipient];
    uint256 _delta = globalAccrualIndex - _state.lastSettledIndex;
    if (_delta == 0) return;

    uint256 _accrued = (_state.sharePips * _delta) / PRECISION;
    // A sub-wei accrual leaves `lastSettledIndex` untouched so the fraction keeps accumulating rather than being lost.
    if (_accrued == 0) return;

    _state.claimable += _accrued;
    _state.lastSettledIndex = globalAccrualIndex;
  }

  /**
   * @notice Validates and writes a recipient list, recording each share and seeding its `lastSettledIndex` at the
   *         current `globalAccrualIndex`.
   * @dev Reverts on a zero-address or self recipient, a zero share, a duplicate, or a share sum other than
   *      `MAX_PIPS`. The duplicate check reads `sharePips`, so callers must clear the prior
   *      list's shares first.
   * @param _recipientList Recipient addresses to write, in insertion order.
   * @param _shareList Shares in PIPS, aligned by index with `_recipientList`.
   */
  function _writeRecipients(address[] memory _recipientList, uint256[] memory _shareList) internal {
    uint256 _index = globalAccrualIndex;
    uint256 _length = _recipientList.length;
    uint256 _sum = 0;
    for (uint256 _i; _i < _length; ++_i) {
      address _recipient = _recipientList[_i];
      uint256 _share = _shareList[_i];
      if (_recipient == address(0)) revert InvalidRecipient();
      if (_recipient == address(this)) revert InvalidRecipient();
      if (_share == 0) revert ZeroShare();
      RecipientState storage _state = recipientState[_recipient];
      if (_state.sharePips != 0) revert DuplicateRecipient();

      _state.sharePips = _share;
      _state.lastSettledIndex = _index;
      recipients.push(_recipient);
      _sum += _share;
    }
    if (_sum != MAX_PIPS) revert InvalidShareSum();
  }

  /**
   * @notice Projects the global accrual state to include TOKEN received but not yet accounted.
   * @return _projectedIndex `globalAccrualIndex` plus the scaled increment from the pending inflow.
   * @return _currentBalance Current TOKEN balance held by the `Splitter`.
   */
  function _projectGlobalAccrual() internal view returns (uint256 _projectedIndex, uint256 _currentBalance) {
    _currentBalance = IERC20(TOKEN).balanceOf(address(this));
    uint256 _newRewards = _currentBalance - accountedBalance;
    _projectedIndex = globalAccrualIndex + (_newRewards * PRECISION) / MAX_PIPS;
  }
}
