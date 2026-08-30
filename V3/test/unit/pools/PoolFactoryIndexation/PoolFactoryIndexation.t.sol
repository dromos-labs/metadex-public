// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IPoolFactoryIndexation} from 'V3/interfaces/pools/IPoolFactoryIndexation.sol';

import {MockPoolFactoryIndexation} from 'V3-test/mocks/MockPoolFactoryIndexation.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitPoolFactoryIndexation is TestHelpers {
  using stdStorage for StdStorage;

  uint256 private constant POOL_BY_TOKEN_INDEX_SLOT = 0;
  uint256 private constant POOLS_INDEX_SLOT = 1;
  uint256 private constant TOKEN_INDEX_SLOT = 2;

  uint256 internal constant LENGTH_CEIL = 1000;

  MockPoolFactoryIndexation internal poolFactoryIndexation;

  function setUp() public virtual {
    poolFactoryIndexation = new MockPoolFactoryIndexation();
  }

  function test_PoolByTokenIndexLengthReturnsLengthOfPoolByTokenIndexForToken(
    address _token,
    uint256 _length
  ) external {
    /// @dev No need to push elements, since compiler will only check
    ///      array's length slot when executing {length}.
    _setPoolByTokenIndexLength(_token, _length);

    // it returns length of poolByTokenIndex for token
    assertEq(poolFactoryIndexation.poolByTokenIndexLength(_token), _length);
  }

  function test_PoolsIndexLengthReturnsLengthOfPoolsIndex(uint256 _length) external {
    _setPoolsIndexLength(_length);

    // it returns length of poolsIndex
    assertEq(poolFactoryIndexation.poolsIndexLength(), _length);
  }

  function test_TokenIndexLengthReturnsLengthOfTokenIndex(uint256 _length) external {
    _setTokenIndexLength(_length);

    // it returns length of tokenIndex
    assertEq(poolFactoryIndexation.tokenIndexLength(), _length);
  }

  /*////////////////////////////////////////////////////////////
                             LENGTH HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setPoolByTokenIndexLength(address _token, uint256 _length) internal {
    bytes32 _arraySlot = keccak256(abi.encode(_token, POOL_BY_TOKEN_INDEX_SLOT));
    vm.store(address(poolFactoryIndexation), _arraySlot, bytes32(_length));
  }

  function _setPoolsIndexLength(uint256 _length) internal {
    vm.store(address(poolFactoryIndexation), bytes32(POOLS_INDEX_SLOT), bytes32(_length));
  }

  function _setTokenIndexLength(uint256 _length) internal {
    vm.store(address(poolFactoryIndexation), bytes32(TOKEN_INDEX_SLOT), bytes32(_length));
  }

  /*////////////////////////////////////////////////////////////
                             PUSH HELPERS
  ////////////////////////////////////////////////////////////*/

  function _poolByTokenIndex_push(address _token, uint256 _numberOfPools) internal {
    for (uint256 _i = 0; _i < _numberOfPools; ++_i) {
      _poolByTokenIndex_push(_token, address(uint160(_i + 1)));
    }
  }

  function _poolsIndex_push(uint256 _numberOfElements) internal {
    for (uint256 _i = 0; _i < _numberOfElements; ++_i) {
      _poolsIndex_push(
        IPoolFactoryIndexation.PoolData({pool: address(uint160(_i + 1)), creationTimestamp: uint48(_i + 1)})
      );
    }
  }

  function _tokenIndex_push(uint256 _numberOfElements) internal {
    for (uint256 _i = 0; _i < _numberOfElements; ++_i) {
      _tokenIndex_push(address(uint160(_i + 1)));
    }
  }

  function _poolsIndex_push(IPoolFactoryIndexation.PoolData memory _poolData) internal {
    bytes32 _valuesSlot = keccak256(abi.encode(POOLS_INDEX_SLOT));
    uint256 _len = uint256(vm.load(address(poolFactoryIndexation), bytes32(POOLS_INDEX_SLOT)));

    bytes32 _pushPos = bytes32(uint256(_valuesSlot) + _len);
    bytes32 _tupleToPush = bytes32(uint256(uint160(_poolData.pool)) | (uint256(_poolData.creationTimestamp) << 160));

    vm.store(address(poolFactoryIndexation), _pushPos, _tupleToPush);
    /// @dev Update the length of array.
    vm.store(address(poolFactoryIndexation), bytes32(POOLS_INDEX_SLOT), bytes32(_len + 1));
  }

  function _poolByTokenIndex_push(address _token, address _pool) internal {
    bytes32 _arraySlot = keccak256(abi.encode(_token, POOL_BY_TOKEN_INDEX_SLOT));

    uint256 _len = uint256(vm.load(address(poolFactoryIndexation), _arraySlot));

    bytes32 _valuesSlot = keccak256(abi.encode(_arraySlot));
    bytes32 _pushPos = bytes32(uint256(_valuesSlot) + _len);

    vm.store(address(poolFactoryIndexation), _pushPos, bytes32(uint256(uint160(_pool))));
    /// @dev Update the length of array.
    vm.store(address(poolFactoryIndexation), _arraySlot, bytes32(_len + 1));
  }

  function _tokenIndex_push(address _token) internal {
    uint256 _len = uint256(vm.load(address(poolFactoryIndexation), bytes32(TOKEN_INDEX_SLOT)));

    bytes32 _valuesSlot = keccak256(abi.encode(TOKEN_INDEX_SLOT));
    bytes32 _pushPos = bytes32(uint256(_valuesSlot) + _len);

    bytes32 _newElement = bytes32(uint256(uint160(_token)));

    /// @dev Push pool to {Set._values}.
    vm.store(address(poolFactoryIndexation), _pushPos, _newElement);

    /// @dev Update the length of {Set._values}.
    _setTokenIndexLength(_len + 1);

    bytes32 _indexesSlot = bytes32(TOKEN_INDEX_SLOT + 1);
    bytes32 _index = keccak256(abi.encode(_newElement, _indexesSlot));

    /// @dev Indexes start at 1.
    vm.store(address(poolFactoryIndexation), _index, bytes32(_len + 1));
  }

  function _tokenIndex_get(uint256 _index) internal view returns (address _token) {
    bytes32 _arrayValues = keccak256(abi.encode(TOKEN_INDEX_SLOT));
    bytes32 _getPos = bytes32(uint256(_arrayValues) + _index);

    _token = address(uint160(uint256(vm.load(address(poolFactoryIndexation), _getPos))));
  }
}
