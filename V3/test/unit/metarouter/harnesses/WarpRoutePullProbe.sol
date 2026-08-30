// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Vm} from 'forge-std/Vm.sol';

import {ITokenRouter} from 'V3/interfaces/external/ITokenRouter.sol';

/// @title WarpRoutePullProbe
/// @notice Fee-less warp route that emulates an ERC20-collateral pull of the chain's native ERC20: settling
///         the transfer moves the pulled amount of native value out of the caller, as the native ERC20's `transferFrom`
///         would on a real deployment.
/// @dev The native ERC20 is a mocked contract in unit tests, so its `transferFrom` cannot move native value; the
///      probe emulates that side effect with `vm.deal` instead. Quotes charge exactly the requested amount, so the
///      whole budget is pulled and no token fee is deducted.
contract WarpRoutePullProbe is ITokenRouter {
  /// @notice Forge cheatcode handle used to emulate the native movement of the collateral pull.
  Vm internal constant _VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  /// @notice Native value per raw native ERC20 unit, applied when converting the pulled amount to native.
  uint256 internal immutable _SCALE;

  /// @notice Native ERC20 the probe reports as its managed collateral.
  address internal immutable _TOKEN;

  /// @notice Number of `transferRemote` calls received.
  uint256 public transferRemoteCalls;

  /// @notice Amount of the last `transferRemote` call.
  uint256 public lastAmount;

  /// @notice Message value forwarded with the last `transferRemote` call.
  uint256 public lastValue;

  /// @notice Wires the collateral token and its native scale.
  /// @param _token Native ERC20 the probe manages.
  /// @param _scale Native value per raw native ERC20 unit.
  constructor(address _token, uint256 _scale) {
    _TOKEN = _token;
    _SCALE = _scale;
  }

  /// @inheritdoc ITokenRouter
  function token() external view returns (address _token) {
    return _TOKEN;
  }

  /// @inheritdoc ITokenRouter
  /// @dev Fee-less: the transfer requires exactly the requested amount of the managed token.
  function quoteTransferRemote(uint32, bytes32, uint256 _amount) external view returns (Quote[] memory _quotes) {
    _quotes = new Quote[](1);
    _quotes[0] = Quote({token: _TOKEN, amount: _amount});
  }

  /// @inheritdoc ITokenRouter
  /// @dev Records the call, then emulates the collateral pull: the caller's native balance drops by the pulled
  ///      amount converted through the scale, as the native ERC20's `transferFrom` would move it.
  function transferRemote(uint32, bytes32, uint256 _amount) external payable returns (bytes32 _messageId) {
    ++transferRemoteCalls;
    lastAmount = _amount;
    lastValue = msg.value;
    _VM.deal(msg.sender, msg.sender.balance - _amount * _SCALE);
    return bytes32(0);
  }
}
