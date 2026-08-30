// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVotingRewardsFactory} from 'V3/interfaces/rewards/IVotingRewardsFactory.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {VotingRewardsFactory} from 'V3/rewards/VotingRewardsFactory.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitVotingRewardsFactory is TestHelpers {
  address internal _voter = makeAddr('voter');
  address internal _factoryRegistry = makeAddr('factoryRegistry');
  address internal _wrappedNative = makeAddr('wrappedNative');
  address internal _gaugeFactory = makeAddr('gaugeFactory');

  VotingRewardsFactory internal _factory;

  function setUp() public {
    vm.mockCall(_voter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistry));
    _factory = new VotingRewardsFactory({_voter: _voter, _wrappedNative: _wrappedNative});
  }

  /*////////////////////////////////////////////////////////////
            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenTheVoterIsTheZeroAddress() external {
    // it should revert with {ZeroAddress}
    vm.expectRevert(IVotingRewardsFactory.ZeroAddress.selector);
    new VotingRewardsFactory({_voter: address(0), _wrappedNative: _wrappedNative});
  }

  function test_ConstructorWhenTheWrappedNativeIsTheZeroAddress() external {
    // it should revert with {ZeroAddress}
    vm.expectRevert(IVotingRewardsFactory.ZeroAddress.selector);
    new VotingRewardsFactory({_voter: _voter, _wrappedNative: address(0)});
  }

  function test_ConstructorWhenTheVoterReportsAZeroFactoryRegistry(address _voterFuzz) external {
    _assumeFuzzable(_voterFuzz);
    vm.mockCall(_voterFuzz, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(address(0)));

    // it should revert with {ZeroAddress}
    vm.expectRevert(IVotingRewardsFactory.ZeroAddress.selector);
    new VotingRewardsFactory({_voter: _voterFuzz, _wrappedNative: _wrappedNative});
  }

  function test_ConstructorWhenTheContractIsDeployed(
    address _voterFuzz,
    address _factoryRegistryFuzz,
    address _wrappedNativeFuzz
  ) external {
    _assumeFuzzable(_voterFuzz);
    vm.assume(_factoryRegistryFuzz != address(0));
    vm.assume(_wrappedNativeFuzz != address(0));
    vm.mockCall(_voterFuzz, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistryFuzz));

    VotingRewardsFactory _newFactory =
      new VotingRewardsFactory({_voter: _voterFuzz, _wrappedNative: _wrappedNativeFuzz});

    // it should set the voter
    assertEq(_newFactory.voter(), _voterFuzz);
    // it should set the factory registry reported by the voter
    assertEq(_newFactory.FACTORY_REGISTRY(), _factoryRegistryFuzz);
    // it should set the wrappedNative
    assertEq(_newFactory.wrappedNative(), _wrappedNativeFuzz);
  }

  /*////////////////////////////////////////////////////////////
            CREATE REWARDS
  ////////////////////////////////////////////////////////////*/

  function test_CreateRewardsWhenTheCallerIsNotAnApprovedGaugeFactory(address _caller, address _gauge) external {
    _assumeFuzzable(_caller);
    address[] memory _rewards = new address[](0);

    _mockAndExpect(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isGaugeFactoryApproved, (_caller)), abi.encode(false)
    );

    // it should revert with {NotAuthorized}
    vm.prank(_caller);
    vm.expectRevert(IVotingRewardsFactory.NotAuthorized.selector);
    _factory.createRewards({_gauge: _gauge, _rewards: _rewards});
  }

  function test_CreateRewardsWhenTheCallerIsAnApprovedGaugeFactory(address _gauge, uint8 _rewardsLength) external {
    _assumeFuzzable(_gauge);
    // VRM constructor requires at least two reward tokens (token0 + token1 for FeeDistribution).
    uint256 _length = bound(_rewardsLength, 2, type(uint8).max);
    address[] memory _rewards = new address[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _rewards[_i] = makeAddr(string.concat('reward', vm.toString(_i)));
    }

    _mockAndExpect(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isGaugeFactoryApproved, (_gaugeFactory)), abi.encode(true)
    );

    address _expectedVotingRewardsManager = _computeCreate({_deployer: address(_factory), _nonce: 1});

    // it should emit VotingRewardsCreated
    _expectEmit(address(_factory));
    emit IVotingRewardsFactory.VotingRewardsCreated({
      _gauge: _gauge, _votingRewardsManager: _expectedVotingRewardsManager
    });

    vm.prank(_gaugeFactory);
    address _votingRewardsManager = _factory.createRewards({_gauge: _gauge, _rewards: _rewards});

    // it should deploy a new VotingRewardsManager
    assertGt(_votingRewardsManager.code.length, 0);
    // it should return the deployed VotingRewardsManager address
    assertEq(_votingRewardsManager, _expectedVotingRewardsManager);
    // it should set the immutables on the deployed VotingRewardsManager
    assertEq(IVotingRewardsManager(_votingRewardsManager).voter(), _voter);
    assertEq(IVotingRewardsManager(_votingRewardsManager).gaugeFactory(), _gaugeFactory);
  }

  /*////////////////////////////////////////////////////////////
            GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_createRewards() external {
    address _gauge = makeAddr('gauge');
    address[] memory _rewards = new address[](2);
    _rewards[0] = makeAddr('token0');
    _rewards[1] = makeAddr('token1');
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isGaugeFactoryApproved, (_gaugeFactory)), abi.encode(true)
    );
    vm.prank(_gaugeFactory);
    _factory.createRewards({_gauge: _gauge, _rewards: _rewards});
    vm.snapshotGasLastCall('VotingRewardsFactory_createRewards');
  }
}
