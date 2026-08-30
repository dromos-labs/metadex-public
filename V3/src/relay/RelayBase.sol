// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {Ownable} from '@solady/auth/Ownable.sol';
import {OwnableRoles} from '@solady/auth/OwnableRoles.sol';

import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';
import {AllocationLib} from 'V3/relay/libraries/AllocationLib.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';
import {QueueLib} from 'V3/relay/libraries/QueueLib.sol';
import {RelayConfigLib} from 'V3/relay/libraries/RelayConfigLib.sol';
import {RelayGovernanceLib} from 'V3/relay/libraries/RelayGovernanceLib.sol';
import {RelayInitLib} from 'V3/relay/libraries/RelayInitLib.sol';
import {RelayRewardsLib} from 'V3/relay/libraries/RelayRewardsLib.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken, IRelayTokenHook} from 'V3/interfaces/relay/IRelayToken.sol';
import {IRelayTokenVotes} from 'V3/interfaces/relay/IRelayTokenVotes.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {RelayRoles} from 'V3/relay/RelayRoles.sol';

/**
 * @title  RelayBase (abstract)
 * @notice Tier-agnostic Relay core. Pools depositors' sAERO voting weight into one Relay-owned
 *         sAERO and issues a satellite token pair against it: PT is the priced position that
 *         carries the withdraw right and never moves holder-to-holder; YT is the balance the
 *         reward accumulator reads. The pair mints and burns in equal units.
 * @dev    Tiers specialize through the virtual seams (`_authorizeTransfer`, `_authorizeDeposit`,
 *         `_canGrowRegistry`, `relayType`, `_extendLock`). Heavy bodies live in external
 *         delegatecalled libraries, keeping the contract under EIP-170.
 */
