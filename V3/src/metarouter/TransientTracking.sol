// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title TransientTracking
 * @notice Transient scalar, array, and mapping-like storage used during execution.
 * @dev All functions are internal, so they inline into the caller and tload/tstore operate
 *      on the calling contract's transient storage. Mapping values use
 *      `keccak256(abi.encode(key, namespace))`; Solidity does not support transient mappings.
 */
library TransientTracking {
  /**
   * @notice Stores a value in a transient slot.
   * @param _slot Transient slot to write.
   * @param _value Value to store.
   */
  function store(bytes32 _slot, uint256 _value) internal {
    assembly {
      tstore(_slot, _value)
    }
  }

  /**
   * @notice Stores a mapping-like transient value for `_key` under `_namespace`.
   * @param _namespace Namespace used to derive the transient mapping slot.
   * @param _key Address key whose value is written.
   * @param _value Value to store for the key.
   */
  function storeMapping(bytes32 _namespace, address _key, uint256 _value) internal {
    assembly {
      mstore(0x00, _key)
      mstore(0x20, _namespace)
      tstore(keccak256(0x00, 0x40), _value)
    }
  }

  /**
   * @notice Adds `_key` to a transient array once per batch.
   * @param _arraySlot Slot storing the transient array length.
   * @param _namespace Namespace holding the transient deduplication flags.
   * @param _key Address to track.
   */
  function track(bytes32 _arraySlot, bytes32 _namespace, address _key) internal {
    if (loadMapping(_namespace, _key) != 0) return;
    storeMapping(_namespace, _key, 1);
    push(_arraySlot, _key);
  }

  /**
   * @notice Appends an address to a transient array.
   * @param _arraySlot Slot storing the transient array length.
   * @param _value Address to append.
   */
  function push(bytes32 _arraySlot, address _value) internal {
    uint256 _length = length(_arraySlot);
    bytes32 _slot = _elementSlot(_arraySlot, _length);
    assembly {
      tstore(_slot, _value)
    }
    store(_arraySlot, _length + 1);
  }

  /**
   * @notice Appends a `uint256` to a transient array.
   * @dev Companion to `push` for full-width values such as NFT token IDs, index-aligned with a paired address array.
   * @param _arraySlot Slot storing the transient array length.
   * @param _value Value to append.
   */
  function pushUint(bytes32 _arraySlot, uint256 _value) internal {
    uint256 _length = length(_arraySlot);
    bytes32 _slot = _elementSlot(_arraySlot, _length);
    assembly {
      tstore(_slot, _value)
    }
    store(_arraySlot, _length + 1);
  }

  /**
   * @notice Resets a transient array for reuse in the same transaction.
   * @dev Element slots are overwritten when reused and need not be cleared individually.
   * @param _arraySlot Slot storing the transient array length.
   */
  function clear(bytes32 _arraySlot) internal {
    store(_arraySlot, 0);
  }

  /**
   * @notice Clears a transient tracked-address flag.
   * @dev Transient storage is transaction-scoped, so flags must be cleared between batches in one transaction.
   * @param _namespace Namespace holding the transient deduplication flag.
   * @param _key Address whose flag is cleared.
   */
  function untrack(bytes32 _namespace, address _key) internal {
    storeMapping(_namespace, _key, 0);
  }

  /**
   * @notice Returns the length of a transient array.
   * @param _arraySlot Slot storing the transient array length.
   * @return _length Number of elements in the array.
   */
  function length(bytes32 _arraySlot) internal view returns (uint256 _length) {
    return load(_arraySlot);
  }

  /**
   * @notice Returns an address from a transient array.
   * @param _arraySlot Slot storing the transient array length.
   * @param _index Element index to read.
   * @return _value Address stored at the index.
   */
  function at(bytes32 _arraySlot, uint256 _index) internal view returns (address _value) {
    bytes32 _slot = _elementSlot(_arraySlot, _index);
    assembly {
      _value := tload(_slot)
    }
  }

  /**
   * @notice Returns a `uint256` from a transient array.
   * @param _arraySlot Slot storing the transient array length.
   * @param _index Element index to read.
   * @return _value Value stored at the index.
   */
  function atUint(bytes32 _arraySlot, uint256 _index) internal view returns (uint256 _value) {
    bytes32 _slot = _elementSlot(_arraySlot, _index);
    assembly {
      _value := tload(_slot)
    }
  }

  /**
   * @notice Loads a value from a transient slot.
   * @param _slot Transient slot to read.
   * @return _value Value stored in the slot.
   */
  function load(bytes32 _slot) internal view returns (uint256 _value) {
    assembly {
      _value := tload(_slot)
    }
  }

  /**
   * @notice Loads the mapping-like transient value for `_key` under `_namespace`.
   * @param _namespace Namespace used to derive the transient mapping slot.
   * @param _key Address key whose value is read.
   * @return _value Value stored for the key.
   */
  function loadMapping(bytes32 _namespace, address _key) internal view returns (uint256 _value) {
    assembly {
      mstore(0x00, _key)
      mstore(0x20, _namespace)
      _value := tload(keccak256(0x00, 0x40))
    }
  }

  /**
   * @notice Derives the slot of an element using Solidity's dynamic-array layout.
   * @param _arraySlot Slot storing the transient array length.
   * @param _index Element index whose slot is derived.
   * @return _slot Transient slot holding the element.
   */
  function _elementSlot(bytes32 _arraySlot, uint256 _index) private pure returns (bytes32 _slot) {
    return bytes32(uint256(keccak256(abi.encode(_arraySlot))) + _index);
  }
}
