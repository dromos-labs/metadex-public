// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';

/**
 * @title TokenRegistry
 * @notice Deployed once per chain. It holds each token's listing, tier, and canonical reference, keeps escrow
 *         deposits in ETH, and points to the NFT contracts that mint and store the metadata NFTs. Governance, read
 *         from the LeafVoter, is the sole curator of listing, tier, and the canonical reference.
 */
contract TokenRegistry is ReentrancyGuardTransient, ITokenRegistry {
  /// @inheritdoc ITokenRegistry
  uint8 public constant MAX_WEIGHT = 100;

  /// @inheritdoc ITokenRegistry
  address public immutable LEAF_VOTER;

  /// @inheritdoc ITokenRegistry
  uint256 public depositAmount;
  /// @inheritdoc ITokenRegistry
  uint256 public nextId;
  /// @inheritdoc ITokenRegistry
  uint256 public lockedFunds;

  /// @inheritdoc ITokenRegistry
  mapping(address _requester => uint256 _amount) public refundOf;
  /// @inheritdoc ITokenRegistry
  mapping(address _token => bool _listed) public isListed;
  /// @inheritdoc ITokenRegistry
  mapping(address _account => bool _delegate) public isDelegate;
  /// @inheritdoc ITokenRegistry
  mapping(address _account => bool _exempt) public isExempt;
  /// @inheritdoc ITokenRegistry
  mapping(address _token => CanonicalReference _reference) public canonicalOf;
  /// @inheritdoc ITokenRegistry
  mapping(address _token => TokenRegistration _registration) public registrationOf;
  /// @inheritdoc ITokenRegistry
  mapping(uint256 _id => address _token) public idToToken;
  /// @inheritdoc ITokenRegistry
  address[] public nftContracts;

  /**
   * @notice Open registration request per token, empty when none is open.
   * @dev Read through `pendingRequest`, which returns the full struct including the records array.
   */
  mapping(address _token => MetadataRequest _request) internal _pendingRequests;

  /// @inheritdoc ITokenRegistry
  mapping(address _token => Tier _tier) public tier;

  /// @notice Restricts a call to the governance role read from the LeafVoter.
  modifier onlyGovernance() {
    if (!IAccessControl(LEAF_VOTER).hasRole(Roles.GOVERNANCE_ROLE, msg.sender)) revert NotGovernance();
    _;
  }

  /**
   * @notice Sets the LeafVoter and the initial deposit, seeding the id sequence at 1. Governance registers the first
   *         NFT contract through `registerNFTContract` before registration opens.
   * @param _leafVoter LeafVoter read for the governance role.
   * @param _depositAmount Initial ETH a request must lock; required non-zero at deploy, though governance may later set
   *        it to any value, including zero.
   */
  constructor(address _leafVoter, uint256 _depositAmount) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    if (_depositAmount == 0) revert ZeroDeposit();

    LEAF_VOTER = _leafVoter;
    depositAmount = _depositAmount;
    // Seed the id sequence at 1 so id 0 stays the null sentinel for `registrationOf` and `idToToken`.
    ++nextId;
  }

  /// @inheritdoc ITokenRegistry
  function requestRegistration(
    address _token,
    CanonicalReference calldata _canonical,
    ITokenNFT.TextRecord[] calldata _records
  ) external payable {
    if (_token == address(0)) revert ZeroAddress();
    if (_canonical.chainId == block.chainid) revert InvalidCanonical();
    if (registrationOf[_token].nftId != 0) revert AlreadyRegistered();
    if (_pendingRequests[_token].requester != address(0)) revert RequestPending();
    if (msg.value != depositAmount) revert WrongDeposit();
    // Reject requests until governance registers the first NFT contract, so no deposit is escrowed for a request
    // that cannot be approved.
    if (nftContracts.length == 0) revert NoNFTContract();

    MetadataRequest storage _request = _pendingRequests[_token];
    _request.requester = msg.sender;
    _request.deposit = msg.value;
    _request.canonical = _canonical;
    // Track the escrowed deposit as owed back, so it is excluded from what governance can sweep.
    lockedFunds += msg.value;
    // Copy records element by element: the legacy pipeline cannot copy a calldata array into a storage struct at once.
    uint256 _length = _records.length;
    for (uint256 _i; _i < _length; ++_i) {
      _request.records.push(_records[_i]);
    }

    emit RegistrationRequested(_token, msg.sender);
  }

  /// @inheritdoc ITokenRegistry
  function registerExempt(
    address _token,
    address _to,
    CanonicalReference calldata _canonical,
    ITokenNFT.TextRecord[] calldata _records
  ) external nonReentrant {
    if (_canonical.chainId == block.chainid) revert InvalidCanonical();
    if (!isExempt[msg.sender]) revert NotExempt();
    if (registrationOf[_token].nftId != 0) revert AlreadyRegistered();

    // Close and refund the open request before the mint: `_safeMint` hands control to the recipient, which must
    // never observe an open request for a token already registered.
    MetadataRequest storage _request = _pendingRequests[_token];
    address _requester = _request.requester;
    if (_requester != address(0)) {
      uint256 _deposit = _request.deposit;
      delete _pendingRequests[_token];
      _creditRefund(_requester, _deposit);
      emit RegistrationPreempted(_token, _requester);
    }

    if (_canonical.chainId != 0) {
      canonicalOf[_token] = _canonical;
      emit CanonicalSet(_token, _canonical.chainId, _canonical.nftId);
    }

    _register(_token, _to, _records);
  }

  /// @inheritdoc ITokenRegistry
  function resolveRequest(address _token, bool _approved) external nonReentrant {
    // Delegate reviewers only, keeping routine approvals off the governance wallet. Governance reviews by adding
    // itself to `isDelegate`, so it is never an implicit reviewer.
    if (!isDelegate[msg.sender]) revert NotReviewer();

    MetadataRequest storage _request = _pendingRequests[_token];
    address _requester = _request.requester;
    if (_requester == address(0)) revert NotPending();

    uint256 _deposit = _request.deposit;

    if (_approved) {
      // Only the approval mints the records, and `_register` takes them in memory, so they are copied here and never
      // on the rejection path.
      ITokenNFT.TextRecord[] memory _records = _request.records;

      // A zero chain id is a native token: it never overwrites a reference governance may have already set.
      uint256 _chainId = _request.canonical.chainId;
      if (_chainId != 0) {
        canonicalOf[_token] = _request.canonical;
        emit CanonicalSet(_token, _chainId, _request.canonical.nftId);
      }

      delete _pendingRequests[_token];

      _register(_token, _requester, _records);
      _creditRefund(_requester, _deposit);
      emit RegistrationApproved(_token, _requester);
    } else {
      delete _pendingRequests[_token];

      // The rejected deposit is no longer owed and stays behind as a sweepable fee.
      lockedFunds -= _deposit;
      emit RegistrationRejected(_token, _requester);
    }
  }

  /// @inheritdoc ITokenRegistry
  function cancel(address _token) external {
    MetadataRequest storage _request = _pendingRequests[_token];
    if (_request.requester != msg.sender) revert NotRequester();

    uint256 _deposit = _request.deposit;
    delete _pendingRequests[_token];
    _creditRefund(msg.sender, _deposit);

    emit RegistrationCancelled(_token, msg.sender);
  }

  /// @inheritdoc ITokenRegistry
  function claimRefund(address _recipient) external {
    if (_recipient == address(0)) revert ZeroAddress();

    uint256 _amount = refundOf[msg.sender];
    if (_amount == 0) revert NoRefund();

    refundOf[msg.sender] = 0;
    lockedFunds -= _amount;

    _transferETH(_recipient, _amount);
    emit RefundClaimed(msg.sender, _recipient, _amount);
  }

  /// @inheritdoc ITokenRegistry
  function registerNFTContract(address _nftContract) external onlyGovernance {
    if (_nftContract == address(0)) revert ZeroAddress();
    if (ITokenNFT(_nftContract).LEAF_VOTER() != LEAF_VOTER) revert InvalidNFTContract();
    if (ITokenNFT(_nftContract).TOKEN_REGISTRY() != address(this)) revert InvalidNFTContract();

    nftContracts.push(_nftContract);
    emit NFTContractRegistered(_nftContract);
  }

  /// @inheritdoc ITokenRegistry
  function withdraw(address _recipient) external onlyGovernance {
    if (_recipient == address(0)) revert ZeroAddress();

    // Sweep everything not owed to open requests or unclaimed refunds: forfeited fees plus force-sent ETH.
    uint256 _amount = address(this).balance - lockedFunds;

    _transferETH(_recipient, _amount);
    emit Withdrawn(_recipient, _amount);
  }

  /// @inheritdoc ITokenRegistry
  function setListing(address _token, bool _listed) external onlyGovernance {
    isListed[_token] = _listed;
    emit ListingSet(_token, _listed);
  }

  /// @inheritdoc ITokenRegistry
  function setType(address _token, uint8 _tierType) external onlyGovernance {
    tier[_token].tierType = _tierType;
    emit TypeSet(_token, _tierType);
  }

  /// @inheritdoc ITokenRegistry
  function setWeight(address _token, uint8 _weight) external onlyGovernance {
    if (_weight > MAX_WEIGHT) revert InvalidWeight();

    tier[_token].weight = _weight;
    emit WeightSet(_token, _weight);
  }

  /// @inheritdoc ITokenRegistry
  function setTier(address _token, uint8 _tierType, uint8 _weight) external onlyGovernance {
    if (_weight > MAX_WEIGHT) revert InvalidWeight();

    tier[_token] = Tier({tierType: _tierType, weight: _weight});
    emit TierSet(_token, _tierType, _weight);
  }

  /// @inheritdoc ITokenRegistry
  function setCanonical(address _token, uint256 _chainId, uint256 _nftId) external onlyGovernance {
    // Only the local chain is rejected. The token and ids are left unchecked on purpose, so governance keeps the
    // power to clear a reference back to native with zero values and to correct a mistake without a redeploy.
    if (_chainId == block.chainid) revert InvalidCanonical();

    canonicalOf[_token] = CanonicalReference({chainId: _chainId, nftId: _nftId});
    emit CanonicalSet(_token, _chainId, _nftId);
  }

  /// @inheritdoc ITokenRegistry
  function setDepositAmount(uint256 _amount) external onlyGovernance {
    depositAmount = _amount;
    emit DepositAmountSet(_amount);
  }

  /// @inheritdoc ITokenRegistry
  function setExemptActor(address _account, bool _exempt) external onlyGovernance {
    isExempt[_account] = _exempt;
    emit ExemptSet(_account, _exempt);
  }

  /// @inheritdoc ITokenRegistry
  function setDelegateReviewer(address _account, bool _allowed) external onlyGovernance {
    isDelegate[_account] = _allowed;
    emit DelegateSet(_account, _allowed);
  }

  /// @inheritdoc ITokenRegistry
  function metadata(
    address _token,
    string[] calldata _keys
  ) external view returns (CanonicalReference memory _canonical, string[] memory _values) {
    _canonical = canonicalOf[_token];
    // Bridged token: its authoritative metadata lives on the home chain, so the local NFT is not read.
    if (_canonical.chainId != 0) return (_canonical, _values);

    TokenRegistration memory _registration = registrationOf[_token];
    if (_registration.nftId == 0) return (_canonical, _values);

    _values = ITokenNFT(nftContracts[_registration.nftContractIndex]).records(_registration.nftId, _keys);
  }

  /// @inheritdoc ITokenRegistry
  function pendingRequest(address _token) external view returns (MetadataRequest memory _request) {
    _request = _pendingRequests[_token];
  }

  /**
   * @notice Assigns the next id, records the token mapping, and mints on the current NFT contract.
   * @param _token Token being registered.
   * @param _to Owner of the minted NFT.
   * @param _records Metadata records written at mint.
   * @return _id Newly assigned NFT id.
   */
  function _register(
    address _token,
    address _to,
    ITokenNFT.TextRecord[] memory _records
  ) internal returns (uint256 _id) {
    if (_token == address(0)) revert ZeroAddress();
    if (nftContracts.length == 0) revert NoNFTContract();

    _id = nextId++;
    uint256 _index = nftContracts.length - 1;
    registrationOf[_token] = TokenRegistration({nftId: uint128(_id), nftContractIndex: uint128(_index)});
    idToToken[_id] = _token;

    ITokenNFT(nftContracts[_index]).mint(_id, _to, _records);
    emit Registered(_token, _id, _to);
  }

  /**
   * @notice Records a refund the requester claims through `claimRefund`.
   * @dev The amount stays counted in `lockedFunds` until claimed, so governance can never sweep it.
   * @param _requester Address the refund is owed to.
   * @param _amount Amount owed, in wei.
   */
  function _creditRefund(address _requester, uint256 _amount) internal {
    refundOf[_requester] += _amount;
    emit RefundCredited(_requester, _amount);
  }

  /**
   * @notice Sends ETH to an address, reverting with the callee's failure data.
   * @param _to Recipient of the ETH.
   * @param _amount Amount to send, in wei.
   */
  function _transferETH(address _to, uint256 _amount) internal {
    // slither-disable-next-line arbitrary-send-eth
    (bool _success, bytes memory _data) = _to.call{value: _amount}('');
    if (!_success) revert TransferFailed(_data);
  }
}
