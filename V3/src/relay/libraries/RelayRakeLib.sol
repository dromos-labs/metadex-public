// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {IRelayState} from 'V3/interfaces/relay/IRelayState.sol';

/**
 * @title  RelayRakeLib
 * @notice The rake: the rate changes, the skim of each yield batch and the fee collection. The Relay
 *         keeps the access checks.
 * @dev    EXTERNAL (linked) library, delegatecalled (EIP-170).
 */
library RelayRakeLib {
  using SafeCastLibrary for uint256;
  using SafeTransferLib for address;

  /// @notice Applies a rake pair that raises neither rate at once; stores any other pair as pending.
  /// @param _rakes The rake state (the Relay's storage).
  /// @param _protocolPips Proposed protocol rake.
  /// @param _allocatorPips Proposed allocator rake.
  /// @dev A pending pair waits out `entrypointTimelock`. A new pending pair replaces the previous
  ///      one and restarts the delay.
  function proposeRakes(IRelay.RakeState storage _rakes, uint256 _protocolPips, uint256 _allocatorPips) external {
    IRelayState _relay = IRelayState(address(this));
    uint256 _maxRakePips = _relay.MAX_RAKE_PIPS();
    if (_protocolPips > _maxRakePips || _allocatorPips > _maxRakePips) {
      revert IRelay.RakeAboveCeiling();
    }

    if (_protocolPips <= _rakes.protocolPips && _allocatorPips <= _rakes.allocatorPips) {
      _setRakes(_rakes, _protocolPips, _allocatorPips);
      return;
    }

    uint256 _executableAt = block.timestamp + _relay.relayConfig().entrypointTimelock;
    _rakes.pendingProtocolPips = uint24(_protocolPips);
    _rakes.pendingAllocatorPips = uint24(_allocatorPips);
    _rakes.executableAt = _executableAt.toUint48();
    emit IRelay.RakesProposed(_protocolPips, _allocatorPips, _executableAt);
  }

  /// @notice Applies the pending rake pair once its delay has elapsed.
  /// @param _rakes The rake state (the Relay's storage).
  function executeRakes(IRelay.RakeState storage _rakes) external {
    uint256 _executableAt = _rakes.executableAt;
    if (_executableAt == 0) revert IRelay.NoPendingRakes();
    if (block.timestamp < _executableAt) revert IRelay.RakeTimelockActive();
    _setRakes(_rakes, _rakes.pendingProtocolPips, _rakes.pendingAllocatorPips);
  }

  /// @notice Sends the protocol lane of each token to the factory's rake treasury.
  /// @param _feeAccrued Per-token rake accruals (the Relay's storage).
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _tokens Tokens to collect.
  function collectProtocolFees(
    mapping(address token => IRelay.FeeAccrual accrual) storage _feeAccrued,
    mapping(address token => uint256 accounted) storage _accountedBalance,
    address[] calldata _tokens
  ) external {
    address _treasury = IRelayFactory(IRelayState(address(this)).factory()).rakeTreasury();
    _collect(_feeAccrued, _accountedBalance, _tokens, _treasury, true);
  }

  /// @notice Sends the allocator lane of each token to `_recipient`.
  /// @param _feeAccrued Per-token rake accruals (the Relay's storage).
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _tokens Tokens to collect.
  /// @param _recipient Recipient of the fees.
  function collectAllocatorFees(
    mapping(address token => IRelay.FeeAccrual accrual) storage _feeAccrued,
    mapping(address token => uint256 accounted) storage _accountedBalance,
    address[] calldata _tokens,
    address _recipient
  ) external {
    if (_recipient == address(0)) revert IRelay.ZeroAddress();
    _collect(_feeAccrued, _accountedBalance, _tokens, _recipient, false);
  }

  /// @notice Takes the protocol rake from a yield batch, then the allocator rake from the rest, and
  ///         books both to `_token`'s lanes.
  /// @param _rakes The rake state (the Relay's storage).
  /// @param _feeAccrued Per-token rake accruals (the Relay's storage).
  /// @param _token Token of the yield batch.
  /// @param _amount Gross yield batch.
  /// @return _net The batch left after both rakes.
  /// @return _fees The two rakes combined.
  /// @dev Both rakes round down, so a non-zero batch keeps a non-zero net while each rate is below
  ///      `MAX_PIPS`.
  function skim(
    IRelay.RakeState storage _rakes,
    mapping(address token => IRelay.FeeAccrual accrual) storage _feeAccrued,
    address _token,
    uint256 _amount
  ) internal returns (uint256 _net, uint256 _fees) {
    IRelay.RakeState memory _rates = _rakes;
    uint256 _protocolFee = Math.mulDiv(_amount, _rates.protocolPips, MAX_PIPS);
    uint256 _allocatorFee = Math.mulDiv(_amount - _protocolFee, _rates.allocatorPips, MAX_PIPS);
    _fees = _protocolFee + _allocatorFee;
    _net = _amount - _fees;
    if (_fees == 0) return (_net, _fees);

    IRelay.FeeAccrual memory _accrual = _feeAccrued[_token];
    _accrual.protocol = (_accrual.protocol + _protocolFee).toUint128();
    _accrual.allocator = (_accrual.allocator + _allocatorFee).toUint128();
    _feeAccrued[_token] = _accrual;
    emit IRelay.RakeSkimmed(_token, _protocolFee, _allocatorFee);
  }

  /// @notice Writes the live rake pair and clears the pending one.
  /// @param _rakes The rake state (the Relay's storage).
  /// @param _protocolPips Protocol rake to apply.
  /// @param _allocatorPips Allocator rake to apply.
  function _setRakes(IRelay.RakeState storage _rakes, uint256 _protocolPips, uint256 _allocatorPips) private {
    _rakes.protocolPips = uint24(_protocolPips);
    _rakes.allocatorPips = uint24(_allocatorPips);
    _rakes.pendingProtocolPips = 0;
    _rakes.pendingAllocatorPips = 0;
    _rakes.executableAt = 0;
    emit IRelay.RakesSet(_protocolPips, _allocatorPips);
  }

  /// @notice Zeroes one lane of each token, releases it from the accounted balance and transfers it.
  /// @param _feeAccrued Per-token rake accruals (the Relay's storage).
  /// @param _accountedBalance Per-token accounted balance (the Relay's storage).
  /// @param _tokens Tokens to collect; a token with nothing accrued is skipped.
  /// @param _recipient Recipient of the fees.
  /// @param _protocolLane True to collect the protocol lane, false for the allocator lane.
  function _collect(
    mapping(address token => IRelay.FeeAccrual accrual) storage _feeAccrued,
    mapping(address token => uint256 accounted) storage _accountedBalance,
    address[] calldata _tokens,
    address _recipient,
    bool _protocolLane
  ) private {
    uint256 _length = _tokens.length;
    for (uint256 _i; _i < _length; ++_i) {
      address _token = _tokens[_i];
      IRelay.FeeAccrual storage _accrual = _feeAccrued[_token];
      uint256 _fee = _protocolLane ? _accrual.protocol : _accrual.allocator;
      if (_fee == 0) continue;

      if (_protocolLane) _accrual.protocol = 0;
      else _accrual.allocator = 0;
      _accountedBalance[_token] -= _fee;

      _token.safeTransfer(_recipient, _fee);
      if (_protocolLane) emit IRelay.ProtocolFeesCollected(_token, _recipient, _fee);
      else emit IRelay.AllocatorFeesCollected(_token, _recipient, _fee);
    }
  }
}
