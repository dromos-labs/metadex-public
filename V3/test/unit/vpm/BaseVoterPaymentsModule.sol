// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';
import {VoterPaymentsModule} from 'V3/vpm/VoterPaymentsModule.sol';

abstract contract BaseVoterPaymentsModule is TestHelpers {
  address internal _deployer = makeAddr('Deployer');
  address internal _ve = makeAddr('VE');
  address internal _feeManagerAdmin = makeAddr('FeeManagerAdmin');

  VoterPaymentsModule internal _vpm;

  function setUp() external virtual {
    vm.prank(_deployer);
    _vpm = new VoterPaymentsModule(_ve, _feeManagerAdmin);
  }

  /*//////////////////////////////////////////////////////////////
                          VE MOCK HELPERS
  //////////////////////////////////////////////////////////////*/

  function _mockIsAuthorized(address _caller, uint256 _tokenId, bool _ok) internal {
    vm.mockCall(_ve, abi.encodeCall(IVotingEscrow.isAuthorized, (_caller, _tokenId)), abi.encode(_ok));
  }

  function _mockOwnerOf(uint256 _tokenId, address _owner) internal {
    vm.mockCall(_ve, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_owner));
  }

  function _mockVERebalanceUnderlying(
    IVotingEscrow.SourceDelta[] memory _sources,
    IVotingEscrow.DestinationDelta[] memory _destinations,
    uint256[] memory _mintedIds
  ) internal {
    vm.mockCall(
      _ve, abi.encodeCall(IVotingEscrow.rebalanceUnderlying, (_sources, _destinations)), abi.encode(_mintedIds)
    );
  }

  /*//////////////////////////////////////////////////////////////
                          STORAGE HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @dev `fees` lives at storage slot 2. Slot for fees[_sig][_caller]:
  ///      outer = keccak256(abi.encode(bytes32(_sig), 2))
  ///      inner = keccak256(abi.encode(_caller, outer))
  ///      CallerInfo packs (bool registered, uint128 rateInPips):
  ///        registered in bits 0-7, rateInPips in bits 8-135.
  function _setFee(bytes4 _sig, address _caller, bool _registered, uint128 _rateInPips) internal {
    bytes32 _outerSlot = keccak256(abi.encode(bytes32(_sig), uint256(2)));
    bytes32 _innerSlot = keccak256(abi.encode(_caller, _outerSlot));
    uint256 _packed = uint256(_registered ? 1 : 0) | (uint256(_rateInPips) << 8);
    vm.store(address(_vpm), _innerSlot, bytes32(_packed));
  }

  /// @dev `restricted` lives at storage slot 3. Slot for restricted[_sig]:
  ///      keccak256(abi.encode(bytes32(_sig), 3))
  function _setRestricted(bytes4 _sig, bool _value) internal {
    bytes32 _slot = keccak256(abi.encode(bytes32(_sig), uint256(3)));
    vm.store(address(_vpm), _slot, bytes32(uint256(_value ? 1 : 0)));
  }

  /// @dev AccessControl `_roles` lives at storage slot 0. Slot for `_roles[_role].hasRole[_account]`:
  ///      roleData = keccak256(abi.encode(_role, 0)); hasRole = keccak256(abi.encode(_account, roleData)).
  ///      Only the `hasRole` bit is set; the enumerable member set is not consulted by `onlyRole`.
  function _setRole(bytes32 _role, address _account) internal {
    bytes32 _roleDataSlot = keccak256(abi.encode(_role, uint256(0)));
    bytes32 _hasRoleSlot = keccak256(abi.encode(_account, _roleDataSlot));
    vm.store(address(_vpm), _hasRoleSlot, bytes32(uint256(1)));
  }
}
