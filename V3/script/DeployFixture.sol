// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICreateX} from 'V3/interfaces/external/ICreateX.sol';

import {Script} from 'forge-std/Script.sol';

import {Constants} from 'V3-script/Constants.sol';
import {CreateXLibrary} from 'V3/libraries/CreateXLibrary.sol';

/**
 * @title DeployFixture
 * @notice Base fixture shared by every deployment unit. Provides the run lifecycle, the CreateX
 *         handle and the deployment verification helpers.
 */
abstract contract DeployFixture is Script, Constants {
  using CreateXLibrary for bytes11;

  /*////////////////////////////////////////////////////////////
                        STATE VARIABLES
  ////////////////////////////////////////////////////////////*/

  /// @notice CreateX contract
  ICreateX internal immutable _CX = ICreateX(CREATEX_ADDRESS);
  address internal _deployer = DEPLOYER;

  /// @dev Used to disable output logging for tests
  bool internal _isTest;

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice error emitted when the input is invalid
  error InvalidInput();

  /// @notice error emitted when the parameters target a different chain than the one deploying to
  error ChainIdMismatch();

  /// @notice error emitted when a deployed address does not match its computed address
  error InvalidAddress(address expected, address output, string contractName);

  /// @notice error emitted when the CreateX deployment on the target chain is not the canonical build
  error InvalidCreateXBytecode();

  /*////////////////////////////////////////////////////////////
                        EXTERNAL AND PUBLIC FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Runs the deployment
  function run() external {
    _verifyCreateX();
    vm.startBroadcast(_deployer);

    _deploy();
    vm.stopBroadcast();

    _logParams();
    _logOutput();
  }

  /// @dev Used by tests to disable output logging
  function setIsTest(bool __isTest) external {
    _isTest = __isTest;
  }

  /// @dev Used by tests to set the deployer address
  function setDeployer(address __deployer) external {
    _deployer = __deployer;
  }

  /// @notice Sets up the deployment parameters
  function setUp() public virtual;

  /*////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Deploys the unit contracts
  function _deploy() internal virtual;

  /// @notice Writes the deployment output file
  function _logOutput() internal virtual;

  /// @notice Logs the deployed addresses
  function _logParams() internal view virtual;

  /*////////////////////////////////////////////////////////////
                        VIEW AND PURE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Verifies the CreateX deployment
  function _verifyCreateX() internal view {
    if (!_isTest && block.chainid != LOCAL_ANVIL_CHAINID && CREATEX_ADDRESS.codehash != bytes32(CREATEX_BYTECODE)) {
      revert InvalidCreateXBytecode();
    }
  }

  /**
   * @notice Verifies if the computed address matches the address produced by the deployment
   * @param _entropy The entropy of the deployment
   * @param _output The output of the deployment
   * @param _contractName The name of the contract
   * @param __deployer The deployer address
   */
  function _verifyAddress(
    bytes11 _entropy,
    address _output,
    string memory _contractName,
    address __deployer
  ) internal pure {
    address _computedAddress = _entropy.computeCreate3Address(__deployer);
    if (_computedAddress != _output) {
      revert InvalidAddress(_computedAddress, _output, _contractName);
    }
  }
}
