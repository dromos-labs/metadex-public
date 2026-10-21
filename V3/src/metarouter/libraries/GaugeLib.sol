// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ZERO_GAUGE} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title GaugeLib
 * @notice Shared gauge introspection helpers for the Metarouter command libraries.
 * @dev Internal-only library: the helpers inline into each command library that uses them, so sharing them adds no
 *      linking or `DELEGATECALL` surface.
 */
library GaugeLib {
  /// @notice Keccak hash of `'cl'`, the `GAUGE_TYPE()` string a concentrated-liquidity gauge factory reports.
  bytes32 private constant _CL_GAUGE_TYPE_HASH = keccak256('cl');

  /**
   * @notice Reverts unless the gauge is a routable target registered with the Voter.
   * @dev The Voter registers `ZERO_GAUGE` as the idle sink a vote parks power on, so registration alone does not make
   *      a target routable. It is a bookkeeping key rather than a contract, and it is excluded here the way
   *      `LeafVoter.activateGauge` excludes it.
   * @param _gauge Gauge target to validate.
   * @param _leafVoter Leaf Voter whose `gaugeStates` gates the target.
   */
  function requireRegisteredGauge(address _gauge, ILeafVoter _leafVoter) internal view {
    if (_gauge == ZERO_GAUGE) revert IMetarouter.GaugeNotRegistered();
    // slither-disable-next-line unused-return
    (,,, bool _isRegistered,,,,,) = _leafVoter.gaugeStates(_gauge);
    if (!_isRegistered) revert IMetarouter.GaugeNotRegistered();
  }

  /**
   * @notice Returns whether a validated gauge is a concentrated-liquidity gauge, along with its factory.
   * @dev Classifies through the factory permanently recorded for the gauge, after requiring the gauge's immutable
   *      self-report to agree with that record. This gives venue classification and every downstream registry lookup
   *      the same trust root. A CL factory reports `cl`; any other value takes the V2 path. A validated gauge always
   *      carries a record, because `GaugeManager.createGauge` writes it in the same transaction that registers the
   *      gauge with the Voter, so agreement is the only thing left to check.
   * @param _gauge Validated gauge whose venue is resolved.
   * @param _factoryRegistry Registry holding the gauge's permanent deploying-factory record.
   * @return _isCl Whether the gauge stakes CL positions.
   * @return _gaugeFactory Factory the gauge reports as its deployer.
   */
  function isClGauge(
    address _gauge,
    IFactoryRegistry _factoryRegistry
  ) internal view returns (bool _isCl, IGaugeFactory _gaugeFactory) {
    address _recordedFactory = _factoryRegistry.gaugeToFactory(_gauge);
    address _reportedFactory = IGauge(_gauge).gaugeFactory();
    if (_reportedFactory != _recordedFactory) {
      revert IMetarouter.GaugeFactoryMismatch(_gauge, _recordedFactory, _reportedFactory);
    }
    _gaugeFactory = IGaugeFactory(_recordedFactory);
    _isCl = keccak256(bytes(_gaugeFactory.GAUGE_TYPE())) == _CL_GAUGE_TYPE_HASH;
  }

  /**
   * @notice Reverts when a V2 gauge's early-unstake penalty is live and the logical sender did not accept it.
   * @dev Uses the gauge's penalty-window view, which shares the condition used when slashing emissions the account has
   *      accrued on a V2 gauge. Routed messages carry no ordering guarantees, so a relayer could land a stale
   *      deposit right before a withdrawal or claim and forfeit the account's full accrual; the explicit flag keeps
   *      that outcome a decision of the logical sender. The gate checks only that the window is live, not whether
   *      anything would actually be slashed: the gauge exposes no pre-penalty accrual view. So an exit with zero
   *      accrued rewards inside the window also needs the flag, which is harmless to accept in that case.
   * @param _gauge V2 gauge whose live penalty state is checked.
   * @param _account Logical sender whose deposit timer controls the penalty.
   * @param _allowPenalty Whether the logical sender explicitly accepts an active penalty.
   */
  function requirePenaltyAllowed(address _gauge, address _account, bool _allowPenalty) internal view {
    if (_allowPenalty) return;

    if (IV2Gauge(_gauge).isPenaltyActive({_account: _account})) revert IMetarouter.PenaltyNotAccepted();
  }
}
