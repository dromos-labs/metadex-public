// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {BasePoolTape} from 'V3/pools/tape/BasePoolTape.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

abstract contract UnitBasePoolTape is TestHelpers {
  uint32 internal constant _DEFAULT_CADENCE = 60;

  address internal _owner = makeAddr('owner');
  BasePoolTape internal _tape;

  function setUp() public virtual {
    _tape = _deployTape(_owner, _DEFAULT_CADENCE);
  }

  function test_ConstructorWhenTheDefaultCadenceIntervalIsEqToZero() external {
    // it reverts with ZeroCadenceInterval
    vm.expectRevert(IBasePoolTape.ZeroCadenceInterval.selector);
    _deployTape(_owner, 0);
  }

  function test_ConstructorWhenTheDefaultCadenceIntervalIsGtZero(address __owner, uint32 _interval) external {
    vm.assume(__owner != address(0));
    _interval = uint32(bound(_interval, 1, type(uint32).max));
    // it emits DefaultCadenceIntervalSet
    vm.expectEmit();
    emit IBasePoolTape.DefaultCadenceIntervalSet(_interval);
    _tape = _deployTape(__owner, _interval);
    // it sets the owner
    assertEq(_tape.owner(), __owner);
    // it stores the default cadence interval
    assertEq(_tape.defaultCadenceInterval(), _interval);
  }

  function test_SetDefaultCadenceIntervalWhenTheCallerIsNotTheOwner(address _caller) external {
    vm.assume(_caller != _owner);
    // it reverts with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _tape.setDefaultCadenceInterval(0);
  }

  modifier whenTheCallerIsTheOwner() {
    vm.startPrank(_owner);
    _;
    vm.stopPrank();
  }

  function test_SetDefaultCadenceIntervalWhenTheIntervalIsEqToZero() external whenTheCallerIsTheOwner {
    // it reverts with ZeroCadenceInterval
    vm.expectRevert(IBasePoolTape.ZeroCadenceInterval.selector);
    _tape.setDefaultCadenceInterval(0);
  }

  function test_SetDefaultCadenceIntervalWhenTheIntervalIsGtZero(uint32 _interval) external whenTheCallerIsTheOwner {
    _interval = uint32(bound(_interval, 1, type(uint32).max));
    // it emits DefaultCadenceIntervalSet
    vm.expectEmit();
    emit IBasePoolTape.DefaultCadenceIntervalSet(_interval);
    _tape.setDefaultCadenceInterval(_interval);
    // it updates the default cadence interval
    assertEq(_tape.defaultCadenceInterval(), _interval);
  }

  function test_SetPoolCadenceWhenTheCallerIsNotTheOwner(address _caller, address _pool) external {
    vm.assume(_caller != _owner);
    // it reverts with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _tape.setPoolCadence(_pool, 0);
  }

  function test_SetPoolCadenceWhenTheCallerIsTheOwner(
    address _pool,
    address _caller,
    uint32 _cadence
  ) external whenTheCallerIsTheOwner {
    _cadence = uint32(bound(_cadence, 1, type(uint32).max));
    _setPoolConfig({_poolAddress: _pool, _configCaller: _caller, _cadence: 0});
    // it emits PoolCadenceSet
    vm.expectEmit();
    emit IBasePoolTape.PoolCadenceSet(_pool, _cadence);
    _tape.setPoolCadence(_pool, _cadence);
    // it stores the per pool cadence
    assertEq(_tape.poolCadence(_pool), _cadence);
  }

  function test_SetPoolCadenceWhenTheCadenceIsEqToZero(
    address _pool,
    uint32 _cadence
  ) external whenTheCallerIsTheOwner {
    _cadence = uint32(bound(_cadence, 1, type(uint32).max));
    _setPoolConfig({_poolAddress: _pool, _configCaller: address(0), _cadence: _cadence});
    _tape.setPoolCadence(_pool, 0);
    // it stores the default cadence
    assertEq(_tape.poolCadence(_pool), _DEFAULT_CADENCE);
  }

  function test_SetAllowedCallerAndInitializePoolWhenTheCallerIsNotTheOwner(address _caller) external {
    vm.assume(_caller != _owner);
    // it reverts with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _tape.setAllowedCallerAndInitializePool(address(0), address(0));
  }

  function test_SetAllowedCallerAndInitializePoolWhenTheCallerIsTheOwner(
    address _caller,
    address _pool
  ) external whenTheCallerIsTheOwner {
    // it emits AllowedCallerSet
    vm.expectEmit();
    emit IBasePoolTape.AllowedCallerSet(_pool, _caller);
    _tape.setAllowedCallerAndInitializePool(_pool, _caller);
    // it stores the authorized caller
    assertEq(_tape.allowedCaller(_pool), _caller);
  }

  function test_SetAllowedCallerAndInitializePoolWhenThePoolCadenceIsNotSet(
    address _caller,
    address _pool
  ) external whenTheCallerIsTheOwner {
    // it emits PoolCadenceSet
    vm.expectEmit();
    emit IBasePoolTape.PoolCadenceSet(_pool, _DEFAULT_CADENCE);

    _tape.setAllowedCallerAndInitializePool(_pool, _caller);

    // it sets the default cadence into the pool config
    assertEq(_tape.poolCadence(_pool), _DEFAULT_CADENCE);
  }

  function test_SetAllowedCallerAndInitializePoolWhenThePoolCadenceIsSet(
    address _caller,
    address _pool,
    uint32 _cadence
  ) external whenTheCallerIsTheOwner {
    _cadence = uint32(bound(_cadence, 1, type(uint32).max));
    _setPoolConfig({_poolAddress: _pool, _configCaller: address(0), _cadence: _cadence});
    _tape.setAllowedCallerAndInitializePool(_pool, _caller);
    // it preserves the pool cadence
    assertEq(_tape.poolCadence(_pool), _cadence);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Writes a pool config
  function _setPoolConfig(address _poolAddress, address _configCaller, uint32 _cadence) internal {
    uint256 _slot = uint256(keccak256(abi.encode(_poolAddress, uint256(2))));
    vm.store(address(_tape), bytes32(_slot), bytes32(uint256(uint160(_configCaller)) | (uint256(_cadence) << 160)));
  }

  /// @dev Child contract deploys the pool tape implementation.
  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal virtual returns (BasePoolTape);
}
