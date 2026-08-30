// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

abstract contract UnitPool is TestHelpers {
  using stdStorage for StdStorage;

  uint8 internal constant DECIMALS_HIGH = 18;
  uint8 internal constant DECIMALS_LOW = 6;

  /// @dev Same minimum liquidity as in Pool
  uint256 internal constant MINIMUM_LIQUIDITY = 10 ** 3;
  uint256 internal constant OBSERVATIONS_CIRCULAR_BUFFER_SIZE = type(uint16).max;
  uint256 internal constant OBSERVATION_SLOT_COUNT = 3;

  address internal _poolAdmin = makeAddr('poolAdmin');
  address internal _recipient = makeAddr('recipient');

  IPool internal _pool;
  address internal _token0;
  address internal _token1;
  uint256 internal _decimals0;
  uint256 internal _decimals1;
  uint256 internal _observationBufferBaseSlot;
  uint256 internal _observationBufferInformationSlot;

  address internal _mockFactory = _mockContract('factory');

  function setUp() public virtual {
    address _tokenA = _mockContract('tokenA');
    address _tokenB = _mockContract('tokenB');

    bool _aIsToken0 = _tokenA < _tokenB;
    _token0 = _aIsToken0 ? _tokenA : _tokenB;
    _token1 = _aIsToken0 ? _tokenB : _tokenA;
    uint8 _dec0 = _aIsToken0 ? DECIMALS_HIGH : DECIMALS_LOW;
    uint8 _dec1 = _aIsToken0 ? DECIMALS_LOW : DECIMALS_HIGH;
    _decimals0 = 10 ** uint256(_dec0);
    _decimals1 = 10 ** uint256(_dec1);

    _pool = _deployPool();

    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(_dec0));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(_dec1));
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK0'));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK1'));

    vm.prank(_mockFactory);
    _pool.initialize(_token0, _token1);

    _observationBufferBaseSlot = 11;
    _observationBufferInformationSlot =
      _observationBufferBaseSlot + OBSERVATIONS_CIRCULAR_BUFFER_SIZE * OBSERVATION_SLOT_COUNT;
  }

  function test_InitializeWhenFactoryAlreadySet() external {
    // it should revert with FactoryAlreadySet
    vm.expectRevert(IPool.FactoryAlreadySet.selector);
    _pool.initialize(_token0, _token1);
  }

  function test_InitializeWhenCalledForTheFirstTime() external view {
    // it should set factory to msg sender
    assertEq(_pool.factory(), _mockFactory);
    // it should set token0 and token1 with provided token arguments
    assertEq(_pool.token0(), _token0);
    assertEq(_pool.token1(), _token1);
    // it should deploy a poolFees contract
    assertTrue(_pool.poolFees() != address(0));
    // it should record the decimals of both tokens
    (uint256 _dec0, uint256 _dec1,,,,) = _pool.metadata();
    assertEq(_dec0, _decimals0);
    assertEq(_dec1, _decimals1);
    // it should set the first observation timestamp to block.timestamp
    (uint32 _ts,,) = _pool.observations(0);
    assertEq(_ts, block.timestamp);
  }

  function test_SetNameWhenTheCallerIsNotThePoolAdmin(address _caller, string calldata _name) external {
    _mockFactoryPoolAdmin(_poolAdmin);
    // it should revert with NotPoolAdmin
    vm.assume(_caller != _poolAdmin);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPoolAdmin.selector);
    _pool.setName(_name);
  }

  function test_SetNameWhenTheCallerIsThePoolAdmin(string calldata _name) external {
    _mockFactoryPoolAdmin(_poolAdmin);
    vm.assume(keccak256(bytes(_name)) != keccak256(bytes(IERC20Metadata(address(_pool)).name())));
    vm.prank(_poolAdmin);
    _pool.setName(_name);
    // it should update the name
    assertEq(IERC20Metadata(address(_pool)).name(), _name);
  }

  function test_SetSymbolWhenTheCallerIsNotThePoolAdmin(address _caller, string calldata _symbol) external {
    _mockFactoryPoolAdmin(_poolAdmin);
    // it should revert with NotPoolAdmin
    vm.assume(_caller != _poolAdmin);
    vm.prank(_caller);
    vm.expectRevert(IPoolFactory.NotPoolAdmin.selector);
    _pool.setSymbol(_symbol);
  }

  function test_SetSymbolWhenTheCallerIsThePoolAdmin(string calldata _symbol) external {
    _mockFactoryPoolAdmin(_poolAdmin);
    vm.assume(keccak256(bytes(_symbol)) != keccak256(bytes(IERC20Metadata(address(_pool)).symbol())));
    vm.prank(_poolAdmin);
    _pool.setSymbol(_symbol);
    // it should update the symbol
    assertEq(IERC20Metadata(address(_pool)).symbol(), _symbol);
  }

  function test_ObservationsShouldReturnTheStoredObservationAtTheGivenIndex(
    uint16 _index,
    uint32 _timestamp,
    uint256 _reserve0Cumulative,
    uint256 _reserve1Cumulative
  ) external {
    _index = uint16(bound(_index, 0, OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _writeObservation(_index, _timestamp, _reserve0Cumulative, _reserve1Cumulative);

    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(_index);
    // it should return the stored observation at the given index
    assertEq(_ts, _timestamp);
    assertEq(_r0c, _reserve0Cumulative);
    assertEq(_r1c, _reserve1Cumulative);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setTotalSupply(uint256 _totalSupply) internal {
    _set(address(_pool), _totalSupply, IERC20.totalSupply.selector);
  }

  function _setLiquidity(uint256 _liquidity) internal {
    stdstore.target(address(_pool)).sig(IERC20.balanceOf.selector).with_key(address(_pool)).checked_write(_liquidity);
  }

  function _setReserves(uint256 _reserve0, uint256 _reserve1) internal {
    _set(address(_pool), _reserve0, _pool.reserve0.selector);
    _set(address(_pool), _reserve1, _pool.reserve1.selector);
  }

  function _setObservationInformationSlot(uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) internal {
    uint256 _packed = uint256(_index) | (uint256(_cardinality) << 16) | (uint256(_cardinalityNext) << 32);
    vm.store(address(_pool), bytes32(_observationBufferInformationSlot), bytes32(_packed));
  }

  function _setObservationCardinalityNext(uint16 _cardinalityNext) internal {
    (uint16 _index, uint16 _cardinality,) = _pool.observationBuffer();
    _setObservationInformationSlot(_index, _cardinality, _cardinalityNext);
  }

  function _setObservationCardinality(uint16 _cardinality) internal {
    (uint16 _index,, uint16 _cardinalityNext) = _pool.observationBuffer();
    _setObservationInformationSlot(_index, _cardinality, _cardinalityNext);
  }

  function _writeObservation(uint16 _index, uint32 _timestamp, uint256 _r0c, uint256 _r1c) internal {
    uint256 _slot = _observationBufferBaseSlot + uint256(_index) * OBSERVATION_SLOT_COUNT;
    vm.store(address(_pool), bytes32(_slot), bytes32(uint256(_timestamp)));
    vm.store(address(_pool), bytes32(_slot + 1), bytes32(_r0c));
    vm.store(address(_pool), bytes32(_slot + 2), bytes32(_r1c));
  }

  /// @dev Child contract deploys the pool implementation.
  function _deployPool() internal virtual returns (IPool);

  function _mockFactoryPoolAdmin(address _admin) internal {
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.poolAdmin, ()), abi.encode(_admin));
  }
}
