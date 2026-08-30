// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {UnitBasePoolTape} from 'V3-test/unit/pools/tape/BasePoolTape/BasePoolTape.t.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {BasePoolTape} from 'V3/pools/tape/BasePoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

contract UnitClPoolTapeSetElasticFeeModule is UnitBasePoolTape {
  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (BasePoolTape) {
    return new CLPoolTape(_initialOwner, _defaultCadenceInterval);
  }

  function test_WhenTheCallerIsNotTheOwner(address _invalidCaller) external {
    vm.assume(_invalidCaller != _owner);
    // it reverts with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _invalidCaller));
    vm.prank(_invalidCaller);
    CLPoolTape(address(_tape)).setElasticFeeModule(address(0));
  }

  function test_WhenTheCallerIsTheOwner(address _newModule) external {
    // it stores the elastic fee module
    // it emits ElasticFeeModuleSet
    vm.expectEmit();
    emit ICLPoolTape.ElasticFeeModuleSet(_newModule);
    vm.prank(_owner);
    CLPoolTape(address(_tape)).setElasticFeeModule(_newModule);
    assertEq(CLPoolTape(address(_tape)).elasticFeeModule(), _newModule);
  }
}
