// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {GaugeLib} from 'V3/metarouter/libraries/GaugeLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';
import {V2PoolLib} from 'V3/metarouter/libraries/V2PoolLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
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
   *
   *      On root, `RootEmissionsHandler` saves rewards below the redeem minimum for each recipient. If the recipient
   *      is the router, small rewards from different users accumulate together. The user whose batch reaches the
   *      minimum receives the total, including less than 1e-12 TOKEN from earlier users. Claim directly to the user's
   *      address to keep these rewards separate.
   * @param _input ABI-encoded gauge, recipient, optional CL position ids, and whether an active V2 penalty is allowed;
   *        an empty position list claims account-wide.
   * @param _leafVoter Leaf Voter used to validate the gauge target.
   * @param _emissionToken Token the gauge claim delivers on this chain, tracked when the router is the recipient.
   * @param _factoryRegistry Registry holding the gauge's permanent deploying-factory record.
   */
  function claimGaugeRewards(
    bytes calldata _input,
    ILeafVoter _leafVoter,
    IERC20 _emissionToken,
    IFactoryRegistry _factoryRegistry
  ) external {
    (address _gauge, address _recipient, uint256[] memory _tokenIds, bool _allowPenalty) =
      abi.decode(_input, (address, address, uint256[], bool));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();

    GaugeLib.requireRegisteredGauge(_gauge, _leafVoter);

    if (_recipient == address(this)) MetarouterState.trackERC20(address(_emissionToken));

    address _account = MetarouterState.msgSender();
    // slither-disable-next-line unused-return
    (bool _isCl,) = GaugeLib.isClGauge(_gauge, _factoryRegistry);
    if (_isCl) {
      if (_tokenIds.length == 0) IGauge(_gauge).claimEmissions(_account, _recipient);
      else ICLGauge(_gauge).claimEmissions(_account, _recipient, _tokenIds);
    } else {
      if (_tokenIds.length > 0) revert IMetarouter.InvalidGaugeType();
      GaugeLib.requirePenaltyAllowed(_gauge, _account, _allowPenalty);
      IGauge(_gauge).claimEmissions(_account, _recipient);
    }
  }

  /**
   * @notice Claims V2 pool fees for the caller or the router.
   * @dev Validates the pool through its permanent creation record, factory membership, and V2 pool family,
   *      so existing pools remain usable after their factory is unapproved. User claims need approval from the caller.
   *      `claimRouterFees` selects fees earned while the router held LP tokens. Anyone can claim these, as with
   *      `SWEEP`. Tokens sent to the router are tracked for later commands and swept at batch end.
   * @param _input ABI-encoded `(pool, recipient, claimRouterFees)`.
   * @param _factoryRegistry Registry used to validate the pool.
   */
  function claimV2PoolFees(bytes calldata _input, IFactoryRegistry _factoryRegistry) external {
    (address _pool, address _recipient, bool _claimRouterFees) = abi.decode(_input, (address, address, bool));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();

    // slither-disable-next-line unused-return
    V2PoolLib.validatePool(_pool, _factoryRegistry);

    if (_recipient == address(this)) {
      MetarouterState.trackERC20(IPool(_pool).token0());
      MetarouterState.trackERC20(IPool(_pool).token1());
    }

    // The pool sees the router as the caller.
    // slither-disable-start unused-return
    if (_claimRouterFees) IPool(_pool).claimFees(_recipient);
    else IPool(_pool).claimFees({_account: MetarouterState.msgSender(), _recipient: _recipient});
    // slither-disable-end unused-return
  }
}
