// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TransientTracking} from 'V3/metarouter/TransientTracking.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Unit tests for the TransientTracking library.
/// @dev The library's internal functions inline into this contract and operate on its own transient storage.
///      Every write is verified against a raw EVM `tload` at an independently-derived slot, so no writer is
///      ever checked through its sibling reader (store via load, push via at, etc.).
contract UnitTransientTracking is TestHelpers {
  function test_StoreWhenAValueIsStoredAtASlot(bytes32 _slot, uint256 _value) external {
    TransientTracking.store(_slot, _value);

    // it should write _value to _slot
    assertEq(_rawTload(_slot), _value);
  }

  function test_StoreMappingWhenAValueIsStoredForAKeyUnderANamespace(
    bytes32 _namespace,
    address _key,
    address _otherKey,
    uint256 _value
  ) external {
    _value = bound(_value, 1, type(uint256).max);
    _otherKey = _boundNotEq(_otherKey, _key);

    TransientTracking.storeMapping(_namespace, _key, _value);

    // it should write _value to the slot derived from _key and _namespace
    assertEq(_rawTload(_mappingSlot(_namespace, _key)), _value);
    // it should leave the slot derived from a different _key at zero
    assertEq(_rawTload(_mappingSlot(_namespace, _otherKey)), 0);
  }

  function test_TrackWhenTheKeyHasAlreadyBeenTrackedUnderTheNamespace(
    bytes32 _arraySlot,
    bytes32 _namespace,
    address _key
  ) external {
    // The first touch tracks the key and appends it to the array.
    TransientTracking.track(_arraySlot, _namespace, _key);
    uint256 _lengthBefore = _rawTload(_arraySlot);

    TransientTracking.track(_arraySlot, _namespace, _key);

    // it should leave the _arraySlot length unchanged
    assertEq(_rawTload(_arraySlot), _lengthBefore);
  }

  function test_TrackWhenTheKeyHasNotBeenTrackedUnderTheNamespace(
    bytes32 _arraySlot,
    bytes32 _namespace,
    address _key
  ) external {
    TransientTracking.track(_arraySlot, _namespace, _key);

    // it should append _key to the _arraySlot array
    assertEq(address(uint160(_rawTload(_elementSlot(_arraySlot, 0)))), _key);
    // it should increment the _arraySlot length
    assertEq(_rawTload(_arraySlot), 1);
  }

  function test_PushWhenTheArrayIsEmpty(bytes32 _arraySlot, address _value) external {
    TransientTracking.push(_arraySlot, _value);

    // it should write _value to the slot derived from _arraySlot at index zero
    assertEq(address(uint160(_rawTload(_elementSlot(_arraySlot, 0)))), _value);
    // it should set the _arraySlot length to one
    assertEq(_rawTload(_arraySlot), 1);
  }

  function test_PushWhenTheArrayAlreadyHoldsElements(bytes32 _arraySlot, address _value, uint256 _count) external {
    _count = bound(_count, 1, 10);
    // Seed a populated length directly so the append point depends only on push reading the current length.
    _rawTstore(_arraySlot, _count);

    TransientTracking.push(_arraySlot, _value);

    // it should write _value to the slot derived from _arraySlot at the current length
    assertEq(address(uint160(_rawTload(_elementSlot(_arraySlot, _count)))), _value);
    // it should increment the _arraySlot length
    assertEq(_rawTload(_arraySlot), _count + 1);
  }

  function test_ClearWhenTheArrayHoldsElements(bytes32 _arraySlot, uint256 _count) external {
    _count = bound(_count, 1, type(uint256).max);
    // Seed a populated length directly.
    _rawTstore(_arraySlot, _count);

    TransientTracking.clear(_arraySlot);

    // it should reset the _arraySlot length to zero
    assertEq(_rawTload(_arraySlot), 0);
  }

  function test_UntrackWhenATrackedKeyIsUntracked(bytes32 _namespace, address _key, uint256 _flag) external {
    _flag = bound(_flag, 1, type(uint256).max);
    // The key is currently tracked: seed its dedup flag directly.
    _rawTstore(_mappingSlot(_namespace, _key), _flag);

    TransientTracking.untrack(_namespace, _key);

    // it should clear the dedup flag at the slot derived from _key and _namespace
    assertEq(_rawTload(_mappingSlot(_namespace, _key)), 0);
  }

  function test_LengthWhenTheArraySlotHoldsALength(bytes32 _arraySlot, uint256 _value) external {
    // Seed the length slot directly.
    _rawTstore(_arraySlot, _value);

    // it should return the _arraySlot value as _length
    assertEq(TransientTracking.length(_arraySlot), _value);
  }

  function test_AtWhenSeveralKeysHaveBeenTracked(
    bytes32 _arraySlot,
    address _key0,
    address _key1,
    address _key2
  ) external {
    // Seed three element slots directly, following the documented dynamic-array layout.
    _rawTstore(_arraySlot, 3);
    _rawTstore(_elementSlot(_arraySlot, 0), uint256(uint160(_key0)));
    _rawTstore(_elementSlot(_arraySlot, 1), uint256(uint160(_key1)));
    _rawTstore(_elementSlot(_arraySlot, 2), uint256(uint160(_key2)));

    // it should return the stored _value at each _index
    assertEq(TransientTracking.at(_arraySlot, 0), _key0);
    assertEq(TransientTracking.at(_arraySlot, 1), _key1);
    assertEq(TransientTracking.at(_arraySlot, 2), _key2);
  }

  function test_LoadWhenTheSlotHoldsAValue(bytes32 _slot, uint256 _value) external {
    // Seed the slot directly.
    _rawTstore(_slot, _value);

    // it should return the stored _value at _slot
    assertEq(TransientTracking.load(_slot), _value);
  }

  function test_LoadMappingWhenAValueHasBeenStoredForAKeyUnderANamespace(
    bytes32 _namespace,
    address _key,
    uint256 _value
  ) external {
    // Seed the derived mapping slot directly.
    _rawTstore(_mappingSlot(_namespace, _key), _value);

    // it should return the stored _value for _key under _namespace
    assertEq(TransientTracking.loadMapping(_namespace, _key), _value);
  }

  // --- Raw transient accessors: independent of the library under test ---

  /// @notice Reads a transient slot directly, bypassing the library.
  function _rawTload(bytes32 _slot) internal view returns (uint256 _value) {
    assembly ('memory-safe') {
      _value := tload(_slot)
    }
  }

  /// @notice Writes a transient slot directly, bypassing the library, to seed reader tests.
  function _rawTstore(bytes32 _slot, uint256 _value) internal {
    assembly ('memory-safe') {
      tstore(_slot, _value)
    }
  }

  // --- Slot derivations: independent reimplementation of the documented layout ---

  /// @notice Mapping slot the library derives from `keccak256(key ‖ namespace)`.
  function _mappingSlot(bytes32 _namespace, address _key) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_key, _namespace));
  }

  /// @notice Array element slot the library derives from `keccak256(abi.encode(arraySlot)) + index`.
  function _elementSlot(bytes32 _arraySlot, uint256 _index) internal pure returns (bytes32 _slot) {
    _slot = bytes32(uint256(keccak256(abi.encode(_arraySlot))) + _index);
  }
}
