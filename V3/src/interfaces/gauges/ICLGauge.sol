// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICLGauge
 * @notice Minimal concentrated-liquidity gauge surface consumed by the Metarouter staking and claim commands.
 * @dev Minimal ABI-compatible slice of the Solidity 0.7.6 `ICLGauge` interface maintained in `metadex-slipstream`.
 */
interface ICLGauge {
  /**
   * @notice Claims emissions for selected positions belonging to an account.
   * @param _account Account whose position emissions are claimed.
   * @param _recipient Address receiving the emissions.
   * @param _tokenIds Positions to claim, bounding the gauge's iteration to this caller-selected set.
   */
  function claimEmissions(address _account, address _recipient, uint256[] calldata _tokenIds) external;

  /**
   * @notice First token of the pool the gauge incentivizes.
   * @return _token0 The pool's `token0`.
   */
  function token0() external view returns (address _token0);

  /**
   * @notice Second token of the pool the gauge incentivizes.
   * @return _token1 The pool's `token1`.
   */
  function token1() external view returns (address _token1);
}
