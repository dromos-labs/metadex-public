// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {GaugeLib} from 'V3/metarouter/libraries/GaugeLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {ICLGauge} from 'V3/interfaces/gauges/ICLGauge.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title ClaimsLib
 * @notice Reward-claim command handlers for the Metarouter.
 * @dev Deployed as a standalone library; the router calls each handler through `DELEGATECALL`, so the code lives
 *      outside the router's bytecode while executing in the router's storage context. Tracking and logical-sender
 *      resolution go through `FundsLib`; the Voter is passed in because a library cannot read the router's immutables.
 */
library ClaimsLib {
  /**
   * @notice Claims the logical sender's gauge emissions.
   * @dev The gauge enforces caller authorization; the account is fixed to the logical sender. An empty position-id
   *      list selects the account-level overload, including for CL gauges, and can therefore iterate the account's
   *      entire staked-position set. A non-empty list is accepted only for CL gauges and bounds their internal
   *      iteration to the caller-supplied positions. A gauge claim delivers one emission token per chain (the
   *      `ReceiptToken` on leaf, the canonical `TOKEN` on root), so when routed to the router that single token is
   *      tracked for the closure sweep. The token is passed in because the router holds it as an immutable and no
   *      reachable contract exposes it uniformly across chains. A V2 gauge slashes the account's full accrual while
   *      the early-unstake penalty window is live, so the claim then requires the explicit `allowPenalty` consent;
   *      a CL gauge slashes only newly accrued rewards and skips the check.
   * @param _input ABI-encoded gauge, recipient, optional CL position ids, and whether an active V2 penalty is allowed;
   *        an empty position list claims account-wide.
   * @param _leafVoter Leaf Voter used to validate the gauge target.
   * @param _emissionToken Token the gauge claim delivers on this chain, tracked when the router is the recipient.
   */
  function claimGaugeRewards(bytes calldata _input, ILeafVoter _leafVoter, IERC20 _emissionToken) external {
    (address _gauge, address _recipient, uint256[] memory _tokenIds, bool _allowPenalty) =
      abi.decode(_input, (address, address, uint256[], bool));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();

    GaugeLib.requireRegisteredGauge(_gauge, _leafVoter);

    if (_recipient == address(this)) MetarouterState.trackERC20(address(_emissionToken));

    address _account = MetarouterState.msgSender();
    (bool _isCl, IGaugeFactory _gaugeFactory) = GaugeLib.isClGauge(_gauge);
    if (_isCl) {
      if (_tokenIds.length == 0) IGauge(_gauge).claimEmissions(_account, _recipient);
      else ICLGauge(_gauge).claimEmissions(_account, _recipient, _tokenIds);
    } else {
      if (_tokenIds.length > 0) revert IMetarouter.InvalidGaugeType();
      GaugeLib.requirePenaltyAllowed(_gauge, _gaugeFactory, _account, _allowPenalty);
      IGauge(_gauge).claimEmissions(_account, _recipient);
    }
  }

  /**
   * @notice Claims the logical sender's account-level V2 LP fees from a pool.
   * @dev The pool is validated through the `FactoryRegistry`: `targetToFactory` resolves the deploying
   *      factory (zero for an unknown pool) and `isTargetFactoryApproved` gates it, so an unregistered pool reverts.
   *      The fee account is fixed to the logical sender and never read from calldata; the pool enforces operator
   *      authorization. When the router is the recipient, both pool tokens are tracked before the claim so later
   *      commands can consume them and closure sweeps any leftovers.
   * @param _input ABI-encoded pool and recipient.
   * @param _factoryRegistry Factory registry that validates the pool target (the router's immutable).
   */
  function claimV2PoolFees(bytes calldata _input, IFactoryRegistry _factoryRegistry) external {
    (address _pool, address _recipient) = abi.decode(_input, (address, address));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();

    if (!_factoryRegistry.isTargetFactoryApproved(_factoryRegistry.targetToFactory(_pool))) {
      revert IMetarouter.PoolNotRegistered();
    }

    if (_recipient == address(this)) {
      MetarouterState.trackERC20(IPool(_pool).token0());
      MetarouterState.trackERC20(IPool(_pool).token1());
    }

    // slither-disable-next-line unused-return
    IPool(_pool).claimFees({_account: MetarouterState.msgSender(), _recipient: _recipient});
  }
}
