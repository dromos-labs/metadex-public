// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {DeployRelayStackFixture} from 'V3-script/DeployRelayStackFixture.s.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

/**
 * @title DeployRelayStack
 * @notice Base deployment parameters for the relay deployment unit
 * @dev Three of the protocol dependencies are deployed by the core unit and the fourth by governance,
 *      so they are filled from that output rather than known here. Zero is rejected by `_deploy`,
 *      which means an accidental run against the placeholders reverts `InvalidInput` instead of
 *      deploying a relay stack bound to nothing. The wrapped native is the canonical Base WETH.
 */
contract DeployRelayStack is DeployRelayStackFixture {
  /// @notice Sets the Base deployment parameters
  function setUp() public override {
    _params = DeploymentParameters({
      chainId: 8453,
      // TODO Replace zero placeholders with operational values before deploying
      votingEscrow: IVotingEscrow(address(0)),
      vpm: IVoterPaymentsModule(address(0)),
      voter: IVoter(address(0)),
      governor: IGovernor(address(0)),
      wrappedNative: 0x4200000000000000000000000000000000000006,
      outputFilename: 'relaystack-base.json'
    });
  }
}
