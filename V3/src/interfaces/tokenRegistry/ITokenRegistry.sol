// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';

/**
 * @title ITokenRegistry
 * @notice Interface for the `TokenRegistry`, deployed once per chain. It holds each token's listing, tier, and
 *         canonical reference, keeps escrow deposits in ETH, and points to the NFT contracts that mint and store the
 *         metadata NFTs. Governance, read from the LeafVoter, is the sole curator of listing, tier, and the canonical
 *         reference.
 */
interface ITokenRegistry {
  /**
   * @notice A pending request to register a token's metadata NFT, held while the token is pending.
   * @param requester Address that opened the request, receives the minted NFT on approval and any refund.
   * @param deposit ETH locked with the request, in wei, credited back on approval or cancellation and kept on rejection.
   * @param records Proposed metadata records governance evaluates, written to the NFT on approval.
   * @param canonical Proposed home chain pointer, written to `canonicalOf` on approval when its chain id is set.
   */
  struct MetadataRequest {
    address requester;
    uint256 deposit;
    ITokenNFT.TextRecord[] records;
    CanonicalReference canonical;
  }

  /**
   * @notice Home chain pointer for a bridged token.
   * @param chainId Chain the authoritative NFT lives on.
   * @param nftId NFT id on that chain.
   */
  struct CanonicalReference {
    uint256 chainId;
    uint256 nftId;
  }

  /**
   * @notice A token's minted NFT and the contract holding it.
   * @param nftId NFT id, zero when the token is unregistered.
   * @param nftContractIndex Position in `nftContracts` of the contract that minted the NFT.
   */
  struct TokenRegistration {
    uint128 nftId;
    uint128 nftContractIndex;
  }

  /**
   * @notice A token's classification tier, packed in one slot.
   * @param tierType Class type, zero when unclassified.
   * @param weight Risk weight from 1 to `MAX_WEIGHT`, zero when unresolved.
   * @param flags Governance-defined bitmask of token properties, including composite properties, zero when no flags are
   *              set.
   */
  struct Tier {
    uint8 tierType;
    uint8 weight;
    uint240 flags;
  }

  /**
   * @notice Emitted when a registration request is opened and its deposit is escrowed.
   * @param _token Token the request is for.
   * @param _requester Address that opened the request.
   */
  event RegistrationRequested(address indexed _token, address indexed _requester);

  /**
   * @notice Emitted when an exempt actor's direct registration preempts an open request and credits its refund.
   * @param _token Token whose open request was closed.
   * @param _requester Address the escrowed deposit was credited back to.
   */
  event RegistrationPreempted(address indexed _token, address indexed _requester);

  /**
   * @notice Emitted when a reviewer approves a request, minting the NFT and crediting the deposit back.
   * @param _token Token whose request was approved.
   * @param _requester Address that opened the request and receives the NFT and the refund credit.
   */
  event RegistrationApproved(address indexed _token, address indexed _requester);

  /**
   * @notice Emitted when a reviewer rejects a request, keeping the deposit as a fee.
   * @param _token Token whose request was rejected.
   * @param _requester Address that opened the request.
   */
  event RegistrationRejected(address indexed _token, address indexed _requester);

  /**
   * @notice Emitted when a requester cancels its own request and is credited the deposit back.
   * @param _token Token whose request was cancelled.
   * @param _requester Address that opened and cancelled the request.
   */
  event RegistrationCancelled(address indexed _token, address indexed _requester);

  /**
   * @notice Emitted when a refund is credited to a requester, claimable through `claimRefund`.
   * @param _requester Address the refund is owed to.
   * @param _amount Amount credited, in wei.
   */
  event RefundCredited(address indexed _requester, uint256 _amount);

  /**
   * @notice Emitted when a requester claims a credited refund.
   * @param _requester Address the refund was owed to.
   * @param _recipient Address the ETH was sent to.
   * @param _amount Amount claimed, in wei.
   */
  event RefundClaimed(address indexed _requester, address indexed _recipient, uint256 _amount);

