// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VmSafe} from 'forge-std/Vm.sol';
import {console} from 'forge-std/console.sol';

import {DeployFixture} from 'V3-script/DeployFixture.sol';
import {CreateXLibrary} from 'V3/libraries/CreateXLibrary.sol';

import {FactoryRegistry} from 'V3/factories/FactoryRegistry.sol';
import {PoolFactory} from 'V3/factories/PoolFactory.sol';
import {StablePoolFactory} from 'V3/factories/StablePoolFactory.sol';
import {VolatilePoolFactory} from 'V3/factories/VolatilePoolFactory.sol';
import {CustomFeeModule} from 'V3/fees/CustomFeeModule.sol';
import {DiscountRegistry} from 'V3/fees/DiscountRegistry.sol';
import {FlatFeeQuoter} from 'V3/fees/FlatFeeQuoter.sol';
import {Pool} from 'V3/pools/Pool.sol';
import {StablePool} from 'V3/pools/StablePool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

/**
 * @title DeployPoolsFixture
 * @notice Deployment fixture for the pool deployment unit: factory registry, pool implementations,
 *         pool factories, pool tape, discount registry, custom fee modules and flat fee quoters. Per chain
 *         classes in
 *         script/deployParameters set the parameters by overriding setUp.
 */
abstract contract DeployPoolsFixture is DeployFixture {
  using CreateXLibrary for bytes11;

  /*////////////////////////////////////////////////////////////
                        STRUCTS
  ////////////////////////////////////////////////////////////*/

  struct DeploymentParameters {
    uint256 chainId;
    address poolAdmin;
    address pauser;
    address feeManager;
    address poolTapeManager;
    address discountRegistryManager;
    address poolTapeOwner;
    address discountRegistryOwner;
    address targetFactoryAdmin;
    uint32 defaultCadenceInterval;
    uint32 poolTapeGasLimit;
    uint32 feeModuleGasLimit;
    string outputFilename;
  }

  /*////////////////////////////////////////////////////////////
                        STATE VARIABLES
  ////////////////////////////////////////////////////////////*/

  FactoryRegistry public factoryRegistry;
  Pool public volatilePoolImplementation;
  Pool public stablePoolImplementation;
  PoolFactory public volatilePoolFactory;
  PoolFactory public stablePoolFactory;
  PoolTape public poolTape;
  DiscountRegistry public discountRegistry;
  CustomFeeModule public volatileCustomFeeModule;
  CustomFeeModule public stableCustomFeeModule;
  FlatFeeQuoter public volatileFlatFeeQuoter;
  FlatFeeQuoter public stableFlatFeeQuoter;

  DeploymentParameters internal _params;

  /*////////////////////////////////////////////////////////////
                        EXTERNAL AND PUBLIC FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev Used by tests to set the deployment parameters
  function setParams(DeploymentParameters memory __params) external {
    _params = __params;
  }

  /// @dev Used by tests to get the deployment parameters
  function params() external view returns (DeploymentParameters memory) {
    return _params;
  }

  /*////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Internal helper function to deploy the pool unit contracts
  function _deploy() internal override {
    if (_params.chainId != block.chainid) revert ChainIdMismatch();
    if (_params.poolAdmin == address(0)) revert InvalidInput();
    if (_params.pauser == address(0)) revert InvalidInput();
    if (_params.feeManager == address(0)) revert InvalidInput();
    if (_params.poolTapeManager == address(0)) revert InvalidInput();
    if (_params.discountRegistryManager == address(0)) revert InvalidInput();
    if (_params.poolTapeOwner == address(0)) revert InvalidInput();
    if (_params.discountRegistryOwner == address(0)) revert InvalidInput();
    if (_params.targetFactoryAdmin == address(0)) revert InvalidInput();
    if (_params.defaultCadenceInterval == 0) revert InvalidInput();
    if (_params.poolTapeGasLimit == 0) revert InvalidInput();
    if (_params.feeModuleGasLimit == 0) revert InvalidInput();

    /// @dev Factory registry ///
    /// @dev The deployer is the target factory admin so the pool factories can be approved as target
    ///      factories in the same broadcast. The admin is rotated after the approvals. The LeafVoter does
    ///      not exist yet in the lite launch, so the admin wires it in later through setLeafVoter.
    factoryRegistry = FactoryRegistry(
      _CX.deployCreate3({
        salt: FACTORY_REGISTRY_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(FactoryRegistry).creationCode, abi.encode(_deployer, address(0)))
      })
    );
    _verifyAddress({
      _entropy: FACTORY_REGISTRY_ENTROPY,
      _output: address(factoryRegistry),
      _contractName: 'FactoryRegistry',
      __deployer: _deployer
    });

    /// @dev Pool implementations ///
    volatilePoolImplementation = Pool(
      _CX.deployCreate3({
        salt: VOLATILE_POOL_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(VolatilePool).creationCode)
      })
    );
    _verifyAddress({
      _entropy: VOLATILE_POOL_ENTROPY,
      _output: address(volatilePoolImplementation),
      _contractName: 'VolatilePool',
      __deployer: _deployer
    });

    stablePoolImplementation = Pool(
      _CX.deployCreate3({
        salt: STABLE_POOL_ENTROPY.calculateSalt(_deployer), initCode: abi.encodePacked(type(StablePool).creationCode)
      })
    );
    _verifyAddress({
      _entropy: STABLE_POOL_ENTROPY,
      _output: address(stablePoolImplementation),
      _contractName: 'StablePool',
      __deployer: _deployer
    });

    /// @dev Pool tape and discount registry ///
    poolTape = PoolTape(
      _CX.deployCreate3({
        salt: POOL_TAPE_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(
          type(PoolTape).creationCode, abi.encode(_params.poolTapeOwner, _params.defaultCadenceInterval)
        )
      })
    );
    _verifyAddress({
      _entropy: POOL_TAPE_ENTROPY, _output: address(poolTape), _contractName: 'PoolTape', __deployer: _deployer
    });

    discountRegistry = DiscountRegistry(
      _CX.deployCreate3({
        salt: DISCOUNT_REGISTRY_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(DiscountRegistry).creationCode, abi.encode(_params.discountRegistryOwner))
      })
    );
    _verifyAddress({
      _entropy: DISCOUNT_REGISTRY_ENTROPY,
      _output: address(discountRegistry),
      _contractName: 'DiscountRegistry',
      __deployer: _deployer
    });

    /// @dev Pool factories ///
    /// @dev The deployer holds the fee, tape and discount registry manager roles so calling the setters below
    ///      can run in the same broadcast. The roles are updated after setting the modules.
    volatilePoolFactory = PoolFactory(
      _CX.deployCreate3({
        salt: VOLATILE_POOL_FACTORY_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(
          type(VolatilePoolFactory).creationCode,
          abi.encode(
            address(volatilePoolImplementation), // pool implementation
            _params.poolAdmin, // pool admin
            _params.pauser, // pauser
            _deployer, // fee manager until the fee module is set
            _deployer, // discount registry manager until the registry is set
            _deployer, // pool tape manager until the tape is set
            address(factoryRegistry) // factory registry
          )
        )
      })
    );
    _verifyAddress({
      _entropy: VOLATILE_POOL_FACTORY_ENTROPY,
      _output: address(volatilePoolFactory),
      _contractName: 'VolatilePoolFactory',
      __deployer: _deployer
    });

    stablePoolFactory = PoolFactory(
      _CX.deployCreate3({
        salt: STABLE_POOL_FACTORY_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(
          type(StablePoolFactory).creationCode,
          abi.encode(
            address(stablePoolImplementation), // pool implementation
            _params.poolAdmin, // pool admin
            _params.pauser, // pauser
            _deployer, // fee manager until the fee module is set
            _deployer, // discount registry manager until the registry is set
            _deployer, // pool tape manager until the tape is set
            address(factoryRegistry) // factory registry
          )
        )
      })
    );
    _verifyAddress({
      _entropy: STABLE_POOL_FACTORY_ENTROPY,
      _output: address(stablePoolFactory),
      _contractName: 'StablePoolFactory',
      __deployer: _deployer
    });

    /// @dev Custom fee modules, one per factory ///
    volatileCustomFeeModule = CustomFeeModule(
      _CX.deployCreate3({
        salt: VOLATILE_CUSTOM_FEE_MODULE_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(CustomFeeModule).creationCode, abi.encode(address(volatilePoolFactory)))
      })
    );
    _verifyAddress({
      _entropy: VOLATILE_CUSTOM_FEE_MODULE_ENTROPY,
      _output: address(volatileCustomFeeModule),
      _contractName: 'VolatileCustomFeeModule',
      __deployer: _deployer
    });

    stableCustomFeeModule = CustomFeeModule(
      _CX.deployCreate3({
        salt: STABLE_CUSTOM_FEE_MODULE_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(CustomFeeModule).creationCode, abi.encode(address(stablePoolFactory)))
      })
    );
    _verifyAddress({
      _entropy: STABLE_CUSTOM_FEE_MODULE_ENTROPY,
      _output: address(stableCustomFeeModule),
      _contractName: 'StableCustomFeeModule',
      __deployer: _deployer
    });

    /// @dev Flat fee quoters, one per factory ///
    volatileFlatFeeQuoter = FlatFeeQuoter(
      _CX.deployCreate3({
        salt: VOLATILE_FLAT_FEE_QUOTER_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(FlatFeeQuoter).creationCode, abi.encode(address(volatilePoolFactory)))
      })
    );
    _verifyAddress({
      _entropy: VOLATILE_FLAT_FEE_QUOTER_ENTROPY,
      _output: address(volatileFlatFeeQuoter),
      _contractName: 'VolatileFlatFeeQuoter',
      __deployer: _deployer
    });

    stableFlatFeeQuoter = FlatFeeQuoter(
      _CX.deployCreate3({
        salt: STABLE_FLAT_FEE_QUOTER_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(type(FlatFeeQuoter).creationCode, abi.encode(address(stablePoolFactory)))
      })
    );
    _verifyAddress({
      _entropy: STABLE_FLAT_FEE_QUOTER_ENTROPY,
      _output: address(stableFlatFeeQuoter),
      _contractName: 'StableFlatFeeQuoter',
      __deployer: _deployer
    });

    /// @dev Set the factory modules and roles ///
    _setFactoryModulesAndRoles(volatilePoolFactory, address(volatileCustomFeeModule), address(volatileFlatFeeQuoter));
    _setFactoryModulesAndRoles(stablePoolFactory, address(stableCustomFeeModule), address(stableFlatFeeQuoter));

    /// @dev Approve the pool factories as target factories, then hand the target factory admin over ///
    factoryRegistry.registerTargetFactory(address(volatilePoolFactory));
    factoryRegistry.registerTargetFactory(address(stablePoolFactory));
    factoryRegistry.setTargetFactoryAdmin(_params.targetFactoryAdmin);
  }

  /// @notice Sets the tape, registry, fee module and exact output fee quoter on a factory, then sets the
  ///         manager roles to the configured addresses
  /// @param _factory The factory to set the modules and roles for
  /// @param _feeModule The fee module built for that factory
  /// @param _exactOutFeeQuoter The flat fee quoter built for that factory
  function _setFactoryModulesAndRoles(PoolFactory _factory, address _feeModule, address _exactOutFeeQuoter) internal {
    _factory.setPoolTape(address(poolTape), _params.poolTapeGasLimit);
    _factory.setDiscountRegistry(address(discountRegistry));
    _factory.setFeeModule(_feeModule, _params.feeModuleGasLimit);
    _factory.setExactOutFeeQuoter(_exactOutFeeQuoter);

    _factory.setPoolTapeManager(_params.poolTapeManager);
    _factory.setDiscountRegistryManager(_params.discountRegistryManager);
    _factory.setFeeManager(_params.feeManager);
  }

  /// @notice Internal helper function to write the deployment addresses file
  /// @dev Only writes during a real broadcast so test runs never touch deployment-addresses/
  function _logOutput() internal override {
    if (_isTest || !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;

    string memory _root = vm.projectRoot();
    string memory _path = string(abi.encodePacked(_root, '/deployment-addresses/', _params.outputFilename));
    vm.writeJson(vm.serializeAddress('', 'factoryRegistry', address(factoryRegistry)), _path);
    vm.writeJson(vm.serializeAddress('', 'volatilePoolImplementation', address(volatilePoolImplementation)), _path);
    vm.writeJson(vm.serializeAddress('', 'stablePoolImplementation', address(stablePoolImplementation)), _path);
    vm.writeJson(vm.serializeAddress('', 'volatilePoolFactory', address(volatilePoolFactory)), _path);
    vm.writeJson(vm.serializeAddress('', 'stablePoolFactory', address(stablePoolFactory)), _path);
    vm.writeJson(vm.serializeAddress('', 'poolTape', address(poolTape)), _path);
    vm.writeJson(vm.serializeAddress('', 'discountRegistry', address(discountRegistry)), _path);
    vm.writeJson(vm.serializeAddress('', 'volatileCustomFeeModule', address(volatileCustomFeeModule)), _path);
    vm.writeJson(vm.serializeAddress('', 'stableCustomFeeModule', address(stableCustomFeeModule)), _path);
    vm.writeJson(vm.serializeAddress('', 'volatileFlatFeeQuoter', address(volatileFlatFeeQuoter)), _path);
    vm.writeJson(vm.serializeAddress('', 'stableFlatFeeQuoter', address(stableFlatFeeQuoter)), _path);
  }

  /// @notice Internal helper function to log contract addresses after deployment
  function _logParams() internal view override {
    if (_isTest) return;
    console.log('factoryRegistry: ', address(factoryRegistry));
    console.log('volatilePoolImplementation: ', address(volatilePoolImplementation));
    console.log('stablePoolImplementation: ', address(stablePoolImplementation));
    console.log('volatilePoolFactory: ', address(volatilePoolFactory));
    console.log('stablePoolFactory: ', address(stablePoolFactory));
    console.log('poolTape: ', address(poolTape));
    console.log('discountRegistry: ', address(discountRegistry));
    console.log('volatileCustomFeeModule: ', address(volatileCustomFeeModule));
    console.log('stableCustomFeeModule: ', address(stableCustomFeeModule));
    console.log('volatileFlatFeeQuoter: ', address(volatileFlatFeeQuoter));
    console.log('stableFlatFeeQuoter: ', address(stableFlatFeeQuoter));
  }
}
