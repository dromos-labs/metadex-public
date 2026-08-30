// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {GaugeLib} from 'V3/metarouter/libraries/GaugeLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title StakingLib
 * @notice Gauge staking command handlers for the Metarouter.
 * @dev Deployed as a standalone library; the router calls each handler through `DELEGATECALL`, so the code lives
 *      outside the router's bytecode but runs in its storage context. Custody tracking, sender resolution, and funding
 *      go through `MetarouterState` / `FundsLib`; the Voter, emission token, and position manager are passed in
 *      because a library cannot read the router's immutables.
 *
 *      A gauge is validated through the Voter (`gaugeStates.isRegistered`), then its venue (V2 LP vs CL position) is
 *      read from its own factory `GAUGE_TYPE()`. The position manager comes from the router's immutables, never from
 *      calldata.
 */
library StakingLib {
  using SafeERC20 for IERC20;

  /**
   * @notice Stakes a V2 LP balance or a CL position into a validated gauge, crediting the logical sender.
   * @dev V2: funds the LP token through `FundsLib.fund` (from the batch balance or the logical sender), approves the
   *      gauge for that amount, then deposits, which pulls it all and leaves no allowance. CL: takes the position into
   *      custody (already held, or pulled from the logical sender), approves the gauge for it, then deposits. Either
   *      way the gauge credits `msgSender()` as the staker.
   * @param _input For a V2 gauge, ABI-encoded `(gauge, abi.encode(BalanceSpend, payerIsUser))`; for a CL gauge,
   *        ABI-encoded `(gauge, abi.encode(tokenId))`, where a zero `tokenId` stakes the in-flight position.
   * @param _leafVoter Leaf Voter used to validate the gauge target.
   * @param _positionManager Position manager the CL path approves and pulls the position through.
   */
  function stakeGauge(
    bytes calldata _input,
    ILeafVoter _leafVoter,
    INonfungiblePositionManager _positionManager
  ) external {
    (address _gauge, bytes memory _payload) = abi.decode(_input, (address, bytes));
    GaugeLib.requireRegisteredGauge(_gauge, _leafVoter);
    address _owner = MetarouterState.msgSender();

    // slither-disable-next-line unused-return
    (bool _isCl,) = GaugeLib.isClGauge(_gauge);
    if (_isCl) {
      uint256 _tokenId = MetarouterState.resolvePositionId(address(_positionManager), abi.decode(_payload, (uint256)));
      _ensureNftCustody(_positionManager, _tokenId, _owner);
      _positionManager.approve(_gauge, _tokenId);
      IGauge(_gauge).depositFor(_tokenId, _owner);
      // The position left the router for the gauge; clear the in-flight slots when it held this position.
      MetarouterState.consumeInFlightNft(address(_positionManager), _tokenId);
    } else {
      (IMetarouter.BalanceSpend memory _spend, bool _payerIsUser) =
        abi.decode(_payload, (IMetarouter.BalanceSpend, bool));
      address _lpToken = IV2Gauge(_gauge).stakingToken();
      uint256 _amount = FundsLib.fund(_lpToken, _spend, _payerIsUser);
      // `depositFor` pulls exactly `_amount`, so success consumes the allowance in full and no reset is needed.
      IERC20(_lpToken).forceApprove(_gauge, _amount);
      IGauge(_gauge).depositFor(_amount, _owner);
    }
  }

  /**
   * @notice Withdraws the logical sender's V2 LP or CL stake from a validated gauge.
   * @dev The router withdraws as an operator, so it needs the gauge's withdrawal approval for `msgSender()`. The V2 LP
   *      or CL position returns to the router, and `withdrawFrom` also claims accrued emissions. Those reach the router
   *      only when it holds claim approval, so the emission token is tracked only then. CL trading fees accrue to the
   *      gauge while staked and are not delivered by withdrawal. A CL position returns through `safeTransferFrom`, so
   *      `onERC721Received` tracks it; closure sweeps leftover ERC20s and requires the position to have left.
   *      A V2 gauge slashes the account's full accrual while the early-unstake penalty window is live, so the
   *      withdrawal then requires the explicit `allowPenalty` consent; a CL gauge slashes only what the position
   *      accrued since its own deposit, so the flag is ignored there.
   * @param _input For a V2 gauge, ABI-encoded `(gauge, abi.encode(amount), allowPenalty)`; for a CL gauge, ABI-encoded
   *        `(gauge, abi.encode(tokenId), allowPenalty)`. The flag is ignored for CL gauges.
   * @param _leafVoter Leaf Voter used to validate the gauge target.
   * @param _emissionToken Emission token a gauge claim delivers on this chain, tracked when routed to the router.
   */
  function unstakeGauge(bytes calldata _input, ILeafVoter _leafVoter, IERC20 _emissionToken) external {
    (address _gauge, bytes memory _payload, bool _allowPenalty) = abi.decode(_input, (address, bytes, bool));
    GaugeLib.requireRegisteredGauge(_gauge, _leafVoter);
    address _owner = MetarouterState.msgSender();
    (bool _isCl, IGaugeFactory _gaugeFactory) = GaugeLib.isClGauge(_gauge);
    if (!_isCl) GaugeLib.requirePenaltyAllowed(_gauge, _gaugeFactory, _owner, _allowPenalty);
    bool _claimApproved = IGauge(_gauge).approvedForClaim(_owner, address(this));

    if (_isCl) {
      uint256 _tokenId = abi.decode(_payload, (uint256));
      // With claim approval, accrued emissions are sent to the router.
      if (_claimApproved) MetarouterState.trackERC20(address(_emissionToken));
      // The gauge returns the position through `safeTransferFrom`; set it and the position as expected so
      // `onERC721Received` accepts and tracks the position, then clear it so nothing else can hand one in.
      MetarouterState.setExpectedNft(_gauge, _tokenId);
      IGauge(_gauge).withdrawFrom(_tokenId, _owner);
      MetarouterState.clearExpectedNft();
    } else {
      uint256 _amount = abi.decode(_payload, (uint256));
      // The withdrawn V2 staking token always returns to the router.
      MetarouterState.trackERC20(IV2Gauge(_gauge).stakingToken());
      // With claim approval, the accrued emissions come to the router too.
      if (_claimApproved) MetarouterState.trackERC20(address(_emissionToken));
      IGauge(_gauge).withdrawFrom(_amount, _owner);
    }
  }

  /**
   * @notice Ensures the router holds the position, pulling it from the logical sender when it does not.
   * @dev A position the router already owns must have entered during this batch — its tracking proves it — so a command
   *      cannot operate an NFT stranded before the batch. Otherwise it is pulled from the logical sender, which
   *      requires the router to hold the ERC721 approval.
   * @param _positionManager Position manager holding the NFT.
   * @param _tokenId Position to acquire.
   * @param _owner Logical sender the position is pulled from when the router does not hold it.
   */
  function _ensureNftCustody(INonfungiblePositionManager _positionManager, uint256 _tokenId, address _owner) private {
    if (_positionManager.ownerOf(_tokenId) == address(this)) {
      if (!MetarouterState.isNftInCustody(address(_positionManager), _tokenId)) revert IMetarouter.NftNotInCustody();
    } else {
      // `_owner` is the logical caller (`msgSender`); the router only ever pulls the caller's own position.
      // slither-disable-next-line arbitrary-send-erc20
      _positionManager.transferFrom(_owner, address(this), _tokenId);
    }
  }
}