  /**
   * @notice Emitted when a token's NFT is minted and its mapping recorded.
   * @param _token Token registered.
   * @param _id NFT id assigned.
   * @param _to Owner of the minted NFT.
   */
  event Registered(address indexed _token, uint256 indexed _id, address indexed _to);

  /**
   * @notice Emitted when a new current NFT contract is registered.
   * @param _nftContract NFT contract registered.
   */
  event NFTContractRegistered(address indexed _nftContract);

  /**
   * @notice Emitted when governance sweeps the funds not owed to open requests or unclaimed refunds.
   * @param _recipient Address that received the ETH.
   * @param _amount Amount of ETH swept, in wei.
   */
  event Withdrawn(address indexed _recipient, uint256 _amount);

  /**
   * @notice Emitted when a token's listing is set.
   * @param _token Token whose listing changed.
   * @param _listed New listing state.
   */
  event ListingSet(address indexed _token, bool _listed);

  /**
   * @notice Emitted when a token's type is set.
   * @param _token Token classified.
   * @param _tierType Type assigned, zero when cleared.
   */
  event TypeSet(address indexed _token, uint8 _tierType);

  /**
   * @notice Emitted when a token's weight is set.
   * @param _token Token weighted.
   * @param _weight Weight assigned, zero when cleared.
   */
  event WeightSet(address indexed _token, uint8 _weight);

  /**
   * @notice Emitted when a token's flags are set.
   * @param _token Token designated.
   * @param _flags Token property bitmask, including composite properties, zero to clear all flags.
   */
  event FlagsSet(address indexed _token, uint240 _flags);

  /**
   * @notice Emitted when a token's type, weight, and flags are set together.
   * @param _token Token classified.
   * @param _tierType Type assigned, zero when cleared.
   * @param _weight Weight assigned, zero when cleared.
   * @param _flags Token property bitmask, including composite properties, zero to clear all flags.
   */
  event TierSet(address indexed _token, uint8 _tierType, uint8 _weight, uint240 _flags);

  /**
   * @notice Emitted when a token's canonical reference is set or cleared.
   * @param _token Token referenced.
   * @param _chainId Home chain id, zero when cleared.
   * @param _nftId Home chain NFT id, zero when cleared.
   */
  event CanonicalSet(address indexed _token, uint256 _chainId, uint256 _nftId);

  /**
   * @notice Emitted when the deposit amount is set.
   * @param _amount New deposit amount, in wei.
   */
  event DepositAmountSet(uint256 _amount);

  /**
   * @notice Emitted when an address's exemption is set.
   * @param _account Address whose exemption changed.
   * @param _exempt New exemption state.
   */
  event ExemptSet(address indexed _account, bool _exempt);

  /**
   * @notice Emitted when an address's delegate reviewer status is set.
   * @param _account Address whose delegate status changed.
   * @param _allowed New delegate state.
   */
  event DelegateSet(address indexed _account, bool _allowed);

  /// @notice Thrown when a required address argument is the zero address.
  error ZeroAddress();

  /// @notice Thrown when the initial deposit is zero.
  error ZeroDeposit();

  /// @notice Thrown when registering a token that already has a minted NFT.
  error AlreadyRegistered();

  /// @notice Thrown when opening a request for a token that already has an open request.
  error RequestPending();

  /// @notice Thrown when the ETH sent with a request does not equal the current deposit amount.
  error WrongDeposit();

  /// @notice Thrown when a request carries more than `MAX_RECORDS` records.
  error TooManyRecords();

  /// @notice Thrown when a request's keys and values exceed `MAX_RECORD_BYTES` bytes in total.
  error RecordsTooLarge();

  /// @notice Thrown when a direct registration is not made by an exempt caller.
  error NotExempt();

  /// @notice Thrown when resolving a token that has no open request.
  error NotPending();

  /// @notice Thrown when the open request does not hash to the reviewed metadata hash.
  error MetadataMismatch();

  /// @notice Thrown when cancelling a request the caller did not open.
  error NotRequester();

  /// @notice Thrown when claiming a refund the caller is not owed.
  error NoRefund();

  /// @notice Thrown when a privileged call is not made by the governance role read from the LeafVoter.
  error NotGovernance();

