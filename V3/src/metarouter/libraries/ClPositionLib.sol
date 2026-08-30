// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/**
 * @title ClPositionLib
 * @notice Concentrated-liquidity position command handlers for the Metarouter: mint, increase, decrease, collect, and
 *         burn.
 * @dev Deployed as a standalone library; the router calls each handler through `DELEGATECALL`, so the code lives
 *      outside the router's bytecode but runs in its storage context. Funding, custody tracking, sender resolution, and
 *      the in-flight NFT slots go through `MetarouterState` / `FundsLib`; the position manager is passed in because a
 *      library cannot read the router's immutables. It is the router's canonical `POSITION_MANAGER`, never calldata.
 *
 *      `MINT_CL_POSITION` mints to the execution address and stores the new position in the in-flight slots so a later
 *      command (increase, stake, or burn) can act on it without knowing its id; the mint also tracks the position
 *      for custody so closure verifies it left even when nothing consumes it. The manager mints with `_mint`, not
 *      `_safeMint`, so the receiver hook does not fire and the handler tracks the position itself.
 *
 *      Operations on an existing position resolve the id (the zero sentinel maps to the in-flight position), then check
 *      the caller may operate it: the router may act on a position it holds only when custody tracking proves it entered
 *      during the batch, and otherwise only on the logical sender's own position, never a third party's.
 */
