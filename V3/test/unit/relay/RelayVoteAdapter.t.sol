// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';

import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';

/// @notice Unit tests for the reference vote adapter against a mocked Governor.
contract UnitRelayVoteAdapter is TestHelpers {
  RelayVoteAdapter internal _adapter;
  address internal _governor;

  function setUp() public {
    _adapter = new RelayVoteAdapter();
    _governor = _mockContract('Governor');
  }

  function test_WhenReadingTheProposalSnapshot(uint256 _proposalId, uint256 _snapshot) external {
    _mockAndExpect(_governor, abi.encodeCall(IGovernor.proposalSnapshot, (_proposalId)), abi.encode(_snapshot));

    // it should forward the governor answer
    assertEq(_adapter.proposalSnapshot(_governor, _proposalId), _snapshot);
  }

  function test_WhenEncodingACast(
    uint256 _proposalId,
    uint256 _tokenId,
    uint128 _against,
    uint128 _for,
    uint128 _abstain
  ) external view {
    bytes memory _callData = _adapter.encodeCast(_proposalId, _tokenId, _against, _for, _abstain, 'why');

    // it should produce the fractional calldata for the governor (support 255, three packed uint128s)
    assertEq(
      _callData,
      abi.encodeCall(
        IGovernor.castVoteWithReasonAndParams,
        (_proposalId, _tokenId, 255, 'why', abi.encodePacked(_against, _for, _abstain))
      )
    );
  }

  function test_WhenAComponentExceedsTheDialectWidth(uint256 _oversized) external {
    _oversized = bound(_oversized, uint256(type(uint128).max) + 1, type(uint256).max);

    // it should revert with UnrepresentableWeight, whichever component overflows
    vm.expectRevert(IRelayVoteAdapter.UnrepresentableWeight.selector);
    _adapter.encodeCast(1, 1, _oversized, 0, 0, '');
    vm.expectRevert(IRelayVoteAdapter.UnrepresentableWeight.selector);
    _adapter.encodeCast(1, 1, 0, _oversized, 0, '');
    vm.expectRevert(IRelayVoteAdapter.UnrepresentableWeight.selector);
    _adapter.encodeCast(1, 1, 0, 0, _oversized, '');
  }
}