  /// @notice Thrown when a review call is not made by an allowed delegate reviewer.
  error NotReviewer();

  /// @notice Thrown when a weight above `MAX_WEIGHT` is written.
  error InvalidWeight();

  /// @notice Thrown when a canonical reference is set to the local chain id.
  error InvalidCanonical();

  /// @notice Thrown when registering an NFT contract not wired to this registry and the same LeafVoter.
  error InvalidNFTContract();

  /// @notice Thrown when registering a token without an NFT contract to mint through.
  error NoNFTContract();

  /**
   * @notice Thrown when an ETH transfer fails, bubbling the callee's revert data.
   * @param _data Revert data returned by the failed call.
   */
  error TransferFailed(bytes _data);

  /**
   * @notice Opens a registration request for a token, locking the deposit in escrow.
   * @dev The token must be unregistered with no open request, and an NFT contract must be registered. Exempt
   *      callers use `registerExempt` instead.
   * @dev The records are bounded because a request stores them and the resolution replays them, and the replay costs
   *      more than the write. Without a bound, anyone could open a request no resolution transaction can complete.
   * @param _token Token to register.
   * @param _canonical Proposed home chain pointer, zero values for a native token.
   * @param _records Proposed metadata records, at most `MAX_RECORDS` of them and `MAX_RECORD_BYTES` in total.
   */
  function requestRegistration(
    address _token,
    CanonicalReference calldata _canonical,
    ITokenNFT.TextRecord[] calldata _records
  ) external payable;

  /**
   * @notice Registers a token's NFT directly, for an exempt caller, with no deposit or escrow.
   * @dev Reverts if the token is already registered. Refunds and closes any open request, then mints to `_to`.
   * @dev The records are not bounded here, unlike `requestRegistration`: they are written in the caller's own
   *      transaction rather than stored and replayed, so an oversized array only fails the caller's own call.
   * @param _token Token to register.
   * @param _to Owner of the minted NFT.
   * @param _canonical Home chain pointer, written to `canonicalOf` when its chain id is set, zero values for a
   *        native token.
   * @param _records Metadata records written at mint.
   */
  function registerExempt(
    address _token,
    address _to,
    CanonicalReference calldata _canonical,
    ITokenNFT.TextRecord[] calldata _records
  ) external;

  /**
   * @notice Resolves a pending request. Approval mints the NFT and refunds the deposit, rejection keeps the deposit
   *         as a fee.
   * @dev Callable only by a delegate reviewer. Governance is not an implicit reviewer and must add itself to the
   *      delegate set to resolve, keeping routine approvals off the governance wallet. The decision is bound to the
   *      reviewed request: it reverts when the open request no longer hashes to `_metadataHash`, so a request
   *      cancelled and reopened with any change after the review is never resolved.
   * @param _token Token whose request to resolve.
   * @param _metadataHash `keccak256(abi.encode(request))` of the request as reviewed, the struct `pendingRequest`
   *        returns, so hashing that call's raw return data yields it.
   * @param _approved True to approve, false to reject.
   */
  function resolveRequest(address _token, bytes32 _metadataHash, bool _approved) external;

  /**
   * @notice Cancels the caller's own pending request and refunds the deposit.
   * @param _token Token whose request to cancel.
   */
  function cancel(address _token) external;

  /**
   * @notice Sends a credited refund to an address the caller names.
   * @dev Refunds are credited rather than pushed, so a requester that cannot receive ETH never blocks a
   *      registration and can still recover its deposit through a payable address.
   * @param _recipient Address the refund is sent to.
   */
  function claimRefund(address _recipient) external;

  /**
   * @notice Registers a new NFT contract as the current mint target, continuing the id sequence.
   * @dev The contract must be a `TokenNFT` wired to this registry and the same LeafVoter, checked through its getters.
   * @param _nftContract NFT contract to register.
   */
  function registerNFTContract(address _nftContract) external;

  /**
   * @notice Sweeps the funds not owed to open requests to a recipient: forfeited fees plus any force-sent ETH.
   * @dev Sends `address(this).balance - lockedFunds`, so open deposits are never touched.
   * @param _recipient Address that receives the ETH.
   */
  function withdraw(address _recipient) external;

