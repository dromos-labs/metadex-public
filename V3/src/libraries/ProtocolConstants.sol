// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/// @dev Pips denominator where `1_000_000` is 100%.
uint256 constant MAX_PIPS = 1_000_000;

/// @dev Minimum receipt amount redeemable, one unit in pips, so the Splitter share cannot round to zero.
uint256 constant MIN_REDEEM_AMOUNT = MAX_PIPS;

/// @dev Sink gauge for idle voting power. Allocations to gauges that cannot receive emissions redirect
///      here and accrue as surplus.
address constant ZERO_GAUGE = address(0);

/// @dev Seconds in one weekly epoch.
uint48 constant WEEK = 1 weeks;

/// @dev Maximum staking period in seconds (4 years).
uint48 constant MAXTIME = 4 * 365 days;

/// @dev Lower bound for configured message lifetimes, rejects values that would expire every dispatch in transit.
uint48 constant MIN_MESSAGE_LIFETIME = 2 minutes;

/// @dev Upper bound for configured message lifetimes, keeps every stamped expiry far from uint48 overflow.
uint48 constant MAX_MESSAGE_LIFETIME = 365 days;

/// @dev Fixed point scale of 1e18.
uint256 constant PRECISION = 1e18;

/// @dev Fixed-point scale used by the fee accumulators.
uint256 constant FEE_ACCUMULATOR_PRECISION = 1e24;

/// @dev Sentinel gauge address expressing deallocation intent in a gauge list. Shared so the root
///      `Voter` and every `LeafVoter` agree on the value: root detects it in a bridged gauge list and
///      the leaf turns it into a return-to-root deallocation. Derived from a fixed string so it can
///      never collide with a real gauge.
address constant DEALLOC_GAUGE = address(uint160(uint256(keccak256('DROMOS_DEALLOC_GAUGE'))));
