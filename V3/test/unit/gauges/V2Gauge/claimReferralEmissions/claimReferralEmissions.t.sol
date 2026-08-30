// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';

import {MockLeafVoter} from 'V3-test/mocks/MockLeafVoter.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

/// @notice Unit tests for claiming pull-only referral emissions from a V2 gauge.
contract UnitV2GaugeClaimReferralEmissions is UnitV2Gauge {
  MockLeafVoter internal _mockLeafVoter;

  function setUp() public override {
    _receiptToken = new TestERC20('Receipt Token', 'RCT', 18);
    _mockLeafVoter = new MockLeafVoter(_receiptToken);
    _voter = address(_mockLeafVoter);

    super.setUp();
  }

  /// @notice Verifies an unauthorized caller cannot claim a referral's emissions.
  function test_WhenTheCallerIsNotTheReferralOrAnApprovedOperator(
    address _caller,
    address _referral,
    address _recipient
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_referral);
    _assumeFuzzable(_recipient);
    _caller = _boundNotEq(_caller, _referral);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGauge.NotAuthorized.selector);
    _gauge.claimReferralEmissions(_referral, _recipient);
  }

  /// @notice Verifies an authorized referral cannot claim to the zero address.
  function test_WhenTheRecipientIsTheZeroAddress(address _referral) external {
    _assumeFuzzable(_referral);

    vm.prank(_referral);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.claimReferralEmissions(_referral, address(0));
  }

  /// @notice Verifies an authorized claim returns without minting when the referral has no stored emissions.
  function test_WhenTheReferralHasNoDeferredEmissions(address _referral, address _recipient) external {
    _assumeFuzzable(_referral);
    _assumeFuzzable(_recipient);

    // it should not mint emissions
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    vm.prank(_referral);
    _gauge.claimReferralEmissions(_referral, _recipient);
  }

  /// @notice Verifies a failed referral mint reverts without consuming the stored balance.
  function test_RevertWhen_EmissionMintingReverts(address _referral, address _recipient, uint128 _amount) external {
    _assumeFuzzable(_referral);
    _assumeFuzzable(_recipient);
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _seedDeferredReferralEmissions(_referral, _amount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    _expectMintEmissionsRevert(_recipients, _amounts);

    vm.prank(_referral);
    // it should revert
    vm.expectRevert(bytes(''));
    _gauge.claimReferralEmissions(_referral, _recipient);

    // it should preserve the deferred referral emissions
    assertEq(_gauge.deferredReferralEmissions(_referral), _amount);
  }

  /// @notice Verifies a referral can claim its full stored balance.
  function test_WhenTheCallerIsTheReferral(address _referral, address _recipient, uint128 _amount) external {
    _assumeFuzzable(_referral);
    _assumeFuzzable(_recipient);
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _seedDeferredReferralEmissions(_referral, _amount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(_referral);
    // it should emit the ReferralEmissionsClaimed event
    _expectEmit(address(_gauge));
    emit IGauge.ReferralEmissionsClaimed(_referral, _recipient, _amount);
    _gauge.claimReferralEmissions(_referral, _recipient);

    // it should clear the deferred referral emissions
    assertEq(_gauge.deferredReferralEmissions(_referral), 0);
    // it should mint the full balance to the recipient
    assertEq(_receiptToken.balanceOf(_recipient), _amount);
  }

  /// @notice Verifies an approved operator can claim a referral's full stored balance.
  function test_WhenTheCallerIsAnApprovedOperator(
    address _referral,
    address _operator,
    address _recipient,
    uint128 _amount
  ) external {
    _assumeFuzzable(_referral);
    _assumeFuzzable(_operator);
    _assumeFuzzable(_recipient);
    _operator = _boundNotEq(_operator, _referral);
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _seedApprovedForClaim(_referral, _operator, true);
    _seedDeferredReferralEmissions(_referral, _amount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(_operator);
    // it should emit the ReferralEmissionsClaimed event
    _expectEmit(address(_gauge));
    emit IGauge.ReferralEmissionsClaimed(_referral, _recipient, _amount);
    _gauge.claimReferralEmissions(_referral, _recipient);

    // it should clear the deferred referral emissions
    assertEq(_gauge.deferredReferralEmissions(_referral), 0);
    // it should mint the full balance to the recipient
    assertEq(_receiptToken.balanceOf(_recipient), _amount);
  }

  /// @notice Measures gas for claiming a referral's stored emissions.
  function testGas_claimReferralEmissions() external {
    uint128 _amount = uint128(100 * TOKEN_1);
    _seedDeferredReferralEmissions(users.referral, _amount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(users.referral);
    _gauge.claimReferralEmissions(users.referral, users.bob);
    vm.snapshotGasLastCall('V2Gauge_claimReferralEmissions');
  }
}
