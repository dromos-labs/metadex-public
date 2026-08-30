// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/// @notice Named actors used by pool integration tests.
struct Users {
  address payable owner;
  address payable feeManager;
  address payable discountRegistryManager;
  address payable poolTapeManager;
  address payable alice;
  address payable bob;
  address payable charlie;
  address payable factoryAdminManager;
  address payable chainAdminManager;
  address payable factoryAdmin;
  address payable chainAdmin;
  address payable deployer;
  address payable deployer2;
  address payable emergencyCouncil;
}
