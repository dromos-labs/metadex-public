// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import {IWETH} from 'V3/interfaces/external/IWETH.sol';

contract MockWETH is ERC20, IWETH {
  constructor() ERC20('Wrapped Ether', 'WETH') {}

  function deposit() external payable override {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external override {
    _burn(msg.sender, amount);
    payable(msg.sender).transfer(amount);
  }

  receive() external payable {
    _mint(msg.sender, msg.value);
  }
}
