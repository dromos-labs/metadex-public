// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IPoolFactoryIndexation {
  /*////////////////////////////////////////////////////////////
                              STRUCTS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Tuples created pool with its creation timestamp.
   * @param pool Address of the deployed pool contract.
   * @param creationTimestamp Timestamp when the pool was created, taken from `block.timestamp`.
   */
  struct PoolData {
    address pool;
    uint48 creationTimestamp;
  }

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when end argument to the pagination function
  ///         is less than or equal to the start argument.
  ///         When end < start: we revert instead of substituting
  ///         `end` with the actual length.
  ///         When end == start: we revert instead of returning an empty array.
  error EndLeqStart();

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice POOL-BY-TOKEN index stores created pools in which the `_token` is present.
   * @dev The array is ordered by pool creation time (oldest first).
   * @param _token Address of the token for which the array of pools is obtained.
   * @param _index Position in the pool array.
   * @return _pool Address of the pool at the specified index.
   */
  function poolByTokenIndex(address _token, uint256 _index) external view returns (address _pool);

  /**
   * @notice POOLS index stores all pools that were created.
   * @dev The array is ordered by pool creation time (oldest first).
   * @param _index Position in the array.
   * @return _pool Address of the pool.
   * @return _creationTimestamp Timestamp when the pool was created.
   */
  function poolsIndex(uint256 _index) external view returns (address _pool, uint48 _creationTimestamp);

  /*////////////////////////////////////////////////////////////
                              FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the number of pools, created by the child factory, that include a given `_token`.
   * @param _token Address of the token to obtain an array of pools for.
   * @return _length Total length of POOL-BY-TOKEN index.
   */
  function poolByTokenIndexLength(address _token) external view returns (uint256 _length);

  /**
   * @notice Returns the total number of pools created by the child factory.
   * @return _length Total length of POOLS index.
   */
  function poolsIndexLength() external view returns (uint256 _length);

  /**
   * @notice Returns the number of unique tokens that have ever appeared in pools created by the child factory.
   * @return _length Total length of TOKEN index.
   */
  function tokenIndexLength() external view returns (uint256 _length);

  /**
   * @notice Returns a slice of the pools array from POOL-BY-TOKEN index for a given `_token`.
   * @dev The slice is taken from `_start` (inclusive) to `_end` (exclusive).
   * @param _token Address of the token whose pools array is being queried.
   * @param _start Start index of the slice (inclusive).
   * @param _end End index of the slice (exclusive).
   * @return _poolByTokenIndexPaginated A sliced array of pool addresses in the requested `[_start:_end]` range.
   */
  function poolByTokenIndexPaginated(
    address _token,
    uint256 _start,
    uint256 _end
  ) external view returns (address[] memory _poolByTokenIndexPaginated);

  /**
   * @notice Returns a slice of the POOLS index.
   * @dev The slice is taken from `_start` (inclusive) to `_end` (exclusive).
   * @param _start Start index of the slice (inclusive).
   * @param _end End index of the slice (exclusive).
   * @return _poolsIndexPaginated A sliced array of `PoolData` structs in the requested `[_start:_end]` range.
   */
  function poolsIndexPaginated(
    uint256 _start,
    uint256 _end
  ) external view returns (PoolData[] memory _poolsIndexPaginated);

  /**
   * @notice Returns a slice of the TOKEN index.
   * @dev The slice is taken from `_start` (inclusive) to `_end` (exclusive).
   * @param _start Start index of the slice (inclusive).
   * @param _end End index of the slice (exclusive).
   * @return _tokenIndexPaginated A sliced array of token addresses in the requested `[_start:_end]` range.
   */
  function tokenIndexPaginated(
    uint256 _start,
    uint256 _end
  ) external view returns (address[] memory _tokenIndexPaginated);
}
