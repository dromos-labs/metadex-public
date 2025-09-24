// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.19 <0.9.0;

import "../../../BaseFixture.sol";

contract CounterTest is BaseFixture {
    function setUp() public override {
        super.setUp();
        // common set up for all counter tests
    }

    // tests default state post set up (i.e. all tests will start with this state)
    function test_CounterTest() external {
        // It should set the number to the new number
        counter.setNumber(0);

        assertEq(counter.number(), 0);
    }
}
