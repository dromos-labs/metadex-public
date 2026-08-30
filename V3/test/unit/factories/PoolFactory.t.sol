// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IExactOutFeeQuoter} from 'V3/interfaces/fees/IExactOutFeeQuoter.sol';
import {IFeeModule} from 'V3/interfaces/fees/IFeeModule.sol';
import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IPoolFactoryIndexation} from 'V3/interfaces/pools/IPoolFactoryIndexation.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

abstract contract UnitPoolFactory is TestHelpers {
  using stdStorage for StdStorage;

  uint256 internal constant MAX_DEFAULT_FEE = 300; // 3%
  uint256 internal constant MAX_BASE_FEE = 1000; // 10%
  uint256 internal constant MIN_REACHABLE_GAS = 10_000;
  /// @dev Cap used to fuzz gas limits so foundry tx doesn't revert
  uint32 internal constant MAX_GAS_LIMIT = 1_000_000;

  address internal _poolAdmin = makeAddr('poolAdmin');
  address internal _pauser = makeAddr('pauser');
  address internal _feeManager = makeAddr('feeManager');
  address internal _discountRegistryManager = makeAddr('discountRegistryManager');
  address internal _feeModule = _mockContract('feeModule');
  address internal _poolTapeManager = makeAddr('poolTapeManager');
  address internal _poolTape = _mockContract('poolTape');
  address internal _mevTaxModule = _mockContract('mevTaxModule');
  address internal _exactOutFeeQuoter = _mockContract('exactOutFeeQuoter');
  address internal _factoryRegistry = _mockContract('factoryRegistry');

  /// @dev Child contract deploys the variant under test and assigns it here.
  IPoolFactory internal _poolFactory;
  /// @dev Child contract deploys its variant's pool implementation and assigns it here.
  address internal _poolImplementation;

  /// @dev Child contract deploys a fresh variant factory using `_poolImplementation` and the test's users.
  function _deployFactory() internal virtual returns (IPoolFactory);

  function setUp() public virtual {}

  function test_ConstructorWhenTheImplementationIsTheZeroAddress() external {
    _poolImplementation = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorWhenThePoolAdminIsTheZeroAddress() external {
    _poolAdmin = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorWhenThePauserIsTheZeroAddress() external {
    _pauser = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorWhenTheFeeManagerIsTheZeroAddress() external {
    _feeManager = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorWhenTheDiscountRegistryManagerIsTheZeroAddress() external {
    _discountRegistryManager = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorWhenThePoolTapeManagerIsTheZeroAddress() external {
    _poolTapeManager = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorWhenTheFactoryRegistryIsTheZeroAddress() external {
    _factoryRegistry = address(0);
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _deployFactory();
  }

  function test_ConstructorGivenAFreshlyDeployedFactory() external {
    uint256 _defaultFee = _poolFactory.DEFAULT_FEE();

    // it should emit SetPoolAdmin
    vm.expectEmit();
    emit IPoolFactory.SetPoolAdmin(_poolAdmin);
    // it should emit SetPauser
    vm.expectEmit();
    emit IPoolFactory.SetPauser(_pauser);
    // it should emit SetFeeManager
    vm.expectEmit();
    emit IPoolFactory.SetFeeManager(_feeManager);
    // it should emit SetPoolTapeManager
    vm.expectEmit();
    emit IPoolFactory.SetPoolTapeManager(_poolTapeManager);
    // it should emit SetDefaultFee
    vm.expectEmit();
    emit IPoolFactory.SetDefaultFee(_defaultFee);

    IPoolFactory _factory = _deployFactory();

    // it should set implementation to the variant pool implementation
    assertEq(_factory.implementation(), _poolImplementation);
    // it should set poolAdmin to the provided pool admin
    assertEq(_factory.poolAdmin(), _poolAdmin);
    // it should set pauser to the provided pauser
    assertEq(_factory.pauser(), _pauser);
    // it should set feeManager to the provided fee manager
    assertEq(_factory.feeManager(), _feeManager);
    // it should set defaultFee to the variant's default fee
    assertEq(_factory.defaultFee(), _defaultFee);
    // it should set poolTapeManager to the provided pool tape manager
    assertEq(_factory.poolTapeManager(), _poolTapeManager);
    // it should set factoryRegistry to the provided factory registry
    assertEq(_factory.factoryRegistry(), _factoryRegistry);
  }

  function test_SetPoolAdminWhenTheCallerIsNotThePoolAdmin(address _caller) external {
    // it should revert with NotPoolAdmin
    vm.assume(_caller != _poolAdmin);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPoolAdmin.selector);
    _poolFactory.setPoolAdmin(address(0));
  }

  modifier whenTheCallerIsThePoolAdmin() {
    vm.startPrank(_poolAdmin);
    _;
  }

  function test_SetPoolAdminWhenTheNewAdminIsTheZeroAddress() external whenTheCallerIsThePoolAdmin {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setPoolAdmin(address(0));
  }

  function test_SetPoolAdminWhenTheNewAdminIsNotTheZeroAddress(address _newAdmin) external whenTheCallerIsThePoolAdmin {
    vm.assume(_newAdmin != address(0));
    vm.assume(_newAdmin != _poolAdmin);
    // it should emit SetPoolAdmin
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetPoolAdmin(_newAdmin);
    _poolFactory.setPoolAdmin(_newAdmin);
    // it should update poolAdmin
    assertEq(_poolFactory.poolAdmin(), _newAdmin);
  }

  function test_SetPauserWhenTheCallerIsNotThePauser(address _caller) external {
    // it should revert with NotPauser
    vm.assume(_caller != _pauser);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPauser.selector);
    _poolFactory.setPauser(address(0));
  }

  modifier whenTheCallerIsThePauser() {
    vm.startPrank(_pauser);
    _;
  }

  function test_SetPauserWhenTheNewPauserIsTheZeroAddress() external whenTheCallerIsThePauser {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setPauser(address(0));
  }

  function test_SetPauserWhenTheNewPauserIsNotTheZeroAddress(address _newPauser) external whenTheCallerIsThePauser {
    vm.assume(_newPauser != address(0));
    vm.assume(_newPauser != _pauser);
    // it should emit SetPauser
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetPauser(_newPauser);
    _poolFactory.setPauser(_newPauser);
    // it should update pauser
    assertEq(_poolFactory.pauser(), _newPauser);
  }

  function test_SetPauseStateWhenTheCallerIsNotThePauser(address _caller) external {
    // it should revert with NotPauser
    vm.assume(_caller != _pauser);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPauser.selector);
    _poolFactory.setPauseState(false);
  }

  function test_SetPauseStateWhenTheNewStateIsTrue() external whenTheCallerIsThePauser {
    // it should emit SetPauseState
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetPauseState(true);
    _poolFactory.setPauseState(true);
    // it should update isPaused to true
    assertEq(_poolFactory.isPaused(), true);
  }

  function test_SetPauseStateWhenTheNewStateIsFalse() external whenTheCallerIsThePauser {
    _poolFactory.setPauseState(true);

    // it should emit SetPauseState
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetPauseState(false);
    _poolFactory.setPauseState(false);
    // it should update isPaused to false
    assertEq(_poolFactory.isPaused(), false);
  }

  function test_SetFeeManagerWhenTheCallerIsNotTheFeeManager(address _caller) external {
    // it should revert with NotFeeManager
    vm.assume(_caller != _feeManager);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotFeeManager.selector);
    _poolFactory.setFeeManager(address(0));
  }

  modifier whenTheCallerIsTheFeeManager() {
    vm.startPrank(_feeManager);
    _;
  }

  function test_SetFeeManagerWhenTheNewFeeManagerIsTheZeroAddress() external whenTheCallerIsTheFeeManager {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setFeeManager(address(0));
  }

  function test_SetFeeManagerWhenTheNewFeeManagerIsNotTheZeroAddress(address _newFeeManager)
    external
    whenTheCallerIsTheFeeManager
  {
    vm.assume(_newFeeManager != address(0));
    vm.assume(_newFeeManager != _feeManager);
    // it should emit SetFeeManager
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetFeeManager(_newFeeManager);
    _poolFactory.setFeeManager(_newFeeManager);
    // it should update feeManager
    assertEq(_poolFactory.feeManager(), _newFeeManager);
  }

  function test_SetFeeModuleWhenTheCallerIsNotTheFeeManager(address _caller) external {
    // it should revert with NotFeeManager
    vm.assume(_caller != _feeManager);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotFeeManager.selector);
    _poolFactory.setFeeModule(address(0), 1);
  }

  function test_SetFeeModuleWhenTheNewFeeModuleIsTheZeroAddress() external whenTheCallerIsTheFeeManager {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setFeeModule(address(0), 1);
  }

  modifier whenTheNewFeeModuleIsNotTheZeroAddress() {
    _;
  }

  function test_SetFeeModuleWhenTheGasLimitIsZero()
    external
    whenTheCallerIsTheFeeManager
    whenTheNewFeeModuleIsNotTheZeroAddress
  {
    // it should revert with ZeroGasLimit
    vm.expectRevert(IPoolFactory.ZeroGasLimit.selector);
    _poolFactory.setFeeModule(_feeModule, 0);
  }

  modifier whenTheGasLimitIsGtZero() {
    _;
  }

  function test_SetFeeModuleWhenTheNewFeeModuleIsBoundToADifferentFactory(address _otherFactory)
    external
    whenTheCallerIsTheFeeManager
    whenTheNewFeeModuleIsNotTheZeroAddress
    whenTheGasLimitIsGtZero
  {
    vm.assume(_otherFactory != address(_poolFactory));
    _mockAndExpect(_feeModule, abi.encodeCall(IFeeModule.factory, ()), abi.encode(_otherFactory));
    // it should revert with InvalidFeeModule
    vm.expectRevert(IPoolFactory.InvalidFeeModule.selector);
    _poolFactory.setFeeModule(_feeModule, 1);
  }

  function test_SetFeeModuleWhenTheNewFeeModuleIsBoundToThisFactory(uint32 _gasLimit)
    external
    whenTheCallerIsTheFeeManager
    whenTheNewFeeModuleIsNotTheZeroAddress
    whenTheGasLimitIsGtZero
  {
    vm.assume(_gasLimit != 0);
    _mockAndExpect(_feeModule, abi.encodeCall(IFeeModule.factory, ()), abi.encode(address(_poolFactory)));
    // it should emit SetFeeModule
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetFeeModule(_feeModule, _gasLimit);
    _poolFactory.setFeeModule(_feeModule, _gasLimit);
    // it should update feeModule
    assertEq(_poolFactory.feeModule(), _feeModule);
    // it should update feeModuleGasLimit
    assertEq(_poolFactory.feeModuleGasLimit(), _gasLimit);
  }

  function test_SetDefaultFeeWhenTheCallerIsNotTheFeeManager(address _caller) external {
    // it should revert with NotFeeManager
    vm.assume(_caller != _feeManager);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotFeeManager.selector);
    _poolFactory.setDefaultFee(0);
  }

  function test_SetDefaultFeeWhenTheNewFeeIsZero() external whenTheCallerIsTheFeeManager {
    // it should revert with ZeroFee
    vm.expectRevert(IPoolFactory.ZeroFee.selector);
    _poolFactory.setDefaultFee(0);
  }

  modifier whenTheNewFeeIsGreaterThanZero() {
    _;
  }

  function test_SetDefaultFeeWhenTheNewFeeIsGreaterThanTheMaxFee(uint256 _newFee)
    external
    whenTheCallerIsTheFeeManager
    whenTheNewFeeIsGreaterThanZero
  {
    _newFee = bound(_newFee, MAX_DEFAULT_FEE + 1, type(uint256).max);
    // it should revert with FeeTooHigh
    vm.expectRevert(IPoolFactory.FeeTooHigh.selector);
    _poolFactory.setDefaultFee(_newFee);
  }

  function test_SetDefaultFeeWhenTheNewFeeIsLessThanTheMaxFee(uint256 _newFee)
    external
    whenTheCallerIsTheFeeManager
    whenTheNewFeeIsGreaterThanZero
  {
    _newFee = bound(_newFee, 1, MAX_DEFAULT_FEE);
    // it should emit SetDefaultFee
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetDefaultFee(_newFee);
    _poolFactory.setDefaultFee(_newFee);
    // it should update defaultFee
    assertEq(_poolFactory.defaultFee(), _newFee);
  }

  function test_CreatePoolWhenTokenAEqualsTokenB(address _token) external {
    // it should revert with SameAddress
    vm.expectRevert(IPoolFactory.SameAddress.selector);
    _poolFactory.createPool(_token, _token);
  }

  modifier whenTokenADiffersFromTokenB(address _tokenA, address _tokenB) {
    vm.assume(_tokenA != _tokenB);
    _;
  }

  function test_CreatePoolWhenTheLowerTokenIsTheZeroAddress(address _token)
    external
    whenTokenADiffersFromTokenB(_token, address(0))
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.createPool(address(0), _token);
  }

  modifier whenTheLowerTokenIsNotTheZeroAddress() {
    _;
  }

  function test_CreatePoolWhenThePoolAlreadyExistsForThePair(
    address _existingPool,
    address _tokenA,
    address _tokenB
  ) external whenTokenADiffersFromTokenB(_tokenA, _tokenB) whenTheLowerTokenIsNotTheZeroAddress {
    _assumeFuzzable(_tokenA);
    _assumeFuzzable(_tokenB);
    vm.assume(_existingPool != address(0));
    (address _token0, address _token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);

    stdstore.target(address(_poolFactory)).sig(IPoolFactory.getPool.selector).with_key(_token0).with_key(_token1)
      .checked_write(_existingPool);

    // it should revert with PoolAlreadyExists
    vm.expectRevert(IPoolFactory.PoolAlreadyExists.selector);
    _poolFactory.createPool(_tokenA, _tokenB);
  }

  modifier whenThePairHasNoPoolYet() {
    _;
  }

  function test_CreatePoolWhenThePairHasNoPoolYet(
    address _tokenA,
    address _tokenB,
    uint48 _timestamp
  ) external whenTokenADiffersFromTokenB(_tokenA, _tokenB) whenTheLowerTokenIsNotTheZeroAddress {
    _assumeFuzzable(_tokenA);
    _assumeFuzzable(_tokenB);
    vm.assume(_tokenA != _poolImplementation && _tokenB != _poolImplementation);
    vm.assume(_tokenA != address(_poolFactory) && _tokenB != address(_poolFactory));

    // Pool.initialize reads `decimals()` and `symbol()` on each token through the clone.
    _mockAndExpect(_tokenA, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18)));
    _mockAndExpect(_tokenB, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
    _mockAndExpect(_tokenA, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TKA'));
    _mockAndExpect(_tokenB, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TKB'));

    (address _token0, address _token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
    bytes32 _salt = keccak256(abi.encodePacked(_token0, _token1));
    address _predicted = Clones.predictDeterministicAddress(_poolImplementation, _salt, address(_poolFactory));

    // it should register the pool as a target in the factory registry
    _mockAndExpect(_factoryRegistry, abi.encodeCall(IFactoryRegistry.registerTarget, (_predicted)), '');

    // it should emit PoolCreated
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.PoolCreated(_token0, _token1, _predicted, 1);

    vm.warp(_timestamp);
    address _pool = _poolFactory.createPool(_tokenA, _tokenB);

    // it should deploy a clone at the predicted deterministic address
    assertEq(_pool, _predicted);
    // it should store the pool in the mapping in both directions
    assertEq(_poolFactory.getPool(_token0, _token1), _pool);
    assertEq(_poolFactory.getPool(_token1, _token0), _pool);
    // it should append the pool to allPools
    assertEq(_poolFactory.allPoolsLength(), 1);
    assertEq(_poolFactory.allPools(0), _pool);
    // it should mark the pool as a valid pool in _isPools mapping
    assertTrue(_poolFactory.isPool(_pool));
    // it should initialize the pool with the sorted token pair
    assertEq(IPool(_pool).token0(), _token0);
    assertEq(IPool(_pool).token1(), _token1);
    assertEq(IPool(_pool).factory(), address(_poolFactory));

    IPoolFactoryIndexation _poolFactoryIndexes = IPoolFactoryIndexation(address(_poolFactory));

    // it should push pool keyed by tokenA to poolByTokenIndex
    assertEq(_pool, _poolFactoryIndexes.poolByTokenIndex(_tokenA, 0));

    // it should push pool keyed by tokenB to poolByTokenIndex
    assertEq(_pool, _poolFactoryIndexes.poolByTokenIndex(_tokenB, 0));

    // it should push pool and timestamp to poolsIndex
    (address _pool0, uint48 _t0) = _poolFactoryIndexes.poolsIndex(0);
    assertEq(_pool0, _pool);
    assertEq(_t0, _timestamp);

    address[] memory _tokens = _poolFactoryIndexes.tokenIndexPaginated(0, 2);
    // it should add tokenA to tokenIndex
    assertEq(_tokenA, _tokens[0]);

    // it should add tokenB to tokenIndex
    assertEq(_tokenB, _tokens[1]);
  }

  function test_CreatePoolRevertWhen_TheFactoryRegistryRevertsTheRegistration(
    address _tokenA,
    address _tokenB
  )
    external
    whenTokenADiffersFromTokenB(_tokenA, _tokenB)
    whenTheLowerTokenIsNotTheZeroAddress
    whenThePairHasNoPoolYet
  {
    _assumeFuzzable(_tokenA);
    _assumeFuzzable(_tokenB);
    vm.assume(_tokenA != _poolImplementation && _tokenB != _poolImplementation);
    vm.assume(_tokenA != address(_poolFactory) && _tokenB != address(_poolFactory));

    vm.mockCall(_tokenA, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18)));
    vm.mockCall(_tokenB, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
    vm.mockCall(_tokenA, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TKA'));
    vm.mockCall(_tokenB, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TKB'));

    (address _token0, address _token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
    bytes32 _salt = keccak256(abi.encodePacked(_token0, _token1));
    address _predicted = Clones.predictDeterministicAddress(_poolImplementation, _salt, address(_poolFactory));

    vm.mockCallRevert(
      _factoryRegistry,
      abi.encodeCall(IFactoryRegistry.registerTarget, (_predicted)),
      abi.encodeWithSelector(IFactoryRegistry.TargetFactoryNotRegistered.selector)
    );

    // it should revert
    vm.expectRevert(IFactoryRegistry.TargetFactoryNotRegistered.selector);
    _poolFactory.createPool(_tokenA, _tokenB);
  }

  function test_GetBaseFeeWhenNoFeeModuleIsSet(address _pool) external view {
    // it should return the default fee
    assertEq(_poolFactory.getBaseFee(_pool, address(0), 0, 0, 0, 0), _poolFactory.DEFAULT_FEE());
  }

  modifier whenAFeeModuleIsSet() {
    stdstore.target(address(_poolFactory)).sig(IPoolFactory.feeModule.selector).checked_write(_feeModule);
    _;
  }

  function test_GetBaseFeeWhenThereIsntEnoughGasLeftForTheExternalCall(
    address _pool,
    uint32 _gasLimit,
    uint256 _gas
  ) external whenAFeeModuleIsSet {
    _gasLimit = uint32(bound(_gasLimit, MIN_REACHABLE_GAS, type(uint32).max));
    _writeGasLimit(IPoolFactory.feeModuleGasLimit.selector, _gasLimit);
    _gas = bound(_gas, MIN_REACHABLE_GAS, _gasLimit);
    // it should revert with InsufficientGasForCall
    vm.expectRevert(IPoolFactory.InsufficientGasForCall.selector);
    _poolFactory.getBaseFee{gas: _gas}(_pool, address(0), 0, 0, 0, 0);
  }

  modifier whenThereIsEnoughGasLeftForTheExternalCall() {
    _;
  }

  function test_GetBaseFeeWhenTheFeeModuleCallReverts(
    address _pool,
    uint32 _gasLimit
  ) external whenAFeeModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall {
    _boundAndWriteGasLimit(IPoolFactory.feeModuleGasLimit.selector, _gasLimit);
    // it should return the default fee
    vm.mockCallRevert(
      _poolFactory.feeModule(), abi.encodeCall(IFeeModule.getFee, (_pool, address(0), 0, 0, 0, 0)), 'error'
    );
    assertEq(_poolFactory.getBaseFee(_pool, address(0), 0, 0, 0, 0), _poolFactory.DEFAULT_FEE());
  }

  function test_GetBaseFeeWhenTheFeeModuleReturnsAFeeAboveTheCustomCap(
    address _pool,
    uint24 _moduleFee,
    uint32 _gasLimit
  ) external whenAFeeModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall {
    _boundAndWriteGasLimit(IPoolFactory.feeModuleGasLimit.selector, _gasLimit);
    // it should return the default fee
    _moduleFee = uint24(bound(uint256(_moduleFee), MAX_BASE_FEE + 1, type(uint24).max));
    _mockAndExpect(
      _poolFactory.feeModule(),
      abi.encodeCall(IFeeModule.getFee, (_pool, address(0), 0, 0, 0, 0)),
      abi.encode(_moduleFee)
    );
    assertEq(_poolFactory.getBaseFee(_pool, address(0), 0, 0, 0, 0), _poolFactory.DEFAULT_FEE());
  }

  function test_GetBaseFeeWhenTheFeeModuleReturnsAFeeWithinTheCustomCap(
    address _pool,
    uint24 _moduleFee,
    uint32 _gasLimit
  ) external whenAFeeModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall {
    _boundAndWriteGasLimit(IPoolFactory.feeModuleGasLimit.selector, _gasLimit);
    // it should return the custom fee
    _moduleFee = uint24(bound(uint256(_moduleFee), 0, MAX_BASE_FEE));
    _mockAndExpect(
      _poolFactory.feeModule(),
      abi.encodeCall(IFeeModule.getFee, (_pool, address(0), 0, 0, 0, 0)),
      abi.encode(_moduleFee)
    );
    assertEq(_poolFactory.getBaseFee(_pool, address(0), 0, 0, 0, 0), _moduleFee);
  }

  function test_SetDiscountRegistryManagerWhenTheCallerIsNotTheDiscountRegistryManager(address _caller) external {
    // it should revert with NotDiscountRegistryManager
    vm.assume(_caller != _discountRegistryManager);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotDiscountRegistryManager.selector);
    _poolFactory.setDiscountRegistryManager(address(0));
  }

  modifier whenTheCallerIsTheDiscountRegistryManager() {
    vm.startPrank(_discountRegistryManager);
    _;
  }

  function test_SetDiscountRegistryManagerWhenTheNewDiscountRegistryManagerIsTheZeroAddress()
    external
    whenTheCallerIsTheDiscountRegistryManager
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setDiscountRegistryManager(address(0));
  }

  function test_SetDiscountRegistryManagerWhenTheNewDiscountRegistryManagerIsNotTheZeroAddress(address _newDiscountRegistryManager)
    external
    whenTheCallerIsTheDiscountRegistryManager
  {
    vm.assume(_newDiscountRegistryManager != address(0));
    // it should emit SetDiscountRegistryManager
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetDiscountRegistryManager(_newDiscountRegistryManager);
    _poolFactory.setDiscountRegistryManager(_newDiscountRegistryManager);
    // it should update discountRegistryManager
    assertEq(_poolFactory.discountRegistryManager(), _newDiscountRegistryManager);
  }

  function test_SetDiscountRegistryWhenTheCallerIsNotTheDiscountRegistryManager(address _caller) external {
    // it should revert with NotDiscountRegistryManager
    vm.assume(_caller != _discountRegistryManager);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotDiscountRegistryManager.selector);
    _poolFactory.setDiscountRegistry(address(0));
  }

  function test_SetDiscountRegistryWhenTheNewDiscountRegistryIsTheZeroAddress()
    external
    whenTheCallerIsTheDiscountRegistryManager
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setDiscountRegistry(address(0));
  }

  function test_SetDiscountRegistryWhenTheNewDiscountRegistryIsNotTheZeroAddress(address _newDiscountRegistry)
    external
    whenTheCallerIsTheDiscountRegistryManager
  {
    vm.assume(_newDiscountRegistry != address(0));
    // it should emit SetDiscountRegistry
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetDiscountRegistry(_newDiscountRegistry);
    _poolFactory.setDiscountRegistry(_newDiscountRegistry);
    // it should update discountRegistry
    assertEq(_poolFactory.discountRegistry(), _newDiscountRegistry);
  }

  function test_SetPoolTapeManagerWhenTheCallerIsNotThePoolTapeManager(address _caller) external {
    vm.assume(_caller != _poolTapeManager);
    // it should revert with NotPoolTapeManager
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPoolTapeManager.selector);
    _poolFactory.setPoolTapeManager(address(0));
  }

  modifier whenTheCallerIsThePoolTapeManager() {
    vm.startPrank(_poolTapeManager);
    _;
    vm.stopPrank();
  }

  function test_SetPoolTapeManagerWhenTheNewManagerIsTheZeroAddress() external whenTheCallerIsThePoolTapeManager {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setPoolTapeManager(address(0));
  }

  function test_SetPoolTapeManagerWhenTheNewManagerIsNotTheZeroAddress(address _newManager)
    external
    whenTheCallerIsThePoolTapeManager
  {
    _assumeFuzzable(_newManager);
    vm.assume(_newManager != _poolTapeManager);
    // it should emit SetPoolTapeManager
    vm.expectEmit();
    emit IPoolFactory.SetPoolTapeManager(_newManager);
    _poolFactory.setPoolTapeManager(_newManager);
    // it should update poolTapeManager
    assertEq(_poolFactory.poolTapeManager(), _newManager);
  }

  function test_SetPoolTapeWhenTheCallerIsNotThePoolTapeManager(address _caller) external {
    vm.assume(_caller != _poolTapeManager);
    // it should revert with NotPoolTapeManager
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPoolTapeManager.selector);
    _poolFactory.setPoolTape(address(0), 1);
  }

  function test_SetPoolTapeWhenTheGasLimitIsZero(address _newPoolTape) external whenTheCallerIsThePoolTapeManager {
    // it should revert with ZeroGasLimit
    vm.expectRevert(IPoolFactory.ZeroGasLimit.selector);
    _poolFactory.setPoolTape(_newPoolTape, 0);
  }

  function test_SetPoolTapeWhenTheGasLimitIsGtZero(
    address _newPoolTape,
    uint32 _gasLimit
  ) external whenTheCallerIsThePoolTapeManager whenTheGasLimitIsGtZero {
    vm.assume(_gasLimit != 0);
    // it should emit SetPoolTape
    vm.expectEmit();
    emit IPoolFactory.SetPoolTape(_newPoolTape, _gasLimit);
    _poolFactory.setPoolTape(_newPoolTape, _gasLimit);
    // it should update poolTape
    assertEq(_poolFactory.poolTape(), _newPoolTape);
    // it should update poolTapeGasLimit
    assertEq(_poolFactory.poolTapeGasLimit(), _gasLimit);
  }

  function test_RecordPoolTapeWhenNoPoolTapeIsSet(address _caller) external {
    IPoolTape.PoolTapeData memory _data;
    // it should not forward to the tape
    vm.expectCall(_poolTape, abi.encodeCall(IPoolTape.record, (_caller, _data)), 0);
    vm.prank(_caller);
    _poolFactory.recordPoolTape(_data);
  }

  modifier whenAPoolTapeIsSet() {
    stdstore.target(address(_poolFactory)).sig(IPoolFactory.poolTape.selector).checked_write(_poolTape);
    _;
  }

  function test_RecordPoolTapeWhenTheCallerIsNotAPool(address _caller) external whenAPoolTapeIsSet {
    _assumeFuzzable(_caller);
    IPoolTape.PoolTapeData memory _data;
    // it should not forward to the tape
    vm.expectCall(_poolTape, abi.encodeCall(IPoolTape.record, (_caller, _data)), 0);
    vm.prank(_caller);
    _poolFactory.recordPoolTape(_data);
  }

  modifier whenTheCallerIsAPool() {
    _;
  }

  function test_RecordPoolTapeWhenThereIsntEnoughGasLeftForTheExternalCall(
    address _pool,
    IPoolTape.PoolTapeData memory _data,
    uint32 _gasLimit,
    uint256 _gas
  ) external whenAPoolTapeIsSet whenTheCallerIsAPool {
    _assumeFuzzable(_pool);
    _gasLimit = uint32(bound(_gasLimit, MIN_REACHABLE_GAS, type(uint32).max));
    _writeGasLimit(IPoolFactory.poolTapeGasLimit.selector, _gasLimit);
    _gas = bound(_gas, MIN_REACHABLE_GAS, _gasLimit);
    stdstore.target(address(_poolFactory)).sig(IPoolFactory.isPool.selector).with_key(_pool).checked_write(true);
    // it should revert with InsufficientGasForCall
    vm.prank(_pool);
    vm.expectRevert(IPoolFactory.InsufficientGasForCall.selector);
    _poolFactory.recordPoolTape{gas: _gas}(_data);
  }

  function test_RecordPoolTapeWhenThereIsEnoughGasLeftForTheExternalCall(
    address _pool,
    IPoolTape.PoolTapeData memory _data,
    uint32 _gasLimit
  ) external whenAPoolTapeIsSet whenTheCallerIsAPool whenThereIsEnoughGasLeftForTheExternalCall {
    _assumeFuzzable(_pool);
    _boundAndWriteGasLimit(IPoolFactory.poolTapeGasLimit.selector, _gasLimit);
    stdstore.target(address(_poolFactory)).sig(IPoolFactory.isPool.selector).with_key(_pool).checked_write(true);
    // it should forward the pool's record data to the pool tape
    _mockAndExpect(_poolTape, abi.encodeCall(IPoolTape.record, (_pool, _data)), '');
    vm.prank(_pool);
    _poolFactory.recordPoolTape(_data);
  }

  function test_SetMevTaxModuleWhenTheCallerIsNotTheFeeManager(address _caller) external {
    // it should revert with NotFeeManager
    vm.assume(_caller != _feeManager);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotFeeManager.selector);
    _poolFactory.setMevTaxModule(address(0), 1);
  }

  function test_SetMevTaxModuleWhenTheGasLimitIsZero() external whenTheCallerIsTheFeeManager {
    // it should revert with ZeroGasLimit
    vm.expectRevert(IPoolFactory.ZeroGasLimit.selector);
    _poolFactory.setMevTaxModule(_mevTaxModule, 0);
  }

  function test_SetMevTaxModuleWhenTheNewMevTaxModuleIsTheZeroAddress()
    external
    whenAMevTaxModuleIsSet
    whenTheCallerIsTheFeeManager
    whenTheGasLimitIsGtZero
  {
    // it should emit SetMevTaxModule
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetMevTaxModule(address(0), 1);
    _poolFactory.setMevTaxModule(address(0), 1);
    // it should clear mevTaxModule
    assertEq(_poolFactory.mevTaxModule(), address(0));
  }

  function test_SetMevTaxModuleWhenTheNewMevTaxModuleIsNotTheZeroAddress(uint32 _gasLimit)
    external
    whenTheCallerIsTheFeeManager
    whenTheGasLimitIsGtZero
  {
    vm.assume(_gasLimit != 0);
    // it should emit SetMevTaxModule
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetMevTaxModule(_mevTaxModule, _gasLimit);
    _poolFactory.setMevTaxModule(_mevTaxModule, _gasLimit);
    // it should update mevTaxModule
    assertEq(_poolFactory.mevTaxModule(), _mevTaxModule);
    // it should update mevTaxModuleGasLimit
    assertEq(_poolFactory.mevTaxModuleGasLimit(), _gasLimit);
  }

  function test_GetFeeWhenNoMevTaxModuleIsSet(address _pool, address _sender) external view {
    (uint256 _fee, uint256 _mevFee, bool _toxic) = _poolFactory.getFee(_pool, _sender, 0, 0, 0, 0);
    // it should return the base fee with zero mev fee and false toxic
    assertEq(_fee, _poolFactory.DEFAULT_FEE());
    assertEq(_mevFee, 0);
    assertFalse(_toxic);
  }

  modifier whenAMevTaxModuleIsSet() {
    stdstore.target(address(_poolFactory)).sig(IPoolFactory.mevTaxModule.selector).checked_write(_mevTaxModule);
    _;
  }

  function test_GetFeeWhenThereIsntEnoughGasLeftForTheExternalCall(
    address _pool,
    address _sender,
    uint32 _gasLimit,
    uint256 _gas
  ) external whenAMevTaxModuleIsSet {
    _gasLimit = uint32(bound(_gasLimit, MIN_REACHABLE_GAS, type(uint32).max));
    _writeGasLimit(IPoolFactory.mevTaxModuleGasLimit.selector, _gasLimit);
    _gas = bound(_gas, MIN_REACHABLE_GAS, _gasLimit);
    // it should revert with InsufficientGasForCall
    vm.expectRevert(IPoolFactory.InsufficientGasForCall.selector);
    _poolFactory.getFee{gas: _gas}(_pool, _sender, 0, 0, 0, 0);
  }

  function test_GetFeeWhenThereIsEnoughGasLeftForTheExternalCall(
    address _pool,
    address _sender,
    uint32 _gasLimit
  ) external whenAMevTaxModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall {
    _boundAndWriteGasLimit(IPoolFactory.mevTaxModuleGasLimit.selector, _gasLimit);
    // it should forward the pool to the module
    _mockAndExpect(_mevTaxModule, abi.encodeCall(IMevTaxModule.getMevTax, ()), abi.encode(uint24(0), false));
    _poolFactory.getFee(_pool, _sender, 0, 0, 0, 0);
  }

  function test_GetFeeWhenTheModuleCallFails(
    address _pool,
    address _sender,
    uint32 _gasLimit
  ) external whenAMevTaxModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall {
    _boundAndWriteGasLimit(IPoolFactory.mevTaxModuleGasLimit.selector, _gasLimit);
    vm.mockCallRevert(_mevTaxModule, abi.encodeCall(IMevTaxModule.getMevTax, ()), 'error');
    (uint256 _fee, uint256 _mevFee, bool _toxic) = _poolFactory.getFee(_pool, _sender, 0, 0, 0, 0);
    // it should return the base fee with zero mev fee and false toxic
    assertEq(_fee, _poolFactory.DEFAULT_FEE());
    assertEq(_mevFee, 0);
    assertFalse(_toxic);
  }

  modifier whenTheModuleCallSucceeds() {
    _;
  }

  function test_GetFeeWhenTheModuleReturnsATaxAboveTheMaximumEncodableTax(
    address _pool,
    address _sender,
    uint256 _tax,
    uint32 _gasLimit
  ) external whenAMevTaxModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall whenTheModuleCallSucceeds {
    _boundAndWriteGasLimit(IPoolFactory.mevTaxModuleGasLimit.selector, _gasLimit);
    _tax = bound(_tax, uint256(type(uint24).max) + 1, type(uint256).max);
    _mockAndExpect(_mevTaxModule, abi.encodeCall(IMevTaxModule.getMevTax, ()), abi.encode(_tax, uint256(1)));
    (uint256 _fee, uint256 _mevFee, bool _toxic) = _poolFactory.getFee(_pool, _sender, 0, 0, 0, 0);
    // it should return the base fee with zero mev fee and false toxic
    assertEq(_fee, _poolFactory.DEFAULT_FEE());
    assertEq(_mevFee, 0);
    assertFalse(_toxic);
  }

  function test_GetFeeWhenTheModuleReturnsAValidTaxAndToxicFlag(
    address _pool,
    address _sender,
    uint24 _tax,
    bool _toxic,
    uint32 _gasLimit
  ) external whenAMevTaxModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall whenTheModuleCallSucceeds {
    _boundAndWriteGasLimit(IPoolFactory.mevTaxModuleGasLimit.selector, _gasLimit);
    uint256 _headroom = _poolFactory.MAX_FEE() - _poolFactory.DEFAULT_FEE();
    _tax = uint24(bound(uint256(_tax), 0, _headroom * 100));
    _mockAndExpect(_mevTaxModule, abi.encodeCall(IMevTaxModule.getMevTax, ()), abi.encode(_tax, _toxic));
    (uint256 _fee, uint256 _mevFee, bool _toxicOut) = _poolFactory.getFee(_pool, _sender, 0, 0, 0, 0);
    // it should return the base fee plus the mev fee in bps
    assertEq(_fee, _poolFactory.DEFAULT_FEE() + (uint256(_tax) + 99) / 100);
    // it should return the mev fee in bps
    assertEq(_mevFee, (uint256(_tax) + 99) / 100);
    assertLe(_mevFee, _fee);
    // it should return the toxic boolean
    assertEq(_toxicOut, _toxic);
  }

  function test_GetFeeWhenFeePlusMevIsHigherThanMAX_FEE(
    address _pool,
    address _sender,
    uint24 _tax,
    bool _toxic,
    uint32 _gasLimit
  ) external whenAMevTaxModuleIsSet whenThereIsEnoughGasLeftForTheExternalCall whenTheModuleCallSucceeds {
    _boundAndWriteGasLimit(IPoolFactory.mevTaxModuleGasLimit.selector, _gasLimit);
    uint256 _headroom = _poolFactory.MAX_FEE() - _poolFactory.DEFAULT_FEE();
    _tax = uint24(bound(uint256(_tax), _headroom * 100 + 1, type(uint24).max));
    _mockAndExpect(_mevTaxModule, abi.encodeCall(IMevTaxModule.getMevTax, ()), abi.encode(_tax, _toxic));
    (uint256 _fee, uint256 _mevFee, bool _toxicOut) = _poolFactory.getFee(_pool, _sender, 0, 0, 0, 0);
    // it should return MAX_FEE
    assertEq(_fee, _poolFactory.MAX_FEE());
    // it should return the mev fee clamped to the remainder
    assertEq(_mevFee, _headroom);
    assertEq(_toxicOut, _toxic);
  }

  function test_SetExactOutFeeQuoterWhenTheCallerIsNotTheFeeManager(address _caller) external {
    vm.assume(_caller != _feeManager);
    vm.prank(_caller);
    // it should revert with NotFeeManager
    vm.expectRevert(IPoolFactory.NotFeeManager.selector);
    _poolFactory.setExactOutFeeQuoter(_exactOutFeeQuoter);
  }

  function test_SetExactOutFeeQuoterWhenTheNewQuoterIsTheZeroAddress() external whenTheCallerIsTheFeeManager {
    // it should revert with ZeroAddress
    vm.expectRevert(IPoolFactory.ZeroAddress.selector);
    _poolFactory.setExactOutFeeQuoter(address(0));
  }

  modifier whenTheNewQuoterIsNotTheZeroAddress() {
    _;
  }

  function test_SetExactOutFeeQuoterWhenTheNewQuoterIsBoundToADifferentFactory(address _otherFactory)
    external
    whenTheCallerIsTheFeeManager
    whenTheNewQuoterIsNotTheZeroAddress
  {
    vm.assume(_otherFactory != address(_poolFactory));
    _mockAndExpect(_exactOutFeeQuoter, abi.encodeCall(IExactOutFeeQuoter.FACTORY, ()), abi.encode(_otherFactory));
    // it should revert with InvalidExactOutFeeQuoter
    vm.expectRevert(IPoolFactory.InvalidExactOutFeeQuoter.selector);
    _poolFactory.setExactOutFeeQuoter(_exactOutFeeQuoter);
  }

  function test_SetExactOutFeeQuoterWhenTheNewQuoterIsBoundToThisFactory()
    external
    whenTheCallerIsTheFeeManager
    whenTheNewQuoterIsNotTheZeroAddress
  {
    _mockAndExpect(
      _exactOutFeeQuoter, abi.encodeCall(IExactOutFeeQuoter.FACTORY, ()), abi.encode(address(_poolFactory))
    );
    // it should emit SetExactOutFeeQuoter
    _expectEmit(address(_poolFactory));
    emit IPoolFactory.SetExactOutFeeQuoter(_exactOutFeeQuoter);
    _poolFactory.setExactOutFeeQuoter(_exactOutFeeQuoter);
    // it should update exactOutFeeQuoter
    assertEq(_poolFactory.exactOutFeeQuoter(), _exactOutFeeQuoter);
  }

  function test_GetFeeForAmountInWhenNoExactOutFeeQuoterIsSet(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1
  ) external {
    // it should revert with NoExactOutFeeQuoter
    vm.expectRevert(IPoolFactory.NoExactOutFeeQuoter.selector);
    _poolFactory.getFeeForAmountIn(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1);
  }

  modifier whenAnExactOutFeeQuoterIsSet() {
    stdstore.target(address(_poolFactory)).sig(IPoolFactory.exactOutFeeQuoter.selector)
      .checked_write(_exactOutFeeQuoter);
    _;
  }

  function test_GetFeeForAmountInWhenTheQuoterReverts(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1
  ) external whenAnExactOutFeeQuoterIsSet {
    vm.mockCallRevert(
      _exactOutFeeQuoter,
      abi.encodeCall(
        IExactOutFeeQuoter.getFeeForAmountIn,
        (_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1)
      ),
      'quoter error'
    );
    // it revert
    vm.expectRevert('quoter error');
    _poolFactory.getFeeForAmountIn(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1);
  }

  function test_GetFeeForAmountInWhenTheQuoterReturnsAFeeAboveTheMaxFee(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee
  ) external whenAnExactOutFeeQuoterIsSet {
    _fee = bound(_fee, _poolFactory.MAX_FEE() + 1, type(uint256).max);
    _mockAndExpect(
      _exactOutFeeQuoter,
      abi.encodeCall(
        IExactOutFeeQuoter.getFeeForAmountIn,
        (_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1)
      ),
      abi.encode(_fee)
    );
    // it should revert with FeeTooHigh
    vm.expectRevert(IPoolFactory.FeeTooHigh.selector);
    _poolFactory.getFeeForAmountIn(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1);
  }

  function test_GetFeeForAmountInWhenTheQuoterReturnsAFeeWithinTheMaxFee(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee
  ) external whenAnExactOutFeeQuoterIsSet {
    _fee = bound(_fee, 0, _poolFactory.MAX_FEE());
    // it should forward the pool caller amounts and reserves to the quoter
    _mockAndExpect(
      _exactOutFeeQuoter,
      abi.encodeCall(
        IExactOutFeeQuoter.getFeeForAmountIn,
        (_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1)
      ),
      abi.encode(_fee)
    );
    // it should return the quoted fee
    assertEq(
      _poolFactory.getFeeForAmountIn(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1), _fee
    );
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Writes a module gas limit
  function _writeGasLimit(bytes4 _getterSig, uint32 _gasLimit) internal {
    stdstore.enable_packed_slots().target(address(_poolFactory)).sig(_getterSig).checked_write(uint256(_gasLimit));
  }

  /// @dev Bounds a fuzzed gas limit to a reachable range and writes it
  function _boundAndWriteGasLimit(bytes4 _getterSig, uint32 _gasLimit) internal {
    _writeGasLimit(_getterSig, uint32(bound(_gasLimit, MIN_REACHABLE_GAS, MAX_GAS_LIMIT)));
  }
}