abstract contract RelayBase is OwnableRoles, ReentrancyGuardTransient, RelayRoles, IRelay, IRelayTokenHook {
  using SafeCastLibrary for uint256;
  using QueueLib for DenseQueue.Queue;
  using EnumerableSet for EnumerableSet.AddressSet;

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    CONSTANTS                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  uint256 public constant MINT_SENTINEL = type(uint256).max;

  /// @notice The Voter's idle chain id: weight parked there is free to fund exits or allocations.
  uint256 internal constant _CHAIN0 = 0;

  /// @inheritdoc IRelay
  uint256 public constant MAX_REWARD_TOKENS = 10;

  /// @inheritdoc IRelay
  uint256 public constant ACC_SCALE = 1e18;

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    IMMUTABLES                                      __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  IVotingEscrow public immutable VOTING_ESCROW;

  /// @inheritdoc IRelay
  IVoter public immutable VOTER;

  /// @inheritdoc IRelay
  address public immutable TOKEN;

  /// @inheritdoc IRelay
  address public immutable PRINCIPAL_TOKEN_IMPLEMENTATION;

  /// @inheritdoc IRelay
  address public immutable YIELD_TOKEN_IMPLEMENTATION;

  /// @inheritdoc IRelay
  address public immutable WRAPPED_NATIVE;

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     STORAGE                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Set by the implementation's constructor, so `initialize` only runs on clones.
  bool internal _initialized;

  /// @notice Relay configuration.
  RelayConfig internal _relayConfig;

  /// @inheritdoc IRelay
  IRelayToken public principalToken;

  /// @inheritdoc IRelay
  IRelayToken public yieldToken;

  /// @inheritdoc IRelay
  mapping(uint256 id => PendingDeposit deposit) public pendingDeposits;

  /// @inheritdoc IRelay
  DenseQueue.Queue public depositList;

  /// @inheritdoc IRelay
  uint256 public pendingDepositWeight;

  /// @inheritdoc IRelay
  uint256 public totalBacking;

  /// @inheritdoc IRelay
  IVoterPaymentsModule public VPM;

  /// @inheritdoc IRelay
  IGovernor public governor;

  /// @inheritdoc IRelay
  IRelayVoteAdapter public voteAdapter;

  /// @inheritdoc IRelay
  mapping(address token => uint256 accounted) public accountedBalance;

  /// @notice Reward tokens the accumulator settles; its length bounds the gas of every share move.
  EnumerableSet.AddressSet private _rewardTokenSet;

  /// @inheritdoc IRelay
  mapping(address token => uint256 index) public rewardIndex;

  /// @inheritdoc IRelay
  mapping(address holder => mapping(address token => uint256 checkpoint)) public userCheckpoint;

  /// @inheritdoc IRelay
  mapping(address holder => mapping(address token => uint256 pending)) public pendingReward;

  /// @notice Registered exits awaiting drain, by id; read through `withdrawals`, which rebuilds
  ///         the mint sentinel the entry only stores as a flag.
  mapping(uint256 id => WithdrawEntry entry) internal _withdrawals;

  /// @inheritdoc IRelay
  DenseQueue.Queue public withdrawQueue;

  /// @inheritdoc IRelay
  uint256 public pendingWithdrawalShares;

  /// @inheritdoc IRelay
  mapping(address holder => uint256 shares) public escrowedShares;

  /// @inheritdoc IRelay
  bool public closed;

  /// @inheritdoc IRelay
  mapping(uint256 chainId => address recipient) public leafRecipient;

  /// @inheritdoc IRelay
  mapping(uint256 chainId => PendingRecipient pending) public pendingLeafRecipient;

  /// @inheritdoc IRelay
  mapping(uint256 chainId => PendingOperator pending) public pendingOperator;

  /// @inheritdoc IRelay
  mapping(address governor => mapping(uint256 proposalId => mapping(address holder => uint256 used))) public
    usedGovernanceWeight;

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                  INITIALIZATION                                    __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Binds the protocol-wide dependencies shared by every Relay.
  /// @param _votingEscrow VotingEscrow address.
  /// @param _voter Voter address.
  /// @param _principalTokenImplementation Checkpointed RelayToken implementation cloned as the PT.
  /// @param _yieldTokenImplementation Plain RelayToken implementation cloned as the YT.
  /// @param _wrappedNative Wrapped native token every native inflow is wrapped into.
  /// @dev Marks the implementation itself initialized, so `initialize` only runs on clones.
  /// @dev The satellite implementations are checked for code, not just for zero: an EIP-1167 clone of
  ///      a codeless address answers every call with success and no data, so its `initialize` and its
  ///      bootstrap mint would both appear to run while nothing exists behind the clone.
  constructor(
    IVotingEscrow _votingEscrow,
    IVoter _voter,
    address _principalTokenImplementation,
    address _yieldTokenImplementation,
    address _wrappedNative
  ) {
    if (address(_votingEscrow) == address(0) || address(_voter) == address(0) || _wrappedNative == address(0)) {
      _revert(uint32(ZeroAddress.selector));
    }
    if (_principalTokenImplementation.code.length == 0 || _yieldTokenImplementation.code.length == 0) {
      _revert(uint32(ImplementationNotAContract.selector));
    }

    VOTING_ESCROW = _votingEscrow;
    VOTER = _voter;
    TOKEN = address(_votingEscrow.TOKEN());
    PRINCIPAL_TOKEN_IMPLEMENTATION = _principalTokenImplementation;
    YIELD_TOKEN_IMPLEMENTATION = _yieldTokenImplementation;
    WRAPPED_NATIVE = _wrappedNative;

    _initialized = true;
  }

  /// @notice Wraps every native inflow into the wrapped native token.
  /// @dev A reward claim that unwraps its payout pays the Relay in native. The Relay accounts
  ///      ERC-20 balances only and never forwards its own balance, so an accepted native inflow
  ///      that stayed native would be stranded. Wrapped, it is a plain reward-token balance the
  ///      harvest lane already drains.
  receive() external payable {
    IWETH(WRAPPED_NATIVE).deposit{value: msg.value}();
  }

  /// @inheritdoc IRelay
  /// @dev The admin becomes the owner, the single seat that manages every role bit; tier-specific
  ///      wiring runs through the `_initializeTier` seam.
  function initialize(InitParams memory _params) external {
    if (_initialized) _revert(uint32(AlreadyInitialized.selector));
    _initialized = true;

    // Zero-checked in RelayInitLib.setUp.
    VPM = _params.vpm;
    governor = _params.governor;
    voteAdapter = _params.voteAdapter;

    // setUp returns the seed stake, the only time totalBacking is written from an outside reading;
    // from here on it only moves through the Relay's own paths.
    (uint256 _seed, address _principalToken, address _yieldToken) = RelayInitLib.setUp(
      _params,
      _relayConfig,
      _rewardTokenSet,
      RelayInitLib.SetUpContext({
        votingEscrow: VOTING_ESCROW,
        vpm: address(VPM),
        token: TOKEN,
        principalTokenImplementation: PRINCIPAL_TOKEN_IMPLEMENTATION,
        yieldTokenImplementation: YIELD_TOKEN_IMPLEMENTATION
      })
    );
    totalBacking = _seed;

    // Bind the satellites before anything mints: `onRelayTokenTransfer` authenticates its caller
    // against these two addresses.
    principalToken = IRelayToken(_principalToken);
    yieldToken = IRelayToken(_yieldToken);
    emit RelayTokensDeployed(_principalToken, _yieldToken);

    // The owner manages every role bit. COMPOUNDER and CONVERTER are refused by the public
    // grant and revoke paths, so both stay fixed after initialization on every tier that adds
    // no flow of its own (ProtocolRelay L2 attaches them through the timelocked proposals).
    _initializeOwner(_params.admin);
    _grantRoles(_params.keeper, KEEPER);

    if (_params.compounder != address(0)) _grantRoles(_params.compounder, COMPOUNDER);
    if (_params.converter != address(0)) _grantRoles(_params.converter, CONVERTER);
    if (_params.voter != address(0)) _grantRoles(_params.voter, VOTER_ROLE);

    _initializeTier(_params);

    // Mint the pair 1:1 against the seed so the genesis price per share is exactly 1. The pair
    // goes to a recoverable owner instead of dead shares: totalBacking is an internal counter,
    // which already blocks donation inflation.
    IRelayToken(_principalToken).mint(_params.bootstrapOwner, _seed);
    IRelayToken(_yieldToken).mint(_params.bootstrapOwner, _seed);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    TOKEN HOOK                                      __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelayTokenHook
  /// @dev Not `nonReentrant`: the satellites fire this hook during the Relay's own guarded
  ///      mint/burn flows, where the transient guard would revert on itself; its only effect is
  ///      the reward settle. PT fires return early — the paired YT operation in the same frame
  ///      runs the settle. Burns clear the escrow before the satellite fires the hook, so draining
  ///      a fully escrowed holder never fails the escrow check.
  function onRelayTokenTransfer(address _from, address _to, uint256 _amount) external {
    address _principalToken = address(principalToken);
    if (msg.sender != _principalToken && msg.sender != address(yieldToken)) _revert(uint32(NotAuthorized.selector));

    if (msg.sender == _principalToken) return;

    // Tier seam: Protocol requires both ends allow-listed.
    if (_from != address(0) && _to != address(0)) _authorizeTransfer(_from, _to);

    // The escrow-cover check and the settle against pre-change balances live in RelayRewardsLib.
    RelayRewardsLib.settleTransfer(
      _rewardTokenSet,
      pendingReward,
      userCheckpoint,
      rewardIndex,
      escrowedShares,
      RelayRewardsLib.SettleContext({
        yieldToken: yieldToken, from: _from, to: _to, amount: _amount, accScale: ACC_SCALE, closed: closed
      })
    );
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     DEPOSIT                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  function requestDeposit(uint256 _tokenId, uint256 _amount) external nonReentrant {
    _requestDeposit(_tokenId, _amount, VOTING_ESCROW.ownerOf(_tokenId));
  }

  /// @inheritdoc IRelay
  function requestDeposit(uint256 _tokenId, uint256 _amount, address _recipient) external nonReentrant {
    _requestDeposit(_tokenId, _amount, _recipient);
  }

  // The processing calls delegatecall into QueueLib and only reach protocol contracts (the
  // satellites): the counter write-back after them is not a reentrancy window.
  // slither-disable-start reentrancy-no-eth
  /// @inheritdoc IRelay
  function processPending(uint256 _maxEntries) external nonReentrant onlyRoles(KEEPER) {
    _applyDepositResult(QueueLib.processDeposits(depositList, pendingDeposits, _depositContext(_maxEntries, 0)));
  }

  /// @inheritdoc IRelay
  function processOverduePending(uint256[] calldata _ids) external nonReentrant {
    _applyDepositResult(
      QueueLib.processOverdueDeposits(depositList, pendingDeposits, _ids, _depositContext(0, _relayConfig.keeperWindow))
    );
  }

  // slither-disable-end reentrancy-no-eth

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     WITHDRAW                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  function registerOnWithdrawQueue(uint256 _shares, uint256 _destination) external nonReentrant {
    // The delegatecall preserves `msg.sender` as the registering holder.
    QueueLib.registerExit(
      withdrawQueue,
      _withdrawals,
      escrowedShares,
      QueueLib.RegisterExitContext({
        principalToken: principalToken,
        yieldToken: yieldToken,
        shares: _shares,
        destination: _destination,
        relayTokenId: _relayConfig.tokenId,
        minWithdrawal: _relayConfig.minWithdrawal,
        closed: closed
      })
    );
    pendingWithdrawalShares += _shares;
  }

  /// @inheritdoc IRelay
  function processWithdrawals(uint256 _maxEntries) external nonReentrant {
    _processWithdrawals(_maxEntries);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    ALLOCATION                                      __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  function allocate(
    IVoter.ChainAllocationDispatch[] calldata _chainDispatches,
    IVoter.GaugeAllocationDispatch[] calldata _gaugeDispatches,
    address _refundRecipient
  ) external payable nonReentrant onlyRoles(VOTER_ROLE) {
    if (closed) _revert(uint32(RelayClosed.selector));
    if (_chainDispatches.length == 0 && _gaugeDispatches.length == 0) _revert(uint32(EmptyAllocation.selector));

    _extendLock();

    // msg.value survives the delegatecall and pays the Voter.
    AllocationLib.allocate(VOTER, _relayConfig.tokenId, _chainDispatches, _gaugeDispatches, _refundRecipient);

    emit Allocated(msg.sender);
  }

  /// @inheritdoc IRelay
  function extendLock() external nonReentrant {
    _extendLock();
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     CLOSURE                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  function close() external nonReentrant {
    if (closed) _revert(uint32(RelayClosed.selector));
    if (!hasAnyRole(msg.sender, KEEPER)) {
      QueueLib.requireUncoveredHead(withdrawQueue, _withdrawals, VOTER, _relayConfig.tokenId);
    }

    closed = true;
    emit Closed(msg.sender);
  }

  /// @inheritdoc IRelay
  /// @dev msg.value survives the delegatecall and pays the Voter.
  function evacuate(uint256 _chainId, uint256 _gasLimit, address _refundRecipient) external payable nonReentrant {
    if (!closed) _revert(uint32(RelayNotClosed.selector));
    AllocationLib.evacuate(VOTER, _relayConfig.tokenId, _chainId, _gasLimit, _refundRecipient);

    emit Evacuated(msg.sender);
  }

  /// @inheritdoc IRelay
  function emergencyDeallocate(
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant {
    if (!closed && !hasAnyRole(msg.sender, KEEPER)) _revert(uint32(NotAuthorized.selector));
    AllocationLib.emergencyDeallocate(VOTER, _relayConfig.tokenId, _chainId, _gasLimit, _refundRecipient);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    GOVERNANCE                                      __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  /// @dev The delegatecall is what lets the cast reach the Governor from this address: the
  ///      Governor credits weight to the caller-sAERO pair. The consumption ledger stays in this
  ///      contract's storage, so relinking the library cannot reset it, and is keyed by Governor,
  ///      so a rotation cannot inherit a colliding proposal id's spend.
  function expressVote(
    uint256 _proposalId,
    uint8 _support,
    bytes calldata _params,
    string calldata _reason
  ) external nonReentrant {
    RelayGovernanceLib.expressVote(
      usedGovernanceWeight,
      RelayGovernanceLib.Context({
        relay: address(this),
        principalToken: IRelayTokenVotes(address(principalToken)),
        governor: governor,
        voteAdapter: voteAdapter,
        votingEscrow: VOTING_ESCROW,
        relayTokenId: _relayConfig.tokenId
      }),
      _proposalId,
      _support,
      _params,
      _reason
    );
  }

  /// @inheritdoc IRelay
  /// @dev Owner-gated, unlike the KEEPER-gated VPM rotation: no on-chain registry bounds the valid
  ///      Governors, so the choice sits with the seat that owns the votes.
  function setGovernor(IGovernor _governor, IRelayVoteAdapter _voteAdapter) external onlyOwner {
    governor = _governor;
    voteAdapter = _voteAdapter;
    RelayConfigLib.rotateGovernor(address(_governor), address(_voteAdapter));
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                      CONFIG                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  /// @dev The escrow's approval holds one address, so pointing it at the new module takes the
  ///      spending right off the old one in the same call. The keeper picks which authorized
  ///      module this Relay uses, never whether a module is authorized at all.
  function setVoterPaymentsModule(IVoterPaymentsModule _vpm) external nonReentrant onlyRoles(KEEPER) {
    if (VPM == _vpm) return;
    VPM = _vpm;
    RelayConfigLib.rotateModule(VOTING_ESCROW, address(_vpm), _relayConfig.tokenId);
  }

  /// @inheritdoc IRelay
  /// @dev The satellite tokens keep their genesis names; a rename never touches the ERC-20 surface.
  function setName(string calldata _name) external onlyOwner {
    RelayConfigLib.setName(_relayConfig, _name);
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     REWARDS                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  function pull(address _token, uint256 _amount) external nonReentrant {
    if (!hasAnyRole(msg.sender, COMPOUNDER | CONVERTER)) _revert(uint32(NotAuthorized.selector));
    RelayRewardsLib.pull(accountedBalance, _token, _amount);
  }

  /// @inheritdoc IRelay
  function compound(uint256 _amount) external nonReentrant onlyRoles(COMPOUNDER) {
    // Roll the lock first: the escrow refuses to grow an expired custom-period stake, and on a
    // closed Relay this is the only refresh that still runs on its own.
    _extendLock();

    // CEI: the backing grows before the library touches the escrow. The library also rejects a
    // compound with no principal outstanding, which would leave the added backing without a claimant.
    totalBacking += _amount;
    RelayRewardsLib.compound(accountedBalance, VOTING_ESCROW, principalToken, TOKEN, _relayConfig.tokenId, _amount);
  }

  /// @inheritdoc IRelay
  /// @dev Cannot underflow: `totalBacking + pendingDepositWeight` accounts for every unit the
  ///      Relay itself staked, so the staked amount only exceeds it by donations.
  function processDonations() external nonReentrant onlyRoles(KEEPER) {
    totalBacking += RelayRewardsLib.processDonations(
      VOTING_ESCROW, _relayConfig.tokenId, totalBacking, pendingDepositWeight
    );
  }

  /// @inheritdoc IRelay
  function addRewardToken(address _token) external onlyRoles(KEEPER) {
    RelayRewardsLib.addRewardToken(_rewardTokenSet, _token, _canGrowRegistry(), MAX_REWARD_TOKENS);
  }

  /// @inheritdoc IRelay
  function removeRewardToken(address _token) external onlyRoles(KEEPER) {
    RelayRewardsLib.removeRewardToken(_rewardTokenSet, rewardIndex, _token);
  }

  /// @inheritdoc IRelay
  function proposeLeafRecipient(uint256 _chainId, address _recipient) external onlyOwner {
    RelayConfigLib.proposeLeafRecipient(pendingLeafRecipient, _chainId, _recipient, _relayConfig.entrypointTimelock);
  }

  /// @inheritdoc IRelay
  function executeLeafRecipient(uint256 _chainId) external onlyOwner {
    RelayConfigLib.executeLeafRecipient(leafRecipient, pendingLeafRecipient, _chainId, _relayConfig.entrypointTimelock);
  }

  /// @inheritdoc IRelay
  function clearLeafRecipient(uint256 _chainId) external onlyOwner {
    RelayConfigLib.clearLeafRecipient(leafRecipient, pendingLeafRecipient, _chainId);
  }

  /// @inheritdoc IRelay
  function proposeOperator(uint256 _chainId, address _operator) external onlyOwner {
    RelayConfigLib.proposeOperator(pendingOperator, _chainId, _operator, _relayConfig);
  }

  /// @inheritdoc IRelay
  /// @dev msg.value survives the delegatecall and pays the Voter.
  function executeOperator(
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant onlyOwner {
    RelayConfigLib.executeOperator(pendingOperator, VOTER, _chainId, _gasLimit, _refundRecipient, _relayConfig);
  }

  /// @inheritdoc IRelay
  /// @dev Kept off `RelayConfigLib`: a delete and an event are cheaper inline than the stub that
  ///      would call out to them.
  function cancelOperator(uint256 _chainId) external onlyOwner {
    delete pendingOperator[_chainId];
    emit OperatorProposalCancelled(_chainId);
  }

  /// @inheritdoc IRelay
  /// @dev msg.value survives the delegatecall and pays the Voter.
  function revokeOperator(
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant onlyOwner {
    RelayConfigLib.revokeOperator(pendingOperator, VOTER, _chainId, _gasLimit, _refundRecipient, _relayConfig);
  }

  /// @inheritdoc IRelay
  function notifyReward(address _token, uint256 _amount) external nonReentrant onlyRoles(CONVERTER) {
    // Rewards accrue to the yield token, so its supply is the accumulator denominator.
    RelayRewardsLib.notifyReward(
      _rewardTokenSet, accountedBalance, rewardIndex, _token, _amount, yieldToken.totalSupply(), ACC_SCALE
    );
  }

  /// @inheritdoc IRelay
  function claim(address _token, address _to) external nonReentrant returns (uint256 _amount) {
    // The delegatecall preserves `msg.sender` as the claiming holder.
    _amount = RelayRewardsLib.claimSettled(
      _rewardTokenSet, pendingReward, userCheckpoint, rewardIndex, accountedBalance, yieldToken, _token, _to, ACC_SCALE
    );
  }

  /// @inheritdoc IRelay
  function claimRewards(
    uint256 _chainId,
    uint256 _gasLimit,
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims
  ) external payable nonReentrant {
    RelayRewardsLib.claimRewards(
      leafRecipient, VOTER, _relayConfig.tokenId, _chainId, _gasLimit, _feeClaims, _incentiveClaims
    );
  }

  /// @inheritdoc IRelay
  function claimable(address _holder, address _token) external view returns (uint256 _amount) {
    uint256 _delta = rewardIndex[_token] - userCheckpoint[_holder][_token];
    _amount = pendingReward[_holder][_token] + (yieldToken.balanceOf(_holder) * _delta) / ACC_SCALE;
  }

  /// @inheritdoc IRelay
  function isRewardToken(address _token) external view returns (bool _registered) {
    _registered = _rewardTokenSet.contains(_token);
  }

  /// @inheritdoc IRelay
  function rewardTokens() external view returns (address[] memory _tokens) {
    _tokens = _rewardTokenSet.values();
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                      VIEWS                                         __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelay
  function relayType() external view virtual returns (RelayType _relayType);

  /// @inheritdoc IRelay
  function relayConfig() external view returns (RelayConfig memory _config) {
    _config = _relayConfig;
  }

  /// @inheritdoc IRelay
  function withdrawals(uint256 _id)
    external
    view
    returns (address _holder, uint48 _registeredAt, uint256 _shares, uint256 _destination)
  {
    WithdrawEntry storage _entry = _withdrawals[_id];
    return (_entry.holder, _entry.registeredAt, _entry.shares, _entry.mintFresh ? MINT_SENTINEL : _entry.destination);
  }

  /// @inheritdoc OwnableRoles
  /// @dev The restricted bits never move through here. A raw entrypoint grant would bypass the
  ///      timelocked attachment flow (and would attach a fund-pulling entrypoint on a tier with no
  ///      flow at all), and an owner that could seat the vetoer would hold both sides of the veto.
  function grantRoles(address _user, uint256 _roles) public payable virtual override {
    if (_roles & (COMPOUNDER | CONVERTER | ENTRYPOINT_VETOER) != 0) _revert(uint32(EntrypointRoleRestricted.selector));
    super.grantRoles(_user, _roles);
  }

  /// @inheritdoc OwnableRoles
  /// @dev Mirrors `grantRoles`: an entrypoint attachment is immutable outside the tier's own flow,
  ///      and the vetoer cannot be unseated by the party its veto watches.
  function revokeRoles(address _user, uint256 _roles) public payable virtual override {
    if (_roles & (COMPOUNDER | CONVERTER | ENTRYPOINT_VETOER) != 0) _revert(uint32(EntrypointRoleRestricted.selector));
    super.revokeRoles(_user, _roles);
  }

  /// @inheritdoc OwnableRoles
  function renounceRoles(uint256 _roles) public payable virtual override {
    if (_roles & (COMPOUNDER | CONVERTER | ENTRYPOINT_VETOER) != 0) _revert(uint32(EntrypointRoleRestricted.selector));
    super.renounceRoles(_roles);
  }

  /// @inheritdoc Ownable
  /// @dev Disabled: every owner-gated path would freeze with no way back. Handing the Relay over
  ///      is `transferOwnership` (or the two-step handover), never a renounce.
  function renounceOwnership() public payable virtual override {
    _revert(uint32(OwnershipRenounceDisabled.selector));
  }

  /// @inheritdoc IRelay
  function assetsBacking() public view returns (uint256 _backing) {
    _backing = totalBacking;
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    INTERNALS                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Tier seam: tier-specific initialization on top of the base wiring.
  /// @param _params The initialization inputs.
  /// @dev The base rejects `startAsLevel2`; only the Protocol tier overrides this.
  function _initializeTier(InitParams memory _params) internal virtual {
    if (_params.startAsLevel2) _revert(uint32(NotPromotable.selector));
    // Entrypoints are fixed at initialization on this tier, so a Relay named without any could
    // never process the rewards it receives.
    if (_params.compounder == address(0) && _params.converter == address(0)) {
      _revert(uint32(MissingEntrypoint.selector));
    }
  }

  /// @notice Refreshes the Relay sAERO's lock; a no-op on permanent Relays (`lockWeeks == 0`).
  /// @dev The rule lives in `AllocationLib.extendLock`: decoding the escrow's `StakedBalance` here
  ///      costs the Protocol tier ~550 bytes it cannot spare under EIP-170. Still a virtual seam, so
  ///      a custom-period tier can replace the whole rule.
  function _extendLock() internal virtual {
    AllocationLib.extendLock(VOTING_ESCROW, _relayConfig.tokenId, _relayConfig.lockWeeks);
  }

  /// @notice Settles a holder's rewards, leaving them claimable, and forces their free position
  ///         into the withdraw queue, to be returned to a fresh sAERO at the next drain.
  /// @param _holder Holder being ejected.
  /// @return _free Free shares forced into the queue (zero when the holder held none).
  function _ejectHolder(address _holder) internal returns (uint256 _free) {
    _free = RelayRewardsLib.ejectHolder(
      _rewardTokenSet,
      pendingReward,
      userCheckpoint,
      rewardIndex,
      withdrawQueue,
      _withdrawals,
      escrowedShares,
      RelayRewardsLib.EjectContext({
        principalToken: principalToken, yieldToken: yieldToken, holder: _holder, accScale: ACC_SCALE, closed: closed
      })
    );
    pendingWithdrawalShares += _free;
  }

  /// @notice Guards and registers an async deposit for `_recipient`.
  /// @param _tokenId Source sAERO whose weight enters the Relay.
  /// @param _amount Staking weight pulled from the source sAERO.
  /// @param _recipient Address the shares mint to at admission.
  function _requestDeposit(uint256 _tokenId, uint256 _amount, address _recipient) internal {
    // Tier seam: on Protocol tiers the share recipient must be allow-listed.
    _authorizeDeposit(_recipient);

    // QueueLib runs the remaining guards and returns the net weight actually received.
    uint256 _netAmount = QueueLib.registerDeposit(
      depositList,
      pendingDeposits,
      VOTING_ESCROW,
      VPM,
      QueueLib.RegisterDepositContext({
        tokenId: _tokenId,
        recipient: _recipient,
        amount: _amount,
        relayTokenId: _relayConfig.tokenId,
        minDeposit: _relayConfig.minDeposit,
        totalSupply: principalToken.totalSupply(),
        totalBacking: totalBacking,
        principalToken: address(principalToken),
        yieldToken: address(yieldToken),
        closed: closed
      })
    );

    // Pending weight parks on chain0 but stays out of totalBacking until admitted, so it neither
    // dilutes nor captures rewards; the counter keeps it from reading as a donation.
    pendingDepositWeight += _netAmount;
  }

  /// @notice Writes a deposit processing result back into the Relay's counters.
  /// @param _result The new backing and the processed count, returned by QueueLib.
  function _applyDepositResult(QueueLib.DepositResult memory _result) internal {
    // The backing delta is exactly the weight the call admitted out of the pending counter.
    pendingDepositWeight -= _result.totalBacking - totalBacking;
    totalBacking = _result.totalBacking;
  }

  // The drain delegatecalls into QueueLib and only reaches protocol contracts (the satellites, the
  // escrow, the VPM): writing the counters back afterwards is not a reentrancy window.
  // slither-disable-start reentrancy-no-eth
  /// @notice Drains up to `_maxEntries` queued exits in FIFO order against the free chain0 weight.
  /// @param _maxEntries Max exits to settle this call.
  /// @dev The free weight is read live from the Voter, never a local counter, so in-flight
  ///      deallocation returns cannot desynchronize the drain; it stops at the first exit the
  ///      reading cannot cover.
  function _processWithdrawals(uint256 _maxEntries) internal {
    QueueLib.WithdrawResult memory _result = withdrawQueue.processWithdrawals(
      _withdrawals,
      escrowedShares,
      VOTING_ESCROW,
      VPM,
      QueueLib.WithdrawContext({
        maxEntries: _maxEntries,
        totalSupply: principalToken.totalSupply(),
        totalBacking: totalBacking,
        freeWeight: VOTER.allocationChainAmounts(_relayConfig.tokenId, _CHAIN0),
        pendingWithdrawalShares: pendingWithdrawalShares,
        relayTokenId: _relayConfig.tokenId,
        principalToken: principalToken,
        yieldToken: yieldToken,
        closed: closed
      })
    );

    // A drain that settles nothing changes neither counter, so it writes no storage.
    if (_result.count == 0) return;

    totalBacking = _result.totalBacking;
    pendingWithdrawalShares = _result.pendingWithdrawalShares;
  }

  // slither-disable-end reentrancy-no-eth

  /// @notice Builds the pricing context of a deposit processing call. Each path passes zero for
  ///         the bound it does not read.
  /// @param _maxEntries Max deposit-queue entries to visit (the ordered walk).
  /// @param _keeperWindow Overdue age bound (the by-id path).
  /// @return _ctx The context QueueLib prices against.
  function _depositContext(
    uint256 _maxEntries,
    uint256 _keeperWindow
  ) internal view returns (QueueLib.DepositContext memory _ctx) {
    _ctx = QueueLib.DepositContext({
      maxEntries: _maxEntries,
      keeperWindow: _keeperWindow,
      totalBacking: totalBacking,
      totalSupply: principalToken.totalSupply(),
      closed: closed,
      principalToken: principalToken,
      yieldToken: yieldToken
    });
  }

  /// @notice Tier seam: authorizes a holder-to-holder YT transfer before balances move.
  /// @param _from Sender of the transfer.
  /// @param _to Recipient of the transfer.
  /// @dev Never called for mints or burns. Base is open (Maxi); ProtocolRelay requires both ends
  ///      allow-listed.
  function _authorizeTransfer(address _from, address _to) internal view virtual {}

  /// @notice Tier seam: authorizes a deposit crediting shares to `_owner`.
  /// @param _owner sAERO owner that will receive the shares.
  /// @dev Base is open (Maxi); ProtocolRelay requires `_owner` allow-listed.
  function _authorizeDeposit(address _owner) internal view virtual {}

  /// @notice Tier seam: whether the reward registry may grow beyond its first token.
  /// @return _can True when more reward tokens may be registered.
  /// @dev Base is false (Maxi/L1); ProtocolRelay returns true once it is L2.
  function _canGrowRegistry() internal view virtual returns (bool _can) {}

  /// @notice Reverts with a bare 4-byte selector; one shared tail instead of one per revert site.
  /// @param _selector The custom error's selector.
  function _revert(uint32 _selector) internal pure {
    assembly ('memory-safe') {
      mstore(0x00, _selector)
      revert(0x1c, 0x04)
    }
  }
}
