// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {ExcessivelySafeCall} from '@nomad-xyz/src/ExcessivelySafeCall.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IExactOutFeeQuoter} from 'V3/interfaces/fees/IExactOutFeeQuoter.sol';
import {IFeeModule} from 'V3/interfaces/fees/IFeeModule.sol';
import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';

import {PoolFactoryIndexation} from 'V3/pools/PoolFactoryIndexation.sol';

/// @title PoolFactory
/// @author velodrome.finance, Solidly, Uniswap Labs
/// @notice Abstract base for Aerodrome V2 pool factories. Holds the logic
///         shared between stable and volatile pool factories.
abstract contract PoolFactory is PoolFactoryIndexation, IPoolFactory {
  using ExcessivelySafeCall for address;

  /*////////////////////////////////////////////////////////////
                            CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPoolFactory
  uint256 public constant MAX_DEFAULT_FEE = 300; // 3%

  /// @inheritdoc IPoolFactory
  uint256 public constant MAX_BASE_FEE = 1000; // 10%

  /// @inheritdoc IPoolFactory
  uint256 public constant MAX_FEE = 2000; // 20%

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPoolFactory
  address public immutable implementation;

  /// @inheritdoc IPoolFactory
  address public immutable factoryRegistry;

  /// @inheritdoc IPoolFactory
  bool public isPaused;
  /// @inheritdoc IPoolFactory
  address public pauser;

  /// @inheritdoc IPoolFactory
  uint256 public defaultFee;
  /// @inheritdoc IPoolFactory
  address public feeManager;
  /// @inheritdoc IPoolFactory
  address public feeModule;
  /// @inheritdoc IPoolFactory
  uint32 public feeModuleGasLimit;
  /// @inheritdoc IPoolFactory
  address public poolAdmin;
  /// @inheritdoc IPoolFactory
  address public discountRegistryManager;
  /// @inheritdoc IPoolFactory
  address public discountRegistry;
  /// @inheritdoc IPoolFactory
  address public poolTape;
  /// @inheritdoc IPoolFactory
  uint32 public poolTapeGasLimit;
  /// @inheritdoc IPoolFactory
  address public poolTapeManager;

  /// @inheritdoc IPoolFactory
  address public mevTaxModule;
  /// @inheritdoc IPoolFactory
  uint32 public mevTaxModuleGasLimit;

  /// @inheritdoc IPoolFactory
  address public exactOutFeeQuoter;

  mapping(address _tokenA => mapping(address _tokenB => address _pool)) internal _getPool;
  address[] internal _allPools;
  /// @dev simplified check if its a pool
  mapping(address _pool => bool _isPool) internal _isPool;

  /*////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Wires the pool implementation, the role holders and the default fee.
  /// @dev Reverts with ZeroAddress when any address parameter is zero.
  /// @param _implementation Pool implementation the factory clones.
  /// @param _poolAdmin Initial pool admin.
  /// @param _pauser Initial pauser.
  /// @param _feeManager Initial fee manager.
  /// @param _defaultFee Default swap fee in basis points.
  /// @param _discountRegistryManager Initial discount registry manager.
  /// @param _poolTapeManager Initial pool tape manager.
  /// @param _factoryRegistry Factory registry every created pool is recorded in as a target.
  constructor(
    address _implementation,
    address _poolAdmin,
    address _pauser,
    address _feeManager,
    uint256 _defaultFee,
    address _discountRegistryManager,
    address _poolTapeManager,
    address _factoryRegistry
  ) {
    if (
      _implementation == address(0) || _poolAdmin == address(0) || _pauser == address(0) || _feeManager == address(0)
        || _discountRegistryManager == address(0) || _poolTapeManager == address(0) || _factoryRegistry == address(0)
    ) revert ZeroAddress();
    implementation = _implementation;
    factoryRegistry = _factoryRegistry;
    discountRegistryManager = _discountRegistryManager;
    poolAdmin = _poolAdmin;
    pauser = _pauser;
    feeManager = _feeManager;
    poolTapeManager = _poolTapeManager;
    isPaused = false;
    defaultFee = _defaultFee;
    emit SetDiscountRegistryManager(_discountRegistryManager);
    emit SetPoolAdmin(_poolAdmin);
    emit SetPauser(_pauser);
    emit SetFeeManager(_feeManager);
    emit SetPoolTapeManager(_poolTapeManager);
    emit SetDefaultFee(_defaultFee);
  }

  /// @inheritdoc IPoolFactory
  function allPools(uint256 index) external view returns (address) {
    return _allPools[index];
  }

  /// @inheritdoc IPoolFactory
  function allPools() external view returns (address[] memory) {
    return _allPools;
  }

  /// @inheritdoc IPoolFactory
  function allPoolsLength() external view returns (uint256) {
    return _allPools.length;
  }

  /// @inheritdoc IPoolFactory
  function getPool(address tokenA, address tokenB) external view returns (address) {
    return _getPool[tokenA][tokenB];
  }

  /// @inheritdoc IPoolFactory
  function isPool(address pool) external view returns (bool) {
    return _isPool[pool];
  }

  /// @inheritdoc IPoolFactory
  function setDiscountRegistryManager(address _discountRegistryManager) external {
    if (msg.sender != discountRegistryManager) revert NotDiscountRegistryManager();
    if (_discountRegistryManager == address(0)) revert ZeroAddress();
    discountRegistryManager = _discountRegistryManager;
    emit SetDiscountRegistryManager(_discountRegistryManager);
  }

  /// @inheritdoc IPoolFactory
  function setPoolAdmin(address _poolAdmin) external {
    if (msg.sender != poolAdmin) revert NotPoolAdmin();
    if (_poolAdmin == address(0)) revert ZeroAddress();
    poolAdmin = _poolAdmin;
    emit SetPoolAdmin(_poolAdmin);
  }

  /// @inheritdoc IPoolFactory
  function setPauser(address _pauser) external {
    if (msg.sender != pauser) revert NotPauser();
    if (_pauser == address(0)) revert ZeroAddress();
    pauser = _pauser;
    emit SetPauser(_pauser);
  }

  /// @inheritdoc IPoolFactory
  function setDiscountRegistry(address _discountRegistry) external {
    if (msg.sender != discountRegistryManager) revert NotDiscountRegistryManager();
    if (_discountRegistry == address(0)) revert ZeroAddress();
    discountRegistry = _discountRegistry;
    emit SetDiscountRegistry(_discountRegistry);
  }

  /// @inheritdoc IPoolFactory
  function setPauseState(bool _state) external {
    if (msg.sender != pauser) revert NotPauser();
    isPaused = _state;
    emit SetPauseState(_state);
  }

  /// @inheritdoc IPoolFactory
  function setFeeManager(address _feeManager) external {
    if (msg.sender != feeManager) revert NotFeeManager();
    if (_feeManager == address(0)) revert ZeroAddress();
    feeManager = _feeManager;
    emit SetFeeManager(_feeManager);
  }

  /// @inheritdoc IPoolFactory
  function setFeeModule(address _feeModule, uint32 _gasLimit) external {
    if (msg.sender != feeManager) revert NotFeeManager();
    if (_feeModule == address(0)) revert ZeroAddress();
    if (_gasLimit == 0) revert ZeroGasLimit();
    if (address(IFeeModule(_feeModule).factory()) != address(this)) revert InvalidFeeModule();
    feeModule = _feeModule;
    feeModuleGasLimit = _gasLimit;
    emit SetFeeModule(_feeModule, _gasLimit);
  }

  /// @inheritdoc IPoolFactory
  function setDefaultFee(uint256 _defaultFee) external {
    if (msg.sender != feeManager) revert NotFeeManager();
    if (_defaultFee > MAX_DEFAULT_FEE) revert FeeTooHigh();
    if (_defaultFee == 0) revert ZeroFee();
    defaultFee = _defaultFee;
    emit SetDefaultFee(_defaultFee);
  }

  /// @inheritdoc IPoolFactory
  function setPoolTapeManager(address _poolTapeManager) external {
    if (msg.sender != poolTapeManager) revert NotPoolTapeManager();
    if (_poolTapeManager == address(0)) revert ZeroAddress();
    poolTapeManager = _poolTapeManager;
    emit SetPoolTapeManager(_poolTapeManager);
  }

  /// @inheritdoc IPoolFactory
  function setPoolTape(address _poolTape, uint32 _gasLimit) external {
    if (msg.sender != poolTapeManager) revert NotPoolTapeManager();
    if (_gasLimit == 0) revert ZeroGasLimit();
    poolTape = _poolTape;
    poolTapeGasLimit = _gasLimit;
    emit SetPoolTape(_poolTape, _gasLimit);
  }

  /// @inheritdoc IPoolFactory
  function setMevTaxModule(address _mevTaxModule, uint32 _gasLimit) external {
    if (msg.sender != feeManager) revert NotFeeManager();
    if (_gasLimit == 0) revert ZeroGasLimit();
    mevTaxModule = _mevTaxModule;
    mevTaxModuleGasLimit = _gasLimit;
    emit SetMevTaxModule(_mevTaxModule, _gasLimit);
  }

  /// @inheritdoc IPoolFactory
  function setExactOutFeeQuoter(address _exactOutFeeQuoter) external {
    if (msg.sender != feeManager) revert NotFeeManager();
    if (_exactOutFeeQuoter == address(0)) revert ZeroAddress();
    if (address(IExactOutFeeQuoter(_exactOutFeeQuoter).FACTORY()) != address(this)) revert InvalidExactOutFeeQuoter();
    exactOutFeeQuoter = _exactOutFeeQuoter;
    emit SetExactOutFeeQuoter(_exactOutFeeQuoter);
  }

  /// @inheritdoc IPoolFactory
  function recordPoolTape(IPoolTape.PoolTapeData calldata _data) external {
    address _poolTape = poolTape;
    if (_poolTape == address(0)) return;
    if (!_isPool[msg.sender]) return;
    uint256 _gasLimit = poolTapeGasLimit;
    _validateGasLeft(_gasLimit);
    // slither-disable-next-line unused-return
    _poolTape.excessivelySafeCall(_gasLimit, 0, 0, abi.encodeCall(IPoolTape.record, (msg.sender, _data)));
  }

  /// @inheritdoc IPoolFactory
  function getFee(
    address _pool,
    address _sender,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256 _fee, uint256 _mevFee, bool _toxic) {
    _fee = getBaseFee(_pool, _sender, _amount0In, _amount1In, _reserve0, _reserve1);
    address _mevTaxModule = mevTaxModule;
    if (_mevTaxModule == address(0)) return (_fee, 0, false);

    uint256 _gasLimit = mevTaxModuleGasLimit;
    _validateGasLeft(_gasLimit);
    (bool _success, bytes memory _data) =
      _mevTaxModule.excessivelySafeStaticCall(_gasLimit, 64, abi.encodeCall(IMevTaxModule.getMevTax, ()));
    if (!_success || _data.length != 64) return (_fee, 0, false);

    (uint256 _dataTax, uint256 _dataToxic) = abi.decode(_data, (uint256, uint256));
    if (_dataTax > type(uint24).max) return (_fee, 0, false);

    _mevFee = FixedPointMathLib.min(FixedPointMathLib.divUp(_dataTax, 100), MAX_FEE - _fee);
    _fee += _mevFee;
    _toxic = _dataToxic == 1;
  }

  /// @inheritdoc IPoolFactory
  function getFeeForAmountIn(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256 _fee) {
    address _quoter = exactOutFeeQuoter;
    if (_quoter == address(0)) revert NoExactOutFeeQuoter();
    _fee = IExactOutFeeQuoter(_quoter)
      .getFeeForAmountIn(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1);
    if (_fee > MAX_FEE) revert FeeTooHigh();
  }

  // slither-disable-start reentrancy-no-eth
  /// @inheritdoc IPoolFactory
  function createPool(address tokenA, address tokenB) external returns (address pool) {
    if (tokenA == tokenB) revert SameAddress();
    (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    if (token0 == address(0)) revert ZeroAddress();
    if (_getPool[token0][token1] != address(0)) revert PoolAlreadyExists();
    bytes32 salt = keccak256(abi.encodePacked(token0, token1));
    pool = Clones.cloneDeterministic(implementation, salt);
    IPool(pool).initialize(token0, token1);
    _getPool[token0][token1] = pool;
    _getPool[token1][token0] = pool; // populate mapping in the reverse direction
    _allPools.push(pool);
    _isPool[pool] = true;

    _createPoolHook({_tokenA: tokenA, _tokenB: tokenB, _pool: pool});

    IFactoryRegistry(factoryRegistry).registerTarget(pool);

    emit PoolCreated(token0, token1, pool, _allPools.length);
  }

  // slither-disable-end reentrancy-no-eth
  /// @inheritdoc IPoolFactory
  function getBaseFee(
    address _pool,
    address _caller,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _reserve0,
    uint256 _reserve1
  ) public view returns (uint256) {
    address _feeModule = feeModule;
    if (_feeModule != address(0)) {
      uint256 _gasLimit = feeModuleGasLimit;
      _validateGasLeft(_gasLimit);
      (bool _success, bytes memory _data) = _feeModule.excessivelySafeStaticCall(
        _gasLimit, 32, abi.encodeCall(IFeeModule.getFee, (_pool, _caller, _amount0In, _amount1In, _reserve0, _reserve1))
      );
      if (_success && _data.length == 32) {
        uint256 _customFee = abi.decode(_data, (uint256));
        if (_customFee <= MAX_BASE_FEE) {
          return _customFee;
        }
      }
    }
    return defaultFee;
  }

  /*////////////////////////////////////////////////////////////
                              INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Reverts when the gas left is equal to or below the gas limit set for the external call.
  /// @param _gasLimit The gas limit set for to the external call.
  function _validateGasLeft(uint256 _gasLimit) internal view {
    if (gasleft() <= _gasLimit) revert InsufficientGasForCall();
  }
}
