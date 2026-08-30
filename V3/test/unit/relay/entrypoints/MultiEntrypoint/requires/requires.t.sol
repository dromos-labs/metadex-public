// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

/// @notice Unit tests for the `MultiEntrypoint` swap guards (through the harness): `_requireBoundRelay`
///         (the swap must target the bound Relay), `_requireConvertible` (input not excluded and
///         target configured) and `_requireNotExcluded` (input not excluded).
contract UnitMultiEntrypointRequires is BaseMultiEntrypoint {
  /// @dev Branch marker for the bound-relay guard.
  modifier whenRequiringABoundRelay() {
    _;
  }

  /// @notice A swap addressing a different Relay is rejected.
  function test_WhenTheRelayIsNotTheBoundRelay(address _caller, address _other) external whenRequiringABoundRelay {
    _assumeFuzzable(_caller);
    vm.assume(_other != _relayAddr);

    // it should revert with WrongRelay
    vm.expectRevert(IMultiEntrypoint.WrongRelay.selector);
    vm.prank(_caller);
    _multi.requireBoundRelay(_other);
  }

  /// @notice The bound Relay passes the guard.
  function test_WhenTheRelayMatchesTheBoundRelay(address _caller) external whenRequiringABoundRelay {
    _assumeFuzzable(_caller);

    // it should allow the call
    vm.prank(_caller);
    _multi.requireBoundRelay(_relayAddr);
  }

  /// @dev Branch marker for the convertible-pair guard; the instance has one target and one exclusion.
  modifier whenRequiringAConvertiblePair() {
    _;
  }

  /// @notice An excluded input cannot be converted.
  function test_WhenTheConvertInputIsExcluded(address _caller) external whenRequiringAConvertiblePair {
    _assumeFuzzable(_caller);
    MultiEntrypointHarness _instance = _deployMulti(_single(_tokenOut), _single(_tokenIn));

    // it should revert with TokenExcluded
    vm.expectRevert(IMultiEntrypoint.TokenExcluded.selector);
    vm.prank(_caller);
    _instance.requireConvertible(_tokenIn, _tokenOut);
  }

  /// @notice A non-configured convert target is rejected.
  function test_WhenTheTargetIsNotConfigured(
    address _caller,
    address _freshInput,
    address _nonTarget
  ) external whenRequiringAConvertiblePair {
    _assumeFuzzable(_caller);
    vm.assume(_freshInput != _tokenIn && _nonTarget != _tokenOut);
    MultiEntrypointHarness _instance = _deployMulti(_single(_tokenOut), _single(_tokenIn));

    // it should revert with NotTargetToken
    vm.expectRevert(IMultiEntrypoint.NotTargetToken.selector);
    vm.prank(_caller);
    _instance.requireConvertible(_freshInput, _nonTarget);
  }

  /// @notice A non-excluded input into a configured target passes.
  function test_WhenThePairIsConvertible(address _caller, address _freshInput) external whenRequiringAConvertiblePair {
    _assumeFuzzable(_caller);
    vm.assume(_freshInput != _tokenIn);
    MultiEntrypointHarness _instance = _deployMulti(_single(_tokenOut), _single(_tokenIn));

    // it should allow the call
    vm.prank(_caller);
    _instance.requireConvertible(_freshInput, _tokenOut);
  }

  /// @dev Branch marker for the not-excluded guard; the instance has one exclusion.
  modifier whenRequiringANonExcludedInput() {
    _;
  }

  /// @notice An excluded input is rejected for the compound side.
  function test_WhenTheCompoundInputIsExcluded(address _caller) external whenRequiringANonExcludedInput {
    _assumeFuzzable(_caller);
    MultiEntrypointHarness _instance = _deployMulti(_empty(), _single(_tokenIn));

    // it should revert with TokenExcluded
    vm.expectRevert(IMultiEntrypoint.TokenExcluded.selector);
    vm.prank(_caller);
    _instance.requireNotExcluded(_tokenIn);
  }

  /// @notice A non-excluded input passes.
  function test_WhenTheInputIsAllowed(address _caller, address _freshInput) external whenRequiringANonExcludedInput {
    _assumeFuzzable(_caller);
    vm.assume(_freshInput != _tokenIn);
    MultiEntrypointHarness _instance = _deployMulti(_empty(), _single(_tokenIn));

    // it should allow the call
    vm.prank(_caller);
    _instance.requireNotExcluded(_freshInput);
  }
}
