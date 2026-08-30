// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/// @title ExecutionProbe
/// @notice Deployed fake ERC20 used as a `SWEEP` target so a command observes and reaches back into the router
///         mid-batch.
/// @dev `SWEEP` invokes `transfer` on this address while a batch is active, letting the probe record the logical
///      sender before either reentering `execute` from a foreign caller (to hit the external-reentry lock) or
///      forwarding native ETH to the router (to hit `receive`'s active-batch acceptance).
contract ExecutionProbe {
  /// @notice Router the probe calls back into.
  IMetarouter internal immutable _ROUTER;
  /// @notice When true the probe reenters `execute`; when false it forwards its native balance to the router.
  bool internal immutable _REENTER;

  /// @notice Logical sender observed through the router while the probe callback executes.
  address public observedSender;

  /// @notice Wires the probe to the router and selects its callback behavior.
  /// @param _router Router the probe reaches back into.
  /// @param _reenter Whether `transfer` reenters `execute` (true) or forwards ETH to the router (false).
  constructor(IMetarouter _router, bool _reenter) {
    _ROUTER = _router;
    _REENTER = _reenter;
  }

  /// @notice Accepts native ETH so the probe can hold a balance to forward.
  receive() external payable {}

  /// @notice Reports a fixed non-zero balance so `SWEEP` proceeds to call `transfer`.
  /// @return _balance Always one.
  function balanceOf(address) external pure returns (uint256 _balance) {
    _balance = 1;
  }

  /// @notice Records the router's logical sender, reaches back into the router, then reports success like a real ERC20.
  /// @return _success Always true.
  function transfer(address, uint256) external returns (bool _success) {
    observedSender = _ROUTER.msgSender();
    if (_REENTER) {
      _ROUTER.execute('', new bytes[](0), type(uint256).max);
    } else {
      (bool _sent,) = address(_ROUTER).call{value: address(this).balance}('');
      require(_sent, 'router rejected eth');
    }
    _success = true;
  }
}
