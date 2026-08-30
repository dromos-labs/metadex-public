// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title V2SwapReceiptTokenProbe
 * @notice Tracks balances credited by stateful V2 pool probes.
 */
contract V2SwapReceiptTokenProbe {
  /// @notice Modeled token balances.
  mapping(address _account => uint256 _balance) public balanceOf;

  /**
   * @notice Sets an account's initial modeled balance.
   * @param _account Account whose balance is configured.
   * @param _balance Initial modeled balance.
   */
  function setBalance(address _account, uint256 _balance) external {
    balanceOf[_account] = _balance;
  }

  /**
   * @notice Credits an account when a modeled pool transfers output.
   * @param _account Account receiving the output.
   * @param _amount Amount actually credited.
   */
  function credit(address _account, uint256 _amount) external {
    balanceOf[_account] += _amount;
  }
}

/**
 * @title V2SwapPoolProbe
 * @notice Models the output-token credit caused by one V2 pool swap.
 */
contract V2SwapPoolProbe {
  /// @notice Output token credited by this pool, or zero when its output is another token.
  address internal _outputToken;
  /// @notice Amount this pool actually credits to its swap recipient.
  uint256 internal _creditedAmount;

  /**
   * @notice Configures this pool's output-token behavior.
   * @param _token Output token to credit, or zero to model an unrelated output token.
   * @param _amount Amount actually credited when `swap` executes.
   */
  function configure(address _token, uint256 _amount) external {
    _outputToken = _token;
    _creditedAmount = _amount;
  }

  /**
   * @notice Credits the configured amount to the swap recipient.
   * @param _recipient Address receiving this hop's output.
   */
  function swap(uint256, uint256, address _recipient, bytes calldata) external {
    if (_outputToken != address(0)) {
      V2SwapReceiptTokenProbe(_outputToken).credit(_recipient, _creditedAmount);
    }
  }
}
