// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TransientTracking} from 'V3/metarouter/TransientTracking.sol';
import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/// @title FundsLibHarness
/// @notice External boundary over the internal `FundsLib` helpers so their reverts surface to `vm.expectRevert`
///         and the harness address acts as the execution address.
/// @dev `FundsLib` resolves the logical sender and tracking through `MetarouterState`, which reads the router's
///      transient slots a caller cannot override. The harness therefore seeds `LOCKER_SLOT` and snapshots the
///      tracked transient array to
///      persistent storage inside the same call as the operation, so assertions read a value that survives the
///      external-call boundary regardless of transient-storage lifetime.
contract FundsLibHarness {
  /// @notice Tokens tracked during the last operation, mirrored from the transient array for later assertions.
  address[] internal _tracked;

  /// @notice Seeds the native ERC20 accounting read by `FundsLib.push` and `FundsLib.resolveSpend`.
  /// @param _nativeBalanceBefore Native balance held before the batch began.
  /// @param _nativeErc20 ERC20 entry point of the chain's native asset.
  /// @param _nativeErc20Scale Native value per raw native ERC20 unit.
  function seedNativeAccounting(
    uint256 _nativeBalanceBefore,
    address _nativeErc20,
    uint256 _nativeErc20Scale
  ) external {
    TransientTracking.store(MetarouterState.NATIVE_BALANCE_BEFORE_SLOT, _nativeBalanceBefore);
    TransientTracking.store(MetarouterState.NATIVE_ERC20_SLOT, uint256(uint160(_nativeErc20)));
    TransientTracking.store(MetarouterState.NATIVE_ERC20_SCALE_SLOT, _nativeErc20Scale);
  }

  /// @notice Moves tokens through `FundsLib.push`; the push path never reads the logical sender.
  /// @param _token ERC20 to transfer.
  /// @param _recipient Address receiving the tokens.
  /// @param _amount Token amount to transfer.
  function push(address _token, address _recipient, uint256 _amount) external {
    FundsLib.push(_token, _recipient, _amount);
    _snapshotTracked();
  }

  /// @notice Pulls tokens through `FundsLib.pull`, seeding the logical sender first.
  /// @param _sender Logical sender seeded into `LOCKER_SLOT`.
  /// @param _token ERC20 to transfer.
  /// @param _amount Token amount to transfer.
  function pull(address _sender, address _token, uint256 _amount) external {
    _seedSender(_sender);
    FundsLib.pull(_token, _amount);
    _snapshotTracked();
  }

  /// @notice Pays a recipient through `FundsLib.pay`, seeding the logical sender first.
  /// @param _sender Logical sender seeded into `LOCKER_SLOT`.
  /// @param _token ERC20 to transfer.
  /// @param _payer Authorized payer: the harness (execution address) or the logical sender.
  /// @param _recipient Address receiving the payment.
  /// @param _amount Token amount to transfer.
  function pay(address _sender, address _token, address _payer, address _recipient, uint256 _amount) external {
    _seedSender(_sender);
    FundsLib.pay(_token, _payer, _recipient, _amount);
    _snapshotTracked();
  }

  /// @notice Funds a command through `FundsLib.fund`, seeding the logical sender first.
  /// @param _sender Logical sender seeded into `LOCKER_SLOT`.
  /// @param _token ERC20 being funded.
  /// @param _spend Selection applied when spending the execution address's balance.
  /// @param _payerIsUser Whether to pull an exact amount from the logical sender instead of the execution balance.
  /// @return _amount Amount available to the command after funding.
  function fund(
    address _sender,
    address _token,
    IMetarouter.BalanceSpend memory _spend,
    bool _payerIsUser
  ) external returns (uint256 _amount) {
    _seedSender(_sender);
    _amount = FundsLib.fund(_token, _spend, _payerIsUser);
    _snapshotTracked();
  }

  /// @notice Resolves a spend against the harness's token balance through `FundsLib.resolveSpend`.
  /// @param _token ERC20 whose balance is being resolved.
  /// @param _spend Balance selection mode and value.
  /// @return _amount Token amount selected by the spend mode.
  function resolveSpend(
    address _token,
    IMetarouter.BalanceSpend memory _spend
  ) external view returns (uint256 _amount) {
    _amount = FundsLib.resolveSpend(_token, _spend);
  }

  /// @notice Tokens tracked during the last `push`/`pull`/`fund` call.
  /// @return _tokens The tracked tokens.
  function trackedTokens() external view returns (address[] memory _tokens) {
    _tokens = _tracked;
  }

  /// @notice Seeds the logical sender into the transient `LOCKER_SLOT` read by `MetarouterState.msgSender`.
  /// @param _sender Logical sender to seed.
  function _seedSender(address _sender) private {
    bytes32 _slot = MetarouterState.LOCKER_SLOT;
    uint256 _value = uint256(uint160(_sender));
    assembly ('memory-safe') {
      tstore(_slot, _value)
    }
  }

  /// @notice Mirrors the transient tracked-token array into persistent storage within the operation's call.
  function _snapshotTracked() private {
    delete _tracked;
    uint256 _length = TransientTracking.length(MetarouterState.ERC20_ARRAY_SLOT);
    for (uint256 _i; _i < _length; ++_i) {
      _tracked.push(TransientTracking.at(MetarouterState.ERC20_ARRAY_SLOT, _i));
    }
  }
}
