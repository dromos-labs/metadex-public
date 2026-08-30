// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {MAX_MESSAGE_LIFETIME, MIN_MESSAGE_LIFETIME} from 'V3/libraries/ProtocolConstants.sol';

import {BaseVoter, IVoter, IVoterCommon, IVotingEscrow, Roles, Voter} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoter is BaseVoter {
  using stdStorage for StdStorage;

  /// @dev Mirrors the system-wide Minter cap whose derivation is pinned independently in UnitMinter.
  uint256 internal constant _MAX_SAFE_BASE_RATE = 730_750_818_665_456_651_398_700_951_213;

  /// @notice Fuzzed seed for the `clearToken` weight-preservation test. Packed into a struct so the test body
  ///         stays inside the stack limit.
  /// @param bias Base bias seeded on every chain point (each chain gets a distinct offset on top).
  /// @param slope Base slope seeded on every chain point.
  /// @param ts Base timestamp seeded on every chain point.
  /// @param perm Base permanent stake balance seeded on every chain point.
  /// @param emissionsPerVP Global sampled emissions per voting power.
  /// @param index Global emissions accumulator.
  /// @param booked Per-chain amount booked in the token's ledger.
  struct ClearTokenWeightSeed {
    uint128 bias;
    uint128 slope;
    uint48 ts;
    uint128 perm;
    uint256 emissionsPerVP;
    uint256 index;
    uint128 booked;
  }

  /*////////////////////////////////////////////////////////////
             CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/
  function test_ConstructorWhenTheMessageOrchestratorIsZero(
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin
  ) external {
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: address(0),
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  function test_ConstructorWhenTheVotingEscrowIsZero(
    address _orchestrator,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: address(0),
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  function test_ConstructorWhenTheMinterIsZero(
    address _orchestrator,
    address _votingEscrow,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: address(0),
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  function test_ConstructorWhenTheTokenIsZero(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _adapterAuthority,
    address _governor,
    address _configAdmin
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: address(0),
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  function test_ConstructorWhenTheAdapterAuthorityIsZero(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _governor,
    address _configAdmin
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: address(0),
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  function test_ConstructorWhenTheGovernorIsZero(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _configAdmin
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _configAdmin = _excludingAddressZero(_configAdmin);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: address(0),
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  function test_ConstructorWhenTheConfigAdminIsZero(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: address(0),
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  /// @notice Deploying with an allocation lifetime below the minimum lifetime must revert.
  function test_ConstructorWhenTheAllocationLifetimeIsBelowTheMinimumLifetime(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin,
    uint48 _allocationLifetime
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _allocationLifetime = uint48(bound(_allocationLifetime, 0, MIN_MESSAGE_LIFETIME - 1));

    // it should revert with AllocationLifetimeTooLow
    vm.expectRevert(IVoter.AllocationLifetimeTooLow.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _allocationLifetime,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  /// @notice Deploying with an allocation lifetime above the maximum lifetime must revert.
  function test_ConstructorWhenTheAllocationLifetimeIsAboveTheMaximumLifetime(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin,
    uint48 _allocationLifetime
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _allocationLifetime = uint48(bound(_allocationLifetime, MAX_MESSAGE_LIFETIME + 1, type(uint48).max));

    // it should revert with AllocationLifetimeTooHigh
    vm.expectRevert(IVoter.AllocationLifetimeTooHigh.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _allocationLifetime,
      _messageLifetime: _MESSAGE_LIFETIME
    });
  }

  /// @notice Deploying with a message lifetime below the minimum lifetime must revert.
  function test_ConstructorWhenTheMessageLifetimeIsBelowTheMinimumLifetime(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin,
    uint48 _messageLifetime
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _messageLifetime = uint48(bound(_messageLifetime, 0, MIN_MESSAGE_LIFETIME - 1));

    // it should revert with MessageLifetimeTooLow
    vm.expectRevert(IVoter.MessageLifetimeTooLow.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _messageLifetime
    });
  }

  /// @notice Deploying with a message lifetime above the maximum lifetime must revert.
  function test_ConstructorWhenTheMessageLifetimeIsAboveTheMaximumLifetime(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin,
    uint48 _messageLifetime
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _messageLifetime = uint48(bound(_messageLifetime, MAX_MESSAGE_LIFETIME + 1, type(uint48).max));

    // it should revert with MessageLifetimeTooHigh
    vm.expectRevert(IVoter.MessageLifetimeTooHigh.selector);
    new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _messageLifetime
    });
  }

  function test_ConstructorWhenTheMinterHasNoCodeYet() external {
    // Deployment-order regression. Minter and Voter reference each other, so one of them must be
    // deployed against a predicted counterpart address. The Voter constructor must therefore never
    // call the minter.
    address _predictedMinter = makeAddr('PredictedMinter');
    assertEq(_predictedMinter.code.length, 0);

    Voter _newVoter = new Voter({
      _orchestrator: makeAddr('Orchestrator'),
      _votingEscrow: makeAddr('VotingEscrow'),
      _minter: _predictedMinter,
      _token: _TOKEN,
      _adapterAuthority: makeAddr('AdapterAuthority'),
      _governor: makeAddr('Governor'),
      _configAdmin: makeAddr('ConfigAdmin'),
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });

    // it should deploy without calling the minter
    // it should set the MINTER immutable to the predicted address
    assertEq(address(_newVoter.MINTER()), _predictedMinter);
    // it should set the TOKEN immutable to the token
    assertEq(address(_newVoter.TOKEN()), _TOKEN);
  }

  function test_ConstructorWhenEveryAddressInputIsNonZero(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin,
    uint48 _deployTs
  ) external {
    _orchestrator = _excludingAddressZero(_orchestrator);
    _votingEscrow = _excludingAddressZero(_votingEscrow);
    _minter = _excludingAddressZero(_minter);
    _token = _excludingAddressZero(_token);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);

    vm.warp(_deployTs);

    Voter _newVoter = new Voter({
      _orchestrator: _orchestrator,
      _votingEscrow: _votingEscrow,
      _minter: _minter,
      _token: _token,
      _adapterAuthority: _adapterAuthority,
      _governor: _governor,
      _configAdmin: _configAdmin,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });

    // it should set the ORCHESTRATOR immutable
    assertEq(address(_newVoter.ORCHESTRATOR()), _orchestrator);
    // it should set the VOTING_ESCROW immutable
    assertEq(address(_newVoter.VOTING_ESCROW()), _votingEscrow);
    // it should set the MINTER immutable
    assertEq(address(_newVoter.MINTER()), _minter);
    // it should set the TOKEN immutable to the token
    assertEq(address(_newVoter.TOKEN()), _token);
    // it should set allocationLifetime to the constructor value
    assertEq(_newVoter.allocationLifetime(), _ALLOCATION_LIFETIME);
    // it should set messageLifetime to the constructor value
    assertEq(_newVoter.messageLifetime(), _MESSAGE_LIFETIME);
    // it should grant the adapter config role to the adapter authority
    assertTrue(_newVoter.hasRole(Roles.ADAPTER_CONFIG_ROLE, _adapterAuthority));
    // it should grant the governance role to the governor
    assertTrue(_newVoter.hasRole(Roles.GOVERNANCE_ROLE, _governor));
    // it should grant the config admin role to the config admin
    assertTrue(_newVoter.hasRole(Roles.CONFIG_ADMIN_ROLE, _configAdmin));
    // it should grant the native withdrawer role to the governor
    // The Voter no longer holds native itself; the role stays here because `RootMessageOrchestrator`
    // gates its own `withdrawNative` on `VOTER.hasRole(NATIVE_WITHDRAWER_ROLE, caller)`.
    assertTrue(_newVoter.hasRole(Roles.NATIVE_WITHDRAWER_ROLE, _governor));
    // it should grant the splitter config role to the governor
    assertTrue(_newVoter.hasRole(Roles.SPLITTER_CONFIG_ROLE, _governor));
    // it should make the governance role its own admin
    assertEq(_newVoter.getRoleAdmin(Roles.GOVERNANCE_ROLE), Roles.GOVERNANCE_ROLE);
    // it should make the governance role admin of the config admin role
    assertEq(_newVoter.getRoleAdmin(Roles.CONFIG_ADMIN_ROLE), Roles.GOVERNANCE_ROLE);
    // it should make the governance role admin of the splitter config role
    // Directing team-share emissions is treasury authority, so its admin sits above the operational tier.
    assertEq(_newVoter.getRoleAdmin(Roles.SPLITTER_CONFIG_ROLE), Roles.GOVERNANCE_ROLE);
    // it should make the config admin role admin of every operational role
    {
      bytes32 _configAdminRole = Roles.CONFIG_ADMIN_ROLE;
      assertEq(_newVoter.getRoleAdmin(Roles.VOTER_CONFIG_ROLE), _configAdminRole);
      assertEq(_newVoter.getRoleAdmin(Roles.CHAIN_CONFIG_ROLE), _configAdminRole);
      assertEq(_newVoter.getRoleAdmin(Roles.CHAIN_STATUS_ROLE), _configAdminRole);
      assertEq(_newVoter.getRoleAdmin(Roles.ADAPTER_CONFIG_ROLE), _configAdminRole);
      assertEq(_newVoter.getRoleAdmin(Roles.NATIVE_WITHDRAWER_ROLE), _configAdminRole);
      // The RelayFactory reads this one to gate creation. Wiring it matters more than the others:
      // an unwired role falls to the unheld DEFAULT_ADMIN_ROLE, which would leave it ungrantable
      // forever and the factory unable to create a single Relay.
      assertEq(_newVoter.getRoleAdmin(Roles.RELAY_DEPLOYER_ROLE), _configAdminRole);
      // Same reasoning for the registry admin. The LeafVoter wires it and the root one did not, so a
      // FactoryRegistry standing on root could never have had a router registered on it, which is
      // what the relay entrypoints read to decide whether a swap router is usable.
      assertEq(_newVoter.getRoleAdmin(Roles.FACTORY_REGISTRY_ADMIN_ROLE), _configAdminRole);
    }

    // it should leave the relay deployer role unheld, for the config admin to grant post deploy
    assertFalse(_newVoter.hasRole(Roles.RELAY_DEPLOYER_ROLE, _governor));
    assertFalse(_newVoter.hasRole(Roles.RELAY_DEPLOYER_ROLE, _configAdmin));
    assertEq(_newVoter.getRoleMemberCount(Roles.RELAY_DEPLOYER_ROLE), 0);

    uint256 _chain0 = _newVoter.CHAIN0();

    // it should seed totalPoint timestamp to the deployment timestamp
    _assertTotalPoint({_target: _newVoter, _bias: 0, _slope: 0, _ts: _deployTs, _perm: 0});

    // it should seed the chain zero point timestamp to the deployment timestamp
    _assertChainPoint({_target: _newVoter, _chainId: _chain0, _bias: 0, _slope: 0, _ts: _deployTs, _perm: 0});

    // it should seed the global last settlement to the deployment timestamp
    assertEq(_newVoter.lastGlobalSettlement(), _deployTs);

    // it should anchor the chain zero ceiling cursor at the initial index
    // The global accumulator starts at zero, and CHAIN0's cursor defaults to the same value, so the
    // first settle finds a zero delta and accrues nothing.
    assertEq(_newVoter.index(), 0);
    assertEq(_chainState(_newVoter, _chain0).lastIndex, 0);

    // it should set the chain zero status to Active
    assertEq(uint8(_chainState(_newVoter, _chain0).status), uint8(IVoterCommon.ChainStatus.Active));
  }

  /*////////////////////////////////////////////////////////////
          GOVERNANCE ROLE ROTATION
  ////////////////////////////////////////////////////////////*/
  function test_GovernanceRoleRotationWhenTheGovernorGrantsASuccessorAndRenounces(address _successor) external {
    _assumeFuzzable(_successor);
    _successor = _boundNotEq(_successor, _GOVERNOR);

    bytes32 _role = Roles.GOVERNANCE_ROLE;
    vm.prank(_GOVERNOR);
    _voter.grantRole(_role, _successor);

    vm.prank(_GOVERNOR);
    _voter.renounceRole(_role, _GOVERNOR);

    // it should grant the role to the successor
    assertTrue(_voter.hasRole(_role, _successor));
    // it should remove the role from the prior governor
    assertFalse(_voter.hasRole(_role, _GOVERNOR));
    // it should leave exactly one holder
    assertEq(_voter.getRoleMemberCount(_role), 1);
  }

  /*////////////////////////////////////////////////////////////
          CONFIG ADMIN ROLE ROTATION
  ////////////////////////////////////////////////////////////*/
  function test_ConfigAdminRoleRotationWhenTheGovernorGrantsANewAdminAndThePriorAdminRenounces(address _newAdmin)
    external
  {
    _assumeFuzzable(_newAdmin);
    _newAdmin = _boundNotEq(_newAdmin, _CONFIG_ADMIN);

    bytes32 _role = Roles.CONFIG_ADMIN_ROLE;
    vm.prank(_GOVERNOR);
    _voter.grantRole(_role, _newAdmin);

    vm.prank(_CONFIG_ADMIN);
    _voter.renounceRole(_role, _CONFIG_ADMIN);

    // it should grant the role to the new admin
    assertTrue(_voter.hasRole(_role, _newAdmin));
    // it should remove the role from the prior admin
    assertFalse(_voter.hasRole(_role, _CONFIG_ADMIN));
    // it should leave exactly one holder
    assertEq(_voter.getRoleMemberCount(_role), 1);
  }

  /*////////////////////////////////////////////////////////////
               SET ALLOCATION LIFETIME
  ////////////////////////////////////////////////////////////*/
  function test_SetAllocationLifetimeWhenTheCallerDoesNotHoldTheVoterConfigRole(
    address _caller,
    uint48 _allocationLifetime
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _VOTER_CONFIG);

    bytes32 _role = Roles.VOTER_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _voter.setAllocationLifetime(_allocationLifetime);
  }

  /// @notice Setting an allocation lifetime below the minimum lifetime must revert.
  function test_SetAllocationLifetimeWhenTheAllocationLifetimeIsBelowTheMinimumLifetime(uint48 _allocationLifetime)
    external
  {
    _allocationLifetime = uint48(bound(_allocationLifetime, 0, MIN_MESSAGE_LIFETIME - 1));

    // it should revert with AllocationLifetimeTooLow
    vm.expectRevert(IVoter.AllocationLifetimeTooLow.selector);
    vm.prank(_VOTER_CONFIG);
    _voter.setAllocationLifetime(_allocationLifetime);
  }

  /// @notice Setting an allocation lifetime above the maximum lifetime must revert.
  function test_SetAllocationLifetimeWhenTheAllocationLifetimeIsAboveTheMaximumLifetime(uint48 _allocationLifetime)
    external
  {
    _allocationLifetime = uint48(bound(_allocationLifetime, MAX_MESSAGE_LIFETIME + 1, type(uint48).max));

    // it should revert with AllocationLifetimeTooHigh
    vm.expectRevert(IVoter.AllocationLifetimeTooHigh.selector);
    vm.prank(_VOTER_CONFIG);
    _voter.setAllocationLifetime(_allocationLifetime);
  }

  function test_SetAllocationLifetimeWhenTheCallerHoldsTheVoterConfigRole(uint48 _allocationLifetime) external {
    _allocationLifetime = uint48(bound(_allocationLifetime, MIN_MESSAGE_LIFETIME, MAX_MESSAGE_LIFETIME));
    // it should emit the AllocationLifetimeSet event
    _expectEmit(address(_voter));
    emit IVoter.AllocationLifetimeSet(_allocationLifetime);

    vm.prank(_VOTER_CONFIG);
    _voter.setAllocationLifetime(_allocationLifetime);

    // it should update the stored allocationLifetime
    assertEq(_voter.allocationLifetime(), _allocationLifetime);
  }

  /*////////////////////////////////////////////////////////////
               SET MESSAGE LIFETIME
  ////////////////////////////////////////////////////////////*/
  function test_SetMessageLifetimeWhenTheCallerDoesNotHoldTheVoterConfigRole(
    address _caller,
    uint48 _messageLifetime
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _VOTER_CONFIG);

    bytes32 _role = Roles.VOTER_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _voter.setMessageLifetime(_messageLifetime);
  }

  /// @notice Setting a message lifetime below the minimum lifetime must revert.
  function test_SetMessageLifetimeWhenTheMessageLifetimeIsBelowTheMinimumLifetime(uint48 _messageLifetime) external {
    _messageLifetime = uint48(bound(_messageLifetime, 0, MIN_MESSAGE_LIFETIME - 1));

    // it should revert with MessageLifetimeTooLow
    vm.expectRevert(IVoter.MessageLifetimeTooLow.selector);
    vm.prank(_VOTER_CONFIG);
    _voter.setMessageLifetime(_messageLifetime);
  }

  /// @notice Setting a message lifetime above the maximum lifetime must revert.
  function test_SetMessageLifetimeWhenTheMessageLifetimeIsAboveTheMaximumLifetime(uint48 _messageLifetime) external {
    _messageLifetime = uint48(bound(_messageLifetime, MAX_MESSAGE_LIFETIME + 1, type(uint48).max));

    // it should revert with MessageLifetimeTooHigh
    vm.expectRevert(IVoter.MessageLifetimeTooHigh.selector);
    vm.prank(_VOTER_CONFIG);
    _voter.setMessageLifetime(_messageLifetime);
  }

  function test_SetMessageLifetimeWhenTheCallerHoldsTheVoterConfigRole(uint48 _messageLifetime) external {
    _messageLifetime = uint48(bound(_messageLifetime, MIN_MESSAGE_LIFETIME, MAX_MESSAGE_LIFETIME));
    // it should emit the MessageLifetimeSet event
    _expectEmit(address(_voter));
    emit IVoter.MessageLifetimeSet(_messageLifetime);

    vm.prank(_VOTER_CONFIG);
    _voter.setMessageLifetime(_messageLifetime);

    // it should update the stored messageLifetime
    assertEq(_voter.messageLifetime(), _messageLifetime);
  }

  /*////////////////////////////////////////////////////////////
                        PARK ON CHAIN0
  ////////////////////////////////////////////////////////////*/
  function test_ParkOnChain0WhenTheCallerIsNotTheVotingEscrow(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTING_ESCROW);

    // it should revert with NotVotingEscrow
    vm.prank(_caller);
    vm.expectRevert(IVoter.NotVotingEscrow.selector);
    _voter.parkOnChain0(_TOKEN_ID);
  }

  function test_ParkOnChain0WhenTheLiveStakeIsExpired() external {
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    vm.warp(_ts);
    // Non-permanent stake whose end is at now: expired, no live weight to book.
    _mockStaked({_amount: _ONE_AERO, _end: _ts, _isPermanent: false});

    // it should revert with StakeExpired
    vm.prank(_VOTING_ESCROW);
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.parkOnChain0(_TOKEN_ID);
  }

  function test_ParkOnChain0WhenTheStakeWasWithdrawn(uint128 _committed) external {
    // A withdrawn token reads back VE's cleared stake `{amount: 0, end: 0, isPermanent: false}`. Seed a
    // non-zero committed so the fully-booked check (`staked <= committed`) would also trip: the live-stake
    // guard runs FIRST, so the revert must be StakeExpired, not NothingToPark.
    _committed = uint128(bound(_committed, 1, _INT128_MAX_HALF));
    _mockStaked({_amount: 0, _end: 0, _isPermanent: false});
    // Model the withdrawn shape faithfully: end 0 but NOT permanent (the explicit flag, not the derived one).
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: 0, _lastAllocated: 0, _isPermanent: false
    });

    // it should revert with StakeExpired
    vm.prank(_VOTING_ESCROW);
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.parkOnChain0(_TOKEN_ID);
  }

  function test_ParkOnChain0WhenTheCommittedAmountExceedsTheStakedAmount(uint128 _staked, uint128 _committed) external {
    // `committed > staked` should not exist. It saturates instead of reverting: the VotingEscrow drives this from
    // its deposit path, so a ledger above the live stake must not lock the owner out of depositing or reshaping.
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF - 1));
    _committed = uint128(bound(_committed, _staked + 1, _INT128_MAX_HALF));
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    vm.warp(_ts);
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts});

    // it should emit ParkedOnChain0 with a zero amount
    _expectEmit(address(_voter));
    emit IVoter.ParkedOnChain0(_TOKEN_ID, 0);

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should park nothing
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    // it should leave committed untouched
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts
    });
  }

  function test_ParkOnChain0WhenTheStakedAmountEqualsTheCommittedAmount(uint128 _staked) external {
    // Fully-booked token whose lock was extended: zero to park, but the call must still re-anchor the
    // stored shape to the live stake end (the zero-delta sync path).
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _oldStakeEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    uint48 _newStakeEnd = _oldStakeEnd + 1 weeks;
    vm.warp(_ts);
    _mockStaked({_amount: _staked, _end: _newStakeEnd, _isPermanent: false});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _staked, _lastStakeEnd: _oldStakeEnd, _lastAllocated: _ts});
    // The committed VP sits parked on CHAIN0, so the token holds a tracked allocation entry — the state
    // a real fully-booked token is in, and what arms the shape re-anchor.
    uint256[] memory _chainIds = new uint256[](1);
    _chainIds[0] = _CHAIN0;
    _mockExistingChainIds(_TOKEN_ID, _chainIds);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _staked);

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should park nothing
    (uint128 _committedAfter, uint48 _lastStakeEndAfter,,) = _voter.tokenStates(_TOKEN_ID);
    assertEq(_committedAfter, _staked);
    // it should re-anchor a stale shape to the live stake end
    assertEq(_lastStakeEndAfter, _newStakeEnd);
  }

  function test_ParkOnChain0WhenTheTokenHasUnbookedVotingPower(uint128 _staked) external {
    // Floor at `_MAXTIME` so the parked slope is non-zero and the exact scalar assertion below holds.
    _staked = uint128(bound(_staked, _MAXTIME, _INT128_MAX_HALF));
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    vm.warp(_ts);
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});

    // it should emit ParkedOnChain0 with the parked amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.ParkedOnChain0(_TOKEN_ID, _staked);

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should book the parked amount on chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _staked);

    // it should increase the token committed by the parked amount
    // it should seed the token shape on a first booking
    (uint128 _committed, uint48 _lastStakeEnd,,) = _voter.tokenStates(_TOKEN_ID);
    assertEq(_committed, _staked);
    assertEq(_lastStakeEnd, _stakeEnd);

    // it should resample the global emissions per VP
    // emissionsPerVP is the GLOBAL scalar mulDiv(MINTER_RATE, PRECISION, totalWeight). CHAIN0 carries
    // the only weight, so totalWeight == its booked bias (slopeOf(_staked) * (_stakeEnd - _ts)).
    int128 _parkSlope = _slopeOf(_staked);
    uint128 _parkTotalWeight = uint128(_parkSlope * int128(uint128(_stakeEnd - _ts)));
    assertEq(_voter.emissionsPerVP(), Math.mulDiv(_MINTER_RATE, _PRECISION, _parkTotalWeight));
  }

  function test_ParkOnChain0WhenTheTokenAlreadyHoldsAChainZeroBookingWithAMatchingShape(
    uint128 _priorChain0,
    uint128 _extra
  ) external {
    // Prior CHAIN0 booking plus a second park at the same shape; the remaining unbooked VP (`_extra`)
    // is booked on top of the existing CHAIN0 position.
    _priorChain0 = uint128(bound(_priorChain0, _MAXTIME, _INT128_MAX_HALF / 2));
    _extra = uint128(bound(_extra, 1, _INT128_MAX_HALF / 2));
    uint128 _staked = _priorChain0 + _extra;
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    vm.warp(_ts);

    // Seed the prior CHAIN0 position at the live shape so the park is a pure additive booking.
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _priorChain0, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts});
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _priorChain0);
    int128 _slope = _slopeOf(_priorChain0);
    int128 _delta = int128(uint128(_stakeEnd - _ts));
    _mockChainPoint({_chainId: _CHAIN0, _bias: _slope * _delta, _slope: _slope, _ts: _ts, _perm: 0});
    _mockTotalPoint({_bias: _slope * _delta, _slope: _slope, _ts: _ts, _perm: 0});
    // Anchor CHAIN0's ceiling cursor at the live global index so the park settles a zero delta.
    _mockChainLastIndex(_CHAIN0, _voter.index());
    uint256[] memory _prior = new uint256[](1);
    _prior[0] = _CHAIN0;
    _mockExistingChainIds(_TOKEN_ID, _prior);

    // Unbooked is `staked - committed = _extra` (the prior `_priorChain0` is already committed on
    // CHAIN0), so parking books exactly `_extra` more onto the existing booking.
    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should add all remaining unbooked voting power onto the existing chain zero booking
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _priorChain0 + _extra);
    (uint128 _committed,,,) = _voter.tokenStates(_TOKEN_ID);
    assertEq(_committed, _priorChain0 + _extra);
  }

  function test_ParkOnChain0WhenTheTokenHoldsAllocationsWithAStaleShape(uint128 _priorX, uint128 _extra) external {
    // The token books `_priorX` on a real chain anchored at an old shape; the live stake has since
    // moved to a longer stakeEnd. Parking `_extra` re-anchors the whole position to the live shape
    // (dispatch-free) and books the park there, instead of reverting `DstShapeStale`.
    _priorX = uint128(bound(_priorX, _MAXTIME, _INT128_MAX_HALF / 2));
    _extra = uint128(bound(_extra, _MAXTIME, _INT128_MAX_HALF / 2));
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _liveStakeEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    uint48 _stableStakeEnd = _liveStakeEnd - 1 weeks; // stored shape lags the live stake
    uint48 _priorAllocated = _ts - 1 days; // distinct from block.timestamp so the preservation check bites
    vm.warp(_ts);

    int128 _slopeX = _slopeOf(_priorX);
    int128 _slope0 = _slopeOf(_extra);
    int128 _dOld = int128(uint128(_stableStakeEnd - _ts));
    int128 _dNew = int128(uint128(_liveStakeEnd - _ts));

    // Prior: `_priorX` booked on CHAIN_1 at the stale shape; CHAIN0 empty; unbooked headroom == _extra.
    _mockStaked({_amount: _priorX + _extra, _end: _liveStakeEnd, _isPermanent: false});
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _priorX, _lastStakeEnd: _stableStakeEnd, _lastAllocated: _priorAllocated
    });
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _priorX);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _slopeX * _dOld, _slope: _slopeX, _ts: _ts, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    _mockTotalPoint({_bias: _slopeX * _dOld, _slope: _slopeX, _ts: _ts, _perm: 0});
    _mockChainSlopeChange({_chainId: _CHAIN_ID_1, _expiry: _stableStakeEnd, _value: _slopeX});
    _mockTotalSlopeChange(_stableStakeEnd, _slopeX);
    // Anchor both ceiling cursors at the live global index so the re-anchor settles a zero delta.
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainLastIndex(_CHAIN0, _voter.index());
    uint256[] memory _prior = new uint256[](1);
    _prior[0] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _prior);

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should re-anchor every allocated chain to the live shape
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: _slopeX * _dNew, _slope: _slopeX, _ts: _ts, _perm: 0
    });
    // it should book the parked amount at the live shape
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: _slope0 * _dNew, _slope: _slope0, _ts: _ts, _perm: 0});
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _extra);
    _assertTotalPoint({
      _target: _voter, _bias: _slopeX * _dNew + _slope0 * _dNew, _slope: _slopeX + _slope0, _ts: _ts, _perm: 0
    });

    // it should move the prior slope schedule entries to the live stakeEnd
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _stableStakeEnd), int128(0));
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _liveStakeEnd), _slopeX);
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _liveStakeEnd), _slope0);

    // it should resample the global emissions per VP against the final total weight
    // The scalar is global: `mulDiv(MINTER_RATE, PRECISION, totalWeight)` against the post-re-anchor total,
    // with no per-chain factor. Every re-anchored chain picks it up through the shared index.
    assertEq(_voter.emissionsPerVP(), Math.mulDiv(_MINTER_RATE, _PRECISION, uint128((_slopeX + _slope0) * _dNew)));
    // Both touched chains settled their ceiling before their weight moved, so each cursor sits at the index.
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());

    // it should increase the token committed by the parked amount and re-anchor the shape, leaving
    // lastAllocated untouched (park must not move the cooldown anchor)
    _assertTokenState({
      _target: _voter,
      _tokenId: _TOKEN_ID,
      _committed: _priorX + _extra,
      _lastStakeEnd: _liveStakeEnd,
      _lastAllocated: _priorAllocated
    });
  }

  function test_ParkOnChain0WhenAPermanentShapeBecomesDecaying(uint128 _amount) external {
    // What `VotingEscrow.downgradeFromPermanentStake` drives: the whole balance is booked on CHAIN0 as permanent
    // power, and the live stake has just flipped to decaying. Nothing is parked, but the position must move out
    // of the permanent bucket so it starts decaying, and the stored shape must follow.
    _amount = uint128(bound(_amount, _MAXTIME, _INT128_MAX_HALF));
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _newEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    vm.warp(_ts);

    // Booked permanent: stored shape `0`, the contribution sitting in `permanentStakeBalance`.
    _mockStaked({_amount: _amount, _end: _newEnd, _isPermanent: false});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: 0, _lastAllocated: _ts - 1 days});
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _amount);
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _amount});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _amount});

    // it should emit ParkedOnChain0 with a zero amount
    _expectEmit(address(_voter));
    emit IVoter.ParkedOnChain0(_TOKEN_ID, 0);

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should move the booking out of the permanent bucket so it decays
    int128 _slope = _slopeOf(_amount);
    int128 _bias = _slope * int128(uint128(_newEnd - _ts));
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: _bias, _slope: _slope, _ts: _ts, _perm: 0});
    _assertTotalPoint({_target: _voter, _bias: _bias, _slope: _slope, _ts: _ts, _perm: 0});
    // it should schedule the slope change at the live stake end
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _newEnd), _slope);
    assertEq(_voter.totalSlopeChanges(_newEnd), _slope);
    // it should re seed the stored shape and park nothing
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _newEnd, _lastAllocated: _ts - 1 days
    });
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _amount);
  }

  function test_ParkOnChain0WhenTheStakeIsPermanent(uint128 _staked) external {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    vm.warp(_ts);
    // Permanent stake: `stakeEnd == 0`, booked as a permanent (non-decaying) contribution.
    _mockStaked({_amount: _staked, _end: 0, _isPermanent: true});

    // it should book the parked amount as a permanent contribution
    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _staked);

    // it should seed a zero token shape
    (uint128 _committed, uint48 _lastStakeEnd,,) = _voter.tokenStates(_TOKEN_ID);
    assertEq(_committed, _staked);
    assertEq(_lastStakeEnd, 0);
    // CHAIN0's point carries the permanent balance, not a decaying slope.
    IVoter.Point memory _chain0Point = _chainState(_voter, _CHAIN0).point;
    assertEq(_chain0Point.permanentStakeBalance, _staked);
    assertEq(_chain0Point.slope, 0);
  }

  function test_ParkOnChain0WhenOneWeiOfPermanentVotingPowerIsPricedAtTheMaximumEffectiveRate() external {
    uint256 _maxEffectiveRate = 2 * _MAX_SAFE_BASE_RATE;
    _mockStaked({_amount: 1, _end: 0, _isPermanent: true});
    vm.mockCall(_MINTER, abi.encodeCall(IMinter.emissionRate, ()), abi.encode(_maxEffectiveRate));

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should resample the maximum safe emissions per voting power
    assertEq(_voter.emissionsPerVP(), _maxEffectiveRate * _PRECISION);
  }

  function test_ParkOnChain0WhenSettlingAtTheMaximumSafeScalarNearTheTimestampHorizon() external {
    uint48 _finalBoundary = (type(uint48).max / _WEEK) * _WEEK;
    uint48 _to = _finalBoundary - 1;
    uint48 _from = _to - 1;
    uint256 _maxEffectiveRate = 2 * _MAX_SAFE_BASE_RATE;
    uint256 _maxSafeScalar = _maxEffectiveRate * _PRECISION;
    uint256 _indexBefore = _maxSafeScalar * _from;
    uint256 _timeIndexBefore = _maxSafeScalar * uint256(_from) * _from;

    // Seed a one-wei permanent position and mathematically consistent accumulators one second before `_to`.
    // The next weekly boundary is still representable but lies after `_to`, so this isolates the trailing
    // accumulator segment at the largest timestamp range the weekly walker can enter safely.
    _mockStaked({_amount: 1, _end: 0, _isPermanent: true});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 1, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _from, _perm: 1});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _from, _perm: 1});
    _mockGlobalIndex(_indexBefore);
    _mockGlobalTimeIndex(_timeIndexBefore);
    _mockEmissionsPerVP(_maxSafeScalar);
    _mockLastGlobalSettlement(_from);
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _indexBefore});
    _mockChainLastTimeIndex({_chainId: _CHAIN0, _value: _timeIndexBefore});
    vm.mockCall(_MINTER, abi.encodeCall(IMinter.emissionRate, ()), abi.encode(_maxEffectiveRate));
    vm.warp(_to);

    vm.prank(_VOTING_ESCROW);
    _voter.parkOnChain0(_TOKEN_ID);

    // it should advance the global index without overflowing
    assertEq(_voter.index(), _maxSafeScalar * _to);
    // it should advance the global time index without overflowing
    assertEq(_voter.timeIndex(), _maxSafeScalar * uint256(_to) * _to);
    // it should accrue the one wei chain ceiling at the maximum effective rate
    assertEq(_chainState(_voter, _CHAIN0).ceiling, _maxEffectiveRate);
    // it should preserve the maximum safe emissions per voting power
    assertEq(_voter.emissionsPerVP(), _maxSafeScalar);
  }

  /*////////////////////////////////////////////////////////////
                        CLEAR TOKEN
  ////////////////////////////////////////////////////////////*/
  function test_ClearTokenWhenTheCallerIsNotTheVotingEscrow(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTING_ESCROW);

    // it should revert with NotVotingEscrow
    vm.prank(_caller);
    vm.expectRevert(IVoter.NotVotingEscrow.selector);
    _voter.clearToken(_TOKEN_ID);
  }

  function test_ClearTokenWhenTheTokenIdIsTokenZero() external {
    // TOKEN0 anchors burned permanent VP and is never withdrawable, so clearing it would wipe the burn ledger.
    // it should revert with Token0NotClearable
    vm.prank(_VOTING_ESCROW);
    vm.expectRevert(IVoter.Token0NotClearable.selector);
    _voter.clearToken(_TOKEN0);
  }

  function test_ClearTokenWhenTheTokenHoldsBookingsOnSeveralChains(
    uint128 _amount0,
    uint128 _amount1,
    uint128 _amount2,
    uint128 _committed,
    uint48 _lastStakeEnd,
    uint48 _lastAllocated
  ) external {
    // Every seeded value is non-zero so each assertion below proves an actual erasure rather than
    // re-reading a slot that was already empty.
    _amount0 = uint128(bound(_amount0, 1, _INT128_MAX_HALF));
    _amount1 = uint128(bound(_amount1, 1, _INT128_MAX_HALF));
    _amount2 = uint128(bound(_amount2, 1, _INT128_MAX_HALF));
    _committed = uint128(bound(_committed, 1, _INT128_MAX_HALF));
    _lastStakeEnd = uint48(bound(_lastStakeEnd, 1, type(uint48).max));
    _lastAllocated = uint48(bound(_lastAllocated, 1, type(uint48).max));

    uint256[] memory _chainIds = new uint256[](3);
    _chainIds[0] = _CHAIN0;
    _chainIds[1] = _CHAIN_ID_1;
    _chainIds[2] = _CHAIN_ID_2;
    _mockExistingChainIds(_TOKEN_ID, _chainIds);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _amount0);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _amount1);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_2, _amount2);
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: _lastStakeEnd, _lastAllocated: _lastAllocated
    });

    // it should emit TokenCleared with the cleared chain ids
    // The event carries the set snapshotted before the loop, in insertion order.
    _expectEmit(address(_voter));
    emit IVoter.TokenCleared(_TOKEN_ID, _chainIds);

    vm.prank(_VOTING_ESCROW);
    _voter.clearToken(_TOKEN_ID);

    // it should zero every per chain booked amount
    // it should empty the tracked chain set
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 0);
    for (uint256 _i; _i < _chainIds.length; ++_i) {
      assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _chainIds[_i]), 0);
      assertFalse(_containsChain(_TOKEN_ID, _chainIds[_i]));
    }

    // it should zero every token state field
    // `lastStakeEnd` is the field that matters on revival: `0` encodes a permanent shape, so a leftover
    // expiry would anchor a revived position at a stale shape.
    _assertTokenState({_target: _voter, _tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: 0, _lastAllocated: 0});
  }

  function test_ClearTokenWhenTheTokenWeightHasAlreadyDecayedOutOfThePoints(ClearTokenWeightSeed memory _seed)
    external
  {
    // `withdraw` only accepts an expired, non-permanent stake, so by the time `clearToken` runs the token's
    // weight has already decayed out of every chain point, out of `totalPoint`, and its slope change was
    // consumed at the week boundary. The residue is ledger-only: subtracting weight here would double-count
    // and break `Σ per-chain == totalPoint`. This test pins that `clearToken` touches no weight at all.
    //
    // Quarter of `int128.max` so the three-chain sums seeded into `totalPoint` (plus the per-chain offsets) fit.
    _seed.bias = uint128(bound(_seed.bias, 1, uint128(type(int128).max) / 4));
    _seed.slope = uint128(bound(_seed.slope, 1, uint128(type(int128).max) / 4));
    _seed.perm = uint128(bound(_seed.perm, 1, type(uint128).max / 4));
    _seed.ts = uint48(bound(_seed.ts, 1, type(uint48).max - 2));
    _seed.emissionsPerVP = bound(_seed.emissionsPerVP, 1, type(uint256).max);
    _seed.index = bound(_seed.index, 1, type(uint256).max);
    _seed.booked = uint128(bound(_seed.booked, 1, _INT128_MAX_HALF));

    uint256[] memory _chainIds = new uint256[](3);
    _chainIds[0] = _CHAIN0;
    _chainIds[1] = _CHAIN_ID_1;
    _chainIds[2] = _CHAIN_ID_2;

    IVoter.Point memory _total = _seedClearTokenWeight(_seed, _chainIds);

    vm.prank(_VOTING_ESCROW);
    _voter.clearToken(_TOKEN_ID);

    // The ledger is gone — without this the weight assertions below would also hold for a no-op function.
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 0);
    _assertTokenState({_target: _voter, _tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: 0, _lastAllocated: 0});

    // it should leave every chain point untouched
    // it should leave the total point untouched
    _assertClearTokenWeightUnchanged(_seed, _chainIds, _total);

    // it should leave the sampled emissions per voting power untouched
    // it should leave the global index untouched
    // Resampling `emissionsPerVP` here would price emissions against a total weight this token never left.
    assertEq(_voter.emissionsPerVP(), _seed.emissionsPerVP);
    assertEq(_voter.index(), _seed.index);
  }

  function test_ClearTokenWhenTheTokenIsAlreadyClear(uint128 _booked, uint48 _lastStakeEnd) external {
    _booked = uint128(bound(_booked, 1, _INT128_MAX_HALF));
    _lastStakeEnd = uint48(bound(_lastStakeEnd, 1, type(uint48).max));

    _mockExistingChainIds(_TOKEN_ID, _singletonArray(_CHAIN_ID_1));
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _booked);
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _booked, _lastStakeEnd: _lastStakeEnd, _lastAllocated: _lastStakeEnd
    });

    vm.prank(_VOTING_ESCROW);
    _voter.clearToken(_TOKEN_ID);

    // it should emit TokenCleared with an empty chain array
    // The second clear finds nothing tracked, so the snapshotted set is empty.
    _expectEmit(address(_voter));
    emit IVoter.TokenCleared(_TOKEN_ID, new uint256[](0));

    vm.prank(_VOTING_ESCROW);
    _voter.clearToken(_TOKEN_ID);

    // it should leave the token state zeroed
    _assertTokenState({_target: _voter, _tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: 0, _lastAllocated: 0});
    // it should leave the tracked chain set empty
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
  }

  function test_ClearTokenWhenAnotherTokenHoldsBookingsOnTheSameChains(
    uint128 _bookedA,
    uint128 _bookedB,
    uint128 _committedB,
    uint48 _lastStakeEndB,
    uint48 _lastAllocatedB
  ) external {
    _bookedA = uint128(bound(_bookedA, 1, _INT128_MAX_HALF));
    _bookedB = uint128(bound(_bookedB, 1, _INT128_MAX_HALF));
    _committedB = uint128(bound(_committedB, 1, _INT128_MAX_HALF));
    _lastStakeEndB = uint48(bound(_lastStakeEndB, 1, type(uint48).max));
    _lastAllocatedB = uint48(bound(_lastAllocatedB, 1, type(uint48).max));

    // Both tokens are booked on CHAIN_ID_1: the per-token mappings must stay independent there.
    uint256[] memory _chainsA = new uint256[](2);
    _chainsA[0] = _CHAIN0;
    _chainsA[1] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _chainsA);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _bookedA);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _bookedA);
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _bookedA * 2, _lastStakeEnd: 1, _lastAllocated: 1});

    uint256[] memory _chainsB = new uint256[](2);
    _chainsB[0] = _CHAIN_ID_1;
    _chainsB[1] = _CHAIN_ID_2;
    _mockExistingChainIds(_TOKEN_ID_2, _chainsB);
    _mockAllocationChainAmount(_TOKEN_ID_2, _CHAIN_ID_1, _bookedB);
    _mockAllocationChainAmount(_TOKEN_ID_2, _CHAIN_ID_2, _bookedB);
    _mockTokenState({
      _tokenId: _TOKEN_ID_2, _committed: _committedB, _lastStakeEnd: _lastStakeEndB, _lastAllocated: _lastAllocatedB
    });

    vm.prank(_VOTING_ESCROW);
    _voter.clearToken(_TOKEN_ID);

    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 0);

    // it should leave the other token booked amounts untouched
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN_ID_1), _bookedB);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN_ID_2), _bookedB);
    uint256[] memory _storedB = _voter.allocationChainIds(_TOKEN_ID_2);
    assertEq(_storedB.length, 2);
    assertEq(_storedB[0], _CHAIN_ID_1);
    assertEq(_storedB[1], _CHAIN_ID_2);

    // it should leave the other token state untouched
    _assertTokenState({
      _target: _voter,
      _tokenId: _TOKEN_ID_2,
      _committed: _committedB,
      _lastStakeEnd: _lastStakeEndB,
      _lastAllocated: _lastAllocatedB
    });
  }

  /*////////////////////////////////////////////////////////////
                REGISTER CHAIN
  ////////////////////////////////////////////////////////////*/
  function test_RegisterChainWhenTheCallerDoesNotHoldTheChainConfigRole(address _caller, uint256 _chainId) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _CHAIN_CONFIG);

    bytes32 _role = Roles.CHAIN_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _voter.registerChain(_chainId);
  }

  function test_RegisterChainWhenTheChainIdIsChainZero() external {
    // it should revert with Chain0NotConfigurable
    vm.expectRevert(IVoter.Chain0NotConfigurable.selector);
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_CHAIN0);
  }

  function test_RegisterChainWhenTheChainIsAlreadyRegistered(uint256 _chainId) external {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(
      _chainId != _CHAIN_ID_1 && _chainId != _CHAIN_ID_2 && _chainId != _CHAIN_ID_3 && _chainId != block.chainid
    );
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_chainId);

    // it should revert with ChainAlreadyRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainAlreadyRegistered.selector, _chainId));
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_chainId);
  }

  function test_RegisterChainWhenTheChainIsFresh(uint256 _chainId, uint48 _registerTs) external {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(
      _chainId != _CHAIN_ID_1 && _chainId != _CHAIN_ID_2 && _chainId != _CHAIN_ID_3 && _chainId != block.chainid
    );
    // Registration settles the global accumulators first, and that walk banks one mark per week boundary since
    // the last settlement, so keep the horizon to a realistic gap rather than the whole `uint48` range.
    _registerTs = uint48(bound(_registerTs, _INITIAL_TIMESTAMP + 1, _INITIAL_TIMESTAMP + 365 days));
    vm.warp(_registerTs);

    uint256 _priorLength = _voter.chains().length;

    // it should emit the ChainRegistered event
    _expectEmit(address(_voter));
    emit IVoter.ChainRegistered(_chainId);

    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_chainId);

    // it should add the chain to the registered set
    uint256[] memory _registered = _voter.chains();
    assertEq(_registered.length, _priorLength + 1);
    assertEq(_registered[_priorLength], _chainId);

    IVoter.ChainState memory _state = _chainState(_voter, _chainId);
    // it should anchor the ceiling cursor at the current global index
    assertEq(_state.lastIndex, _voter.index());
    // it should anchor the time weighted ceiling cursor at the current global time index
    assertEq(_state.lastTimeIndex, _voter.timeIndex());
    // it should seed the chain point timestamp to the current timestamp
    assertEq(_state.point.ts, _registerTs);
    // it should default the status to Active
    assertEq(uint8(_state.status), uint8(IVoterCommon.ChainStatus.Active));
  }

  function test_RegisterChainWhenTheGlobalIndexHasAlreadyAccrued(
    uint256 _chainId,
    uint256 _accruedIndex,
    uint256 _accruedTimeIndex,
    uint128 _scalar,
    uint48 _elapsed
  ) external {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(
      _chainId != _CHAIN_ID_1 && _chainId != _CHAIN_ID_2 && _chainId != _CHAIN_ID_3 && _chainId != block.chainid
    );
    // A live protocol registers chains long after the accumulators started moving. Both cursors must be planted
    // at the accumulated values, otherwise the fresh chain bills the whole pre-registration integral.
    _accruedIndex = bound(_accruedIndex, 1, type(uint64).max);
    _accruedTimeIndex = bound(_accruedTimeIndex, 1, type(uint128).max);
    _scalar = uint128(bound(_scalar, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    // The accumulators are current as of now, so the accrued values are entirely pre-registration integral.
    _mockGlobalIndex(_accruedIndex);
    _mockGlobalTimeIndex(_accruedTimeIndex);
    _mockEmissionsPerVP(_scalar);
    _mockLastGlobalSettlement(uint48(block.timestamp));

    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_chainId);

    // it should anchor the ceiling cursor at the accumulated index
    assertEq(_chainState(_voter, _chainId).lastIndex, _accruedIndex);
    // it should anchor the time weighted ceiling cursor at the accumulated time index
    assertEq(_chainState(_voter, _chainId).lastTimeIndex, _accruedTimeIndex);

    // Permanent chain weight of `_ONE_AERO == PRECISION` so the accrual reduces to `scalar * dt`.
    _mockChainPoint({_chainId: _chainId, _bias: 0, _slope: 0, _ts: uint48(block.timestamp), _perm: _ONE_AERO});
    vm.warp(block.timestamp + _elapsed);
    // Suspending settles the chain under its current Active status, routing the accrual into the ceiling.
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_chainId, IVoterCommon.ChainStatus.Suspended);

    // it should accrue only the interval since registration
    assertEq(_chainState(_voter, _chainId).ceiling, uint256(_scalar) * _elapsed);
  }

  function test_RegisterChainWhenTheGlobalSettlementIsBehindTheCurrentTimestamp(
    uint256 _chainId,
    uint256 _accruedIndex,
    uint128 _scalar,
    uint48 _pending,
    uint48 _elapsed
  ) external {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(
      _chainId != _CHAIN_ID_1 && _chainId != _CHAIN_ID_2 && _chainId != _CHAIN_ID_3 && _chainId != block.chainid
    );
    // The accumulators only move when something settles them, so a registration can land while `_pending`
    // seconds are still unbanked. The cursors must be planted at the settled values, not the stale reads, or
    // the fresh chain bills that unbanked stretch as if it had been registered for it.
    _accruedIndex = bound(_accruedIndex, 1, type(uint64).max);
    _scalar = uint128(bound(_scalar, 1, type(uint64).max));
    _pending = uint48(bound(_pending, 1, 52 weeks));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    _mockGlobalIndex(_accruedIndex);
    _mockGlobalTimeIndex(0);
    _mockEmissionsPerVP(_scalar);

    // Leave the cursor `_pending` seconds behind now, so the stored accumulators are stale by that much.
    uint48 _registeredAt = uint48(block.timestamp);
    _mockLastGlobalSettlement(_registeredAt - _pending);

    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_chainId);

    // it should anchor the ceiling cursor at the settled index
    // The settled value is the stale read plus the unbanked stretch, `scalar * pending`.
    uint48 _settledFrom = _registeredAt - _pending;
    assertEq(_chainState(_voter, _chainId).lastIndex, _accruedIndex + uint256(_scalar) * _pending);
    // it should anchor the time weighted ceiling cursor at the settled time index
    // `timeIndex` sums the scalar weighted by absolute unix time, doubled, so the stretch adds
    // `scalar * (registeredAt^2 - settledFrom^2)` onto the zero it was seeded with.
    uint256 _timeStretch = uint256(_registeredAt) * _registeredAt - uint256(_settledFrom) * _settledFrom;
    assertEq(_chainState(_voter, _chainId).lastTimeIndex, uint256(_scalar) * _timeStretch);
    // Both cursors now describe the same instant as the point timestamp written beside them.
    assertEq(_voter.lastGlobalSettlement(), _registeredAt);

    // Permanent chain weight of `_ONE_AERO == PRECISION` so the accrual reduces to `scalar * dt`.
    _mockChainPoint({_chainId: _chainId, _bias: 0, _slope: 0, _ts: _registeredAt, _perm: _ONE_AERO});
    vm.warp(uint256(_registeredAt) + _elapsed);
    // Suspending settles the chain under its current Active status, routing the accrual into the ceiling.
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_chainId, IVoterCommon.ChainStatus.Suspended);

    // it should accrue only the interval since registration
    assertEq(_chainState(_voter, _chainId).ceiling, uint256(_scalar) * _elapsed);
  }

  /*////////////////////////////////////////////////////////////
               SET CHAIN STATUS
  ////////////////////////////////////////////////////////////*/
  function test_SetChainStatusWhenTheCallerDoesNotHoldTheChainStatusRole(
    address _caller,
    uint256 _chainId,
    uint8 _statusRaw
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _CHAIN_STATUS);
    _statusRaw = uint8(bound(_statusRaw, 0, uint8(type(IVoterCommon.ChainStatus).max)));

    bytes32 _role = Roles.CHAIN_STATUS_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _voter.setChainStatus(_chainId, IVoterCommon.ChainStatus(_statusRaw));
  }

  function test_SetChainStatusWhenTheChainIdIsChainZero(uint8 _statusRaw) external {
    _statusRaw = uint8(bound(_statusRaw, 0, uint8(type(IVoterCommon.ChainStatus).max)));

    // it should revert with Chain0NotConfigurable
    vm.expectRevert(IVoter.Chain0NotConfigurable.selector);
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN0, IVoterCommon.ChainStatus(_statusRaw));
  }

  function test_SetChainStatusWhenTheChainIsNotRegistered(uint256 _chainId, uint8 _statusRaw) external {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(
      _chainId != _CHAIN_ID_1 && _chainId != _CHAIN_ID_2 && _chainId != _CHAIN_ID_3 && _chainId != block.chainid
    );
    _statusRaw = uint8(bound(_statusRaw, 0, uint8(type(IVoterCommon.ChainStatus).max)));

    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _chainId));
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_chainId, IVoterCommon.ChainStatus(_statusRaw));
  }

  function test_SetChainStatusWhenTheTargetStatusIsNone() external {
    // `_CHAIN_ID_1` is registered, so the call clears the registered check and hits the None guard.
    // it should revert with InvalidStatus
    vm.expectRevert(IVoterCommon.InvalidStatus.selector);
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.None);
  }

  function test_SetChainStatusWhenTheNewStatusMatchesTheCurrentStatus() external {
    // `_CHAIN_ID_1` is registered with the default `Active` status.
    // it should revert with ChainStatusUnchanged
    vm.expectRevert(IVoterCommon.ChainStatusUnchanged.selector);
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);
  }

  function test_SetChainStatusWhenFlippingFromSuspendedToPaused() external {
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    // it should revert with InvalidChainStatusTransition
    vm.expectRevert(IVoterCommon.InvalidChainStatusTransition.selector);
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);
  }

  function test_SetChainStatusWhenFlippingFromSuspendedToSunsetWithElapsedTime(
    uint128 _emissionsPerVP,
    uint48 _elapsed
  ) external {
    // Sunset routes accrual to the same surplus bucket Suspended does and the leaf scalar is already zero,
    // so the wind-down flips directly without reopening allocations through an Active hop.
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 30 days));

    uint48 _settledAt = uint48(block.timestamp);
    // Seed a permanent chain point (weight == _ONE_AERO == PRECISION) so the settle accrual
    // `mulDiv(weightOf(point), index delta, PRECISION)` reduces to the raw index delta.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _settledAt, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_settledAt);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    vm.warp(uint256(_settledAt) + _elapsed);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_voter));
    emit IVoter.ChainStatusSet(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should advance the global last settlement to the current timestamp
    assertEq(_voter.lastGlobalSettlement(), uint48(block.timestamp));
    // it should anchor the chain ceiling cursor at the advanced index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
    // it should accrue cumulativeSuspendedSurplus at the sampled emissions per VP
    // Chain weight equals PRECISION, so the accrual is exactly the index delta.
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, uint256(_emissionsPerVP) * _elapsed);
    // it should leave the ceiling unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, 0);
    // it should update the stored status
    assertEq(uint8(_chainState(_voter, _CHAIN_ID_1).status), uint8(IVoterCommon.ChainStatus.Sunset));
  }

  function test_SetChainStatusWhenFlippingFromSunsetToPaused() external {
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should revert with InvalidChainStatusTransition
    vm.expectRevert(IVoterCommon.InvalidChainStatusTransition.selector);
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);
  }

  function test_SetChainStatusWhenFlippingFromSunsetToActive() external {
    // A reactivation must route through Suspended so the in-flight deallocation set drains first; the
    // direct resume is blocked.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should revert with InvalidChainStatusTransition
    vm.expectRevert(IVoterCommon.InvalidChainStatusTransition.selector);
    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);
  }

  function test_SetChainStatusWhenFlippingFromSunsetToSuspended() external {
    // The lone exit: the kill switch for a compromised or unreachable sunset chain and the first leg of
    // a reactivation.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_voter));
    emit IVoter.ChainStatusSet(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    // it should update the stored status
    assertEq(uint8(_chainState(_voter, _CHAIN_ID_1).status), uint8(IVoterCommon.ChainStatus.Suspended));
  }

  function test_SetChainStatusWhenTheChainIsRegistered(uint8 _statusRaw) external {
    // Bound away from the default `Active` so the write is a real transition.
    _statusRaw =
      uint8(bound(_statusRaw, uint8(IVoterCommon.ChainStatus.Paused), uint8(type(IVoterCommon.ChainStatus).max)));
    IVoterCommon.ChainStatus _status = IVoterCommon.ChainStatus(_statusRaw);

    // `_CHAIN_ID_1` is pre-registered in setUp.
    // it should emit the ChainStatusSet event
    _expectEmit(address(_voter));
    emit IVoter.ChainStatusSet(_CHAIN_ID_1, _status);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, _status);

    // it should update the stored status
    assertEq(uint8(_chainState(_voter, _CHAIN_ID_1).status), _statusRaw);
  }

  function test_SetChainStatusWhenFlippingFromSuspendedToActiveWithElapsedTime(
    uint128 _emissionsPerVP,
    uint48 _elapsed
  ) external {
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 30 days));

    uint48 _settledAt = uint48(block.timestamp);
    // Seed a permanent chain point (weight == _ONE_AERO == PRECISION) so the settle accrual
    // `mulDiv(weightOf(point), index delta, PRECISION)` reduces to the raw index delta.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _settledAt, _perm: _ONE_AERO});
    // Pending accrual comes from the GLOBAL accumulator: the scalar in effect plus the last settlement it
    // was integrated to, with the chain's cursor sitting at the current index.
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_settledAt);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    vm.warp(uint256(_settledAt) + _elapsed);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    // it should advance the global last settlement to the current timestamp
    assertEq(_voter.lastGlobalSettlement(), uint48(block.timestamp));
    // it should advance the global index at the sampled emissions per VP
    // Index started at zero, so it now holds the whole integral `emissionsPerVP * elapsed`.
    assertEq(_voter.index(), uint256(_emissionsPerVP) * _elapsed);
    // it should anchor the chain ceiling cursor at the advanced index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, uint256(_emissionsPerVP) * _elapsed);
    // it should accrue cumulativeSuspendedSurplus at the sampled emissions per VP
    // Chain weight equals PRECISION, so the accrual is exactly the index delta.
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, uint256(_emissionsPerVP) * _elapsed);
    // it should leave the ceiling unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, 0);
  }

  function test_SetChainStatusWhenFlippingFromActiveToSuspendedWithElapsedTime(
    uint128 _emissionsPerVP,
    uint48 _elapsed
  ) external {
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 30 days));

    uint48 _settledAt = uint48(block.timestamp);
    // Seed a permanent chain point (weight == _ONE_AERO == PRECISION) so the settle accrual
    // `mulDiv(weightOf(point), index delta, PRECISION)` reduces to the raw index delta.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _settledAt, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_settledAt);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    // Active is the default post-registration; no status mock needed.
    vm.warp(uint256(_settledAt) + _elapsed);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    // it should advance the global last settlement to the current timestamp
    assertEq(_voter.lastGlobalSettlement(), uint48(block.timestamp));
    // it should anchor the chain ceiling cursor at the advanced index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
    // it should advance the ceiling at the sampled emissions per VP
    // Chain weight equals PRECISION, so the accrual is exactly the index delta.
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, uint256(_emissionsPerVP) * _elapsed);
    // it should leave cumulativeSuspendedSurplus unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, 0);
  }

  function test_SetChainStatusWhenFlippingFromActiveToSunsetWithElapsedTime(
    uint128 _emissionsPerVP,
    uint48 _elapsed
  ) external {
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 30 days));

    uint48 _settledAt = uint48(block.timestamp);
    // Seed a permanent chain point (weight == _ONE_AERO == PRECISION) so the settle accrual
    // `mulDiv(weightOf(point), index delta, PRECISION)` reduces to the raw index delta.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _settledAt, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_settledAt);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    // Active is the default post-registration; the settle runs under the OLD status, so the pending accrual
    // still lands on the ceiling and only post-flip accrual goes to surplus.
    vm.warp(uint256(_settledAt) + _elapsed);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should advance the global last settlement to the current timestamp
    assertEq(_voter.lastGlobalSettlement(), uint48(block.timestamp));
    // it should anchor the chain ceiling cursor at the advanced index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
    // it should advance the ceiling at the sampled emissions per VP
    // Chain weight equals PRECISION, so the accrual is exactly the index delta.
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, uint256(_emissionsPerVP) * _elapsed);
    // it should leave cumulativeSuspendedSurplus unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, 0);
  }

  function test_SetChainStatusWhenFlippingFromPausedToActive() external {
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_voter));
    emit IVoter.ChainStatusSet(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    // it should update the stored status
    assertEq(uint8(_chainState(_voter, _CHAIN_ID_1).status), uint8(IVoterCommon.ChainStatus.Active));
  }

  function test_SetChainStatusWhenFlippingFromPausedToSuspended() external {
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_voter));
    emit IVoter.ChainStatusSet(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    // it should update the stored status
    assertEq(uint8(_chainState(_voter, _CHAIN_ID_1).status), uint8(IVoterCommon.ChainStatus.Suspended));
  }

  function test_SetChainStatusWhenFlippingFromPausedToSunset() external {
    // A paused chain can wind down directly; the Paused block only applies as a target, never a source.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_voter));
    emit IVoter.ChainStatusSet(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should update the stored status
    assertEq(uint8(_chainState(_voter, _CHAIN_ID_1).status), uint8(IVoterCommon.ChainStatus.Sunset));
  }

  function test_SetChainStatusWhenEnteringSuspendedWithTheEmergencySwitchEnabled() external {
    // `_CHAIN_ID_1` is Active by default. Seed the emergency switch ON, then suspend: entering Suspended
    // must clear the switch so each suspension independently re-authorizes emergency deallocation.
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    // it should emit the EmergencyDeallocationAllowedSet event
    _expectEmit(address(_voter));
    emit IVoter.EmergencyDeallocationAllowedSet(_CHAIN_ID_1, false);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    // it should reset the emergencyDeallocationAllowed switch to false
    assertFalse(_voter.emergencyDeallocationAllowed(_CHAIN_ID_1));
  }

  function test_SetChainStatusWhenEnteringSunsetWithTheEmergencySwitchEnabled() external {
    // `_CHAIN_ID_1` is Active by default. Emergency deallocation is Suspended-only, so entering Sunset
    // leaves the switch alone; a dead sunset chain flips to Suspended first, which clears it.
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should leave the emergencyDeallocationAllowed switch unchanged
    assertTrue(_voter.emergencyDeallocationAllowed(_CHAIN_ID_1));
  }

  function test_SetChainStatusWhenTransitioningToANonSuspendedStatusWithTheEmergencySwitchEnabled() external {
    // Only entering Suspended clears the switch. Transition Paused -> Active with the switch ON
    // and confirm it survives, so any other status change never touches the flag.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    vm.prank(_CHAIN_STATUS);
    _voter.setChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    // it should leave the emergencyDeallocationAllowed switch unchanged
    assertTrue(_voter.emergencyDeallocationAllowed(_CHAIN_ID_1));
  }

  /*////////////////////////////////////////////////////////////
             SET EMERGENCY DEALLOCATION ALLOWED
  ////////////////////////////////////////////////////////////*/
  function test_SetEmergencyDeallocationAllowedWhenTheCallerDoesNotHoldTheChainStatusRole(
    address _caller,
    uint256 _chainId,
    bool _allowed
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _CHAIN_STATUS);

    bytes32 _role = Roles.CHAIN_STATUS_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _voter.setEmergencyDeallocationAllowed(_chainId, _allowed);
  }

  function test_SetEmergencyDeallocationAllowedWhenTheChainIsNotRegistered(bool _allowed) external {
    // `_UNREGISTERED_CHAIN_ID` is deliberately kept out of the registered set, so `_requireRegisteredChain`
    // reverts before the switch is written.
    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _UNREGISTERED_CHAIN_ID));
    vm.prank(_CHAIN_STATUS);
    _voter.setEmergencyDeallocationAllowed(_UNREGISTERED_CHAIN_ID, _allowed);
  }

  function test_SetEmergencyDeallocationAllowedWhenTheCallerHoldsTheChainStatusRoleAndAllowedIsTrue() external {
    // `_CHAIN_ID_1` is registered in setUp and its switch defaults false.
    // it should emit the EmergencyDeallocationAllowedSet event
    _expectEmit(address(_voter));
    emit IVoter.EmergencyDeallocationAllowedSet(_CHAIN_ID_1, true);

    vm.prank(_CHAIN_STATUS);
    _voter.setEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    // it should set the emergencyDeallocationAllowed switch to true
    assertTrue(_voter.emergencyDeallocationAllowed(_CHAIN_ID_1));
  }

  function test_SetEmergencyDeallocationAllowedWhenTheCallerHoldsTheChainStatusRoleAndAllowedIsFalse() external {
    // Seed the switch ON first (directly, not via the setter) so the write-to-false is observable.
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    // it should emit the EmergencyDeallocationAllowedSet event
    _expectEmit(address(_voter));
    emit IVoter.EmergencyDeallocationAllowedSet(_CHAIN_ID_1, false);

    vm.prank(_CHAIN_STATUS);
    _voter.setEmergencyDeallocationAllowed(_CHAIN_ID_1, false);

    // it should set the emergencyDeallocationAllowed switch to false
    assertFalse(_voter.emergencyDeallocationAllowed(_CHAIN_ID_1));
  }

  /*////////////////////////////////////////////////////////////
                  SET OPERATOR
  ////////////////////////////////////////////////////////////*/
  function test_SetOperatorWhenTheCallerIsNotAuthorized(address _caller, address _operator) external {
    _assumeFuzzable(_caller);
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_caller, _TOKEN_ID)), abi.encode(false));

    // it should revert with NotAuthorized
    vm.expectRevert(IVoter.NotAuthorized.selector);
    vm.prank(_caller);
    _voter.setOperator(_TOKEN_ID, _CHAIN_ID_1, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheChainIdIsChainZero(address _operator) external {
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));

    // it should revert with Chain0NotConfigurable
    vm.expectRevert(IVoter.Chain0NotConfigurable.selector);
    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, _CHAIN0, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheChainIsNotRegistered(uint256 _chainId, address _operator) external {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(
      _chainId != _CHAIN_ID_1 && _chainId != _CHAIN_ID_2 && _chainId != _CHAIN_ID_3 && _chainId != block.chainid
    );
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));

    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _chainId));
    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, _chainId, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheChainIsPaused(address _operator) external {
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));

    // it should revert with ChainPaused
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainPaused.selector, _CHAIN_ID_1));
    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, _CHAIN_ID_1, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheChainIsSuspended(address _operator) external {
    _operator = _excludingAddressZero(_operator);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    _expectOperatorDispatch({_chainId: _CHAIN_ID_1, _tokenId: _TOKEN_ID, _operator: _operator, _gasLimit: _GAS_LIMIT});

    // it should emit the OperatorSet event
    _expectEmit(address(_voter));
    emit IVoter.OperatorSet(_TOKEN_ID, _CHAIN_ID_1, _operator);

    // it should dispatch the SetOperator propagation message
    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, _CHAIN_ID_1, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheChainIsSunset(address _operator) external {
    // A sunset chain keeps operator rotation open so the leaf's local exit vote stays runnable.
    _operator = _excludingAddressZero(_operator);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    _expectOperatorDispatch({_chainId: _CHAIN_ID_1, _tokenId: _TOKEN_ID, _operator: _operator, _gasLimit: _GAS_LIMIT});

    // it should emit the OperatorSet event
    _expectEmit(address(_voter));
    emit IVoter.OperatorSet(_TOKEN_ID, _CHAIN_ID_1, _operator);

    // it should dispatch the SetOperator propagation message
    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, _CHAIN_ID_1, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheDestinationGasLimitIsZeroForANonRootChain(address _operator) external {
    // A non-root destination with a zero gas limit is undeliverable, so it is rejected upfront like
    // every other dispatching entrypoint.
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with MissingDestinationGasLimit
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.setOperator(_TOKEN_ID, _CHAIN_ID_1, _operator, 0, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheDestinationGasLimitIsZeroForTheLocalChain(address _operator) external {
    // `block.chainid` is registered and Active in setUp. The root-colocated leaf is exempt from the
    // destination-gas requirement: a zero gas limit must NOT revert and must still dispatch.
    _operator = _excludingAddressZero(_operator);
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    _expectOperatorDispatch({_chainId: block.chainid, _tokenId: _TOKEN_ID, _operator: _operator, _gasLimit: 0});

    // it should emit the OperatorSet event
    _expectEmit(address(_voter));
    emit IVoter.OperatorSet(_TOKEN_ID, block.chainid, _operator);

    // it should not revert
    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, block.chainid, _operator, 0, _REFUND_RECIPIENT);
  }

  function test_SetOperatorWhenTheOperatorChanges(address _operator) external {
    _operator = _excludingAddressZero(_operator);
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    // it should stamp the message with the message lifetime expiry
    // The helper's expectCall pins the full payload, including `block.timestamp + _MESSAGE_LIFETIME`.
    _expectOperatorDispatch({_chainId: _CHAIN_ID_1, _tokenId: _TOKEN_ID, _operator: _operator, _gasLimit: _GAS_LIMIT});

    // it should emit the OperatorSet event
    _expectEmit(address(_voter));
    emit IVoter.OperatorSet(_TOKEN_ID, _CHAIN_ID_1, _operator);

    vm.prank(_CALLER);
    _voter.setOperator(_TOKEN_ID, _CHAIN_ID_1, _operator, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function _expectOperatorDispatch(uint256 _chainId, uint256 _tokenId, address _operator, uint256 _gasLimit) private {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: 0,
      chargeDeallocationReturn: false,
      payload: abi.encode(
        IVoterCommon.OperatorMessage({
          tokenId: _tokenId, expiry: uint48(block.timestamp) + _MESSAGE_LIFETIME, operator: _operator
        })
      )
    });
    vm.expectCall(
      _ORCHESTRATOR,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.SetOperator, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /*////////////////////////////////////////////////////////////
                    VIEWS
  ////////////////////////////////////////////////////////////*/
  function test_IsSuspendedWhenTheChainStatusIsSuspended(uint256 _chainId) external {
    _mockChainStatus(_chainId, IVoterCommon.ChainStatus.Suspended);

    // it should return true
    assertTrue(_voter.isSuspended(_chainId));
  }

  function test_IsSuspendedWhenTheChainStatusIsNotSuspended(uint256 _chainId) external {
    _mockChainStatus(_chainId, IVoterCommon.ChainStatus.Active);
    // it should return false when the chain is active
    assertFalse(_voter.isSuspended(_chainId));

    _mockChainStatus(_chainId, IVoterCommon.ChainStatus.Paused);
    // it should return false when the chain is paused
    assertFalse(_voter.isSuspended(_chainId));

    _mockChainStatus(_chainId, IVoterCommon.ChainStatus.Sunset);
    // it should return false when the chain is Sunset
    assertFalse(_voter.isSuspended(_chainId));
  }

  function test_AllocatingWhenTheTokenIdHasNoAllocationChains(uint256 _tokenId) external view {
    // it should return false
    assertFalse(_voter.allocating(_tokenId));
  }

  function test_AllocatingWhenTheTokenIdHasAllocationChains(uint256 _tokenId) external {
    uint256[] memory _chainIds = new uint256[](1);
    _chainIds[0] = _CHAIN_ID_1;
    _mockExistingChainIds(_tokenId, _chainIds);
    // `allocating()` is true when the tokenId directs any voting power to a non-CHAIN0 chain:
    // `_committed != 0 && _committed != allocationChainAmounts[CHAIN0]`. Seed `_committed: 1`
    // against the default-zero CHAIN0 amount to satisfy both.
    _mockTokenState({_tokenId: _tokenId, _committed: 1, _lastStakeEnd: 0, _lastAllocated: 0});

    // it should return true
    assertTrue(_voter.allocating(_tokenId));
  }

  function test_AllocatingWhenTheTokenIdIsParkedOnChainZero(uint256 _tokenId, uint128 _committed) external {
    _committed = uint128(bound(_committed, 1, type(uint128).max));
    // Parked on CHAIN0: `committed == allocationChainAmounts[CHAIN0]` and CHAIN0 is the only chain.
    uint256[] memory _chainIds = new uint256[](1);
    _chainIds[0] = _CHAIN0;
    _mockExistingChainIds(_tokenId, _chainIds);
    _mockTokenState({_tokenId: _tokenId, _committed: _committed, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _tokenId, _chainId: _CHAIN0, _amount: _committed});

    // it should return false
    assertFalse(_voter.allocating(_tokenId));
  }

  function test_SpendableSurplusWhenTheChainIsChainZero(uint256 _ceiling, uint256 _spent) external {
    _ceiling = bound(_ceiling, 0, type(uint256).max);
    _spent = bound(_spent, 0, _ceiling);
    _mockChainCeiling(_CHAIN0, _ceiling);
    _mockSurplusSpent(_CHAIN0, _spent);

    // it should return the ceiling minus the spent surplus
    assertEq(_voter.spendableSurplus(_CHAIN0), _ceiling - _spent);
  }

  function test_SpendableSurplusWhenTheChainIsNotChainZero(
    uint256 _reported,
    uint256 _suspended,
    uint256 _spent,
    uint256 _totalRedeemed,
    uint256 _ceiling
  ) external {
    // The reported pot clamps to the entitlement `ceiling - totalRedeemed`. Seed the ceiling at or above
    // the report plus the redeemed total so the clamp is provably inactive on this branch.
    _reported = bound(_reported, 0, type(uint256).max / 4);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint256).max / 4);
    _ceiling = bound(_ceiling, _reported + _totalRedeemed, type(uint256).max / 2);
    _suspended = bound(_suspended, 0, type(uint256).max / 2);
    _spent = bound(_spent, 0, _reported + _suspended);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);
    _mockCumulativeSuspendedSurplus(_CHAIN_ID_1, _suspended);
    _mockSurplusSpent(_CHAIN_ID_1, _spent);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);

    // it should return the reported plus suspended surplus minus the spent surplus
    assertEq(_voter.spendableSurplus(_CHAIN_ID_1), _reported + _suspended - _spent);
  }

  function test_SpendableSurplusWhenTheReportedSurplusExceedsTheRemainingMintEntitlement(
    uint256 _reported,
    uint256 _suspended,
    uint256 _spent,
    uint256 _totalRedeemed,
    uint256 _ceiling
  ) external {
    // A buffer backed redeem can store a report past the entitlement `ceiling - totalRedeemed`. The view
    // caps the reported pot at that entitlement so the buffer backed excess is never spendable.
    _ceiling = bound(_ceiling, 0, type(uint256).max / 4);
    _totalRedeemed = bound(_totalRedeemed, 0, _ceiling);
    uint256 _entitlement = _ceiling - _totalRedeemed;
    _reported = bound(_reported, _entitlement + 1, type(uint256).max / 4 + 1);
    _suspended = bound(_suspended, 0, type(uint256).max / 2);
    _spent = bound(_spent, 0, _entitlement + _suspended);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);
    _mockCumulativeSuspendedSurplus(_CHAIN_ID_1, _suspended);
    _mockSurplusSpent(_CHAIN_ID_1, _spent);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);

    // it should return the entitlement plus suspended surplus minus the spent surplus
    assertEq(_voter.spendableSurplus(_CHAIN_ID_1), _entitlement + _suspended - _spent);
  }

  function test_SpendableSurplusWhenTheChainHasPendingUnsettledAccrual(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _ceiling
  ) external {
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    _ceiling = bound(_ceiling, 0, type(uint128).max);
    // CHAIN0 with a permanent park and a pending window: the view reads stored values only, so the
    // unsettled accrual is invisible until the next settle. `spendSurplus` settles first, so this
    // is a floor on the executable amount.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN0, _ceiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    // it should return the stored floor without settling
    assertEq(_voter.spendableSurplus(_CHAIN0), _ceiling);
  }

  /// @dev Regression test for raw-storage mock helper layout. Kept out of the Bulloak tree because it tests the
  ///      fixture, not Voter behavior. The `_mock*` helpers write raw slots derived from the `VoterStorage` field
  ///      order, so reordering that struct compiles clean and silently seeds the wrong slots. Each helper reads
  ///      its write back through a getter, but only when some test calls it: exercising every one here makes the
  ///      layout guard deterministic instead of incidental. A new `_mock*` helper belongs in this test.
  function test_StorageMockHelpersWhenTheyAreUsedTogether() external {
    uint256[] memory _chainIds = new uint256[](1);
    _chainIds[0] = _CHAIN_ID_2;

    _mockTokenState(_TOKEN_ID_2, 100 ether, 30 days, 12 hours);
    _mockExistingChainIds(_TOKEN_ID_2, _chainIds);
    _mockAllocationChainAmount(_TOKEN_ID_2, _CHAIN_ID_2, 40 ether);
    _mockChainCeiling(_CHAIN_ID_2, 1000 ether);
    _mockTotalRedeemed(_CHAIN_ID_2, 111 ether);
    _mockSurplusAlreadyReported(_CHAIN_ID_2, 222 ether);
    _mockCumulativeSuspendedSurplus(_CHAIN_ID_2, 333 ether);
    _mockSurplusSpent(_CHAIN_ID_2, 444 ether);
    _mockChainLastIndex(_CHAIN_ID_2, type(uint256).max);
    _mockGlobalIndex(333 ether);
    _mockEmissionsPerVP(type(uint128).max);
    _mockLastGlobalSettlement(type(uint48).max);
    _mockChainStatus(_CHAIN_ID_2, IVoterCommon.ChainStatus.Suspended);
    _mockGlobalTimeIndex(555 ether);
    _mockChainLastTimeIndex(_CHAIN_ID_2, 666 ether);
    _mockDonatedBuffer(_CHAIN_ID_2, 777 ether);
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_2, true);
    _mockChainSlopeChange(_CHAIN_ID_2, 7 days, -123);
    _mockTotalSlopeChange(7 days, 456);
    _mockChainPoint(_CHAIN_ID_2, 789, 321, 3 days, 55 ether);
    _mockTotalPoint(789, 321, 3 days, 55 ether);

    // it should write mapping and set backed mock state
    _assertTokenState(_voter, _TOKEN_ID_2, 100 ether, 30 days, 12 hours);
    assertEq(_voter.allocationChainIds(_TOKEN_ID_2), _chainIds);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN_ID_2), 40 ether);
    assertTrue(_voter.hasRole(Roles.ADAPTER_CONFIG_ROLE, _ADAPTER_AUTHORITY));

    // it should write chain state fields
    IVoter.ChainState memory _state = _chainState(_voter, _CHAIN_ID_2);
    assertEq(_state.ceiling, 1000 ether);
    assertEq(_state.totalRedeemed, 111 ether);
    assertEq(_state.reportedSurplus, 222 ether);
    assertEq(_state.lastIndex, type(uint256).max);
    assertEq(uint8(_state.status), uint8(IVoterCommon.ChainStatus.Suspended));
    assertEq(_chainState(_voter, _CHAIN_ID_2).cumulativeSuspendedSurplus, 333 ether);
    assertEq(_chainState(_voter, _CHAIN_ID_2).surplusSpent, 444 ether);

    // it should write the global emissions accumulator state
    assertEq(_voter.index(), 333 ether);
    assertEq(_voter.timeIndex(), 555 ether);
    assertEq(_state.lastTimeIndex, 666 ether);
    assertEq(_voter.donatedBuffer(_CHAIN_ID_2), 777 ether);
    assertTrue(_voter.emergencyDeallocationAllowed(_CHAIN_ID_2));
    assertEq(_voter.emissionsPerVP(), type(uint128).max);
    assertEq(_voter.lastGlobalSettlement(), type(uint48).max);

    // it should write aggregate point and slope state
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_2, 7 days), -123);
    assertEq(_voter.totalSlopeChanges(7 days), 456);
    _assertChainPoint(_voter, _CHAIN_ID_2, 789, 321, 3 days, 55 ether);
    _assertTotalPoint(_voter, 789, 321, 3 days, 55 ether);
  }

  /// @dev Guard for the Voter's storage layout. Kept out of the Bulloak tree because it tests the storage
  ///      layout, not Voter behavior. `VoterStorageBase` declares the `VoterStorage` holder right after
  ///      `AccessControlEnumerable`'s two slots, so a base reorder, a variable declared before the holder, or
  ///      a struct-field reorder compiles clean and silently moves deployed state. `stdstore` locates each
  ///      real slot through the getter, so this pins the layout to compiler truth: any shift of the storage
  ///      section fails here first.
  function test_StorageLayoutWhenTheVoterStorageSectionAnchorsAtSlotTwo() external {
    // it should keep the value-type state variables at their VoterStorage field offsets from slot 2
    assertEq(stdstore.target(address(_voter)).sig('index()').find(), 2 + 9);
    assertEq(stdstore.target(address(_voter)).sig('timeIndex()').find(), 2 + 10);
    assertEq(stdstore.target(address(_voter)).sig('emissionsPerVP()').find(), 2 + 11);
    assertEq(stdstore.target(address(_voter)).sig('lastGlobalSettlement()').find(), 2 + 12);
  }

  /*////////////////////////////////////////////////////////////
      REDUCE COOLDOWN - REVERTS
  ////////////////////////////////////////////////////////////*/
  function test_ReduceCooldownWhenTheCallerIsNotWhitelistedVPM(
    address _caller,
    uint256 _tokenId,
    uint48 _reduction
  ) external {
    _assumeFuzzable(_caller);
    _mockAuthorizedVPM(_caller, false);

    vm.prank(_caller);
    // it should revert with NotVoterPaymentsModule
    vm.expectRevert(IVoter.NotVoterPaymentsModule.selector);
    _voter.reduceCooldown(_tokenId, _CHAIN_ID_1, _reduction, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_ReduceCooldownWhenTheReductionIsZero(uint256 _tokenId) external {
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);

    vm.prank(_AUTHORIZED_VPM);
    // it should revert with ZeroReduction
    vm.expectRevert(IVoter.ZeroReduction.selector);
    _voter.reduceCooldown(_tokenId, _CHAIN_ID_1, 0, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_ReduceCooldownWhenTheChainIsNotRegistered(uint256 _tokenId, uint48 _reduction) external {
    _reduction = uint48(bound(_reduction, 1, type(uint48).max));
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);

    vm.prank(_AUTHORIZED_VPM);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _UNREGISTERED_CHAIN_ID));
    _voter.reduceCooldown(_tokenId, _UNREGISTERED_CHAIN_ID, _reduction, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_ReduceCooldownWhenTheChainIsPausedOrSuspended(
    uint256 _tokenId,
    uint48 _reduction,
    bool _suspended
  ) external {
    _reduction = uint48(bound(_reduction, 1, type(uint48).max));
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);
    // Fuzz only `_suspended` — both blocked statuses (Paused / Suspended) hit the same revert.
    _mockChainStatus({
      _chainId: _CHAIN_ID_1, _status: _suspended ? IVoterCommon.ChainStatus.Suspended : IVoterCommon.ChainStatus.Paused
    });

    vm.prank(_AUTHORIZED_VPM);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _CHAIN_ID_1));
    _voter.reduceCooldown(_tokenId, _CHAIN_ID_1, _reduction, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_ReduceCooldownWhenTheChainIsSunset(uint256 _tokenId, uint48 _reduction, uint256 _value) external {
    // A sunset chain keeps reductions open so a holder deep in cooldown can land the exit vote.
    _reduction = uint48(bound(_reduction, 1, type(uint48).max));
    _value = bound(_value, 0, 100 ether);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);
    vm.deal(_AUTHORIZED_VPM, _value);

    // it should emit the CooldownReductionDispatched event
    _expectEmit(address(_voter));
    emit IVoter.CooldownReductionDispatched(_tokenId, _CHAIN_ID_1, _reduction);

    // it should dispatch one ReduceCooldown message forwarding the value
    _expectReduceCooldownDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _value: _value,
      _message: IVoterCommon.ReduceCooldownMessage({tokenId: _tokenId, reduction: _reduction})
    });

    vm.prank(_AUTHORIZED_VPM);
    _voter.reduceCooldown{value: _value}(_tokenId, _CHAIN_ID_1, _reduction, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_ReduceCooldownWhenTheDestinationGasLimitIsZeroForANonRootChain(
    uint256 _tokenId,
    uint48 _reduction
  ) external {
    _reduction = uint48(bound(_reduction, 1, type(uint48).max));
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);

    vm.prank(_AUTHORIZED_VPM);
    // it should revert with MissingDestinationGasLimit
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.reduceCooldown(_tokenId, _CHAIN_ID_1, _reduction, 0, _REFUND_RECIPIENT);
  }

  function test_ReduceCooldownWhenTheDestinationGasLimitIsZeroForTheLocalChain(
    uint256 _tokenId,
    uint48 _reduction
  ) external {
    // `block.chainid` is registered and Active in setUp. The root-colocated leaf is exempt from the
    // destination-gas-limit requirement: a zero gas limit must NOT revert and must still dispatch.
    _reduction = uint48(bound(_reduction, 1, type(uint48).max));
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);

    // it should emit the CooldownReductionDispatched event
    _expectEmit(address(_voter));
    emit IVoter.CooldownReductionDispatched(_tokenId, block.chainid, _reduction);

    // it should dispatch one ReduceCooldown message with zero gas limit to the local chain
    _expectReduceCooldownDispatch({
      _chainId: block.chainid,
      _gasLimit: 0,
      _value: 0,
      _message: IVoterCommon.ReduceCooldownMessage({tokenId: _tokenId, reduction: _reduction})
    });

    // it should not revert
    vm.prank(_AUTHORIZED_VPM);
    _voter.reduceCooldown(_tokenId, block.chainid, _reduction, 0, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
    REDUCE COOLDOWN - HAPPY PATH
  ////////////////////////////////////////////////////////////*/
  function test_ReduceCooldownWhenTheCallIsValid(uint256 _tokenId, uint48 _reduction, uint256 _value) external {
    _reduction = uint48(bound(_reduction, 1, type(uint48).max));
    _value = bound(_value, 0, 100 ether);
    _mockAuthorizedVPM(_AUTHORIZED_VPM, true);
    vm.deal(_AUTHORIZED_VPM, _value);

    // it should emit the CooldownReductionDispatched event
    _expectEmit(address(_voter));
    emit IVoter.CooldownReductionDispatched(_tokenId, _CHAIN_ID_1, _reduction);

    // it should dispatch one ReduceCooldown message forwarding the value
    _expectReduceCooldownDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _value: _value,
      _message: IVoterCommon.ReduceCooldownMessage({tokenId: _tokenId, reduction: _reduction})
    });

    vm.prank(_AUTHORIZED_VPM);
    _voter.reduceCooldown{value: _value}(_tokenId, _CHAIN_ID_1, _reduction, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
             DONATE
  ////////////////////////////////////////////////////////////*/
  function test_DonateWhenTheChainIsNotRegistered(uint256 _amount) external {
    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _UNREGISTERED_CHAIN_ID));
    _voter.donate(_UNREGISTERED_CHAIN_ID, _amount);
  }

  function test_DonateWhenTheAmountIsZero() external {
    // it should revert with ZeroAmount
    vm.expectRevert(IVoter.ZeroAmount.selector);
    _voter.donate(_CHAIN_ID_1, 0);
  }

  function test_DonateWhenTheDonationIsValid(uint256 _amount) external {
    _amount = bound(_amount, 1, type(uint256).max);

    // it should pull the amount from the caller
    _mockAndExpect(_TOKEN, abi.encodeCall(IERC20.transferFrom, (_CALLER, address(_voter), _amount)), abi.encode(true));

    // it should emit the Donated event
    _expectEmit(address(_voter));
    emit IVoter.Donated(_CHAIN_ID_1, _CALLER, _amount);

    vm.prank(_CALLER);
    _voter.donate(_CHAIN_ID_1, _amount);

    // it should increase the chain donated buffer by the amount
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _amount);
  }

  function test_DonateWhenDonationsAccrueAcrossCallsAndChains(
    uint256 _firstAmount,
    uint256 _secondAmount,
    uint256 _otherChainAmount
  ) external {
    // Two donations land on the first chain and one on the second, so their sums must not overflow.
    _firstAmount = bound(_firstAmount, 1, type(uint256).max / 2);
    _secondAmount = bound(_secondAmount, 1, type(uint256).max / 2);
    _otherChainAmount = bound(_otherChainAmount, 1, type(uint256).max);

    vm.mockCall(_TOKEN, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    vm.prank(_CALLER);
    _voter.donate(_CHAIN_ID_1, _firstAmount);
    vm.prank(_CALLER);
    _voter.donate(_CHAIN_ID_1, _secondAmount);
    vm.prank(_CALLER);
    _voter.donate(_CHAIN_ID_2, _otherChainAmount);

    // it should sum donations on the same chain
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _firstAmount + _secondAmount);
    // it should keep per chain buffers independent
    assertEq(_voter.donatedBuffer(_CHAIN_ID_2), _otherChainAmount);
  }

  function test_DonateWhenTheDonationTransferReverts(uint256 _existingBuffer, uint256 _amount) external {
    // The buffer credit lands before the pull, so a reverting pull must roll the credit back.
    _existingBuffer = bound(_existingBuffer, 0, type(uint256).max / 2);
    _amount = bound(_amount, 1, type(uint256).max / 2);
    _mockDonatedBuffer(_CHAIN_ID_1, _existingBuffer);

    vm.mockCallRevert(
      _TOKEN, abi.encodeCall(IERC20.transferFrom, (_CALLER, address(_voter), _amount)), 'transfer reverted'
    );

    // it should bubble the transfer revert
    vm.expectRevert(bytes('transfer reverted'));
    vm.prank(_CALLER);
    _voter.donate(_CHAIN_ID_1, _amount);

    // it should leave the chain donated buffer unchanged
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _existingBuffer);
  }

  /**
   * @notice Seed the pre-clear weight state for `test_ClearTokenWhenTheTokenWeightHasAlreadyDecayedOutOfThePoints`:
   *         a distinct non-zero point per chain, `totalPoint` at their exact sum, the global scalars, and
   *         `_TOKEN_ID`'s ledger booked on every chain.
   * @dev Each chain point gets a `+_i` offset on every field so a slot-routing bug cannot hide behind three
   *      identical points. `totalPoint` is the exact sum so the post-clear assertions re-check
   *      `Σ per-chain == totalPoint`.
   * @param _seed Bounded seed values.
   * @param _chainIds Chains to seed, in the order they enter the token's tracked set.
   * @return _total The `totalPoint` that was seeded.
   */
  function _seedClearTokenWeight(
    ClearTokenWeightSeed memory _seed,
    uint256[] memory _chainIds
  ) internal returns (IVoter.Point memory _total) {
    for (uint256 _i; _i < _chainIds.length; ++_i) {
      _mockChainPoint({
        _chainId: _chainIds[_i],
        _bias: int128(_seed.bias + uint128(_i)),
        _slope: int128(_seed.slope + uint128(_i)),
        _ts: _seed.ts + uint48(_i),
        _perm: _seed.perm + uint128(_i)
      });
      _total.bias += int128(_seed.bias + uint128(_i));
      _total.slope += int128(_seed.slope + uint128(_i));
      _total.permanentStakeBalance += _seed.perm + uint128(_i);

      _mockAllocationChainAmount(_TOKEN_ID, _chainIds[_i], _seed.booked);
    }
    // The total point resolves at the latest per-chain timestamp.
    _total.ts = _seed.ts + uint48(_chainIds.length - 1);

    _mockTotalPoint({_bias: _total.bias, _slope: _total.slope, _ts: _total.ts, _perm: _total.permanentStakeBalance});
    _mockEmissionsPerVP(_seed.emissionsPerVP);
    _mockGlobalIndex(_seed.index);
    _mockExistingChainIds(_TOKEN_ID, _chainIds);
    _mockTokenState({
      _tokenId: _TOKEN_ID,
      _committed: _seed.booked * uint128(_chainIds.length),
      _lastStakeEnd: _seed.ts,
      _lastAllocated: _seed.ts
    });
  }

  /**
   * @notice Assert every chain point and `totalPoint` still hold exactly what `_seedClearTokenWeight` wrote,
   *         and that `Σ per-chain == totalPoint` still holds.
   * @param _seed The same bounded seed the state was written from.
   * @param _chainIds Chains that were seeded.
   * @param _total The `totalPoint` that was seeded.
   */
  function _assertClearTokenWeightUnchanged(
    ClearTokenWeightSeed memory _seed,
    uint256[] memory _chainIds,
    IVoter.Point memory _total
  ) internal view {
    IVoter.Point memory _sum;
    for (uint256 _i; _i < _chainIds.length; ++_i) {
      _assertChainPoint({
        _target: _voter,
        _chainId: _chainIds[_i],
        _bias: int128(_seed.bias + uint128(_i)),
        _slope: int128(_seed.slope + uint128(_i)),
        _ts: _seed.ts + uint48(_i),
        _perm: _seed.perm + uint128(_i)
      });
      IVoter.Point memory _point = _chainState(_voter, _chainIds[_i]).point;
      _sum.bias += _point.bias;
      _sum.slope += _point.slope;
      _sum.permanentStakeBalance += _point.permanentStakeBalance;
    }

    _assertTotalPoint({
      _target: _voter, _bias: _total.bias, _slope: _total.slope, _ts: _total.ts, _perm: _total.permanentStakeBalance
    });
    // `Σ per-chain == totalPoint` still holds: neither side moved.
    assertEq(_sum.bias, _total.bias);
    assertEq(_sum.slope, _total.slope);
    assertEq(_sum.permanentStakeBalance, _total.permanentStakeBalance);
  }

  /// @notice Whether `_chainId` is currently in `_tokenId`'s tracked allocation set.
  function _containsChain(uint256 _tokenId, uint256 _chainId) internal view returns (bool) {
    uint256[] memory _ids = _voter.allocationChainIds(_tokenId);
    for (uint256 _i; _i < _ids.length; ++_i) {
      if (_ids[_i] == _chainId) return true;
    }
    return false;
  }
}
