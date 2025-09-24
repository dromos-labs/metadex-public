// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

/**
 * @title  RelayFactory
 * @notice Deploys Relays as deterministic EIP-1167 clones of the two per-tier implementations. A
 *         create call pulls the seed TOKEN from the caller, mints a fresh sAERO, transfers it to
 *         the clone's predicted address, then clones and initializes the Relay there — one
 *         transaction, so the clone already owns its seed when it is created. Creation is
 *         restricted to RELAY_DEPLOYER_ROLE on the Voter.
 * @dev Cloning keeps creation code out of the factory (embedding the variants exceeded EIP-170 and
 *      EIP-3860). Sending the seed sAERO to the predicted address first is what lets `initialize`'s
 *      ownership check pass when the clone is created.
 */
contract RelayFactory is IRelayFactory {
  using SafeTransferLib for address;

  /// @inheritdoc IRelayFactory
  IVotingEscrow public immutable VOTING_ESCROW;

  /// @inheritdoc IRelayFactory
  address public immutable TOKEN;

  /// @inheritdoc IRelayFactory
  address public immutable MAXI_IMPLEMENTATION;

  /// @inheritdoc IRelayFactory
  address public immutable PROTOCOL_IMPLEMENTATION;

  /// @inheritdoc IRelayFactory
  IVoterPaymentsModule public immutable VPM;

  /// @inheritdoc IRelayFactory
  IGovernor public immutable GOVERNOR;

  /// @inheritdoc IRelayFactory
  IRelayVoteAdapter public immutable VOTE_ADAPTER;

  /// @inheritdoc IRelayFactory
  /// @dev Read for `Roles.RELAY_DEPLOYER_ROLE` only: creation is the factory's single governed
  ///      action, so it borrows governance from the Voter instead of running an admin tree of its
  ///      own.
  address public immutable VOTER;

  /// @notice Every Relay this factory has created, in creation order.
  address[] internal _allRelays;

  /// @notice Whether an address is a Relay this factory created.
  /// @dev Its own mapping rather than a search over `_allRelays`, so a membership gate answers in
  ///      constant gas.
  mapping(address _relay => bool _created) internal _isRelay;

  /// @notice Restricts creation to holders of RELAY_DEPLOYER_ROLE on the Voter.
  /// @dev Reverts with NotAuthorized when the role check fails.
  modifier onlyRelayDeployer() {
    if (!IAccessControl(VOTER).hasRole(Roles.RELAY_DEPLOYER_ROLE, msg.sender)) revert NotAuthorized();
    _;
  }

  /// @notice Binds the escrow, the Voter holding the deployer role, the two implementations and
  ///         the modules every created Relay starts on.
  /// @param _votingEscrow VotingEscrow address.
  /// @param _voter Voter address whose RELAY_DEPLOYER_ROLE gates creation.
  /// @param _maxiImplementation MaxiRelay implementation address.
  /// @param _protocolImplementation ProtocolRelay implementation address.
  /// @param _vpm VoterPaymentsModule every created Relay starts on.
  /// @param _governor Governor every created Relay starts casting into.
  /// @param _voteAdapter Adapter every created Relay's casts start encoded by.
  constructor(
    IVotingEscrow _votingEscrow,
    address _voter,
    address _maxiImplementation,
    address _protocolImplementation,
    IVoterPaymentsModule _vpm,
    IGovernor _governor,
    IRelayVoteAdapter _voteAdapter
  ) {
    if (
      address(_votingEscrow) == address(0) || _voter == address(0) || _maxiImplementation == address(0)
        || _protocolImplementation == address(0) || address(_vpm) == address(0) || address(_governor) == address(0)
        || address(_voteAdapter) == address(0)
    ) revert ZeroAddress();
    // A clone of a codeless implementation initializes to nothing and strands the seed sAERO at its
    // predicted address; only the implementations are checked, the clones inherit their code.
    if (_maxiImplementation.code.length == 0 || _protocolImplementation.code.length == 0) {
      revert ImplementationNotAContract();
    }
    VOTING_ESCROW = _votingEscrow;
    VOTER = _voter;
    TOKEN = address(_votingEscrow.TOKEN());
    MAXI_IMPLEMENTATION = _maxiImplementation;
    PROTOCOL_IMPLEMENTATION = _protocolImplementation;
    VPM = _vpm;
    GOVERNOR = _governor;
    VOTE_ADAPTER = _voteAdapter;
  }

  /// @inheritdoc IRelayFactory
  function createMaxiRelay(CreateParams calldata _params)
    external
    onlyRelayDeployer
    returns (address _relay, uint256 _tokenId)
  {
    (_relay, _tokenId) = _create(MAXI_IMPLEMENTATION, _params, false);
    emit RelayCreated(_relay, _tokenId, IRelay.RelayType.Maxi);
  }

  /// @inheritdoc IRelayFactory
  function createProtocolRelay(
    CreateParams calldata _params,
    bool _startAsLevel2
  ) external onlyRelayDeployer returns (address _relay, uint256 _tokenId) {
    (_relay, _tokenId) = _create(PROTOCOL_IMPLEMENTATION, _params, _startAsLevel2);
    emit RelayCreated(_relay, _tokenId, _startAsLevel2 ? IRelay.RelayType.ProtocolL2 : IRelay.RelayType.ProtocolL1);
  }

  /// @inheritdoc IRelayFactory
  function isRelay(address _relay) external view returns (bool _created) {
    _created = _isRelay[_relay];
  }

  /// @inheritdoc IRelayFactory
  function allRelaysLength() external view returns (uint256 _length) {
    _length = _allRelays.length;
  }

  /// @inheritdoc IRelayFactory
  function allRelays(uint256 _start, uint256 _end) external view returns (address[] memory _relays) {
    uint256 _last = Math.min(_end, _allRelays.length);
    uint256 _first = Math.min(_start, _last);

    _relays = new address[](_last - _first);
    for (uint256 _i; _i < _relays.length; ++_i) {
      _relays[_i] = _allRelays[_first + _i];
    }
  }

  /// @notice Seeds the stake, clones the implementation at its deterministic address and
  ///         initializes it.
  /// @param _implementation Per-tier implementation to clone.
  /// @param _params Creation inputs.
  /// @param _startAsLevel2 True to start a Protocol Relay directly as L2 (always false on Maxi).
  /// @return _relay The deployed Relay clone (equals the predicted address).
  /// @return _tokenId The sAERO minted and bound to the Relay.
  /// @dev The salt is scoped to the caller so a third party cannot occupy someone else's chosen
  ///      salt; reusing a (caller, salt) pair on the same implementation reverts on the CREATE2
  ///      collision. The seed sAERO is transferred to the predicted address before the clone exists,
  ///      so `initialize`'s ownership check passes the moment the clone is created.
  function _create(
    address _implementation,
    CreateParams calldata _params,
    bool _startAsLevel2
  ) internal returns (address _relay, uint256 _tokenId) {
    _tokenId = _seedStake(_params);
    IRelay.RelayConfig memory _config = _params.config;
    _config.tokenId = _tokenId;
    // Keep the lock duration consistent with the seed stake type: 0 for a permanent stake, else the
    // staking weeks the seed was created with (so `_extendLock` renews the lock to the same duration).
    _config.lockWeeks = _params.isPermanent ? 0 : _params.stakingWeeks;

    bytes32 _salt = keccak256(abi.encodePacked(msg.sender, _params.salt));
    address _predicted = Clones.predictDeterministicAddress(_implementation, _salt, address(this));
    VOTING_ESCROW.transferFrom(address(this), _predicted, _tokenId);

    _relay = Clones.cloneDeterministic(_implementation, _salt);
    IRelay.InitParams memory _initParams = IRelay.InitParams({
      admin: _params.admin,
      keeper: _params.keeper,
      voter: _params.voter,
      compounder: _params.compounder,
      converter: _params.converter,
      bootstrapOwner: _params.bootstrapOwner,
      rewardToken: _params.rewardToken,
      entrypointVetoer: _params.entrypointVetoer,
      vpm: VPM,
      governor: GOVERNOR,
      voteAdapter: VOTE_ADAPTER,
      startAsLevel2: _startAsLevel2,
      ytTransferable: _params.ytTransferable,
      config: _config
    });
    IRelay(_relay).initialize(_initParams);

    // An inert clone would let `initialize` return success without running a single opcode, stranding
    // the seed sAERO in it. The satellites are the proof the body ran.
    if (address(IRelay(_relay).principalToken()) == address(0)) revert RelayInitializationFailed();

    _allRelays.push(_relay);
    _isRelay[_relay] = true;
  }

  /// @notice Pulls the seed TOKEN from the caller and mints the Relay's sAERO.
  /// @param _params Creation inputs carrying the seed amount and stake type.
  /// @return _tokenId The freshly minted sAERO.
  function _seedStake(CreateParams calldata _params) internal returns (uint256 _tokenId) {
    // No zero-seed guard: VotingEscrow.createStake rejects a zero amount.
    TOKEN.safeTransferFrom(msg.sender, address(this), _params.seedAmount);
    TOKEN.safeApprove(address(VOTING_ESCROW), _params.seedAmount);
    _tokenId = VOTING_ESCROW.createStake(_params.seedAmount, _params.stakingWeeks, _params.isPermanent);
  }
}
