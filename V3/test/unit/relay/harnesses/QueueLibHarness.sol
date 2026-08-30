// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';
import {QueueLib} from 'V3/relay/libraries/QueueLib.sol';

/**
 * @title QueueLibHarness
 * @notice Test harness replicating the storage shapes QueueLib takes by reference, with plain setters
 *         to preset queue state. It also serves the slice of the Relay surface `requireUncoveredHead`
 *         reads back through self-calls (`relayConfig`, `totalBacking`, `principalToken`).
 * @dev The library is delegatecalled from here, so its events emit as this harness, its writes land
 *      in these mappings and its self-calls land on this harness.
 */
contract QueueLibHarness {
  using DenseQueue for DenseQueue.Queue;

  /// @notice Bookkeeping of the withdraw FIFO under test.
  DenseQueue.Queue public withdrawQueue;

  /// @notice Deposit-queue bookkeeping, mirroring RelayBase's storage shape.
  DenseQueue.Queue public depositList;

  /// @notice Deposit-queue entries by id, mirroring RelayBase's mapping shape.
  mapping(uint256 id => IRelay.PendingDeposit deposit) public pendingDeposits;

  /// @notice Registered exits by id, mirroring RelayBase's mapping shape.
  mapping(uint256 id => IRelay.WithdrawEntry entry) public withdrawals;

  /// @notice Per-holder escrowed shares, mirroring RelayBase's mapping shape.
  mapping(address holder => uint256 shares) public escrowedShares;

  /// @notice The backing counter the closing gate prices the head exit against.
  uint256 public totalBacking;

  /// @notice The principal token whose supply prices the head exit.
  IRelayToken public principalToken;

  /// @notice The config block the closing gate reads the evacuation window from.
  IRelay.RelayConfig internal _relayConfig;

  /// @notice The Relay's configuration block, mirroring RelayBase's getter.
  /// @return _config The full configuration struct.
  function relayConfig() external view returns (IRelay.RelayConfig memory _config) {
    _config = _relayConfig;
  }

  /// @notice Preset the backing counter.
  function setTotalBacking(uint256 _totalBacking) external {
    totalBacking = _totalBacking;
  }

  /// @notice Preset the principal token address.
  function setPrincipalToken(IRelayToken _principalToken) external {
    principalToken = _principalToken;
  }

  /// @notice Preset the evacuation window on the config block.
  function setEvacuationWindow(uint48 _evacuationWindow) external {
    _relayConfig.evacuationWindow = _evacuationWindow;
  }

  /// @notice Preset the withdraw-queue bookkeeping to an arbitrary shape.
  function setWithdrawQueue(DenseQueue.Queue calldata _queue) external {
    withdrawQueue = _queue;
  }

  /// @notice Preset the deposit-queue bookkeeping to an arbitrary shape.
  function setDepositList(DenseQueue.Queue calldata _list) external {
    depositList = _list;
  }

  /// @notice Preset a deposit-queue entry at an id.
  function setPendingDeposit(uint256 _id, IRelay.PendingDeposit calldata _deposit) external {
    pendingDeposits[_id] = _deposit;
  }

  /// @notice Preset a withdraw entry at an id.
  function setWithdrawal(uint256 _id, IRelay.WithdrawEntry calldata _entry) external {
    withdrawals[_id] = _entry;
  }

  /// @notice Preset a holder's escrowed share amount.
  function setEscrowedShares(address _holder, uint256 _shares) external {
    escrowedShares[_holder] = _shares;
  }

  /// @notice Drive `DenseQueue.append` against the deposit-queue bookkeeping, the way
  ///         `registerDeposit` issues an id.
  /// @return _id Id the new entry must be stored under.
  function appendDeposit() external returns (uint40 _id) {
    _id = depositList.append();
  }

  /// @notice Drive `DenseQueue.nextHead` against the deposit-queue bookkeeping.
  /// @param _cursor Id a walk stopped on.
  /// @return _next The head the bookkeeping would take from that cursor.
  function nextDepositHead(uint256 _cursor) external view returns (uint40 _next) {
    _next = depositList.nextHead(_cursor);
  }

  /// @notice Drive `QueueLib.processDeposits` against the harness storage.
  function processDeposits(
    QueueLib.DepositContext memory _ctx
  ) external returns (QueueLib.DepositResult memory _result) {
    _result = QueueLib.processDeposits(depositList, pendingDeposits, _ctx);
  }

  /// @notice Drive `QueueLib.processOverdueDeposits` against the harness storage.
  function processOverdueDeposits(
    uint256[] calldata _ids,
    QueueLib.DepositContext memory _ctx
  ) external returns (QueueLib.DepositResult memory _result) {
    _result = QueueLib.processOverdueDeposits(depositList, pendingDeposits, _ids, _ctx);
  }

  /// @notice Drive `QueueLib.processWithdrawals` against the harness storage.
  function processWithdrawals(
    IVotingEscrow _votingEscrow,
    IVoterPaymentsModule _vpm,
    QueueLib.WithdrawContext memory _ctx
  ) external returns (QueueLib.WithdrawResult memory _result) {
    _result = QueueLib.processWithdrawals(withdrawQueue, withdrawals, escrowedShares, _votingEscrow, _vpm, _ctx);
  }

  /// @notice Drive `QueueLib.requireUncoveredHead` against the harness storage.
  function requireUncoveredHead(IVoter _voter, uint256 _tokenId) external view {
    QueueLib.requireUncoveredHead(withdrawQueue, withdrawals, _voter, _tokenId);
  }
}
