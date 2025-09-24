// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.19 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TestConstants} from "./utils/TestConstants.sol";
import {Users} from "./utils/TestUsers.sol";

import {Counter, DeployCounter} from "../script/Counter.s.sol";

abstract contract BaseFixture is Test, TestConstants {
    Users public users;

    // Contracts
    DeployCounter public deployCounter;
    Counter public counter;

    function setUp() public virtual {
        createUsers();

        // Always reuse scripts for deployment to have a uniform deployment / testing environment
        deployCounter = new DeployCounter();
        deployCounter.run();

        counter = deployCounter.counter();
    }

    function createUsers() internal {
        users = Users({
            owner: createUser("Owner"),
            feeManager: createUser("FeeManager"),
            alice: createUser("Alice"),
            bob: createUser("Bob"),
            charlie: createUser("Charlie"),
            deployer: createUser("Deployer")
        });
    }

    function createUser(string memory name) internal returns (address payable user) {
        user = payable(makeAddr({name: name}));
        vm.deal({account: user, newBalance: TOKEN_1 * 1_000});
    }
}
