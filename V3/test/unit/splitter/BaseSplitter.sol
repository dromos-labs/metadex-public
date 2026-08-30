// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';
import {Splitter} from 'V3/splitter/Splitter.sol';

abstract contract BaseSplitter is TestHelpers {
  uint256 internal constant _MAX_PIPS = 1_000_000;
  uint256 internal constant _MAX_RECIPIENTS = 50;
  uint256 internal constant _SCALE = 1e18;
  // Largest inflow whose `inflow * SCALE` product still fits in a uint256; the binding overflow ceiling for fuzzing.
  uint256 internal constant _MAX_INFLOW = type(uint256).max / _SCALE;
  // Top bit of an address; OR-ing it onto a hashed seed keeps every derived recipient non-zero and above precompiles.
  uint160 internal constant _ADDRESS_HIGH_BIT = uint160(1) << 159;

  // The `setUp` splitter runs an odd, realistically sized list so claims floor across many recipients at once,
  // pushing the per-recipient dust accumulation in `_settle` to its limit. Fixed because `setUp` cannot be fuzzed.
  uint256 internal constant _RECIPIENT_COUNT = 11;
  uint256 internal constant _SETUP_SEED = 0x5EED;

  // `Splitter` storage slots, seeded with `vm.store` instead of `stdstore` to skip per-fuzz-run slot discovery.
  // Constants and immutables occupy no slots, so the first state variable `globalAccrualIndex` lands in slot zero.
  uint256 internal constant _GLOBAL_ACCRUAL_INDEX_SLOT = 0;
  uint256 internal constant _ACCOUNTED_BALANCE_SLOT = 1;
  uint256 internal constant _RECIPIENT_STATE_SLOT = 3;
  // Field offsets inside a `RecipientState`, three single-slot uint256 fields laid out in declaration order. The
  // first field `sharePips` sits at the struct base slot, so only the later two carry an offset.
  uint256 internal constant _LAST_SETTLED_INDEX_OFFSET = 1;
  uint256 internal constant _CLAIMABLE_OFFSET = 2;

  address internal _token;
  address internal _voter;
  Splitter internal _splitter;

  // The recipient list and aligned shares deployed into `_splitter`, kept so the claim tests act on the live list.
  address[] internal _setupRecipients;
  uint256[] internal _setupShares;

  function setUp() external {
    _token = _mockContract('Token');
    _voter = _mockContract('Voter');
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_SETUP_SEED, _RECIPIENT_COUNT);
    _setupRecipients = _recipients;
    _setupShares = _shares;
    _splitter = new Splitter(_token, _voter, _recipients, _shares);
  }

  // --- Helpers ---

  /// @notice Builds `_length` distinct valid recipients and a PIPS split summing to MAX_PIPS, both derived from `_seed`.
  /// @dev Every recipient floors at one pip so no share is zero; the seed distributes the rest and the last recipient
  ///      absorbs the remainder so the split sums to exactly MAX_PIPS.
  function _fuzzedRecipientsAndShares(
    uint256 _seed,
    uint256 _length
  ) internal pure returns (address[] memory _recipients, uint256[] memory _shares) {
    _recipients = new address[](_length);
    _shares = new uint256[](_length);

    uint256 _remaining = _MAX_PIPS - _length;
    for (uint256 _i; _i < _length; ++_i) {
      // Distinct indices keep the addresses unique; the high bit keeps each above precompiles and non-zero.
      _recipients[_i] = address(uint160(uint256(keccak256(abi.encode(_seed, _i)))) | _ADDRESS_HIGH_BIT);

      uint256 _extra = _remaining;
      if (_i != _length - 1) {
        _extra = uint256(keccak256(abi.encode('share', _seed, _i))) % (_remaining + 1);
        _remaining -= _extra;
      }
      _shares[_i] = 1 + _extra;
    }
  }

  /// @notice Mocks the `Splitter` TOKEN balance and expects it to be read.
  function _mockBalance(uint256 _balance) internal {
    _mockAndExpectTokenBalance(_token, address(_splitter), _balance);
  }

  /// @notice Reads a recipient's last-settlement index from the `recipientState` getter tuple.
  function _lastSettledIndexOf(address _recipient) internal view returns (uint256 _lastIndex) {
    (, _lastIndex,) = _splitter.recipientState(_recipient);
  }

  /// @notice Seeds `globalAccrualIndex` directly in storage.
  function _setGlobalAccrualIndex(uint256 _value) internal {
    vm.store(address(_splitter), bytes32(_GLOBAL_ACCRUAL_INDEX_SLOT), bytes32(_value));
  }

  /// @notice Seeds `accountedBalance` directly in storage.
  function _setAccountedBalance(uint256 _value) internal {
    vm.store(address(_splitter), bytes32(_ACCOUNTED_BALANCE_SLOT), bytes32(_value));
  }

  /// @notice Base storage slot of a recipient's `RecipientState` struct within the `recipientState` mapping.
  function _recipientStateSlot(address _recipient) internal pure returns (uint256 _slot) {
    _slot = uint256(keccak256(abi.encode(_recipient, _RECIPIENT_STATE_SLOT)));
  }

  /// @notice Seeds a recipient's `sharePips` directly in storage.
  function _setSharePips(address _recipient, uint256 _value) internal {
    vm.store(address(_splitter), bytes32(_recipientStateSlot(_recipient)), bytes32(_value));
  }

  /// @notice Seeds a recipient's `lastSettledIndex` directly in storage.
  function _setLastSettledIndex(address _recipient, uint256 _value) internal {
    vm.store(address(_splitter), bytes32(_recipientStateSlot(_recipient) + _LAST_SETTLED_INDEX_OFFSET), bytes32(_value));
  }

  /// @notice Seeds a recipient's `claimable` directly in storage.
  function _setClaimable(address _recipient, uint256 _value) internal {
    vm.store(address(_splitter), bytes32(_recipientStateSlot(_recipient) + _CLAIMABLE_OFFSET), bytes32(_value));
  }
}
