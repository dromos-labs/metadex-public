// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2EpochGovernor} from 'V3/interfaces/migration/v2/IV2EpochGovernor.sol';
import {IV2Minter} from 'V3/interfaces/migration/v2/IV2Minter.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationDecreaseTailEmissionRate is UnitAerodromeMigration {
  function setUp() public override {
    super.setUp();
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_WhenTheCallerIsNotTheOwner(address _caller) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.decreaseTailEmissionRate();
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  modifier whenTheV2TailEmissionRateIncreases() {
    vm.prank(_owner);
    _migration.setResult(IV2EpochGovernor.ProposalState.Succeeded);
    _;
  }

  function test_WhenTheV2TailEmissionRateIncreases()
    external
    whenTheCallerIsTheOwner
    whenTheV2TailEmissionRateIncreases
  {
    _mockAndExpectTailEmissionRates({_previousRate: 1, _newRate: 2, _expectedCalls: 4});
    _mockAndExpect(_v2Minter, abi.encodeCall(IV2Minter.nudge, ()), '');

    // it should revert with TailEmissionRateNotDecreased
    vm.expectRevert(IMigration.TailEmissionRateNotDecreased.selector);
    vm.prank(_owner);
    _migration.decreaseTailEmissionRate();

    // it should succeed after setting the result to Defeated
    vm.prank(_owner);
    _migration.setResult(IV2EpochGovernor.ProposalState.Defeated);
    _mockTailEmissionRates({_previousRate: 2, _newRate: 1});

    vm.prank(_owner);
    _migration.decreaseTailEmissionRate();
  }

  modifier whenTheV2TailEmissionRateRemainsUnchanged() {
    vm.prank(_owner);
    _migration.setResult(IV2EpochGovernor.ProposalState.Expired);
    _;
  }

  function test_WhenTheV2TailEmissionRateRemainsUnchanged()
    external
    whenTheCallerIsTheOwner
    whenTheV2TailEmissionRateRemainsUnchanged
  {
    _mockAndExpectTailEmissionRates({_previousRate: 1, _newRate: 1, _expectedCalls: 4});
    _mockAndExpect(_v2Minter, abi.encodeCall(IV2Minter.nudge, ()), '');

    // it should revert with TailEmissionRateNotDecreased
    vm.expectRevert(IMigration.TailEmissionRateNotDecreased.selector);
    vm.prank(_owner);
    _migration.decreaseTailEmissionRate();

    // it should succeed after setting the result to Defeated
    vm.prank(_owner);
    _migration.setResult(IV2EpochGovernor.ProposalState.Defeated);
    _mockTailEmissionRates({_previousRate: 2, _newRate: 1});

    vm.prank(_owner);
    _migration.decreaseTailEmissionRate();
  }

  modifier whenTheV2TailEmissionRateDecreases() {
    vm.prank(_owner);
    _migration.setResult(IV2EpochGovernor.ProposalState.Defeated);
    _;
  }

  function test_WhenTheContractIsUnpaused() external whenTheCallerIsTheOwner whenTheV2TailEmissionRateDecreases {
    _mockAndExpectTailEmissionRates({_previousRate: 2, _newRate: 1, _expectedCalls: 2});
    // it should nudge the V2 Minter
    _mockAndExpect(_v2Minter, abi.encodeCall(IV2Minter.nudge, ()), '');

    vm.prank(_owner);
    // it should emit the NudgeExecuted event
    _expectEmit(address(_migration));
    emit IMigration.NudgeExecuted();
    _migration.decreaseTailEmissionRate();
  }

  function test_WhenTheContractIsPaused() external whenTheCallerIsTheOwner whenTheV2TailEmissionRateDecreases {
    _setPaused(true);

    _mockAndExpectTailEmissionRates({_previousRate: 2, _newRate: 1, _expectedCalls: 2});
    // it should nudge the V2 Minter
    _mockAndExpect(_v2Minter, abi.encodeCall(IV2Minter.nudge, ()), '');

    vm.prank(_owner);
    // it should emit the NudgeExecuted event
    _expectEmit(address(_migration));
    emit IMigration.NudgeExecuted();
    _migration.decreaseTailEmissionRate();
  }

  function testGas_decreaseTailEmissionRate() external {
    _mockAndExpectTailEmissionRates({_previousRate: 2, _newRate: 1, _expectedCalls: 2});
    _mockAndExpect(_v2Minter, abi.encodeCall(IV2Minter.nudge, ()), '');

    vm.prank(_owner);
    _migration.decreaseTailEmissionRate();
    vm.snapshotGasLastCall('AerodromeMigration_decreaseTailEmissionRate');
  }

  /// @dev Mocks and expects the tail emission rate reads before and after the nudge
  function _mockAndExpectTailEmissionRates(uint256 _previousRate, uint256 _newRate, uint64 _expectedCalls) internal {
    bytes memory _calldata = abi.encodeCall(IV2Minter.tailEmissionRate, ());
    bytes[] memory _returns = new bytes[](2);
    _returns[0] = abi.encode(_previousRate);
    _returns[1] = abi.encode(_newRate);
    vm.mockCalls(_v2Minter, _calldata, _returns);
    vm.expectCall(_v2Minter, _calldata, _expectedCalls);
  }

  /// @dev Mocks the tail emission rate reads before and after the nudge
  function _mockTailEmissionRates(uint256 _previousRate, uint256 _newRate) internal {
    bytes[] memory _returns = new bytes[](2);
    _returns[0] = abi.encode(_previousRate);
    _returns[1] = abi.encode(_newRate);
    vm.mockCalls(_v2Minter, abi.encodeCall(IV2Minter.tailEmissionRate, ()), _returns);
  }
}
