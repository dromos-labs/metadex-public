// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {ICLFactory} from 'V3/interfaces/factories/ICLFactory.sol';
import {ICLGaugeFactory} from 'V3/interfaces/factories/ICLGaugeFactory.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/**
 * @title ClResolverLib
 * @notice Resolves the position manager a CL command operates through, from the factory that owns the position's
 *         collection.
 * @dev Internal helpers inlined into the command libraries, so the router holds no canonical position manager and a
 *      second approved CL factory can be added without redeploying it. Each factory names one immutable manager and
 *      each manager names one immutable factory, so the pair authenticates itself: requiring the manager to point back
 *      leaves a factory unable to nominate another factory's collection. A factory deployed before the manager getter
 *      existed cannot name its manager itself; the gauge factory the registry pairs it with binds the same manager
 *      through its own immutable, so the resolver falls back to that record when the getter fails and the reverse
 *      link authenticates the pair all the same. What establishes the factory itself differs per entry point. A
 *      factory named in calldata must be approved or have a permanent factory-pair record in the registry. That
 *      record survives deregistration, so existing positions remain usable. A factory reached through a gauge is
 *      already fixed by write-once registry records, so that path reads the records alone.
 */
library ClResolverLib {
  /**
   * @notice Resolves and authenticates the position manager of a known CL factory, including a retired one.
   * @dev Current approval admits factories before gauge pairing. The permanent pair record also authenticates a
   *      factory after deregistration. Both are checked before calling the factory; a caller-supplied address alone
   *      cannot cross the registry boundary. Pool creation must separately require current approval.
   * @param _poolFactory Pool factory naming the collection the command operates on.
   * @param _factoryRegistry Registry holding the router's factory trust boundary.
   * @return _positionManager Authenticated position manager of `_poolFactory`.
   */
  function resolvePositionManager(
    address _poolFactory,
    IFactoryRegistry _factoryRegistry
  ) internal view returns (INonfungiblePositionManager _positionManager) {
    if (
      !_factoryRegistry.isTargetFactoryApproved(_poolFactory)
        && _factoryRegistry.targetFactoryToGaugeFactory(_poolFactory) == address(0)
    ) {
      revert IMetarouter.FactoryNotApproved();
    }
    _positionManager = _authenticatePositionManager(_poolFactory, _factoryRegistry);
  }

  /**
   * @notice Resolves and authenticates the position manager paired with a gauge factory.
   * @dev `GaugeLib` first proves this is the factory permanently recorded for the gauge, and the target factory it
   *      links to is recorded write-once as well. Both records outlive `unregisterFactories`, so they anchor the
   *      factory's identity on their own and this path takes no approval check. A caller never names either factory,
   *      which leaves nothing for the approval set to authenticate here, and unregistering a live CL factory
   *      therefore does not strand staked positions behind the router.
   * @param _gaugeFactory Registry-authenticated gauge factory serving the position collection.
   * @param _factoryRegistry Registry holding the gauge, target, and factory records.
   * @return _positionManager Authenticated position manager of the gauge factory's linked target factory.
   */
  function resolveGaugePositionManager(
    address _gaugeFactory,
    IFactoryRegistry _factoryRegistry
  ) internal view returns (INonfungiblePositionManager _positionManager) {
    _positionManager = _authenticatePositionManager(
      _factoryRegistry.gaugeFactoryToTargetFactory(_gaugeFactory), _factoryRegistry
    );
  }

  /**
   * @notice Resolves a CL factory's position manager and requires it to name that factory back.
   * @dev The factory's own getter is the canonical source. A factory deployed before that getter existed reverts on
   *      it, so the resolver then reads the manager bound by the gauge factory the registry pairs with the factory.
   *      That pair record is write-once and the gauge factory's manager is immutable, so the fallback adds no mutable
   *      trust, and the reverse link below still refuses a manager of another factory. A factory with neither source
   *      names no manager at all.
   * @param _poolFactory Pool factory whose canonical manager is resolved.
   * @param _factoryRegistry Registry holding the factory-pair record the fallback reads.
   * @return _positionManager Authenticated position manager of `_poolFactory`.
   */
  function _authenticatePositionManager(
    address _poolFactory,
    IFactoryRegistry _factoryRegistry
  ) private view returns (INonfungiblePositionManager _positionManager) {
    try ICLFactory(_poolFactory).positionManager() returns (address _namedPositionManager) {
      _positionManager = INonfungiblePositionManager(_namedPositionManager);
    } catch {
      address _gaugeFactory = _factoryRegistry.targetFactoryToGaugeFactory(_poolFactory);
      if (_gaugeFactory == address(0)) revert IMetarouter.PositionManagerNotConfigured(_poolFactory);
      _positionManager = INonfungiblePositionManager(ICLGaugeFactory(_gaugeFactory).nft());
    }
    if (address(_positionManager) == address(0)) revert IMetarouter.PositionManagerNotConfigured(_poolFactory);

    if (_positionManager.factory() != _poolFactory) {
      revert IMetarouter.PositionManagerFactoryMismatch(_poolFactory, address(_positionManager));
    }
  }
}
