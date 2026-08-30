// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {console} from 'forge-std/console.sol';

import {CreateXLibrary} from 'V3/libraries/CreateXLibrary.sol';

import {DeployFixture} from 'V3-script/DeployFixture.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MaxiRelay} from 'V3/relay/MaxiRelay.sol';
import {ProtocolRelay} from 'V3/relay/ProtocolRelay.sol';
import {RelayFactory} from 'V3/relay/RelayFactory.sol';
import {RelayToken} from 'V3/relay/RelayToken.sol';
import {RelayTokenVotes} from 'V3/relay/RelayTokenVotes.sol';
import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';

/**
 * @title DeployRelayStackFixture
 * @notice Deployment fixture for the relay unit: the two satellite-token implementations
 *         (RelayTokenVotes, cloned as every Relay's checkpointed PT, and RelayToken, cloned as the
 *         plain YT), one implementation per tier (MaxiRelay, ProtocolRelay) and the RelayFactory that
 *         clones them as deterministic EIP-1167 minimal proxies. Per chain classes in
 *         script/deployParameters set the parameters by overriding setUp.
 * @dev The unit is root only. A Relay pools staking weight into a sAERO it owns, and both the sAERO
 *      and the escrow that custodies it live on root, so there is nothing for this unit to do on a
 *      leaf chain.
 * @dev The four protocol dependencies are parameters rather than deploy steps: they belong to the core
 *      unit (VotingEscrow, Voter, VoterPaymentsModule) and to governance (the Governor), and this unit
 *      runs after them. Callers fill the parameters from that unit's deployment output.
 * @dev No entrypoint is deployed here. Entrypoints are per strategy rather than per protocol, they take
 *      the factory registry instead of these dependencies, and which ones a Relay gets is named when
 *      that Relay is created. They are their own unit.
 * @dev Governance needs no step of its own either: the lane is `RelayGovernanceLib`, a linked library
 *      the tier implementations delegatecall, so the deployer only has to make sure it is linked before
 *      the implementations are built. Every Relay then answers `expressVote` from its first block.
 */
