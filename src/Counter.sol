// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.19 <0.9.0;

contract Counter {
    uint256 public number;

    function setNumber(uint256 _newNumber) public {
        number = _newNumber;
    }

    function increment() public {
        number++;
    }
}
