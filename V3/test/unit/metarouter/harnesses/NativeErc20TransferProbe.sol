// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Vm} from 'forge-std/Vm.sol';

/// @title NativeErc20TransferProbe
/// @notice Native ERC20 that emulates the entry point of a chain whose native asset is also an ERC20: settling a
///         transfer moves the transferred amount of native value from the sender to the recipient, as the real
///         native ERC20 would, without running the recipient's code.
/// @dev A mocked native ERC20 cannot move native value, so the closure's fallback refund can only be proven as
///      attempted against it. This probe performs the move with `vm.deal` so the whole success path runs. It reports
///      its own decimals, so the router constructor needs no mock to derive the native-to-token scale.
contract NativeErc20TransferProbe {
  /// @notice Forge cheatcode handle used to emulate the native movement of a transfer.
  Vm internal constant _VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  /// @notice Decimals the token reports; the router derives the native-to-token scale from them.
  uint8 internal immutable _DECIMALS;

  /// @notice Native value per raw token unit, applied when converting a transferred amount to native.
  uint256 internal immutable _SCALE;

  /// @notice Wires the reported decimals and derives the native scale from them.
  /// @param _tokenDecimals Decimals the token reports at construction.
  constructor(uint8 _tokenDecimals) {
    _DECIMALS = _tokenDecimals;
    _SCALE = 10 ** (18 - _tokenDecimals);
  }

  /// @notice Decimals the token expresses the eighteen-decimal native asset in.
  /// @return _tokenDecimals Reported token decimals.
  function decimals() external view returns (uint8 _tokenDecimals) {
    return _DECIMALS;
  }

  /// @notice Moves `_amount` raw token units from the caller to `_to`.
  /// @dev Emulates the entry point's side effect: the amount converted through the scale leaves the caller's native
  ///      balance and lands on the recipient's, with no code run on the recipient.
  /// @param _to Recipient of the transfer.
  /// @param _amount Raw token units to transfer.
  /// @return _success Always true; a rejecting token is covered by mocking instead.
  function transfer(address _to, uint256 _amount) external returns (bool _success) {
    uint256 _nativeAmount = _amount * _SCALE;
    _VM.deal(msg.sender, msg.sender.balance - _nativeAmount);
    _VM.deal(_to, _to.balance + _nativeAmount);
    return true;
  }
}