  /**
   * @notice Sets whether a token is listed for gauge activation and incentive eligibility.
   * @param _token Token to set.
   * @param _listed New listing state.
   */
  function setListing(address _token, bool _listed) external;

  /**
   * @notice Sets a token's type, keeping its weight and flags.
   * @dev Clearing passes type zero. Types are a governance-curated convention, not validated on-chain.
   * @param _token Token to classify.
   * @param _tierType Type to assign, or zero to unclassify.
   */
  function setType(address _token, uint8 _tierType) external;

  /**
   * @notice Sets a token's resolved risk weight, or clears it to unresolved with zero.
   * @dev Keeps the type and flags.
   * @param _token Token to weight.
   * @param _weight Resolved weight from 1 to `MAX_WEIGHT`, or zero to clear.
   */
  function setWeight(address _token, uint8 _weight) external;

  /**
   * @notice Replaces a token's flags without changing its type or weight.
   * @param _token Token to designate.
   * @param _flags Token property bitmask, including composite properties, zero to clear all flags.
   */
  function setFlags(address _token, uint240 _flags) external;

  /**
   * @notice Sets a token's type, weight, and flags together, overwriting all three.
   * @dev Pass zero to clear any field.
   *      Types and flags are governance-curated metadata, not validated on-chain.
   * @param _token Token to classify.
   * @param _tierType Type to assign, or zero to unclassify.
   * @param _weight Resolved weight from 1 to `MAX_WEIGHT`, or zero to clear.
   * @param _flags Token property bitmask, including composite properties, zero to clear all flags.
   */
  function setTier(address _token, uint8 _tierType, uint8 _weight, uint240 _flags) external;

  /**
   * @notice Sets a token's canonical reference, or clears it with zero values.
   * @dev Only the local chain id is rejected. The token and ids are otherwise unchecked, so governance keeps the
   *      power to clear a reference back to native and to correct a mistake without a redeploy.
   * @param _token Token to reference.
   * @param _chainId Home chain id, other than the local chain, or zero to clear.
   * @param _nftId Home chain NFT id, or zero to clear.
   */
  function setCanonical(address _token, uint256 _chainId, uint256 _nftId) external;

  /**
   * @notice Sets the ETH deposit a request must lock.
   * @param _amount New deposit amount, in wei.
   */
  function setDepositAmount(uint256 _amount) external;

  /**
   * @notice Sets whether an address skips the deposit and escrow.
   * @param _account Address to set.
   * @param _exempt New exemption state.
   */
  function setExemptActor(address _account, bool _exempt) external;

  /**
   * @notice Sets whether an address may approve or reject requests.
   * @param _account Address to set.
   * @param _allowed New delegate state.
   */
  function setDelegateReviewer(address _account, bool _allowed) external;

  /**
   * @notice Reads a token's tier as a decoded type, weight, and flags.
   * @dev A weight of zero means unresolved, the storage default. Resolved weights run 1 to `MAX_WEIGHT`.
   * @param _token Token to read.
   * @return _tierType Class type, zero when unclassified.
   * @return _weight Risk weight from 1 to `MAX_WEIGHT`, zero when unresolved.
   * @return _flags Token property bitmask, including composite properties, zero by default.
   */
  function tier(address _token) external view returns (uint8 _tierType, uint8 _weight, uint240 _flags);

  /**
   * @notice Reads a token's canonical reference and, when native, its local metadata records.
   * @dev Read-resolution order for callers: when `_canonical` is set, its `chainId` is non-zero, the token is bridged
   *      and its authoritative metadata lives on the home chain, so `_values` is returned empty and the caller must
   *      follow the reference off-chain. Otherwise the token is native and `_values` holds its local records, forwarded
   *      to the NFT contract that minted it.
   * @param _token Token to read.
   * @param _keys Record keys to read.
   * @return _canonical Home chain reference, unset with a zero `chainId` when the token is native.
   * @return _values Local record values aligned with `_keys`, empty when the token is bridged or has no local NFT.
   */
  function metadata(
    address _token,
    string[] calldata _keys
  ) external view returns (CanonicalReference memory _canonical, string[] memory _values);

