// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitPoolOracleLte is TestHelpers {
  MockPool internal pool;

  function setUp() public {
    pool = new MockPool();
  }

  function test_WhenAAndBAreLtOrEqToTime(uint32 _time, uint32 _a, uint32 _b) external view {
    _time = uint32(bound(uint256(_time), 1, type(uint32).max));
    _a = uint32(bound(uint256(_a), 0, _time));
    _b = uint32(bound(uint256(_b), 0, _time));

    /// @dev Both a and b are at or before time, so they compare directly.
    // it should return whether a is less than or equal to b
    assertEq(pool.externalLte(_time, _a, _b), _a <= _b);
  }

  function test_WhenAAndBAreGtTime(uint32 _time, uint32 _a, uint32 _b) external view {
    _time = uint32(bound(uint256(_time), 0, type(uint32).max - 2));
    _a = uint32(bound(uint256(_a), uint256(_time) + 1, type(uint32).max));
    _b = uint32(bound(uint256(_b), uint256(_time) + 1, type(uint32).max));

    /// @dev Both a and b are ahead of time, so the block has wrapped past both and they compare directly.
    // it should return whether a is less than or equal to b
    assertEq(pool.externalLte(_time, _a, _b), _a <= _b);
  }

  function test_WhenAIsLtOrEqToTimeAndBIsGtTime(uint32 _time, uint32 _a, uint32 _b) external view {
    _time = uint32(bound(uint256(_time), 1, type(uint32).max - 1));
    _a = uint32(bound(uint256(_a), 0, _time));
    _b = uint32(bound(uint256(_b), uint256(_time) + 1, type(uint32).max));

    /// @dev The clock has wrapped past b, making b the earlier timestamp.
    // it should return false
    assertFalse(pool.externalLte(_time, _a, _b));
  }

  function test_WhenAIsGtTimeAndBIsLtOrEqToTime(uint32 _time, uint32 _a, uint32 _b) external view {
    _time = uint32(bound(uint256(_time), 1, type(uint32).max - 1));
    _a = uint32(bound(uint256(_a), uint256(_time) + 1, type(uint32).max));
    _b = uint32(bound(uint256(_b), 0, _time));

    /// @dev The clock has wrapped past a, making a the earlier timestamp.
    // it should return true
    assertTrue(pool.externalLte(_time, _a, _b));
  }
}
