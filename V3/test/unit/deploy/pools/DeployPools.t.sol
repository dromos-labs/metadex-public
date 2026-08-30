// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Constants} from 'V3-script/Constants.sol';
import {DeployFixture} from 'V3-script/DeployFixture.sol';
import {DeployPoolsFixture} from 'V3-script/DeployPoolsFixture.s.sol';
import {DeployPools} from 'V3-script/deployParameters/base/DeployPools.s.sol';
import {CreateXLibrary} from 'V3/libraries/CreateXLibrary.sol';

import {FactoryRegistry} from 'V3/factories/FactoryRegistry.sol';
import {PoolFactory} from 'V3/factories/PoolFactory.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitDeployPools is TestHelpers, Constants {
  uint32 public constant DEFAULT_CADENCE_INTERVAL = 300;
  uint32 public constant POOL_TAPE_GAS_LIMIT = 200_000;
  uint32 public constant FEE_MODULE_GAS_LIMIT = 60_000;

  address public immutable POOL_ADMIN = makeAddr('poolAdmin');
  address public immutable PAUSER = makeAddr('pauser');
  address public immutable FEE_MANAGER = makeAddr('feeManager');
  address public immutable POOL_TAPE_MANAGER = makeAddr('poolTapeManager');
  address public immutable DISCOUNT_REGISTRY_MANAGER = makeAddr('discountRegistryManager');
  address public immutable POOL_TAPE_OWNER = makeAddr('poolTapeOwner');
  address public immutable DISCOUNT_REGISTRY_OWNER = makeAddr('discountRegistryOwner');
  address public immutable TARGET_FACTORY_ADMIN = makeAddr('targetFactoryAdmin');
  address public immutable TEST_DEPLOYER = makeAddr('testDeployer');

  DeployPoolsFixture.DeploymentParameters internal _poolsParams;
  DeployPools public poolsDeploy;

  function setUp() public {
    _etchCreateX(CREATEX_ADDRESS);
    poolsDeploy = new DeployPools();

    _buildPoolsParams();
    poolsDeploy.setParams(_poolsParams);
    poolsDeploy.setDeployer(TEST_DEPLOYER);
    poolsDeploy.setIsTest(true);
  }

  function _buildPoolsParams() internal {
    _poolsParams.chainId = block.chainid;
    _poolsParams.poolAdmin = POOL_ADMIN;
    _poolsParams.pauser = PAUSER;
    _poolsParams.feeManager = FEE_MANAGER;
    _poolsParams.poolTapeManager = POOL_TAPE_MANAGER;
    _poolsParams.discountRegistryManager = DISCOUNT_REGISTRY_MANAGER;
    _poolsParams.poolTapeOwner = POOL_TAPE_OWNER;
    _poolsParams.discountRegistryOwner = DISCOUNT_REGISTRY_OWNER;
    _poolsParams.targetFactoryAdmin = TARGET_FACTORY_ADMIN;
    _poolsParams.defaultCadenceInterval = DEFAULT_CADENCE_INTERVAL;
    _poolsParams.poolTapeGasLimit = POOL_TAPE_GAS_LIMIT;
    _poolsParams.feeModuleGasLimit = FEE_MODULE_GAS_LIMIT;
    _poolsParams.outputFilename = 'pools-base.json';
  }

  modifier whenParametersAreNotValid() {
    _;
  }

  function test_WhenTheChainIdDoesNotMatchTheCurrentChain(uint256 _wrongChainId) external whenParametersAreNotValid {
    vm.assume(_wrongChainId != block.chainid);
    _poolsParams.chainId = _wrongChainId;
    poolsDeploy.setParams(_poolsParams);

    // it should revert with ChainIdMismatch
    vm.expectRevert(DeployFixture.ChainIdMismatch.selector);
    poolsDeploy.run();
  }

  function test_WhenThePoolAdminIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.poolAdmin = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenThePauserIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.pauser = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenTheFeeManagerIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.feeManager = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenThePoolTapeManagerIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.poolTapeManager = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenTheDiscountRegistryManagerIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.discountRegistryManager = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenThePoolTapeOwnerIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.poolTapeOwner = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenTheDiscountRegistryOwnerIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.discountRegistryOwner = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenTheTargetFactoryAdminIsTheZeroAddress() external whenParametersAreNotValid {
    _poolsParams.targetFactoryAdmin = address(0);
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenTheDefaultCadenceIntervalIsZero() external whenParametersAreNotValid {
    _poolsParams.defaultCadenceInterval = 0;
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenThePoolTapeGasLimitIsZero() external whenParametersAreNotValid {
    _poolsParams.poolTapeGasLimit = 0;
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenTheFeeModuleGasLimitIsZero() external whenParametersAreNotValid {
    _poolsParams.feeModuleGasLimit = 0;
    poolsDeploy.setParams(_poolsParams);

    // it should revert with InvalidInput
    vm.expectRevert(DeployFixture.InvalidInput.selector);
    poolsDeploy.run();
  }

  function test_WhenAllParametersAreValid() external {
    poolsDeploy.run();

    PoolFactory _volatileFactory = poolsDeploy.volatilePoolFactory();
    PoolFactory _stableFactory = poolsDeploy.stablePoolFactory();
    FactoryRegistry _factoryRegistry = poolsDeploy.factoryRegistry();

    // it should link both pool factories to the deployed factory registry
    assertNotEq(address(_factoryRegistry), address(0));
    assertEq(_volatileFactory.factoryRegistry(), address(_factoryRegistry));
    assertEq(_stableFactory.factoryRegistry(), address(_factoryRegistry));

    // it should approve both pool factories as target factories
    assertTrue(_factoryRegistry.isTargetFactoryApproved(address(_volatileFactory)));
    assertTrue(_factoryRegistry.isTargetFactoryApproved(address(_stableFactory)));

    // it should hand the target factory admin over to the configured target factory admin
    assertEq(_factoryRegistry.targetFactoryAdmin(), TARGET_FACTORY_ADMIN);

    // it should leave the leaf voter unset
    assertEq(_factoryRegistry.leafVoter(), address(0));

    // it should set the volatile factory configuration eq to the deployment parameters
    assertEq(_volatileFactory.implementation(), address(poolsDeploy.volatilePoolImplementation()));
    assertEq(_volatileFactory.poolAdmin(), POOL_ADMIN);
    assertEq(_volatileFactory.pauser(), PAUSER);
    assertEq(_volatileFactory.feeManager(), FEE_MANAGER);
    assertEq(_volatileFactory.poolTapeManager(), POOL_TAPE_MANAGER);
    assertEq(_volatileFactory.discountRegistryManager(), DISCOUNT_REGISTRY_MANAGER);
    assertEq(_volatileFactory.poolTape(), address(poolsDeploy.poolTape()));
    assertEq(_volatileFactory.poolTapeGasLimit(), POOL_TAPE_GAS_LIMIT);
    assertEq(_volatileFactory.discountRegistry(), address(poolsDeploy.discountRegistry()));
    assertEq(_volatileFactory.feeModule(), address(poolsDeploy.volatileCustomFeeModule()));
    assertEq(_volatileFactory.feeModuleGasLimit(), FEE_MODULE_GAS_LIMIT);
    assertEq(_volatileFactory.exactOutFeeQuoter(), address(poolsDeploy.volatileFlatFeeQuoter()));
    assertEq(_volatileFactory.defaultFee(), 30);

    // it should set the stable factory configuration eq to the deployment parameters
    assertEq(_stableFactory.implementation(), address(poolsDeploy.stablePoolImplementation()));
    assertEq(_stableFactory.poolAdmin(), POOL_ADMIN);
    assertEq(_stableFactory.pauser(), PAUSER);
    assertEq(_stableFactory.feeManager(), FEE_MANAGER);
    assertEq(_stableFactory.poolTapeManager(), POOL_TAPE_MANAGER);
    assertEq(_stableFactory.discountRegistryManager(), DISCOUNT_REGISTRY_MANAGER);
    assertEq(_stableFactory.poolTape(), address(poolsDeploy.poolTape()));
    assertEq(_stableFactory.poolTapeGasLimit(), POOL_TAPE_GAS_LIMIT);
    assertEq(_stableFactory.discountRegistry(), address(poolsDeploy.discountRegistry()));
    assertEq(_stableFactory.feeModule(), address(poolsDeploy.stableCustomFeeModule()));
    assertEq(_stableFactory.feeModuleGasLimit(), FEE_MODULE_GAS_LIMIT);
    assertEq(_stableFactory.exactOutFeeQuoter(), address(poolsDeploy.stableFlatFeeQuoter()));
    assertEq(_stableFactory.defaultFee(), 5);

    // it should set the tape and registry owners and the default cadence interval
    assertEq(poolsDeploy.poolTape().owner(), POOL_TAPE_OWNER);
    assertEq(poolsDeploy.poolTape().defaultCadenceInterval(), DEFAULT_CADENCE_INTERVAL);
    assertEq(poolsDeploy.discountRegistry().owner(), DISCOUNT_REGISTRY_OWNER);

    // it should set each fee module and flat fee quoter factory eq to its pool factory
    assertEq(address(poolsDeploy.volatileCustomFeeModule().factory()), address(_volatileFactory));
    assertEq(address(poolsDeploy.stableCustomFeeModule().factory()), address(_stableFactory));
    assertEq(address(poolsDeploy.volatileFlatFeeQuoter().FACTORY()), address(_volatileFactory));
    assertEq(address(poolsDeploy.stableFlatFeeQuoter().FACTORY()), address(_stableFactory));

    // it should deploy every contract at its deterministic CREATE3 address
    assertEq(
      address(_factoryRegistry),
      CreateXLibrary.computeCreate3Address({_entropy: FACTORY_REGISTRY_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.volatilePoolImplementation()),
      CreateXLibrary.computeCreate3Address({_entropy: VOLATILE_POOL_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.stablePoolImplementation()),
      CreateXLibrary.computeCreate3Address({_entropy: STABLE_POOL_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(_volatileFactory),
      CreateXLibrary.computeCreate3Address({_entropy: VOLATILE_POOL_FACTORY_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(_stableFactory),
      CreateXLibrary.computeCreate3Address({_entropy: STABLE_POOL_FACTORY_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.poolTape()),
      CreateXLibrary.computeCreate3Address({_entropy: POOL_TAPE_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.discountRegistry()),
      CreateXLibrary.computeCreate3Address({_entropy: DISCOUNT_REGISTRY_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.volatileCustomFeeModule()),
      CreateXLibrary.computeCreate3Address({_entropy: VOLATILE_CUSTOM_FEE_MODULE_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.stableCustomFeeModule()),
      CreateXLibrary.computeCreate3Address({_entropy: STABLE_CUSTOM_FEE_MODULE_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.volatileFlatFeeQuoter()),
      CreateXLibrary.computeCreate3Address({_entropy: VOLATILE_FLAT_FEE_QUOTER_ENTROPY, _deployer: TEST_DEPLOYER})
    );
    assertEq(
      address(poolsDeploy.stableFlatFeeQuoter()),
      CreateXLibrary.computeCreate3Address({_entropy: STABLE_FLAT_FEE_QUOTER_ENTROPY, _deployer: TEST_DEPLOYER})
    );
  }
}