  /**
   * @notice Reads the open registration request of a token, empty when none is open.
   * @dev Reviewers hash it, ABI-encoded as returned, into the `_metadataHash` they pass to `resolveRequest`.
   * @param _token Token to read.
   * @return _request Requester, deposit, proposed records, and canonical reference.
   */
  function pendingRequest(address _token) external view returns (MetadataRequest memory _request);

  /**
   * @notice Highest resolved weight.
   * @return _maxWeight The constant `100`.
   */
  function MAX_WEIGHT() external view returns (uint8 _maxWeight);

  /**
   * @notice Highest number of records a registration request may carry.
   * @dev Headroom above the ENS key sets these records follow: the sixteen non-deprecated ERC-634 keys, and the
   *      eleven ENSIP-18 profile keys.
   * @return _maxRecords The constant `24`.
   */
  function MAX_RECORDS() external view returns (uint256 _maxRecords);

  /**
   * @notice Highest total byte length of the keys and values a registration request may carry.
   * @dev Over four times a complete ENSIP-18 profile, whose only specified length is a description of 160 characters.
   * @return _maxRecordBytes The constant `4096`.
   */
  function MAX_RECORD_BYTES() external view returns (uint256 _maxRecordBytes);

  /**
   * @notice Source of the governance role, read on every privileged call.
   * @return _leafVoter LeafVoter address.
   */
  function LEAF_VOTER() external view returns (address _leafVoter);

  /**
   * @notice ETH a registration request must lock, set non-zero at deploy and adjustable by governance.
   * @return _depositAmount Deposit in wei.
   */
  function depositAmount() external view returns (uint256 _depositAmount);

  /**
   * @notice Next NFT id the registry will mint.
   * @return _nextId The next id to mint.
   */
  function nextId() external view returns (uint256 _nextId);

  /**
   * @notice ETH owed to open requests and unclaimed refunds, excluded from what governance can sweep.
   * @return _lockedFunds Locked balance in wei.
   */
  function lockedFunds() external view returns (uint256 _lockedFunds);

  /**
   * @notice Refund credited to an address and not yet claimed, in wei.
   * @param _requester Address to read.
   * @return _amount Claimable refund, zero when none is owed.
   */
  function refundOf(address _requester) external view returns (uint256 _amount);

  /**
   * @notice Whether a token is listed for gauge activation and incentive eligibility.
   * @param _token Token to read.
   * @return _listed True when the token is listed.
   */
  function isListed(address _token) external view returns (bool _listed);

  /**
   * @notice Whether an address may approve or reject requests.
   * @param _account Address to read.
   * @return _delegate True when the address is an allowed reviewer.
   */
  function isDelegate(address _account) external view returns (bool _delegate);

  /**
   * @notice Whether an address skips the deposit and escrow, registering directly.
   * @param _account Address to read.
   * @return _exempt True when exempt.
   */
  function isExempt(address _account) external view returns (bool _exempt);

  /**
   * @notice Canonical reference per token, unset when the token is native to this chain.
   * @param _token Token to read.
   * @return _chainId Home chain id, zero when unset.
   * @return _nftId Home chain NFT id.
   */
  function canonicalOf(address _token) external view returns (uint256 _chainId, uint256 _nftId);

  /**
   * @notice NFT id and minting contract index mapped to a token.
   * @param _token Token to read.
   * @return _nftId NFT id, zero when the token is unregistered.
   * @return _nftContractIndex Position in `nftContracts` of the contract that minted the NFT.
   */
  function registrationOf(address _token) external view returns (uint128 _nftId, uint128 _nftContractIndex);

  /**
   * @notice Token mapped to an NFT id, zero when the id is unminted.
   * @param _id NFT id to read.
   * @return _token Token address, zero when unmapped.
   */
  function idToToken(uint256 _id) external view returns (address _token);

  /**
   * @notice NFT contract in registration order.
   * @param _index Position in the list.
   * @return _nftAddress NFT contract address.
   */
  function nftContracts(uint256 _index) external view returns (address _nftAddress);
}
