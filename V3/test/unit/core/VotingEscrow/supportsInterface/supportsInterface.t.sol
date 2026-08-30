// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IAccessControlEnumerable} from '@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol';
import {IERC5267} from '@openzeppelin/contracts/interfaces/IERC5267.sol';
import {IERC6372} from '@openzeppelin/contracts/interfaces/IERC6372.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol';
import {IERC721Metadata} from '@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowSupportsInterface is BaseVotingEscrow {
  function test_WhenTheInterfaceIsSupported() external view {
    // it should return true
    assertTrue(_ve.supportsInterface(type(IERC165).interfaceId));
    assertTrue(_ve.supportsInterface(type(IERC721).interfaceId));
    assertTrue(_ve.supportsInterface(type(IERC721Metadata).interfaceId));
    assertTrue(_ve.supportsInterface(type(IERC721Enumerable).interfaceId));
    assertTrue(_ve.supportsInterface(bytes4(0x49064906))); // ERC4906
    assertTrue(_ve.supportsInterface(type(IERC5267).interfaceId));
    assertTrue(_ve.supportsInterface(type(IERC6372).interfaceId));
    assertTrue(_ve.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(_ve.supportsInterface(type(IAccessControlEnumerable).interfaceId));
    assertTrue(_ve.supportsInterface(type(IVotingEscrow).interfaceId));
  }

  function test_WhenTheInterfaceIsNotSupported(bytes4 _interfaceId) external view {
    vm.assume(_interfaceId != type(IERC165).interfaceId);
    vm.assume(_interfaceId != type(IERC721).interfaceId);
    vm.assume(_interfaceId != type(IERC721Metadata).interfaceId);
    vm.assume(_interfaceId != type(IERC721Enumerable).interfaceId);
    vm.assume(_interfaceId != bytes4(0x49064906));
    vm.assume(_interfaceId != type(IERC5267).interfaceId);
    vm.assume(_interfaceId != type(IERC6372).interfaceId);
    vm.assume(_interfaceId != type(IAccessControl).interfaceId);
    vm.assume(_interfaceId != type(IAccessControlEnumerable).interfaceId);
    vm.assume(_interfaceId != type(IVotingEscrow).interfaceId);

    // it should return false
    assertFalse(_ve.supportsInterface(_interfaceId));
  }
}
