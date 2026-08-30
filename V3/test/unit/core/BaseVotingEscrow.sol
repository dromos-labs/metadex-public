// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {VotingEscrow} from 'V3/core/VotingEscrow.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

abstract contract BaseVotingEscrow is TestHelpers {
  using stdStorage for StdStorage;

  /// @dev Mirrors `VotingEscrow.WEEK`.
  uint48 internal constant _WEEK = 1 weeks;
  /// @dev Mirrors `VotingEscrow.MAXTIME` = 4 * 365 days. Note: 1460 days ≈ 208.57 weeks, so
  ///      `_MAXTIME / _WEEK` resolves to 208 (the last fully-aligned week boundary inside MAXTIME).
  uint48 internal constant _MAXTIME = 4 * 365 * 86_400;
  /// @dev Signed mirror of `_MAXTIME` for use in `bias = amount / iMAXTIME * (end - now)` decay math.
  int128 internal constant _IMAXTIME = 4 * 365 * 86_400;
  /// @dev Conservative cap for decay-mode `amount` inputs. Picked so `bias = (amount / iMAXTIME) *
  ///      (end - now)` stays below `int128.max` even when `end - now ≈ uint48.max`. True safe ceiling
  ///      is `int128.max * iMAXTIME / uint48.max ≈ 7.6e31`; `1e30` leaves ~76x headroom.
  uint128 internal constant _DECAY_AMOUNT_CAP = 1e30;

  address internal _deployer = makeAddr('Deployer');
  address internal _token = makeAddr('Token');
  address internal _vpm = makeAddr('VoterPaymentsModule');
  address internal _voter = makeAddr('Voter');
  address internal _artProxy = makeAddr('ArtProxy');
  address internal _vpmAdmin = makeAddr('VPMRoleAdmin');
  address internal _artProxyAdmin = makeAddr('ArtProxyAdmin');
  address internal _burnFeesAdmin = makeAddr('BurnFeesAdmin');
  address internal _owner = makeAddr('Owner');

  VotingEscrow internal _ve;

  function setUp() external {
    vm.prank(_deployer);
    _ve = new VotingEscrow(_defaultContracts(), _defaultAdmins());

    // `_vpm` is a VoterPaymentsModule granted VPM_ROLE by the admin, mirroring production where a VPM is deployed
    // standalone and authorized post-deploy. Tests still need the owner's `setApprovalForAll` for per-token ops.
    bytes32 _vpmRole = _ve.VPM_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _vpm);

    // VE mirrors rebalances and fee burns onto the Voter's chain0 ledger; stub the Voter so VE-level tests run
    // in isolation.
    _mockVoterRebalanceChain0();
    _mockVoterBurn();
    _mockVoterParkOnChain0();
  }

  /// @dev Default contract dependencies for VotingEscrow construction; tests tweak a single field to exercise
  ///      a specific zero-address branch.
  function _defaultContracts() internal view returns (IVotingEscrow.Contracts memory) {
    return IVotingEscrow.Contracts({token: _token, voter: _voter, artProxy: _artProxy});
  }

  /// @dev Default role admins for VotingEscrow construction; tests tweak a single field to exercise a specific
  ///      zero-address branch.
  function _defaultAdmins() internal view returns (IVotingEscrow.Admins memory) {
    return IVotingEscrow.Admins({vpmAdmin: _vpmAdmin, artProxyAdmin: _artProxyAdmin, burnFeesAdmin: _burnFeesAdmin});
  }

  /// @dev Catch-all stub for the Voter's chain0 mirror (`rebalanceChain0`), matched by selector regardless of args,
  ///      so `rebalanceUnderlying` tests exercise VE logic without a live Voter.
  function _mockVoterRebalanceChain0() internal {
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.rebalanceChain0.selector), bytes(''));
  }

  /// @dev Catch-all stub for the Voter's fee burn (`burn`), matched by selector regardless of args, so `burnFees`
  ///      tests exercise VE logic without a live Voter.
  function _mockVoterBurn() internal {
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.burn.selector), bytes(''));
  }

  /// @dev Catch-all stub for the Voter's chain0 park (`parkOnChain0`), matched by selector regardless of args, so the
  ///      deposit paths and `upgradeToPermanentStake` exercise VE logic without a live Voter.
  function _mockVoterParkOnChain0() internal {
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.parkOnChain0.selector), bytes(''));
  }

  /// @dev Reserved idle chain id used in the chain0-coverage check; value is arbitrary for the mock as long as
  ///      `CHAIN0()` and `allocationChainAmounts(_, CHAIN0)` stay consistent.
  uint256 internal constant _CHAIN0 = 0;

  /// @dev Stub the Voter's chain0-coverage view for `_tokenId`: `CHAIN0()` and the token's chain0 allocation,
  ///      so withdraw / downgrade exercise their `_requireFullyOnChain0` check without a live Voter.
  function _mockVoterChain0Allocation(uint256 _tokenId, uint128 _allocated) internal {
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.CHAIN0.selector), abi.encode(_CHAIN0));
    vm.mockCall(_voter, abi.encodeCall(IVoter.allocationChainAmounts, (_tokenId, _CHAIN0)), abi.encode(_allocated));
  }

  /// @dev OZ ERC721 v5 stores `_owners` at slot 2. stdStorage cannot probe this mapping because the
  ///      public getter (ownerOf) reverts on nonexistent tokens.
  function _setOwner(uint256 _tokenId, address _ownerAddr) internal {
    vm.store(address(_ve), keccak256(abi.encode(_tokenId, uint256(2))), bytes32(uint256(uint160(_ownerAddr))));
  }

  /// @dev ERC721Enumerable keeps the global token list in a private `uint256[] _allTokens`. `totalSupply()` is the
  ///      getter for its length, so stdStorage resolves the length slot and the elements follow at
  ///      `keccak256(lengthSlot) + i`; no slot constant is hardcoded. The paired `_allTokensIndex` map stays
  ///      unwritten because only the burn path reads it, and sAERO is never burned.
  function _setGlobalEnumeration(uint256[] memory _tokenIds) internal {
    uint256 _lengthSlot = stdstore.target(address(_ve)).sig(_ve.totalSupply.selector).find();
    vm.store(address(_ve), bytes32(_lengthSlot), bytes32(_tokenIds.length));
    uint256 _elementSlot = uint256(keccak256(abi.encode(_lengthSlot)));
    for (uint256 _i; _i < _tokenIds.length; ++_i) {
      vm.store(address(_ve), bytes32(_elementSlot + _i), bytes32(_tokenIds[_i]));
    }
  }

  /// @dev supply and permanentStakeBalance share a packed slot. stdStorage finds the slot through the
  ///      supply getter; vm.store writes both halves atomically since stdStorage's checked_write probes
  ///      overflow on packed uint128 layouts.
  function _setSupplyAndPermanent(uint128 _supply, uint128 _permanent) internal {
    uint256 _slot = stdstore.target(address(_ve)).sig(_ve.supply.selector).find();
    vm.store(address(_ve), bytes32(_slot), bytes32(uint256(_supply) | (uint256(_permanent) << 128)));
  }

  /// @dev StakedBalance (uint128 amount | uint48 end | bool isPermanent) is packed into one slot.
  ///      stdStorage finds the slot through the staked getter; vm.store writes the packed value atomically
  ///      since stdStorage's per-field checked_write probes overflow on packed layouts.
  function _setStaked(uint256 _tokenId, uint128 _amount, uint48 _end, bool _isPermanent) internal {
    uint256 _slot = stdstore.target(address(_ve)).sig(_ve.staked.selector).with_key(_tokenId).find();
    uint256 _packed = uint256(_amount) | (uint256(_end) << 128) | (uint256(_isPermanent ? 1 : 0) << 176);
    vm.store(address(_ve), bytes32(_slot), bytes32(_packed));
  }

  function _setTokenIdCounter(uint256 _next) internal {
    stdstore.target(address(_ve)).sig(_ve.tokenId.selector).checked_write(_next);
  }

  function _setEpoch(uint256 _epoch) internal {
    stdstore.target(address(_ve)).sig(_ve.epoch.selector).checked_write(_epoch);
  }

  /// @dev GlobalPoint occupies two slots: slot0 = bias|slope (int128 packed), slot1 = ts|permanent (uint48|uint128).
  ///      stdStorage finds the base slot via the pointHistory getter; vm.store writes both slots atomically.
  function _setPointHistory(uint256 _k, int128 _bias, int128 _slope, uint48 _ts, uint128 _permanent) internal {
    uint256 _slot0 = stdstore.target(address(_ve)).sig(_ve.pointHistory.selector).with_key(_k).find();
    vm.store(address(_ve), bytes32(_slot0), bytes32(uint256(uint128(_bias)) | (uint256(uint128(_slope)) << 128)));
    vm.store(address(_ve), bytes32(_slot0 + 1), bytes32(uint256(_ts) | (uint256(_permanent) << 48)));
  }

  /// @dev slopeChanges is mapping(uint48 => int128); each entry is alone in its slot, no packing issues.
  function _setSlopeChange(uint48 _ts, int128 _change) internal {
    stdstore.target(address(_ve)).sig(_ve.slopeChanges.selector).with_key(uint256(_ts))
      .checked_write_int(int256(_change));
  }

  /// @dev OZ ERC-721 stores `_operatorApprovals` at slot 5: mapping(owner => mapping(operator => bool)).
  function _setOperatorApproval(address _ownerAddr, address _operator, bool _approved) internal {
    bytes32 _outerSlot = keccak256(abi.encode(_ownerAddr, uint256(5)));
    bytes32 _innerSlot = keccak256(abi.encode(_operator, _outerSlot));
    vm.store(address(_ve), _innerSlot, bytes32(uint256(_approved ? 1 : 0)));
  }

  function _setDelegate(uint256 _tokenId, uint256 _delegatee) internal {
    stdstore.target(address(_ve)).sig(_ve.delegates.selector).with_key(_tokenId).checked_write(_delegatee);
  }

  function _setOwnershipChange(uint256 _tokenId, uint256 _blockNumber) internal {
    stdstore.target(address(_ve)).sig(_ve.ownershipChange.selector).with_key(_tokenId).checked_write(_blockNumber);
  }

  function _setNumCheckpoints(uint256 _tokenId, uint48 _count) internal {
    stdstore.target(address(_ve)).sig(_ve.numCheckpoints.selector).with_key(_tokenId).checked_write(uint256(_count));
  }

  /// @dev Checkpoint is a 4-slot struct: fromTimestamp, owner, delegatedBalance, delegatee.
  ///      stdStorage finds the base slot via the checkpoints getter; vm.store writes each field.
  function _setCheckpoint(
    uint256 _tokenId,
    uint48 _index,
    uint256 _fromTimestamp,
    address _ownerAddr,
    uint256 _delegatedBalance,
    uint256 _delegatee
  ) internal {
    uint256 _slot = stdstore.target(address(_ve)).sig(_ve.checkpoints.selector).with_key(_tokenId)
      .with_key(uint256(_index)).find();
    vm.store(address(_ve), bytes32(_slot), bytes32(_fromTimestamp));
    vm.store(address(_ve), bytes32(_slot + 1), bytes32(uint256(uint160(_ownerAddr))));
    vm.store(address(_ve), bytes32(_slot + 2), bytes32(_delegatedBalance));
    vm.store(address(_ve), bytes32(_slot + 3), bytes32(_delegatee));
  }

  /// @dev `_userPointHistory` is `mapping(uint256 => UserPoint[1_000_000_000])`; element `_loc` occupies two slots.
  ///      stdStorage finds the element base slot via the userPointHistory getter; vm.store writes both. UserPoint
  ///      packs as slot0 = bias|slope (int128 low | int128 high) and slot1 = ts|permanent (uint48 low | uint128 at
  ///      bit 48), mirroring the GlobalPoint layout in `_setPointHistory`. Also seeds `userPointEpoch[tokenId]`.
  function _setUserPoint(
    uint256 _tokenId,
    uint256 _loc,
    int128 _bias,
    int128 _slope,
    uint48 _ts,
    uint128 _permanent
  ) internal {
    uint256 _slot0 = stdstore.target(address(_ve)).sig(_ve.userPointHistory.selector).with_key(_tokenId).with_key(_loc)
      .find();
    vm.store(address(_ve), bytes32(_slot0), bytes32(uint256(uint128(_bias)) | (uint256(uint128(_slope)) << 128)));
    vm.store(address(_ve), bytes32(_slot0 + 1), bytes32(uint256(_ts) | (uint256(_permanent) << 48)));
    stdstore.target(address(_ve)).sig(_ve.userPointEpoch.selector).with_key(_tokenId).checked_write(_loc);
  }

  function _setNonce(address _account, uint256 _nonce) internal {
    stdstore.target(address(_ve)).sig(_ve.nonces.selector).with_key(_account).checked_write(_nonce);
  }

  /// @dev OZ ERC-721 stores per-token approvals (`_tokenApprovals`) at slot 4: mapping(tokenId => approved spender).
  function _setTokenApproval(uint256 _tokenId, address _approved) internal {
    bytes32 _slot = keccak256(abi.encode(_tokenId, uint256(4)));
    vm.store(address(_ve), _slot, bytes32(uint256(uint160(_approved))));
  }

  function _mockTransferFrom(address _from, address _to, uint256 _value) internal {
    vm.mockCall(_token, abi.encodeCall(IERC20.transferFrom, (_from, _to, _value)), abi.encode(true));
  }

  function _mockTransfer(address _to, uint256 _value) internal {
    vm.mockCall(_token, abi.encodeCall(IERC20.transfer, (_to, _value)), abi.encode(true));
  }

  /// @dev Assert invariants on the latest global point. Should hold after any operation that
  ///      triggers `_checkpoint`. Catches the accumulator drift bug behind codex finding 1
  ///      (permanentStakeBalance) plus stale-snapshot bugs (ts). Bias/slope are intentionally
  ///      not checked here — they're test-specific aggregates, asserted per-test where tractable.
  function _assertGlobalPointInvariants() internal view {
    uint256 _epoch = _ve.epoch();
    IVotingEscrow.GlobalPoint memory _p = _ve.pointHistory(_epoch);
    assertEq(_p.permanentStakeBalance, _ve.permanentStakeBalance(), 'global snapshot drift');
    assertEq(uint256(_p.ts), block.timestamp, 'global point ts mismatch');
  }

  /// @dev Assert the public voting-power read APIs at block.timestamp: total supply and per-token balance.
  ///      For multi-token tests where a single per-token balance is not meaningful, assert
  ///      `totalVotingPowerAt` inline instead.
  function _assertVotingPower(
    uint256 _expectedTotalSupply,
    uint256 _tokenId,
    uint256 _expectedTokenBalance
  ) internal view {
    assertEq(_ve.totalVotingPowerAt(block.timestamp), _expectedTotalSupply, 'totalVotingPowerAt drift');
    assertEq(_ve.balanceOfNFT(_tokenId), _expectedTokenBalance, 'balanceOfNFT drift');
  }
}