abstract contract DeployRelayStackFixture is DeployFixture {
  using CreateXLibrary for bytes11;

  /*////////////////////////////////////////////////////////////
                        STRUCTS
  ////////////////////////////////////////////////////////////*/

  struct DeploymentParameters {
    uint256 chainId;
    IVotingEscrow votingEscrow;
    IVoterPaymentsModule vpm;
    IVoter voter;
    IGovernor governor;
    address wrappedNative;
    string outputFilename;
  }

  /*////////////////////////////////////////////////////////////
                        STATE VARIABLES
  ////////////////////////////////////////////////////////////*/

  RelayToken public relayTokenImplementation;
  RelayTokenVotes public relayTokenVotesImplementation;
  RelayVoteAdapter public relayVoteAdapter;
  MaxiRelay public maxiRelayImplementation;
  ProtocolRelay public protocolRelayImplementation;
  RelayFactory public relayFactory;

  DeploymentParameters internal _params;

  /*////////////////////////////////////////////////////////////
                        EXTERNAL AND PUBLIC FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev Used by tests to set the deployment parameters
  function setParams(DeploymentParameters memory __params) external {
    _params = __params;
  }

  /// @dev Used by tests to get the deployment parameters
  function params() external view returns (DeploymentParameters memory) {
    return _params;
  }

  /*////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Internal helper function to deploy the relay unit contracts
  function _deploy() internal override {
    if (_params.chainId != block.chainid) revert ChainIdMismatch();
    if (address(_params.votingEscrow) == address(0)) revert InvalidInput();
    if (address(_params.vpm) == address(0)) revert InvalidInput();
    if (address(_params.voter) == address(0)) revert InvalidInput();
    if (address(_params.governor) == address(0)) revert InvalidInput();
    if (_params.wrappedNative == address(0)) revert InvalidInput();

    /// @dev Satellite token implementations, cloned per Relay as its PT and YT ///
    relayTokenImplementation = RelayToken(
      _CX.deployCreate3({
        salt: RELAY_TOKEN_IMPLEMENTATION_ENTROPY.calculateSalt(_deployer), initCode: type(RelayToken).creationCode
      })
    );
    _verifyAddress({
      _entropy: RELAY_TOKEN_IMPLEMENTATION_ENTROPY,
      _output: address(relayTokenImplementation),
      _contractName: 'RelayToken',
      __deployer: _deployer
    });

    relayTokenVotesImplementation = RelayTokenVotes(
      _CX.deployCreate3({
        salt: RELAY_TOKEN_VOTES_IMPLEMENTATION_ENTROPY.calculateSalt(_deployer),
        initCode: type(RelayTokenVotes).creationCode
      })
    );
    _verifyAddress({
      _entropy: RELAY_TOKEN_VOTES_IMPLEMENTATION_ENTROPY,
      _output: address(relayTokenVotesImplementation),
      _contractName: 'RelayTokenVotes',
      __deployer: _deployer
    });

    /// @dev The canonical vote adapter: stateless, one deployment serves every Relay ///
    relayVoteAdapter = RelayVoteAdapter(
      _CX.deployCreate3({
        salt: RELAY_VOTE_ADAPTER_ENTROPY.calculateSalt(_deployer), initCode: type(RelayVoteAdapter).creationCode
      })
    );
    _verifyAddress({
      _entropy: RELAY_VOTE_ADAPTER_ENTROPY,
      _output: address(relayVoteAdapter),
      _contractName: 'RelayVoteAdapter',
      __deployer: _deployer
    });

    /// @dev Tier implementations, carrying the protocol dependencies as immutables ///
    maxiRelayImplementation = MaxiRelay(
      payable(_CX.deployCreate3({
          salt: MAXI_RELAY_IMPLEMENTATION_ENTROPY.calculateSalt(_deployer),
          initCode: abi.encodePacked(
            type(MaxiRelay).creationCode,
            abi.encode(
              _params.votingEscrow,
              _params.voter,
              address(relayTokenVotesImplementation),
              address(relayTokenImplementation),
              _params.wrappedNative
            )
          )
        }))
    );
    _verifyAddress({
      _entropy: MAXI_RELAY_IMPLEMENTATION_ENTROPY,
      _output: address(maxiRelayImplementation),
      _contractName: 'MaxiRelay',
      __deployer: _deployer
    });

    protocolRelayImplementation = ProtocolRelay(
      payable(_CX.deployCreate3({
          salt: PROTOCOL_RELAY_IMPLEMENTATION_ENTROPY.calculateSalt(_deployer),
          initCode: abi.encodePacked(
            type(ProtocolRelay).creationCode,
            abi.encode(
              _params.votingEscrow,
              _params.voter,
              address(relayTokenVotesImplementation),
              address(relayTokenImplementation),
              _params.wrappedNative
            )
          )
        }))
    );
    _verifyAddress({
      _entropy: PROTOCOL_RELAY_IMPLEMENTATION_ENTROPY,
      _output: address(protocolRelayImplementation),
      _contractName: 'ProtocolRelay',
      __deployer: _deployer
    });

    /// @dev The factory that clones the tiers. Creation is gated on RELAY_DEPLOYER_ROLE, read off the
    /// Voter, and that role starts unheld: it has to be granted before the first Relay can be created.
    relayFactory = RelayFactory(
      _CX.deployCreate3({
        salt: RELAY_FACTORY_ENTROPY.calculateSalt(_deployer),
        initCode: abi.encodePacked(
          type(RelayFactory).creationCode,
          abi.encode(
            _params.votingEscrow,
            address(_params.voter),
            address(maxiRelayImplementation),
            address(protocolRelayImplementation),
            _params.vpm,
            _params.governor,
            relayVoteAdapter
          )
        )
      })
    );
    _verifyAddress({
      _entropy: RELAY_FACTORY_ENTROPY,
      _output: address(relayFactory),
      _contractName: 'RelayFactory',
      __deployer: _deployer
    });
  }

  /// @inheritdoc DeployFixture
  function _logOutput() internal override {
    if (_isTest) return;

    string memory _path = string(abi.encodePacked(vm.projectRoot(), '/deployment-addresses/', _params.outputFilename));
    vm.writeJson(vm.serializeAddress('', 'relayTokenImplementation', address(relayTokenImplementation)), _path);
    vm.writeJson(
      vm.serializeAddress('', 'relayTokenVotesImplementation', address(relayTokenVotesImplementation)), _path
    );
    vm.writeJson(vm.serializeAddress('', 'relayVoteAdapter', address(relayVoteAdapter)), _path);
    vm.writeJson(vm.serializeAddress('', 'maxiRelayImplementation', address(maxiRelayImplementation)), _path);
    vm.writeJson(vm.serializeAddress('', 'protocolRelayImplementation', address(protocolRelayImplementation)), _path);
    vm.writeJson(vm.serializeAddress('', 'relayFactory', address(relayFactory)), _path);
  }

  /// @inheritdoc DeployFixture
  function _logParams() internal view override {
    if (_isTest) return;
    console.log('relayTokenImplementation:', address(relayTokenImplementation));
    console.log('relayTokenVotesImplementation:', address(relayTokenVotesImplementation));
    console.log('relayVoteAdapter:', address(relayVoteAdapter));
    console.log('maxiRelayImplementation:', address(maxiRelayImplementation));
    console.log('protocolRelayImplementation:', address(protocolRelayImplementation));
    console.log('relayFactory:', address(relayFactory));
  }
}
