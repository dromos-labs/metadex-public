// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {LeafAllocationLibrary} from 'V3/libraries/LeafAllocationLibrary.sol';
import {MIN_REDEEM_AMOUNT as _MIN_REDEEM_AMOUNT, ZERO_GAUGE as _ZERO_GAUGE} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {GuardedAccessControlEnumerable} from 'V3/access/GuardedAccessControlEnumerable.sol';
import {LeafVoterStorageBase} from 'V3/voter/LeafVoterStorageBase.sol';

/**
 * @title LeafVoter
 * @notice Per-chain Voter that turns allocations and chain reward rates into per-gauge emission allocations.
 * @dev Allocations arrive from root through the Leaf MessageOrchestrator, split across `applyChainAllocation`
 *      (budget + scalar) and `applyGaugeAllocations`, or locally from an operator through `allocateGauges`.
 * @dev The GaugeManager drives the gauge lifecycle through `registerGauge` and `activateGauge`.
 * @dev Inheritance order is load-bearing: `GuardedAccessControlEnumerable` takes slots 0 and 1, so the
 *      `LeafStorage` holder `LeafVoterStorageBase` declares starts at slot 2.
 */
contract LeafVoter is GuardedAccessControlEnumerable, ReentrancyGuardTransient, LeafVoterStorageBase {
  /*//////////////////////////////////////////////////////////////
                                CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILeafVoter
  address public constant ZERO_GAUGE = _ZERO_GAUGE;

  /// @inheritdoc ILeafVoter
  uint256 public constant MIN_REDEEM_AMOUNT = _MIN_REDEEM_AMOUNT;

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILeafVoter
  ILeafMessageOrchestrator public immutable ORCHESTRATOR;

  /// @inheritdoc ILeafVoter
  IReceiptToken public immutable RECEIPT_TOKEN;

  /// @inheritdoc ILeafVoter
  address public immutable EMISSIONS_HANDLER;

  /// @inheritdoc ILeafVoter
  IFactoryRegistry public immutable FACTORY_REGISTRY;

  /// @inheritdoc ILeafVoter
  address public immutable GAUGE_MANAGER;

  /*//////////////////////////////////////////////////////////////
                                MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restrict the caller to the Leaf MessageOrchestrator, reverting `NotMessageOrchestrator` otherwise.
   */
  modifier onlyMessageOrchestrator() {
    if (msg.sender != address(ORCHESTRATOR)) revert NotMessageOrchestrator();
    _;
  }

  /**
   * @notice Restrict the caller to the GaugeManager, reverting `NotGaugeManager` otherwise.
   */
  modifier onlyGaugeManager() {
    if (msg.sender != GAUGE_MANAGER) revert NotGaugeManager();
    _;
  }

  /**
   * @notice Restrict the entrypoint to an `Active` or `Sunset` chain, reverting `ChainNotActiveOrSunset` otherwise.
   * @dev The wind-down gate: `mintEmissions`, `redeem` and `allocateGauges` stay open while the chain winds
   *      down, so everything earned before the sunset stays claimable and redeemable and booked voting power
   *      can still exit through `DEALLOC_GAUGE`.
   */
  modifier chainIsActiveOrSunset() {
    ChainStatus _status = _leafStorage.chainStatus;
    if (_status != ChainStatus.Active && _status != ChainStatus.Sunset) revert ChainNotActiveOrSunset();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Set the wiring and the role hierarchy, anchor the chain accumulator and initialize the `ZERO_GAUGE`
   *         sink. Reverts `ZeroAddress` when any address argument is zero.
   * @dev Anchors `lastSettlement` and the sink's cursor at `block.timestamp` so the first walk starts there, not
   *      at the unix epoch. The sink is registered but never activated, so it never routes live emissions.
   * @dev `GOVERNANCE_ROLE` is its own admin and admins `CONFIG_ADMIN_ROLE`, `EMERGENCY_COUNCIL_ROLE` and
   *      `SEIZER_ROLE`; `CONFIG_ADMIN_ROLE` admins every other role. Nobody holds `DEFAULT_ADMIN_ROLE`.
   * @param _governor Initial `GOVERNANCE_ROLE` holder.
   * @param _configAdmin Initial `CONFIG_ADMIN_ROLE` holder.
   * @param _leafMessageOrchestrator Orchestrator allowed to call the cross-chain entrypoints and to dispatch.
   * @param _receiptToken Per-chain `ReceiptToken` burned on redeem.
   * @param _factoryRegistry FactoryRegistry queried for per-gauge emission caps.
   * @param _gaugeManager GaugeManager authorized for the gauge-lifecycle writes.
   * @param _allocationCooldown Minimum seconds between local allocations for a tokenId.
   * @param _maxGauges Per-chain cap on the gauges a tokenId may allocate to in a local allocation.
   * @param _adapterAuthority Initial `ADAPTER_CONFIG_ROLE` holder, may update the orchestrator's adapter config.
   * @param _emissionsHandler Handler bound to this voter for chain-specific emissions delivery.
   * @param _emergencyCouncil Initial `EMERGENCY_COUNCIL_ROLE` holder, allowed emergency gauge actions.
   */
  constructor(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    address _gaugeManager,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) {
    if (_governor == address(0)) revert ZeroAddress();
    if (_configAdmin == address(0)) revert ZeroAddress();
    if (_leafMessageOrchestrator == address(0)) revert ZeroAddress();
    if (_receiptToken == address(0)) revert ZeroAddress();
    if (_factoryRegistry == address(0)) revert ZeroAddress();
    if (_gaugeManager == address(0)) revert ZeroAddress();
    if (_adapterAuthority == address(0)) revert ZeroAddress();
    if (_emissionsHandler == address(0)) revert ZeroAddress();
    if (_emergencyCouncil == address(0)) revert ZeroAddress();

    ORCHESTRATOR = ILeafMessageOrchestrator(_leafMessageOrchestrator);
    RECEIPT_TOKEN = IReceiptToken(_receiptToken);
    EMISSIONS_HANDLER = _emissionsHandler;
    FACTORY_REGISTRY = IFactoryRegistry(_factoryRegistry);
    GAUGE_MANAGER = _gaugeManager;
    _leafStorage.allocationCooldown = _allocationCooldown;
    _leafStorage.maxGauges = _maxGauges;

    // The enum default is `None`, so the leaf has to be activated here.
    _leafStorage.chainStatus = ChainStatus.Active;

    uint48 _initTimestamp = uint48(block.timestamp);
    _leafStorage.lastSettlement = _initTimestamp;
    _leafStorage.gaugeStates[ZERO_GAUGE].lastSettlement = _initTimestamp;
    _leafStorage.gaugeStates[ZERO_GAUGE].point.ts = _initTimestamp;
    _leafStorage.gaugeStates[ZERO_GAUGE].isRegistered = true;
    // `DEALLOC_GAUGE` is never registered: it is the sentinel meaning "return this voting power to root".

    _setRoleAdmin(Roles.GOVERNANCE_ROLE, Roles.GOVERNANCE_ROLE);
    _setRoleAdmin(Roles.CONFIG_ADMIN_ROLE, Roles.GOVERNANCE_ROLE);
    _setRoleAdmin(Roles.VOTER_CONFIG_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.TOKEN_WHITELIST_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.ADAPTER_CONFIG_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.CHAIN_STATUS_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.FACTORY_REGISTRY_ADMIN_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.MODULE_ADMIN_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.EMERGENCY_COUNCIL_ROLE, Roles.GOVERNANCE_ROLE);
    // Checked by `TokenNFT.seize`, which reads this role from here. Left ungranted: governance appoints the
    // operator that confiscates an NFT whose holder published misleading metadata.
    _setRoleAdmin(Roles.SEIZER_ROLE, Roles.GOVERNANCE_ROLE);
    // Checked by the orchestrator's deallocation setters and `withdrawNative`. Both left ungranted here:
    // `CONFIG_ADMIN_ROLE` grants holders before deallocations are enabled.
    _setRoleAdmin(Roles.GAS_CONFIGURER_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.NATIVE_WITHDRAWER_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _grantRole(Roles.GOVERNANCE_ROLE, _governor);
    _grantRole(Roles.CONFIG_ADMIN_ROLE, _configAdmin);
    _grantRole(Roles.ADAPTER_CONFIG_ROLE, _adapterAuthority);
    _grantRole(Roles.EMERGENCY_COUNCIL_ROLE, _emergencyCouncil);
  }

  /*//////////////////////////////////////////////////////////////
                             MESSAGING LAYER
  //////////////////////////////////////////////////////////////*/

  /**
   * @inheritdoc ILeafVoter
   * @dev RootEmissionsHandler re-enters `redeem` on purpose; the low-severity reentrancy report is the
   *      post-callback event ordering.
   */
  // slither-disable-next-line reentrancy-events
  function mintEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external chainIsActiveOrSunset {
    if (_recipients.length != _amounts.length) revert ArrayLengthMismatch();

    // The library owns the accounting; the mint and the handler callback stay here with the immutables.
    uint128 _amountToMint = LeafAllocationLibrary.mintEmissions(_leafStorage, msg.sender, _amounts);
    if (_amountToMint == 0) return;

    RECEIPT_TOKEN.mint(EMISSIONS_HANDLER, _amountToMint);
    IEmissionsHandler(EMISSIONS_HANDLER).handleEmissions(_recipients, _amounts);

    emit EmissionsMinted(msg.sender, _recipients, _amounts);
  }

  /// @inheritdoc ILeafVoter
  function redeem(
    uint256 _amount,
    address _recipient,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant chainIsActiveOrSunset {
    // The library validates, burns and builds the payload; the dispatch below stays here.
    bytes memory _payload = LeafAllocationLibrary.redeem(_leafStorage, RECEIPT_TOKEN, _amount, _recipient);

    ORCHESTRATOR.dispatch{value: msg.value}({
      _msgType: IMessageOrchestrator.MessageType.Redeem,
      _payload: _payload,
      _gasLimit: _gasLimit,
      _refundRecipient: _refundRecipient,
      _fundFromPool: false
    });

    emit Redeemed(msg.sender, _recipient, _amount);
  }

  /// @inheritdoc ILeafVoter
  function claimRewards(
    uint256 _tokenId,
    address _recipient,
    FeeClaim[] calldata _feeClaims,
    IncentiveClaim[] calldata _incentiveClaims
  ) external nonReentrant {
    if (_recipient == address(0)) revert ZeroAddress();
    if (msg.sender != address(ORCHESTRATOR) && msg.sender != _leafStorage.tokenStates[_tokenId].operator) {
      revert NotAuthorized();
    }

    // The library owns the claim loops past the access gates.
    LeafAllocationLibrary.claimRewards(_tokenId, _recipient, _feeClaims, _incentiveClaims, FACTORY_REGISTRY);
  }

  /*//////////////////////////////////////////////////////////////
                          EXTERNAL ENTRIES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILeafVoter
  function applyChainAllocation(
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint256 _emissionsPerVP,
    bool _refreshEmissionsPerVP,
    bool _refreshShape,
    TokenSnapshot calldata _snapshot
  ) external onlyMessageOrchestrator {
    // The library owns everything past the access gate.
    LeafAllocationLibrary.applyChainAllocation({
      _leafStorage: _leafStorage,
      _tokenId: _tokenId,
      _allocationDelta: _allocationDelta,
      _emissionsPerVP: _emissionsPerVP,
      _refreshEmissionsPerVP: _refreshEmissionsPerVP,
      _refreshShape: _refreshShape,
      _snapshot: _snapshot
    });
  }

  /// @inheritdoc ILeafVoter
  function applyGaugeAllocations(
    uint256 _tokenId,
    uint48 _expiry,
    uint256 _emissionsPerVP,
    bool _refreshEmissionsPerVP,
    bool _refreshShape,
    TokenSnapshot calldata _newSnapshot,
    GaugeAllocation[] calldata _gauges
  ) external onlyMessageOrchestrator nonReentrant returns (CheckpointData[] memory _callParamsList) {
    // The library owns everything past the access gates; the send below stays here.
    uint128 _deallocAmount;
    (_callParamsList, _deallocAmount) = LeafAllocationLibrary.applyGaugeAllocations({
      _leafStorage: _leafStorage,
      _input: LeafAllocationLibrary.BridgedGaugeAllocationInput({
        tokenId: _tokenId,
        expiry: _expiry,
        emissionsPerVP: _emissionsPerVP,
        refreshEmissionsPerVP: _refreshEmissionsPerVP,
        refreshShape: _refreshShape
      }),
      _newSnapshot: _newSnapshot,
      _gauges: _gauges,
      _factoryRegistry: FACTORY_REGISTRY
    });

    // Last: every local effect is written and every checkpoint has run, so the control this hands to the
    // transport's refund recipient has nothing left to interfere with.
    if (_deallocAmount > 0) _dispatchDeallocation(_tokenId, _deallocAmount);
  }

  /// @inheritdoc ILeafVoter
  function setOperator(uint256 _tokenId, address _operator) external onlyMessageOrchestrator {
    _leafStorage.tokenStates[_tokenId].operator = _operator;
    emit OperatorSet(_tokenId, _operator);
  }

  /// @inheritdoc ILeafVoter
  function applyCooldownReduction(uint256 _tokenId, uint48 _reduction) external onlyMessageOrchestrator {
    // Additive, so order does not matter and no nonce gate is needed. The total clamps at
    // `maxAccumulatedCooldownReduction`, zero by default, so reductions stay off until governance opts in.
    // Summed in uint256 so an extreme total clamps instead of reverting on every redelivery.
    uint256 _accrued = uint256(_leafStorage.accumulatedCooldownReduction[_tokenId]) + _reduction;
    uint48 _maxAccumulated = _leafStorage.maxAccumulatedCooldownReduction;
    uint48 _accumulated = _accrued > _maxAccumulated ? _maxAccumulated : uint48(_accrued);
    _leafStorage.accumulatedCooldownReduction[_tokenId] = _accumulated;
    emit CooldownReductionApplied(_tokenId, _reduction, _accumulated);
  }

  /// @inheritdoc ILeafVoter
  function applyEmergencyDeallocation(uint256 _tokenId, uint128 _amount) external onlyMessageOrchestrator nonReentrant {
    // The library owns everything past the access gates.
    LeafAllocationLibrary.applyEmergencyDeallocation(_leafStorage, _tokenId, _amount, FACTORY_REGISTRY);
  }

  /// @inheritdoc ILeafVoter
  function allocateGauges(
    uint256 _tokenId,
    GaugeAllocation[] calldata _gauges
  ) external payable nonReentrant chainIsActiveOrSunset {
    // 0. Local-path master switch, checked before the operator check. Off until governance opens it, so a leaf
    //    ships with the bridged pipeline as the only way to move its budget.
    if (!_leafStorage.localVotingEnabled) revert LocalVotingDisabled();

    // 1. Only the registered operator may redistribute the chain budget.
    if (msg.sender != _leafStorage.tokenStates[_tokenId].operator) revert NotOperator();

    // 2. The library owns everything past the access gates; the send below stays here.
    uint128 _deallocAmount = LeafAllocationLibrary.allocateGauges(_leafStorage, _tokenId, _gauges, FACTORY_REGISTRY);

    // A `DEALLOC_GAUGE` entry funds a leaf->root return message with the caller's whole value, and the
    // orchestrator rejects an underfunded return. Without the sentinel that value would be trapped here.
    if (_deallocAmount == 0 && msg.value != 0) revert UnexpectedValue();

    // Last: every local effect is written and every checkpoint has run, so the control this hands to the
    // transport's refund recipient has nothing left to interfere with.
    if (_deallocAmount > 0) _dispatchDeallocation(_tokenId, _deallocAmount);
  }

  /// @inheritdoc ILeafVoter
  function registerGauge(address _gauge, bool _activate) external onlyGaugeManager {
    // The library owns everything past the access gate.
    LeafAllocationLibrary.registerGauge(_leafStorage, _gauge, _activate);
  }

  /// @inheritdoc ILeafVoter
  function activateGauge(address _gauge) external onlyGaugeManager nonReentrant {
    // The library owns everything past the access gates.
    LeafAllocationLibrary.activateGauge(_leafStorage, _gauge, FACTORY_REGISTRY);
  }

  /// @inheritdoc ILeafVoter
  function settleGauge(address _gauge) external nonReentrant returns (uint256 _cumulativeRewardShare) {
    // The library owns everything past the reentrancy gate.
    _cumulativeRewardShare = LeafAllocationLibrary.settleGauge(_leafStorage, _gauge, FACTORY_REGISTRY);
  }

  /// @inheritdoc ILeafVoter
  function forfeitEmissions(uint128 _amount) external nonReentrant {
    // The library owns everything past the reentrancy gate.
    LeafAllocationLibrary.forfeitEmissions(_leafStorage, msg.sender, _amount);
  }

  /*//////////////////////////////////////////////////////////////
                                  CONFIG
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILeafVoter
  function setCanVoteForZeroCapGauges(uint256 _tokenId, bool _allowed) external onlyRole(Roles.TOKEN_WHITELIST_ROLE) {
    _leafStorage.tokenStates[_tokenId].canVoteForZeroCapGauges = _allowed;
    emit CanVoteForZeroCapGaugesSet(_tokenId, _allowed);
  }

  /// @inheritdoc ILeafVoter
  function setLocalVotingEnabled(bool _enabled) external onlyRole(Roles.VOTER_CONFIG_ROLE) {
    _leafStorage.localVotingEnabled = _enabled;
    emit LocalVotingEnabledSet(_enabled);
  }

  /// @inheritdoc ILeafVoter
  function setAllocationCooldown(uint48 _allocationCooldown) external onlyRole(Roles.VOTER_CONFIG_ROLE) {
    _leafStorage.allocationCooldown = _allocationCooldown;
    emit AllocationCooldownSet(_allocationCooldown);
  }

  /// @inheritdoc ILeafVoter
  function setMaxAccumulatedCooldownReduction(uint48 _maxAccumulatedCooldownReduction)
    external
    onlyRole(Roles.VOTER_CONFIG_ROLE)
  {
    _leafStorage.maxAccumulatedCooldownReduction = _maxAccumulatedCooldownReduction;
    emit MaxAccumulatedCooldownReductionSet(_maxAccumulatedCooldownReduction);
  }

  /// @inheritdoc ILeafVoter
  function setMaxGauges(uint256 _maxGauges) external onlyRole(Roles.VOTER_CONFIG_ROLE) {
    _leafStorage.maxGauges = _maxGauges;
    emit MaxGaugesSet(_maxGauges);
  }

  /// @inheritdoc ILeafVoter
  function setChainStatus(ChainStatus _status) external onlyRole(Roles.CHAIN_STATUS_ROLE) {
    if (_status == ChainStatus.None) revert InvalidStatus();
    ChainStatus _currentStatus = _leafStorage.chainStatus;
    if (_currentStatus == _status) revert ChainStatusUnchanged();
    // Same transition matrix as root. Suspended only exits to Active or Sunset, so the zeroed rate can never
    // sit behind a status that resumes accounting root-side. Sunset only exits to Suspended, the mandatory
    // first leg of a reactivation (see `IVoter.setChainStatus`).
    if (_currentStatus == ChainStatus.Suspended && _status == ChainStatus.Paused) {
      revert InvalidChainStatusTransition();
    }
    if (_currentStatus == ChainStatus.Sunset && _status != ChainStatus.Suspended) {
      revert InvalidChainStatusTransition();
    }

    // The library settles at the old rate, stores the status and masks the scalar.
    LeafAllocationLibrary.applyChainStatus(_leafStorage, _status);

    emit ChainStatusSet(_status);
  }

  /*//////////////////////////////////////////////////////////////
                                  VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILeafVoter
  function operator(uint256 _tokenId) external view returns (address _operator) {
    _operator = _leafStorage.tokenStates[_tokenId].operator;
  }

  /// @inheritdoc ILeafVoter
  function isActivated(address _gauge) external view returns (bool _isActivated) {
    _isActivated = _leafStorage.gaugeStates[_gauge].isActivated;
  }

  /// @inheritdoc ILeafVoter
  function projectedCumulativeRewardShare(address _gauge) external view returns (uint256 _cumulativeRewardShare) {
    _cumulativeRewardShare =
      LeafAllocationLibrary.projectedCumulativeRewardShare(_leafStorage, _gauge, FACTORY_REGISTRY);
  }

  /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Dispatch a deallocation return to root for `_amount` of `_tokenId`'s voting power.
   * @dev Picks the funding source; the orchestrator owns the transport quote, the gas budget and the pre-funding,
   *      so `_gasLimit` is zero.
   * @dev Only the remote path is gated by `ORCHESTRATOR`, so `msg.sender == ORCHESTRATOR` selects the pool. Any
   *      other caller is local `allocateGauges`: its whole `msg.value` is forwarded and the excess refunded to it.
   * @param _tokenId Token whose voting power is returned to root.
   * @param _amount Voting power deallocated.
   */
  function _dispatchDeallocation(uint256 _tokenId, uint128 _amount) internal {
    DeallocationMessageBody memory _body = DeallocationMessageBody({tokenId: _tokenId, amount: _amount});
    ORCHESTRATOR.dispatch{value: msg.value}({
      _msgType: IMessageOrchestrator.MessageType.Deallocate,
      _payload: abi.encode(_body),
      _gasLimit: 0,
      _refundRecipient: msg.sender,
      _fundFromPool: msg.sender == address(ORCHESTRATOR)
    });
    emit Deallocated(_tokenId, _amount);
  }
}