library ClPositionLib {
  using SafeERC20 for IERC20;

  /**
   * @notice Mints a new CL position to a chosen recipient, or the metarouter itself to keep it for a later command.
   * @dev Funds both pool tokens, approves the manager, mints, and clears the approvals; the manager pulls only what it
   *      uses, so any remainder is swept at closure. Only a position minted to the metarouter is tracked for custody
   *      and put in flight; one minted to another recipient never enters the router and is left untracked.
   * @param _input ABI-encoded `MintClParams`.
   * @param _positionManager Position manager the position is minted through; the router's immutable.
   */
  function mintClPosition(bytes calldata _input, INonfungiblePositionManager _positionManager) external {
    IMetarouter.MintClParams memory _params = abi.decode(_input, (IMetarouter.MintClParams));

    if (_params.recipient == address(0)) revert IMetarouter.InvalidRecipient();

    uint256 _amount0 = FundsLib.fund(_params.token0, _params.spend0, _params.payerIsUser0);
    uint256 _amount1 = FundsLib.fund(_params.token1, _params.spend1, _params.payerIsUser1);

    IERC20(_params.token0).forceApprove(address(_positionManager), _amount0);
    IERC20(_params.token1).forceApprove(address(_positionManager), _amount1);

    // slither-disable-next-line unused-return
    (uint256 _tokenId,,,) = _positionManager.mint(
      INonfungiblePositionManager.MintParams({
        token0: _params.token0,
        token1: _params.token1,
        tickSpacing: _params.tickSpacing,
        tickLower: _params.tickLower,
        tickUpper: _params.tickUpper,
        amount0Desired: _amount0,
        amount1Desired: _amount1,
        amount0Min: _params.amount0Min,
        amount1Min: _params.amount1Min,
        recipient: _params.recipient,
        deadline: _params.deadline,
        sqrtPriceX96: _params.sqrtPriceX96
      })
    );

    // Held by the router: a later command stakes or burns it, and closure verifies it left. Recorded before the
    // allowance-clearing interactions below, so the custody effect precedes them.
    if (_params.recipient == address(this)) {
      MetarouterState.trackNft(address(_positionManager), _tokenId);
      MetarouterState.setInFlightNft(address(_positionManager), _tokenId);
    }

    // The manager pulls only what the mint used; clear the residual allowance it leaves.
    IERC20(_params.token0).forceApprove(address(_positionManager), 0);
    IERC20(_params.token1).forceApprove(address(_positionManager), 0);
  }

  /**
   * @notice Adds liquidity to an existing position, funded from the batch balance or the logical sender.
   * @dev Resolves the position (the zero sentinel maps to the in-flight one), reads its pool tokens, funds each, and
   *      increases. Ownership is deliberately not checked: adding liquidity cannot harm the position's owner, and the
   *      manager gates the caller only for a gauge-staked position (letting just the owning gauge increase it), so any
   *      other position may be topped up while a staked one reverts. A position parked in the router is still refused,
   *      since operating one is how a batch would reach a position it never took custody of. The manager pulls only the
   *      used amounts, so any funded remainder stays tracked and is swept at closure; the temporary approvals are
   *      cleared after. The position stays available, so the in-flight slots are left untouched.
   * @param _input ABI-encoded `IncreaseClParams`.
   * @param _positionManager Position manager holding the position; the router's immutable.
   */
  function increaseClLiquidity(bytes calldata _input, INonfungiblePositionManager _positionManager) external {
    IMetarouter.IncreaseClParams memory _params = abi.decode(_input, (IMetarouter.IncreaseClParams));

    uint256 _tokenId = MetarouterState.resolvePositionId(address(_positionManager), _params.tokenId);
    // The router owns anything parked in it, so the manager's own authorization would wave such a position through;
    // only the batch's custody tracking separates one this batch took from one stranded here earlier.
    if (_positionManager.ownerOf(_tokenId) == address(this)) {
      if (!MetarouterState.isNftInCustody(address(_positionManager), _tokenId)) revert IMetarouter.NftNotInCustody();
    }

    // slither-disable-next-line unused-return
    (,, address _token0, address _token1,,,,,,,,) = _positionManager.positions(_tokenId);

    uint256 _amount0 = FundsLib.fund(_token0, _params.spend0, _params.payerIsUser0);
    uint256 _amount1 = FundsLib.fund(_token1, _params.spend1, _params.payerIsUser1);

    IERC20(_token0).forceApprove(address(_positionManager), _amount0);
    IERC20(_token1).forceApprove(address(_positionManager), _amount1);

    // slither-disable-next-line unused-return
    _positionManager.increaseLiquidity(
      INonfungiblePositionManager.IncreaseLiquidityParams({
        tokenId: _tokenId,
        amount0Desired: _amount0,
        amount1Desired: _amount1,
        amount0Min: _params.amount0Min,
        amount1Min: _params.amount1Min,
        deadline: _params.deadline
      })
    );

    // The manager pulls only what the increase used; clear the residual allowance it leaves.
    IERC20(_token0).forceApprove(address(_positionManager), 0);
    IERC20(_token1).forceApprove(address(_positionManager), 0);
  }

  /**
   * @notice Removes liquidity from an existing position into its owed-token balance.
   * @dev Resolves the position and checks the caller may operate it, then decreases. The manager accounts the removed
   *      liquidity to the position's owed tokens without transferring anything out, so a later `COLLECT_CL_FEES`
   *      extracts it; nothing is tracked here. When all liquidity is requested, its live value is read immediately
   *      before the decrease so a third-party increase cannot leave residue, and an already-empty position is a
   *      no-op so a remove-everything plan cannot abort on it. The position stays available, so the in-flight slots
   *      are left untouched.
   * @param _input ABI-encoded `(INonfungiblePositionManager.DecreaseLiquidityParams, bool decreaseAllLiquidity)`;
   *        `tokenId` zero uses the in-flight position.
   * @param _positionManager Position manager holding the position; the router's immutable.
   */
  function decreaseClLiquidity(bytes calldata _input, INonfungiblePositionManager _positionManager) external {
    (INonfungiblePositionManager.DecreaseLiquidityParams memory _params, bool _decreaseAllLiquidity) =
      abi.decode(_input, (INonfungiblePositionManager.DecreaseLiquidityParams, bool));

    _params.tokenId = MetarouterState.resolvePositionId(address(_positionManager), _params.tokenId);
    _requireOperable(_positionManager, _params.tokenId);

    if (_decreaseAllLiquidity) {
      // slither-disable-next-line unused-return
      (,,,,,,, uint128 _currentLiquidity,,,,) = _positionManager.positions(_params.tokenId);
      // An already empty position has nothing to remove and the manager rejects a zero decrease, so skip it as a
      // no-op instead of aborting a batch containing a remove everything command whose liquidity is already gone.
      if (_currentLiquidity == 0) return;
      _params.liquidity = _currentLiquidity;
    }

    // slither-disable-next-line unused-return
    _positionManager.decreaseLiquidity(_params);
  }

  /**
   * @notice Collects a position's owed tokens to a recipient, or the metarouter to keep them for the batch.
   * @dev Resolves the position and checks the caller may operate it, then collects. Collecting to the metarouter tracks
   *      the pool tokens so a later command can consume them and closure returns any leftover; any other recipient
   *      receives them directly, untracked. The position stays available, so the in-flight slots are left untouched.
   * @param _input ABI-encoded `INonfungiblePositionManager.CollectParams`; `tokenId` zero uses the in-flight position,
   *        and `recipient` must be non-zero.
   * @param _positionManager Position manager holding the position; the router's immutable.
   */
  function collectClFees(bytes calldata _input, INonfungiblePositionManager _positionManager) external {
    INonfungiblePositionManager.CollectParams memory _params =
      abi.decode(_input, (INonfungiblePositionManager.CollectParams));

    if (_params.recipient == address(0)) revert IMetarouter.InvalidRecipient();

    _params.tokenId = MetarouterState.resolvePositionId(address(_positionManager), _params.tokenId);
    _requireOperable(_positionManager, _params.tokenId);

    // A collect into the router tracks the pool tokens so closure returns any leftover.
    if (_params.recipient == address(this)) {
      // slither-disable-next-line unused-return
      (,, address _token0, address _token1,,,,,,,,) = _positionManager.positions(_params.tokenId);
      MetarouterState.trackERC20(_token0);
      MetarouterState.trackERC20(_token1);
    }

    // slither-disable-next-line unused-return
    _positionManager.collect(_params);
  }

  /**
   * @notice Burns an empty position and drops it from custody and the in-flight slots.
   * @dev Resolves the position and checks the caller may operate it, then burns. The manager requires the position to
   *      hold no liquidity and no owed tokens. The burned id is untracked so the closure ownership check skips it rather
   *      than reading a nonexistent token, and cleared from the in-flight slots when it was the in-flight position.
   * @param _input ABI-encoded `(uint256 tokenId)`; `tokenId` zero uses the in-flight position.
   * @param _positionManager Position manager holding the position; the router's immutable.
   */
  function burnClPosition(bytes calldata _input, INonfungiblePositionManager _positionManager) external {
    uint256 _tokenId = abi.decode(_input, (uint256));

    _tokenId = MetarouterState.resolvePositionId(address(_positionManager), _tokenId);
    _requireOperable(_positionManager, _tokenId);

    _positionManager.burn(_tokenId);

    MetarouterState.untrackNft(address(_positionManager), _tokenId);
    MetarouterState.consumeInFlightNft(address(_positionManager), _tokenId);
  }

  /**
   * @notice Reverts unless the logical sender may operate the position.
   * @dev A router-held position must have entered custody during the batch, proven by its tracking, so a command cannot
   *      operate a position stranded before the batch. Any other holder must be the logical sender; the router never
   *      operates a third party's position.
   * @param _positionManager Position manager holding the position.
   * @param _tokenId Position to check.
   */
  function _requireOperable(INonfungiblePositionManager _positionManager, uint256 _tokenId) private view {
    address _owner = _positionManager.ownerOf(_tokenId);
    if (_owner == address(this)) {
      if (!MetarouterState.isNftInCustody(address(_positionManager), _tokenId)) revert IMetarouter.NftNotInCustody();
    } else if (_owner != MetarouterState.msgSender()) {
      revert IMetarouter.NotPositionOwner();
    }
  }
}
