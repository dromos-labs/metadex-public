// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

struct Users {
  // owner / general purpose admin
  address payable owner;
  // fee manager
  address payable feeManager;
  // User, used to initiate calls
  address payable alice;
  // User, used as recipient
  address payable bob;
  // User, used as malicious user
  address payable charlie;
  // User, used as referral recipient
  address payable referral;
  // User, used as deployer
  address payable deployer;
}
