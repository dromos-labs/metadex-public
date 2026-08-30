// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {DeployPoolsFixture} from 'V3-script/DeployPoolsFixture.s.sol';
import {DeployPools} from 'V3-script/deployParameters/base/DeployPools.s.sol';

import {FactoryRegistry} from 'V3/factories/FactoryRegistry.sol';
import {PoolFactory} from 'V3/factories/PoolFactory.sol';
import {CustomFeeModule} from 'V3/fees/CustomFeeModule.sol';
import {DiscountRegistry} from 'V3/fees/DiscountRegistry.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {Pool} from 'V3/pools/Pool.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';
import {LeafVoter} from 'V3/voter/LeafVoter.sol';

import {IntegrationFixture} from 'V3-test/integration/IntegrationFixture.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {Users} from 'V3-test/utils/Users.sol';

/// @notice Base fixture for the pool unit integration tests.
abstract contract PoolsFixture is IntegrationFixture {
  uint32 public constant DEFAULT_CADENCE_INTERVAL = 300;
  uint48 public constant ALLOCATION_COOLDOWN = 1 hours;
  uint256 public constant MAX_GAUGES = 100;
  uint32 public constant POOL_TAPE_GAS_LIMIT = 200_000;
  uint32 public constant FEE_MODULE_GAS_LIMIT = 60_000;

  DeployPools public deployPools;

  LeafVoter public leafVoter;
  FactoryRegistry public factoryRegistry;

  Pool public volatilePoolImplementation;
  Pool public stablePoolImplementation;
  PoolFactory public volatilePoolFactory;
  PoolFactory public stablePoolFactory;
  PoolTape public poolTape;
  DiscountRegistry public discountRegistry;
  CustomFeeModule public volatileCustomFeeModule;
  CustomFeeModule public stableCustomFeeModule;

  TestERC20 public token0;
  TestERC20 public token1;

  Users internal _users;

  function setUp() public virtual override {
    super.setUp();
    _createUsers();

    deployPools = new DeployPools();
    deployPools.setParams(
      DeployPoolsFixture.DeploymentParameters({
        chainId: block.chainid,
        poolAdmin: _users.owner,
        pauser: _users.owner,
        feeManager: _users.feeManager,
        poolTapeManager: _users.poolTapeManager,
        discountRegistryManager: _users.discountRegistryManager,
        poolTapeOwner: _users.owner,
        discountRegistryOwner: _users.owner,
        targetFactoryAdmin: _users.owner,
        defaultCadenceInterval: DEFAULT_CADENCE_INTERVAL,
        poolTapeGasLimit: POOL_TAPE_GAS_LIMIT,
        feeModuleGasLimit: FEE_MODULE_GAS_LIMIT,
        outputFilename: 'pools-base.json'
      })
    );
    deployPools.setDeployer(_users.deployer);
    deployPools.setIsTest(true);
    deployPools.run();

    factoryRegistry = deployPools.factoryRegistry();
    volatilePoolImplementation = deployPools.volatilePoolImplementation();
    stablePoolImplementation = deployPools.stablePoolImplementation();
    volatilePoolFactory = deployPools.volatilePoolFactory();
    stablePoolFactory = deployPools.stablePoolFactory();
    poolTape = deployPools.poolTape();
    discountRegistry = deployPools.discountRegistry();
    volatileCustomFeeModule = deployPools.volatileCustomFeeModule();
    stableCustomFeeModule = deployPools.stableCustomFeeModule();

    _deployLeafVoter();
    _linkGaugeFactories();

    _deployTokens();

    deal(address(token0), _users.alice, TOKEN_1 * 1e9);
    deal(address(token1), _users.alice, TOKEN_1 * 1e9);
    deal(address(token0), _users.bob, TOKEN_1 * 1e9);
    deal(address(token1), _users.bob, TOKEN_1 * 1e9);

    _labelContracts();
  }

  /// @dev Deploys the real LeafVoter after the pool unit and wires it into the registry so admin
  ///      actions resolve through the voter's real AccessControl state, mirroring the lite launch
  ///      order. Peripheral voter dependencies (orchestrator, receipt token, gauge manager, emissions
  ///      handler) are stand-in actors since the cross-chain and gauge units are out of scope for the
  ///      pools fixture. The owner holds the target factory admin handed over by the deploy script and receives
  ///      FACTORY_REGISTRY_ADMIN_ROLE through a real grant by the config admin.
  function _deployLeafVoter() internal {
    leafVoter = new LeafVoter({
      _governor: _users.owner,
      _configAdmin: _users.owner,
      _leafMessageOrchestrator: makeAddr('leafMessageOrchestrator'),
      _receiptToken: makeAddr('receiptToken'),
      _factoryRegistry: address(factoryRegistry),
      _gaugeManager: makeAddr('gaugeManager'),
      _allocationCooldown: ALLOCATION_COOLDOWN,
      _maxGauges: MAX_GAUGES,
      _adapterAuthority: _users.owner,
      _emissionsHandler: makeAddr('emissionsHandler'),
      _emergencyCouncil: _users.emergencyCouncil
    });

    vm.startPrank(_users.owner);
    factoryRegistry.setLeafVoter(address(leafVoter));
    leafVoter.grantRole(Roles.FACTORY_REGISTRY_ADMIN_ROLE, _users.owner);
    vm.stopPrank();
  }

  /// @dev Links a gauge factory to each pool factory registered as a target factory by the deploy
  ///      script, exercising the late linking path of registerFactories. Gauge factories are stand-in
  ///      addresses since gauge creation is out of scope here.
  function _linkGaugeFactories() internal {
    vm.startPrank(_users.owner);
    factoryRegistry.registerFactories({
      _gaugeFactory: makeAddr('volatileGaugeFactory'), _targetFactory: address(volatilePoolFactory)
    });
    factoryRegistry.registerFactories({
      _gaugeFactory: makeAddr('stableGaugeFactory'), _targetFactory: address(stablePoolFactory)
    });
    vm.stopPrank();
  }

  function _createUsers() internal {
    _users = Users({
      owner: _createActor('Owner'),
      feeManager: _createActor('FeeManager'),
      discountRegistryManager: _createActor('DiscountRegistryManager'),
      poolTapeManager: _createActor('PoolTapeManager'),
      alice: _createActor('Alice'),
      bob: _createActor('Bob'),
      charlie: _createActor('Charlie'),
      factoryAdminManager: _createActor('FactoryAdminManager'),
      chainAdminManager: _createActor('ChainAdminManager'),
      factoryAdmin: _createActor('FactoryAdmin'),
      chainAdmin: _createActor('ChainAdmin'),
      deployer: _createActor('Deployer'),
      deployer2: _createActor('Deployer2'),
      emergencyCouncil: _createActor('EmergencyCouncil')
    });
  }

  function _deployTokens() internal {
    TestERC20 _tokenA = new TestERC20('Test Token A', 'TTA', 18);
    TestERC20 _tokenB = new TestERC20('Test Token B', 'TTB', 6); // mimic USDC
    (token0, token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
  }

  function _labelContracts() internal {
    vm.label(address(volatilePoolImplementation), 'Volatile Pool Implementation');
    vm.label(address(stablePoolImplementation), 'Stable Pool Implementation');
    vm.label(address(volatilePoolFactory), 'Volatile Pool Factory');
    vm.label(address(stablePoolFactory), 'Stable Pool Factory');
    vm.label(address(poolTape), 'Pool Tape');
    vm.label(address(discountRegistry), 'Discount Registry');
    vm.label(address(volatileCustomFeeModule), 'Volatile Custom Fee Module');
    vm.label(address(stableCustomFeeModule), 'Stable Custom Fee Module');
  }
}
