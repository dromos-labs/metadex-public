// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.19 <0.9.0;

import {CounterTest} from "../Counter.t.sol";

contract SetNumberConcreteTest is CounterTest {
    function test_WhenSetNumberIsCalled() external {
        // It should set the number to the new number
        // Tests should be written in a way so that they can be easily rewritten as a fuzz test
        // We use underscore prefixes for functions, so variables that will become fuzz inputs
        // should follow this convention
        uint256 _number = 0;
        counter.setNumber({_newNumber: _number});

        assertEq(counter.number(), _number);
    }

    function testGas_SetNumber() external {
        uint256 _number = 0;
        counter.setNumber({_newNumber: _number});

        vm.snapshotGasLastCall("SetNumber");
    }
}
