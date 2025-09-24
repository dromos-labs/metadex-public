// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

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
   * @notice Reverts unless the gauge is registered with the Voter.
   * @param _gauge Gauge target to validate.
   * @param _leafVoter Leaf Voter whose `gaugeStates` gates the target.
   */
  function requireRegisteredGauge(address _gauge, ILeafVoter _leafVoter) internal view {
    // slither-disable-next-line unused-return
    (,,, bool _isRegistered,,,,,) = _leafVoter.gaugeStates(_gauge);
    if (!_isRegistered) revert IMetarouter.GaugeNotRegistered();
  }

  /**
   * @notice Returns whether a validated gauge is a concentrated-liquidity gauge, along with its factory.
   * @dev Reads the gauge's factory `GAUGE_TYPE()`; the gauge is Voter-registered, so its self-reported factory is
   *      trusted. A CL factory reports `cl`; any other value takes the V2 path. The factory is returned so a caller
   *      that also checks the penalty does not fetch it again.
   * @param _gauge Validated gauge whose venue is resolved.
   * @return _isCl Whether the gauge stakes CL positions.
   * @return _gaugeFactory Factory the gauge reports as its deployer.
   */
  function isClGauge(address _gauge) internal view returns (bool _isCl, IGaugeFactory _gaugeFactory) {
    _gaugeFactory = IGaugeFactory(IGauge(_gauge).gaugeFactory());
    _isCl = keccak256(bytes(_gaugeFactory.GAUGE_TYPE())) == _CL_GAUGE_TYPE_HASH;
  }

  /**
   * @notice Reverts when a V2 gauge's early-unstake penalty is live and the logical sender did not accept it.
   * @dev Mirrors the activation condition of `Gauge._applyPenalty`, which slashes every emission the account has
   *      accrued on a V2 gauge. Routed messages carry no ordering guarantees, so a relayer could land a stale
   *      deposit right before a withdrawal or claim and forfeit the account's full accrual; the explicit flag keeps
   *      that outcome a decision of the logical sender. The gate checks only that the window is live, not whether
   *      anything would actually be slashed: the gauge exposes no pre-penalty accrual view. So an exit with zero
   *      accrued rewards inside the window also needs the flag, which is harmless to accept in that case.
   * @param _gauge V2 gauge whose live penalty state is checked.
   * @param _gaugeFactory The gauge's factory, providing its effective penalty configuration.
   * @param _account Logical sender whose deposit timer controls the penalty.
   * @param _allowPenalty Whether the logical sender explicitly accepts an active penalty.
   */
  function requirePenaltyAllowed(
    address _gauge,
    IGaugeFactory _gaugeFactory,
    address _account,
    bool _allowPenalty
  ) internal view {
    if (_allowPenalty) return;

    IGaugeFactory.PenaltyConfig memory _config = _gaugeFactory.effectivePenaltyConfig(_gauge);
    if (
      _config.penaltyRate > 0 && _config.minStakeBlocks > 0
        && block.number < IV2Gauge(_gauge).depositBlock(_account) + _config.minStakeBlocks
    ) revert IMetarouter.PenaltyNotAccepted();
  }
}
