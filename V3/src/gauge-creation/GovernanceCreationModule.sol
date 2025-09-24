// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Roles} from 'V3/libraries/Roles.sol';

import {IGaugeCreationModule} from 'V3/interfaces/gauge-creation/IGaugeCreationModule.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {IGovernanceCreationModule} from 'V3/interfaces/gauge-creation/IGovernanceCreationModule.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title GovernanceCreationModule
 * @notice Governance-gated bypass module for custom and non-pool gauges.
 *         Governance supplies opaque factory data and the activation flag
 *         without TokenRegistry listing checks. The target must still be
 *         recorded on the FactoryRegistry by a registered target factory. May
 *         be deployed and left unregistered until needed.
 * @dev Authorization resolves GOVERNANCE_ROLE through the LeafVoter's
 *      AccessControl state, so the module carries none of its own. The
 *      GaugeManager still enforces factory approval, target provenance, the
 *      write once target link, and cursor seeding uniformly, so the bypass
 *      covers policy only, never registration integrity.
 */
contract GovernanceCreationModule is IGovernanceCreationModule {
  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeCreationModule
  IGaugeManager public immutable GAUGE_MANAGER;

  /// @inheritdoc IGovernanceCreationModule
  ILeafVoter public immutable LEAF_VOTER;

  /*//////////////////////////////////////////////////////////////
                               MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restrict the caller to holders of GOVERNANCE_ROLE on the
   *         LeafVoter.
   * @dev Reverts with NotAuthorized when the role check fails.
   */
  modifier onlyGovernor() {
    if (!LEAF_VOTER.hasRole(Roles.GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Wire the LeafVoter reference.
   * @dev The GaugeManager is read from the LeafVoter so both always agree on
   *      it. Reverts when the address is zero or the LeafVoter reports a
   *      zero GaugeManager.
   * @param _leafVoter LeafVoter on this chain.
   */
  constructor(address _leafVoter) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    address _gaugeManager = ILeafVoter(_leafVoter).GAUGE_MANAGER();
    if (_gaugeManager == address(0)) revert ZeroAddress();

    GAUGE_MANAGER = IGaugeManager(_gaugeManager);
    LEAF_VOTER = ILeafVoter(_leafVoter);
  }

  /*//////////////////////////////////////////////////////////////
                            GAUGE LIFECYCLE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGovernanceCreationModule
  function createGauge(
    address _target,
    address _gaugeFactory,
    bytes calldata _factoryData,
    bool _activate
  ) external onlyGovernor returns (address _gauge) {
    _gauge = GAUGE_MANAGER.createGauge(
      IGaugeManager.GaugeCreationRequest({
        creator: msg.sender,
        gaugeFactory: _gaugeFactory,
        target: _target,
        factoryData: _factoryData,
        activate: _activate
      })
    );
  }

  /// @inheritdoc IGaugeCreationModule
  function activate(address _gauge) external onlyGovernor {
    GAUGE_MANAGER.activateGauge(_gauge);
  }
}
