// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';

/**
 * @title StakeRelayLib
 * @notice sAERO-creation and relay-deposit command handlers for the Metarouter.
 * @dev Deployed as a standalone library; the router calls each handler through `DELEGATECALL`, so the code lives
 *      outside the router's bytecode but runs in its storage context. Custody tracking, sender resolution, and funding
 *      go through `MetarouterState` / `FundsLib`; the VotingEscrow and its staking token are passed in because a
 *      library cannot read the router's immutables.
 *
 *      `CREATE_STAKE` and `DEPOSIT_RELAY` are root-only: the VotingEscrow and the relays exist only on the root
 *      deployment, so the router gates both on `IS_ROOT` before dispatch and these handlers receive a non-zero escrow.
 */
library StakeRelayLib {
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  /**
   * @notice Stakes the staking token into a freshly minted sAERO, retaining it in flight or delivering it.
   * @dev Funds the staking token through `FundsLib.fund` (from the batch balance or the logical sender), approves the
   *      escrow for that amount, and calls `createStake`, which pulls the amount and mints the sAERO to the router.
   *      A recipient equal to the router leaves the new sAERO in flight so a later command can consume its otherwise
   *      unknowable token id; any other non-zero recipient receives it immediately.
   * @param _input ABI-encoded `(BalanceSpend spend, bool payerIsUser, uint48 stakingWeeks, bool isPermanent, address
   *        recipient)`, where the router address retains the new sAERO in flight.
   * @param _escrow VotingEscrow the stake is created through; non-zero, the router gates the command on `IS_ROOT`.
   * @param _stakingToken Token the escrow stakes, funded and approved before the stake.
   */
  function createStake(bytes calldata _input, IVotingEscrow _escrow, IERC20 _stakingToken) external {
    (
      IMetarouter.BalanceSpend memory _spend,
      bool _payerIsUser,
      uint48 _stakingWeeks,
      bool _isPermanent,
      address _recipient
    ) = abi.decode(_input, (IMetarouter.BalanceSpend, bool, uint48, bool, address));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();

    // The downcast runs before the approve so an over-width amount fails before any effect.
    uint128 _amount = FundsLib.fund(address(_stakingToken), _spend, _payerIsUser).toUint128();
    // `createStake` pulls exactly `_amount`, so success consumes the allowance in full and no reset is needed.
    _stakingToken.forceApprove(address(_escrow), _amount);
    uint256 _tokenId = _escrow.createStake(_amount, _stakingWeeks, _isPermanent);

    if (_recipient == address(this)) {
      // The escrow mints directly to the router without invoking its receiver hook. Track the new sAERO and publish
      // its otherwise unknowable id so a later command in this batch can resolve the zero sentinel.
      MetarouterState.trackNft(address(_escrow), _tokenId);
      MetarouterState.setInFlightNft(address(_escrow), _tokenId);
    } else {
      IERC721(address(_escrow)).safeTransferFrom(address(this), _recipient, _tokenId);
    }
  }

  /**
   * @notice Deposits an existing or in-flight sAERO into a caller-selected relay for the selected share recipient.
   * @dev Pass-through custody: a zero token id resolves the in-flight sAERO; otherwise the router uses an sAERO already
   *      in this batch's custody or pulls the logical sender's token with `transferFrom` (its receiver hook accepts only
   *      the position manager). It requests the deposit for the selected share recipient, returns the source sAERO to
   *      the logical sender, and consumes the in-flight reference when that was the source.
   *
   *      The relay is caller-supplied, so it is authenticated against the RelayFactory before any approval is granted:
   *      a spoofed relay could otherwise report an authorized VPM and route the caller's weight to an attacker-chosen
   *      destination. The deposit moves weight through the relay's VoterPaymentsModule, so the relay and that VPM must
   *      both be ERC721-authorized on the token at once. The single token-scoped approval goes to the caller-selected
   *      relay (cleared when the sAERO returns); the operator grant goes to the VPM, which the escrow vouches for
   *      through `isAuthorizedVPM` and which is revoked after the deposit.
   *
   *      Caller preconditions, surfaced as relay-side reverts: the sAERO needs at least `_amount` of idle chain0
   *      weight (set by a prior vote outside the router), and a permissioned relay must have allow-listed the router
   *      and selected recipient. The custody round-trip also clears the sAERO's delegation and blocks same-block
   *      re-delegation (escrow transfers checkpoint the delegator), so delegators must re-delegate after.
   * @param _input ABI-encoded `(uint256 tokenId, uint256 amount, address relay, address recipient)`, where token id zero
   *        uses the in-flight sAERO.
   * @param _escrow VotingEscrow the sAERO belongs to; non-zero, the router gates the command on `IS_ROOT`.
   * @param _relayFactory RelayFactory the caller-selected relay is authenticated against; non-zero on root.
   */
  function depositRelay(bytes calldata _input, IVotingEscrow _escrow, IRelayFactory _relayFactory) external {
    (uint256 _tokenId, uint256 _amount, address _relay, address _recipient) =
      abi.decode(_input, (uint256, uint256, address, address));
    if (_recipient == address(0)) revert IMetarouter.InvalidRecipient();
    // Shares mint at keeper settlement, outside any batch, so a router recipient would leave them untracked on the
    // execution address where the permissionless `SWEEP` takes them.
    if (_recipient == address(this)) revert IMetarouter.InvalidRecipient();

    // Authenticate the caller-selected relay before trusting anything it reports: a spoofed relay could otherwise name
    // an authorized VPM and route the caller's weight to an attacker-chosen destination.
    if (!_relayFactory.isRelay(_relay)) revert IMetarouter.UnauthorizedRelay();

    // Vet the relay's VoterPaymentsModule before taking custody: the operator grant below goes to this address.
    address _vpm = address(IRelay(_relay).VPM());
    if (!_escrow.isAuthorizedVPM(_vpm)) revert IMetarouter.UnauthorizedRelayVpm();

    _tokenId = MetarouterState.resolvePositionId(address(_escrow), _tokenId);
    address _owner = MetarouterState.msgSender();
    // A position the router currently owns must have entered custody during this batch. A tracked position may have
    // been returned by an earlier command, so reacquire it from the logical sender whenever ownership has moved out.
    if (_escrow.ownerOf(_tokenId) == address(this)) {
      if (!MetarouterState.isNftInCustody(address(_escrow), _tokenId)) revert IMetarouter.NftNotInCustody();
    } else {
      // slither-disable-next-line arbitrary-send-erc20
      _escrow.transferFrom(_owner, address(this), _tokenId);
    }

    _escrow.setApprovalForAll(_vpm, true);
    _escrow.approve(_relay, _tokenId);

    // The selected recipient receives the shares at settlement regardless of who holds the source sAERO then.
    IRelay(_relay).requestDeposit(_tokenId, _amount, _recipient);

    // Revoke the operator grant, return the source sAERO to the logical sender, and consume an in-flight reference.
    _escrow.setApprovalForAll(_vpm, false);
    _escrow.transferFrom(address(this), _owner, _tokenId);
    MetarouterState.consumeInFlightNft(address(_escrow), _tokenId);
  }
}
