// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';

/// @notice Unit tests for the `SingleConverter` constructor: it binds the immutable target token the
///         convert side always outputs to, and rejects the zero address.
contract UnitSingleConverterConstructor is BaseEntrypoints {
  /// @notice A converter must have a target token to convert rewards into.
  function test_WhenTheTargetTokenIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new SingleConverter(IFactoryRegistry(_factoryRegistry), address(0));
  }

  /// @notice A non-zero target is stored as the immutable the convert side reads.
  function test_WhenTheTargetTokenIsValid(address _target) external {
    _assumeFuzzable(_target);
    SingleConverter _converter = new SingleConverter(IFactoryRegistry(_factoryRegistry), _target);

    // it should set the target token immutable
    assertEq(_converter.TARGET_TOKEN(), _target);
  }
}
