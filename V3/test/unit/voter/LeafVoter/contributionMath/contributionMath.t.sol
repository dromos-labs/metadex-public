// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

contract UnitLeafVoterContributionMath is BaseLeafVoter {
  /// @notice Cached `MAXTIME`, the slope divisor. Allocations below it round to a zero slope.
  uint128 internal _maxtime;

  /*////////////////////////////////////////////////////////////
                          _contribution
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheContributionResolvesAPermanentStake(uint128 _allocated, uint48 _asOf) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));

    // A permanent stake holds at any `lastSettlement`.
    _mockChainSettlement(_asOf);
    (int128 _bias, int128 _slope, int128 _perm) = _leafVoter.contribution(_allocated, 0, true);

    // it should return the allocated amount as the permanent component
    assertEq(_perm, int128(_allocated));
    // it should return a zero bias and slope
    assertEq(_bias, 0);
    assertEq(_slope, 0);
  }

  function test_WhenTheContributionResolvesAWithdrawnStake(uint128 _allocated, uint48 _asOf) external {
    // A withdrawn stake is `{stakeEnd: 0, isPermanent: false}` — the same zero stakeEnd as a permanent stake,
    // but the false flag routes it away from the permanent path, so it contributes nothing instead of phantom
    // permanent weight. This is the distinction the boolean adds over the old `stakeEnd == 0` sentinel.
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _asOf = uint48(bound(_asOf, 1, type(uint48).max));

    _mockChainSettlement(_asOf);
    (int128 _bias, int128 _slope, int128 _perm) = _leafVoter.contribution(_allocated, 0, false);

    // it should return the zero triple
    assertEq(_bias, 0);
    assertEq(_slope, 0);
    assertEq(_perm, 0);
  }

  function test_WhenTheContributionResolvesADecayingStake(
    uint128 _allocated,
    uint48 _tAct,
    uint48 _durationRaw
  ) external {
    _setMaxtime();
    // At or above MAXTIME the slope rounds to a non-zero value.
    _allocated = uint128(bound(_allocated, _maxtime, _MAX_AMOUNT));
    _tAct = uint48(bound(_tAct, 0, type(uint48).max - 100 * _WEEK));
    uint48 _duration = uint48(bound(_durationRaw, 1, 100 * _WEEK));
    uint48 _stakeEnd = _tAct + _duration;

    int128 _expectedSlope = int128(_allocated / _maxtime);
    int128 _expectedBias = _expectedSlope * int128(uint128(_duration));

    _mockChainSettlement(_tAct);
    (int128 _bias, int128 _slope, int128 _perm) = _leafVoter.contribution(_allocated, _stakeEnd, _stakeEnd == 0);

    // it should return the slope as the allocated amount over the max stake time
    assertEq(_slope, _expectedSlope);
    // it should return the bias as the slope scaled by the time until stake end
    assertEq(_bias, _expectedBias);
    assertEq(_perm, 0);
  }

  function test_WhenTheContributionResolvesAStakeAlreadyExpiredAtTheActivationTimestamp(
    uint128 _allocated,
    uint48 _tAct,
    uint48 _stakeEnd
  ) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _tAct = uint48(bound(_tAct, 1, type(uint48).max));
    // A non-zero expiry at or before the activation timestamp has already fired its slope reduction.
    _stakeEnd = uint48(bound(_stakeEnd, 1, _tAct));

    _mockChainSettlement(_tAct);
    (int128 _bias, int128 _slope, int128 _perm) = _leafVoter.contribution(_allocated, _stakeEnd, _stakeEnd == 0);

    // it should return the zero triple
    assertEq(_bias, 0);
    assertEq(_slope, 0);
    assertEq(_perm, 0);
  }

  function test_WhenTheAllocationRoundsDownBelowASingleSlopeUnit(
    uint128 _allocated,
    uint48 _tAct,
    uint48 _durationRaw
  ) external {
    _setMaxtime();
    // Below MAXTIME wei the integer slope divides to zero, so bias follows.
    _allocated = uint128(bound(_allocated, 1, _maxtime - 1));
    _tAct = uint48(bound(_tAct, 0, type(uint48).max - 100 * _WEEK));
    uint48 _duration = uint48(bound(_durationRaw, 1, 100 * _WEEK));
    uint48 _stakeEnd = _tAct + _duration;

    _mockChainSettlement(_tAct);
    (int128 _bias, int128 _slope, int128 _perm) = _leafVoter.contribution(_allocated, _stakeEnd, _stakeEnd == 0);

    // it should return the zero triple
    assertEq(_bias, 0);
    assertEq(_slope, 0);
    assertEq(_perm, 0);
  }

  /*////////////////////////////////////////////////////////////
                        _applyContribution
  ////////////////////////////////////////////////////////////*/

  function test_WhenAPermanentContributionIsAppliedToTheGauge(uint128 _allocated) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));

    (int128 _bias, int128 _slope, int128 _perm) = _leafVoter.applyContribution(_GAUGE_A, _allocated, 0, 0 == 0);

    IVoterCommon.Point memory _p = _point();
    // it should increase the gauge permanent stake balance by the allocated amount
    assertEq(_p.permanentStakeBalance, _allocated);
    assertEq(_perm, int128(_allocated));
    // it should leave the gauge bias and slope unchanged
    assertEq(_p.bias, 0);
    assertEq(_p.slope, 0);
    assertEq(_bias, 0);
    assertEq(_slope, 0);
    // it should not schedule a slope change
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, 0), 0);
  }

  function test_WhenADecayingContributionIsAppliedToTheGauge(uint128 _allocated, uint48 _durationRaw) external {
    _setMaxtime();
    _allocated = uint128(bound(_allocated, _maxtime, _MAX_AMOUNT));

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _duration = uint48(bound(_durationRaw, 1, 100 * _WEEK));
    uint48 _stakeEnd = _settledAt + _duration;

    int128 _expectedSlope = int128(_allocated / _maxtime);
    int128 _expectedBias = _expectedSlope * int128(uint128(_duration));

    (int128 _bias, int128 _slope,) = _leafVoter.applyContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);

    IVoterCommon.Point memory _p = _point();
    // it should increase the gauge bias by the resolved bias
    assertEq(_p.bias, _expectedBias);
    assertEq(_bias, _expectedBias);
    // it should increase the gauge slope by the resolved slope
    assertEq(_p.slope, _expectedSlope);
    assertEq(_slope, _expectedSlope);
    // it should schedule the slope change at the stake end
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), _expectedSlope);
    // it should leave the gauge permanent stake balance unchanged
    assertEq(_p.permanentStakeBalance, 0);
  }

  /*////////////////////////////////////////////////////////////
                       _unwindContribution
  ////////////////////////////////////////////////////////////*/

  function test_WhenAnAppliedPermanentContributionIsUnwound(uint128 _allocated) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));

    _leafVoter.applyContribution(_GAUGE_A, _allocated, 0, 0 == 0);
    _leafVoter.unwindContribution(_GAUGE_A, _allocated, 0, 0 == 0);

    IVoterCommon.Point memory _p = _point();
    // it should net the gauge permanent stake balance back to its prior value
    assertEq(_p.permanentStakeBalance, 0);
    // it should leave the gauge bias and slope unchanged
    assertEq(_p.bias, 0);
    assertEq(_p.slope, 0);
    // it should not schedule a slope change
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, 0), 0);
  }

  function test_WhenAnAppliedDecayingContributionIsUnwoundAtTheSameSettlementTimestamp(
    uint128 _allocated,
    uint48 _durationRaw
  ) external {
    _setMaxtime();
    _allocated = uint128(bound(_allocated, _maxtime, _MAX_AMOUNT));

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _duration = uint48(bound(_durationRaw, 1, 100 * _WEEK));
    uint48 _stakeEnd = _settledAt + _duration;

    // Apply then unwind against the same lastSettlement and stakeEnd.
    _leafVoter.applyContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);
    _leafVoter.unwindContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);

    IVoterCommon.Point memory _p = _point();
    // it should net the gauge bias back to its prior value
    assertEq(_p.bias, 0);
    // it should net the gauge slope back to its prior value
    assertEq(_p.slope, 0);
    // it should net the scheduled slope change back to its prior value
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), 0);
    // it should leave the gauge permanent stake balance unchanged
    assertEq(_p.permanentStakeBalance, 0);
  }

  function test_WhenAnAppliedDecayingContributionIsUnwoundAfterTheSettlementTimestampAdvancedButBeforeTheStakeExpires(
    uint128 _allocated,
    uint48 _durationRaw,
    uint48 _deltaRaw
  ) external {
    _setMaxtime();
    _allocated = uint128(bound(_allocated, _maxtime, _MAX_AMOUNT));

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _duration = uint48(bound(_durationRaw, 2, 100 * _WEEK));
    uint48 _stakeEnd = _settledAt + _duration;

    int128 _slope = int128(_allocated / _maxtime);

    // Apply at the original settlement, then advance it short of the expiry.
    _leafVoter.applyContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);
    uint48 _delta = uint48(bound(_deltaRaw, 1, _duration - 1));
    _mockChainSettlement(_settledAt + _delta);
    _leafVoter.unwindContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);

    IVoterCommon.Point memory _p = _point();
    // it should net the gauge slope back to its prior value
    assertEq(_p.slope, 0);
    // it should net the scheduled slope change back to its prior value
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), 0);
    // it should leave a residual bias equal to the decay since the apply
    assertEq(_p.bias, _slope * int128(uint128(_delta)));
  }

  function test_WhenAnAppliedDecayingContributionIsUnwoundAfterTheStakeHasExpired(
    uint128 _allocated,
    uint48 _durationRaw,
    uint48 _laterRaw
  ) external {
    _setMaxtime();
    _allocated = uint128(bound(_allocated, _maxtime, _MAX_AMOUNT));

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _duration = uint48(bound(_durationRaw, 1, 100 * _WEEK));
    uint48 _stakeEnd = _settledAt + _duration;

    int128 _appliedSlope = int128(_allocated / _maxtime);
    int128 _appliedBias = _appliedSlope * int128(uint128(_duration));

    // Apply while live, then advance the settlement to or past the expiry before unwinding.
    _leafVoter.applyContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);
    uint48 _later = uint48(bound(_laterRaw, _stakeEnd, type(uint48).max));
    _mockChainSettlement(_later);
    _leafVoter.unwindContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);

    IVoterCommon.Point memory _p = _point();
    // it should subtract nothing from the gauge point
    assertEq(_p.bias, _appliedBias);
    assertEq(_p.slope, _appliedSlope);
    // it should leave the scheduled slope change unchanged
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), _appliedSlope);
  }

  /*////////////////////////////////////////////////////////////
                  _applyContribution DUST GATE
  ////////////////////////////////////////////////////////////*/

  function test_WhenAContributionResolvingToTheZeroTripleIsAppliedToTheGauge(
    uint128 _allocated,
    uint48 _durationRaw
  ) external {
    _setMaxtime();
    // A decaying allocation below MAXTIME resolves to the zero triple.
    _allocated = uint128(bound(_allocated, 1, _maxtime - 1));

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _duration = uint48(bound(_durationRaw, 1, 100 * _WEEK));
    uint48 _stakeEnd = _settledAt + _duration;

    (int128 _bias, int128 _slope, int128 _perm) =
      _leafVoter.applyContribution(_GAUGE_A, _allocated, _stakeEnd, _stakeEnd == 0);

    // the caller receives the zero triple
    assertEq(_bias, 0);
    assertEq(_slope, 0);
    assertEq(_perm, 0);

    IVoterCommon.Point memory _p = _point();
    // it should not write the gauge point
    assertEq(_p.bias, 0);
    assertEq(_p.slope, 0);
    assertEq(_p.permanentStakeBalance, 0);
    // it should not schedule a slope change
    assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), 0);
  }

  /*////////////////////////////////////////////////////////////
                            HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setMaxtime() internal {
    _maxtime = uint128(MAXTIME);
  }

  /// @notice The gauge's current decaying point fields.
  function _point() internal view returns (IVoterCommon.Point memory _p) {
    (,,,,,,,, _p) = _leafVoter.gaugeStates(_GAUGE_A);
  }
}
