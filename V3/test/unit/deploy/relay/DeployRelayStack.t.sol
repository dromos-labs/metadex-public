// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {CreateXLibrary} from 'V3/libraries/CreateXLibrary.sol';

import {Constants} from 'V3-script/Constants.sol';
import {DeployFixture} from 'V3-script/DeployFixture.sol';
import {DeployPoolsFixture} from 'V3-script/DeployPoolsFixture.s.sol';
import {DeployRelayStackFixture} from 'V3-script/DeployRelayStackFixture.s.sol';
import {DeployPools} from 'V3-script/deployParameters/base/DeployPools.s.sol';
import {DeployRelayStack} from 'V3-script/deployParameters/base/DeployRelayStack.s.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/**
 * @notice The relay unit deploys through CreateX, and a create3 address is a pure function of
 *         (deployer, entropy). Every V3 unit shares one deployer, so an entropy another unit claims is
 *         an address this one cannot take at all: CreateX places its create3 proxy with create2, and
 *         the proxy from the first run is already sitting there. These tests hold the relay's five
 *         entropies clear of every other unit, which is what lets the units be deployed in any order.
 */
contract UnitDeployRelayStack is TestHelpers, Constants {
  uint32 public constant POOLS_CADENCE_INTERVAL = 300;

  /// @notice Gas limits the pool factories forward to the tape and the fee module, mirroring the
  ///         pool deployment suite.
  uint32 public constant POOL_TAPE_GAS_LIMIT = 200_000;

  /// @notice Gas limit the pool factories forward to the fee module.
  uint32 public constant FEE_MODULE_GAS_LIMIT = 60_000;

  address public immutable TEST_DEPLOYER = makeAddr('testDeployer');

  DeployRelayStack public relayDeploy;

  DeployRelayStackFixture.DeploymentParameters internal _relayParams;

  function setUp() public {
    _etchCreateX(CREATEX_ADDRESS);

    address _votingEscrow = _mockContract('votingEscrow');
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.TOKEN, ()), abi.encode(_mockContract('token')));

    _relayParams = DeployRelayStackFixture.DeploymentParameters({
      chainId: block.chainid,
      votingEscrow: IVotingEscrow(_votingEscrow),
      vpm: IVoterPaymentsModule(_mockContract('vpm')),
      voter: IVoter(_mockContract('voter')),
      governor: IGovernor(_mockContract('governor')),
      wrappedNative: _mockContract('wrappedNative'),
      outputFilename: 'relaystack-base.json'
    });

    relayDeploy = new DeployRelayStack();
    relayDeploy.setParams(_relayParams);
    relayDeploy.setDeployer(TEST_DEPLOYER);
    relayDeploy.setIsTest(true);
  }

  modifier whenParametersAreNotValid() {
    _;
  }

  function test_WhenTheChainIdDoesNotMatchTheCurrentChain(uint256 _wrongChainId) external whenParametersAreNotValid {
    vm.assume(_wrongChainId != block.chainid);
    _relayParams.chainId = _wrongChainId;
    relayDeploy.setParams(_relayParams);

    // it should revert with ChainIdMismatch
    vm.expectRevert(DeployFixture.ChainIdMismatch.selector);
    relayDeploy.run();
  }

  function test_WhenTheVotingEscrowIsTheZeroAddress() external whenParametersAreNotValid {
    _relayParams.votingEscrow = IVotingEscrow(address(0));
    relayDeploy.setParams(_relayParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    relayDeploy.run();
  }

  function test_WhenThePaymentsModuleIsTheZeroAddress() external whenParametersAreNotValid {
    _relayParams.vpm = IVoterPaymentsModule(address(0));
    relayDeploy.setParams(_relayParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    relayDeploy.run();
  }

  function test_WhenTheVoterIsTheZeroAddress() external whenParametersAreNotValid {
    _relayParams.voter = IVoter(address(0));
    relayDeploy.setParams(_relayParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    relayDeploy.run();
  }

  function test_WhenTheGovernorIsTheZeroAddress() external whenParametersAreNotValid {
    _relayParams.governor = IGovernor(address(0));
    relayDeploy.setParams(_relayParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    relayDeploy.run();
  }

  function test_WhenTheShippedParametersAreStillPlaceholders() external {
    // The Base class ships with zeros until the core unit exists to fill them from.
    DeployRelayStack _shipped = new DeployRelayStack();
    _shipped.setUp();
    _shipped.setDeployer(TEST_DEPLOYER);
    _shipped.setIsTest(true);

    // it should revert rather than deploy a stack bound to nothing
    vm.chainId(8453);
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    _shipped.run();
  }

  function test_WhenNoOtherDeploymentUnitHasRun() external {
    relayDeploy.run();

    // it should deploy every contract at its deterministic create three address
    _assertDeterministicAddresses();
  }

  function test_WhenThePoolsUnitRanFirstUnderTheSameDeployer() external {
    DeployPools _poolsDeploy = _runPoolsUnit();

    relayDeploy.run();

    // it should deploy every contract at its deterministic create three address
    _assertDeterministicAddresses();

    // it should leave the pool unit addresses untouched
    assertEq(
      address(_poolsDeploy.volatilePoolImplementation()),
      CreateXLibrary.computeCreate3Address({_entropy: VOLATILE_POOL_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(_poolsDeploy.volatilePoolFactory()),
      CreateXLibrary.computeCreate3Address({_entropy: VOLATILE_POOL_FACTORY_ENTROPY, _deployer: TEST_DEPLOYER})
    );
  }

  function test_WhenReadingTheRelayEntropiesAgainstTheDeploymentRegistry() external view {
    // it should share no entropy with another deployment unit
    assertTrue(_isFree(MAXI_RELAY_IMPLEMENTATION_ENTROPY));
    assertTrue(_isFree(PROTOCOL_RELAY_IMPLEMENTATION_ENTROPY));
    assertTrue(_isFree(RELAY_TOKEN_IMPLEMENTATION_ENTROPY));
    assertTrue(_isFree(RELAY_TOKEN_VOTES_IMPLEMENTATION_ENTROPY));
    assertTrue(_isFree(RELAY_FACTORY_ENTROPY));
  }

  /// @notice Asserts each deployed contract sits at the create3 address its entropy resolves to.
  function _assertDeterministicAddresses() internal view {
    assertEq(
      address(relayDeploy.relayTokenImplementation()),
      CreateXLibrary.computeCreate3Address({_entropy: RELAY_TOKEN_IMPLEMENTATION_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(relayDeploy.relayTokenVotesImplementation()),
      CreateXLibrary.computeCreate3Address({
        _entropy: RELAY_TOKEN_VOTES_IMPLEMENTATION_ENTROPY, _deployer: TEST_DEPLOYER
      })
    );
    assertEq(
      address(relayDeploy.maxiRelayImplementation()),
      CreateXLibrary.computeCreate3Address({_entropy: MAXI_RELAY_IMPLEMENTATION_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(relayDeploy.protocolRelayImplementation()),
      CreateXLibrary.computeCreate3Address({_entropy: PROTOCOL_RELAY_IMPLEMENTATION_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(relayDeploy.relayFactory()),
      CreateXLibrary.computeCreate3Address({_entropy: RELAY_FACTORY_ENTROPY, _deployer: TEST_DEPLOYER})
    );
  }

  /// @notice Runs the pool deployment unit through its real script, under the relay's deployer.
  /// @return _poolsDeploy The script that ran, for reading the addresses it took.
  function _runPoolsUnit() internal returns (DeployPools _poolsDeploy) {
    _poolsDeploy = new DeployPools();
    _poolsDeploy.setParams(
      DeployPoolsFixture.DeploymentParameters({
        chainId: block.chainid,
        poolAdmin: makeAddr('poolAdmin'),
        pauser: makeAddr('pauser'),
        feeManager: makeAddr('feeManager'),
        poolTapeManager: makeAddr('poolTapeManager'),
        discountRegistryManager: makeAddr('discountRegistryManager'),
        poolTapeOwner: makeAddr('poolTapeOwner'),
        discountRegistryOwner: makeAddr('discountRegistryOwner'),
        targetFactoryAdmin: makeAddr('targetFactoryAdmin'),
        defaultCadenceInterval: POOLS_CADENCE_INTERVAL,
        poolTapeGasLimit: POOL_TAPE_GAS_LIMIT,
        feeModuleGasLimit: FEE_MODULE_GAS_LIMIT,
        outputFilename: 'pools-base.json'
      })
    );
    _poolsDeploy.setDeployer(TEST_DEPLOYER);
    _poolsDeploy.setIsTest(true);
    _poolsDeploy.run();
  }

  /// @notice Whether no other V3 deployment unit claims `_entropy`.
  /// @param _entropy Entropy to look up.
  /// @return _free True when the entropy is unclaimed.
  function _isFree(bytes11 _entropy) internal pure returns (bool _free) {
    bytes11[] memory _claimed = _claimedEntropies();
    for (uint256 _i; _i < _claimed.length; ++_i) {
      if (_claimed[_i] == _entropy) return false;
    }
    _free = true;
  }

  /// @notice Every entropy another deployment unit claims. The relay's own five are excluded, which is
  ///         what makes this list the thing they are checked against.
  /// @dev The tail is the core unit's block, written as literals rather than by name. Those constants
  ///      arrive with the core unit, which is not on `V3` yet, so naming them would not compile here.
  ///      Leaving them out instead would let this pass by luck: the whole point is that the relay's
  ///      bytes clear every byte another unit will take, not only the ones already declared.
  /// @return _claimed The claimed entropies.
  function _claimedEntropies() internal pure returns (bytes11[] memory _claimed) {
    _claimed = new bytes11[](18);
    _claimed[0] = VOLATILE_POOL_ENTROPY;
    _claimed[1] = VOLATILE_POOL_FACTORY_ENTROPY;
    _claimed[2] = STABLE_POOL_ENTROPY;
    _claimed[3] = STABLE_POOL_FACTORY_ENTROPY;
    _claimed[4] = POOL_TAPE_ENTROPY;
    _claimed[5] = DISCOUNT_REGISTRY_ENTROPY;
    _claimed[6] = VOLATILE_CUSTOM_FEE_MODULE_ENTROPY;
    _claimed[7] = STABLE_CUSTOM_FEE_MODULE_ENTROPY;
    _claimed[8] = ROUTER_ENTROPY;
    _claimed[9] = VOTING_ESCROW_ENTROPY;
    _claimed[10] = MINTER_ENTROPY;
    _claimed[11] = VOTER_ENTROPY;
    _claimed[12] = FACTORY_REGISTRY_ENTROPY;
    // The core unit's block: Token, Splitter, VeArtProxy, VoterPaymentsModule, RootMessageOrchestrator.
    _claimed[13] = 0x0000000000000000000053;
    _claimed[14] = 0x0000000000000000000057;
    _claimed[15] = 0x0000000000000000000059;
    _claimed[16] = 0x000000000000000000005a;
    _claimed[17] = 0x000000000000000000005b;
  }
}
