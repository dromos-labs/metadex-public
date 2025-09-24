// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.19 <0.9.0;

import {CounterTest} from "../Counter.t.sol";

contract SetNumberFuzzTest is CounterTest {
    function testFuzz_WhenSetNumberIsCalled(uint256 _number) external {
        // It should set the number to the new number
        // No tree file here
        counter.setNumber({_newNumber: _number});

        assertEq(counter.number(), _number);
    }

    // Functions that are not fuzzed should be kept in the file, but left empty
}
