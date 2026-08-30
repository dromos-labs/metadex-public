// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {stdError} from 'forge-std/StdError.sol';

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {LeafVoter} from 'V3/voter/LeafVoter.sol';

contract UnitLeafVoter is BaseLeafVoter {
  /// @dev Mirrors `LeafVoter.MIN_REDEEM_AMOUNT`.
  uint256 internal constant _MIN_REDEEM_AMOUNT = MAX_PIPS;
  /// @dev Maximum root scalar produced by a doubled capped base rate over one wei of voting power.
  uint256 internal constant _MAX_SAFE_EMISSIONS_PER_VP = 2 * 730_750_818_665_456_651_398_700_951_213 * 1e18;

  /*////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenTheGovernorIsTheZeroAddress(
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the governor.
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      address(0),
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheConfigAdminIsTheZeroAddress(
    address _governor,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the config admin.
    _governor = _excludingAddressZero(_governor);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      address(0),
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheLeafMessageOrchestratorIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      address(0),
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheReceiptTokenIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the receipt token.
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      address(0),
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheFactoryRegistryIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the registry.
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      address(0),
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheGaugeManagerIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the gauge manager.
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      address(0),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheAdapterAuthorityIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _emissionsHandler,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the adapter authority.
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      address(0),
      _emissionsHandler,
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheEmissionsHandlerIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emergencyCouncil
  ) external {
    // Pin the other inputs non-zero so the revert is attributable to the emissions handler.
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      address(0),
      _emergencyCouncil
    );
  }

  function test_ConstructorWhenTheEmergencyCouncilIsTheZeroAddress(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler
  ) external {
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);

    // it should revert with ZeroAddress
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAddress.selector));
    new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      address(0)
    );
  }

  function test_ConstructorWhenNoAddressIsZero(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil,
    uint48 _deployTimestamp
  ) external {
    _governor = _excludingAddressZero(_governor);
    _configAdmin = _excludingAddressZero(_configAdmin);
    _leafMessageOrchestrator = _excludingAddressZero(_leafMessageOrchestrator);
    _receiptToken = _excludingAddressZero(_receiptToken);
    _factoryRegistry = _excludingAddressZero(_factoryRegistry);
    _adapterAuthority = _excludingAddressZero(_adapterAuthority);
    _emissionsHandler = _excludingAddressZero(_emissionsHandler);
    _emergencyCouncil = _excludingAddressZero(_emergencyCouncil);

    vm.warp(_deployTimestamp);
    LeafVoter _voter = new LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      makeAddr('gaugeManager'),
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    );

    // it should grant the governance role to the governor
    assertTrue(_voter.hasRole(Roles.GOVERNANCE_ROLE, _governor));

    // it should grant the config admin role to the config admin
    assertTrue(_voter.hasRole(Roles.CONFIG_ADMIN_ROLE, _configAdmin));

    // it should grant the adapter config role to the adapter authority
    assertTrue(_voter.hasRole(Roles.ADAPTER_CONFIG_ROLE, _adapterAuthority));

    // it should make the governance role its own admin
    assertEq(_voter.getRoleAdmin(Roles.GOVERNANCE_ROLE), Roles.GOVERNANCE_ROLE);

    // it should make the governance role admin of the config admin role
    assertEq(_voter.getRoleAdmin(Roles.CONFIG_ADMIN_ROLE), Roles.GOVERNANCE_ROLE);

    // it should make the config admin role admin of every operational role
    {
      bytes32 _configAdminRole = Roles.CONFIG_ADMIN_ROLE;
      assertEq(_voter.getRoleAdmin(Roles.VOTER_CONFIG_ROLE), _configAdminRole);
      assertEq(_voter.getRoleAdmin(Roles.TOKEN_WHITELIST_ROLE), _configAdminRole);
      assertEq(_voter.getRoleAdmin(Roles.ADAPTER_CONFIG_ROLE), _configAdminRole);
      assertEq(_voter.getRoleAdmin(Roles.CHAIN_STATUS_ROLE), _configAdminRole);
      assertEq(_voter.getRoleAdmin(Roles.FACTORY_REGISTRY_ADMIN_ROLE), _configAdminRole);
      // GAS_CONFIGURER_ROLE must have a real admin, else the deallocation gas setters here and on the
      // orchestrator (which reads this role from the voter) are permanently uncallable.
      assertEq(_voter.getRoleAdmin(Roles.GAS_CONFIGURER_ROLE), _configAdminRole);
      // NATIVE_WITHDRAWER_ROLE must have a real admin, else the orchestrator's `withdrawNative` (which
      // reads this role from the voter) is permanently uncallable and its pre-funding can never be swept.
      assertEq(_voter.getRoleAdmin(Roles.NATIVE_WITHDRAWER_ROLE), _configAdminRole);
    }

    // it should make the governance role admin of the emergency council role
    assertEq(_voter.getRoleAdmin(Roles.EMERGENCY_COUNCIL_ROLE), Roles.GOVERNANCE_ROLE);

    // SEIZER_ROLE must have a real admin, else `TokenNFT.seize` (which reads this role from the voter) is
    // permanently uncallable and misleading metadata can never be seized.
    // it should make the governance role admin of the seizer role
    assertEq(_voter.getRoleAdmin(Roles.SEIZER_ROLE), Roles.GOVERNANCE_ROLE);

    // it should set the orchestrator handle to the leaf message orchestrator
    assertEq(address(_voter.ORCHESTRATOR()), _leafMessageOrchestrator);

    // it should set the receipt token
    assertEq(address(_voter.RECEIPT_TOKEN()), _receiptToken);

    // it should set the emissions handler
    assertEq(_voter.EMISSIONS_HANDLER(), _emissionsHandler);

    // it should grant the emergency council role to the emergency council
    assertTrue(_voter.hasRole(Roles.EMERGENCY_COUNCIL_ROLE, _emergencyCouncil));

    // it should set the factory registry
    assertEq(address(_voter.FACTORY_REGISTRY()), _factoryRegistry);

    // it should set the gauge manager
    assertEq(_voter.GAUGE_MANAGER(), makeAddr('gaugeManager'));

    // it should set the vote cooldown
    assertEq(_voter.allocationCooldown(), _allocationCooldown);

    // it should set the max gauges
    assertEq(_voter.maxGauges(), _maxGauges);

    // it should default the max accumulated cooldown reduction to zero
    assertEq(_voter.maxAccumulatedCooldownReduction(), 0);

    // it should default local voting to disabled
    assertFalse(_voter.localVotingEnabled());

    // Scoped so the tuple destructure does not add to the stack depth of the outer fuzzed frame.
    {
      // it should anchor the last settlement at the deployment timestamp
      assertEq(_voter.lastSettlement(), _deployTimestamp);

      (,, uint48 _zeroGaugeLastSettlement, bool _zeroGaugeIsRegistered,,,,, IVoterCommon.Point memory _zeroGaugePoint) =
        _voter.gaugeStates(_voter.ZERO_GAUGE());

      // it should seed the zero gauge settlement cursor
      assertEq(_zeroGaugeLastSettlement, _deployTimestamp);

      // it should seed the zero gauge point timestamp
      assertEq(_zeroGaugePoint.ts, _deployTimestamp);

      // it should register the zero gauge
      assertTrue(_zeroGaugeIsRegistered);
    }
  }

  /*////////////////////////////////////////////////////////////
                          MINT EMISSIONS
  ////////////////////////////////////////////////////////////*/
  modifier givenTheCallerIsAGauge() {
    _mockRegisterGauge(_GAUGE, false);
    vm.startPrank(_GAUGE);
    _;
    vm.stopPrank();
  }

  function test_MintEmissionsWhenTheChainStatusIsNeitherActiveNorSunset(uint8 _statusRaw) external {
    // Bound to Paused or Suspended; the settled entitlement stays claimable after resume and under Sunset.
    _statusRaw =
      uint8(bound(_statusRaw, uint8(IVoterCommon.ChainStatus.Paused), uint8(IVoterCommon.ChainStatus.Suspended)));
    _mockChainStatus(IVoterCommon.ChainStatus(_statusRaw));

    address[] memory _recipients = new address[](0);
    uint128[] memory _amounts = new uint128[](0);

    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(ILeafVoter.ChainNotActiveOrSunset.selector);
    _leafVoter.mintEmissions(_recipients, _amounts);
  }

  function test_MintEmissionsWhenTheCallerIsNotARegisteredGauge(address _caller) external {
    // ZERO_GAUGE (address zero) is excluded by _assumeFuzzable; it is the only address registered at
    // deployment. DEALLOC_GAUGE is a pure sentinel, never registered, so it reverts here like any
    // other unregistered address and needs no exclusion.
    _assumeFuzzable(_caller);

    address[] memory _recipients = new address[](0);
    uint128[] memory _amounts = new uint128[](0);

    // it should revert with GaugeNotRegistered
    vm.expectRevert(ILeafVoter.GaugeNotRegistered.selector);
    vm.prank(_caller);
    _leafVoter.mintEmissions(_recipients, _amounts);
  }

  function test_MintEmissionsWhenTheRecipientsAndAmountsLengthsDiffer(
    uint8 _recipientsLen,
    uint8 _amountsLen
  ) external givenTheCallerIsAGauge {
    _recipientsLen = uint8(bound(_recipientsLen, 0, 5));
    _amountsLen = uint8((_recipientsLen + bound(_amountsLen, 1, 5)) % 6);

    address[] memory _recipients = new address[](_recipientsLen);
    uint128[] memory _amounts = new uint128[](_amountsLen);

    // it should revert with ArrayLengthMismatch
    vm.expectRevert(ILeafVoter.ArrayLengthMismatch.selector);

    _leafVoter.mintEmissions(_recipients, _amounts);
  }

  modifier givenTheRecipientsAndAmountsLengthsMatch() {
    _;
  }

  function test_MintEmissionsWhenTheAmountToMintIsZero(
    uint8 _arrayLen,
    address _recipientSeed,
    uint256 _seededSurplus,
    uint128 _seededClaimed
  ) external givenTheCallerIsAGauge givenTheRecipientsAndAmountsLengthsMatch {
    _arrayLen = uint8(bound(_arrayLen, 1, 5));
    _seededSurplus = bound(_seededSurplus, 0, type(uint128).max);

    (address[] memory _recipients, uint128[] memory _amounts) = _buildRecipientsAmounts(_arrayLen, _recipientSeed, 0);

    _mockSurplusAccrued(_seededSurplus);

    // Seed a non-zero claimed so the no-change assertion is meaningful.
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_GAUGE);
    _state.ceiling = _seededClaimed;
    _state.claimed = _seededClaimed;
    _mockGaugeState(_GAUGE, _state);

    // it should not call mint on the receipt token
    vm.mockCallRevert(_RECEIPT_TOKEN, abi.encodeWithSelector(IReceiptToken.mint.selector), 'unexpected mint');

    // it should not call handleEmissions on the emissions handler
    vm.mockCallRevert(
      _EMISSIONS_HANDLER,
      abi.encodeWithSelector(IEmissionsHandler.handleEmissions.selector),
      'unexpected handleEmissions'
    );

    vm.recordLogs();

    _leafVoter.mintEmissions(_recipients, _amounts);

    // it should not emit the EmissionsMinted event
    assertEq(vm.getRecordedLogs().length, 0);

    // it should not change surplus accrued
    assertEq(_leafVoter.surplusAccrued(), _seededSurplus);

    // it should not change the gauge claimed amount
    assertEq(_gaugeStateOf(_GAUGE).claimed, _seededClaimed);
  }

  function test_MintEmissionsWhenTheAmountToMintExceedsTheClaimableHeadroom(
    uint8 _arrayLen,
    address _recipientSeed,
    uint256 _amountSeed,
    uint128 _seededClaimed,
    uint128 _seededSurplus,
    uint128 _deficit
  ) external givenTheCallerIsAGauge givenTheRecipientsAndAmountsLengthsMatch {
    _arrayLen = uint8(bound(_arrayLen, 1, 5));
    // Keep the parts of the ceiling within uint128 once summed.
    _amountSeed = bound(_amountSeed, 1, uint256(type(uint128).max) / 4 / _arrayLen);
    uint128 _amountToMint = uint128(_amountSeed * _arrayLen);
    _seededClaimed = uint128(bound(_seededClaimed, 0, uint256(type(uint128).max) / 4));
    _seededSurplus = uint128(bound(_seededSurplus, 0, uint256(type(uint128).max) / 4));
    // Set the headroom one to a full mint below the claim so the ceiling is exceeded.
    _deficit = uint128(bound(_deficit, 1, _amountToMint));
    uint128 _claimable = _amountToMint - _deficit;

    (address[] memory _recipients, uint128[] memory _amounts) =
      _buildRecipientsAmounts(_arrayLen, _recipientSeed, _amountSeed);

    // ceiling - claimed - surplus == _claimable < _amountToMint.
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_GAUGE);
    _state.ceiling = _seededClaimed + _seededSurplus + _claimable;
    _state.claimed = _seededClaimed;
    _state.surplus = _seededSurplus;
    _mockGaugeState(_GAUGE, _state);

    // it should revert with CeilingExceeded
    vm.expectRevert(ILeafVoter.CeilingExceeded.selector);

    _leafVoter.mintEmissions(_recipients, _amounts);
  }

  function test_MintEmissionsWhenTheAmountToMintIsPositiveAndWithinTheClaimableHeadroom(
    uint8 _arrayLen,
    address _recipientSeed,
    uint256 _amountSeed,
    uint256 _seededSurplusAccrued,
    uint128 _seededClaimed,
    uint128 _seededSurplus,
    uint128 _extraHeadroom
  ) external givenTheCallerIsAGauge givenTheRecipientsAndAmountsLengthsMatch {
    _arrayLen = uint8(bound(_arrayLen, 1, 5));
    // Keep the parts of the ceiling within uint128 once summed.
    _amountSeed = bound(_amountSeed, 1, uint256(type(uint128).max) / 4 / _arrayLen);
    uint128 _amountToMint = uint128(_amountSeed * _arrayLen);
    _seededClaimed = uint128(bound(_seededClaimed, 0, uint256(type(uint128).max) / 4));
    _seededSurplus = uint128(bound(_seededSurplus, 0, uint256(type(uint128).max) / 4));
    _extraHeadroom = uint128(bound(_extraHeadroom, 0, uint256(type(uint128).max) / 4));

    (address[] memory _recipients, uint128[] memory _amounts) =
      _buildRecipientsAmounts(_arrayLen, _recipientSeed, _amountSeed);

    _mockSurplusAccrued(_seededSurplusAccrued);

    // ceiling - claimed - surplus == _amountToMint + _extraHeadroom >= _amountToMint.
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_GAUGE);
    _state.ceiling = _seededClaimed + _seededSurplus + _amountToMint + _extraHeadroom;
    _state.claimed = _seededClaimed;
    _state.surplus = _seededSurplus;
    _mockGaugeState(_GAUGE, _state);

    // it should emit EmissionsMinted with msg.sender, _recipients and _amounts
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmissionsMinted(_GAUGE, _recipients, _amounts);

    // it should call mint on the receipt token with the handler and the amount to mint
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IReceiptToken.mint, (_EMISSIONS_HANDLER, uint256(_amountToMint))), '');

    // it should call handleEmissions on the emissions handler
    _mockAndExpect(_EMISSIONS_HANDLER, abi.encodeCall(IEmissionsHandler.handleEmissions, (_recipients, _amounts)), '');

    _leafVoter.mintEmissions(_recipients, _amounts);

    // it should not change surplus accrued
    assertEq(_leafVoter.surplusAccrued(), _seededSurplusAccrued);

    // it should increase the gauge claimed amount by the amount to mint
    assertEq(_gaugeStateOf(_GAUGE).claimed, _seededClaimed + _amountToMint);
  }

  function test_MintEmissionsWhenTheChainStatusIsSunsetAndTheAmountIsWithinTheClaimableHeadroom(
    uint8 _arrayLen,
    address _recipientSeed,
    uint256 _amountSeed,
    uint128 _seededClaimed,
    uint128 _seededSurplus,
    uint128 _extraHeadroom
  ) external givenTheCallerIsAGauge givenTheRecipientsAndAmountsLengthsMatch {
    // Sunset keeps the exit paths open: emissions earned before the wind-down stay claimable.
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);

    _arrayLen = uint8(bound(_arrayLen, 1, 5));
    // Keep the parts of the ceiling within uint128 once summed.
    _amountSeed = bound(_amountSeed, 1, uint256(type(uint128).max) / 4 / _arrayLen);
    uint128 _amountToMint = uint128(_amountSeed * _arrayLen);
    _seededClaimed = uint128(bound(_seededClaimed, 0, uint256(type(uint128).max) / 4));
    _seededSurplus = uint128(bound(_seededSurplus, 0, uint256(type(uint128).max) / 4));
    _extraHeadroom = uint128(bound(_extraHeadroom, 0, uint256(type(uint128).max) / 4));

    (address[] memory _recipients, uint128[] memory _amounts) =
      _buildRecipientsAmounts(_arrayLen, _recipientSeed, _amountSeed);

    // ceiling - claimed - surplus == _amountToMint + _extraHeadroom >= _amountToMint.
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_GAUGE);
    _state.ceiling = _seededClaimed + _seededSurplus + _amountToMint + _extraHeadroom;
    _state.claimed = _seededClaimed;
    _state.surplus = _seededSurplus;
    _mockGaugeState(_GAUGE, _state);

    // it should emit EmissionsMinted with msg.sender, _recipients and _amounts
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmissionsMinted(_GAUGE, _recipients, _amounts);

    // it should call mint on the receipt token with the handler and the amount to mint
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IReceiptToken.mint, (_EMISSIONS_HANDLER, uint256(_amountToMint))), '');

    _mockAndExpect(_EMISSIONS_HANDLER, abi.encodeCall(IEmissionsHandler.handleEmissions, (_recipients, _amounts)), '');

    _leafVoter.mintEmissions(_recipients, _amounts);

    // it should increase the gauge claimed amount by the amount to mint
    assertEq(_gaugeStateOf(_GAUGE).claimed, _seededClaimed + _amountToMint);
  }

  /*////////////////////////////////////////////////////////////
                          SET OPERATOR
  ////////////////////////////////////////////////////////////*/
  function test_SetOperatorWhenTheCallerIsNotTheLeafMessageOrchestrator(address _caller) external {
    _caller = _boundNotEq(_caller, _LEAF_MESSAGE_ORCHESTRATOR);

    // it should revert with NotMessageOrchestrator
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.NotMessageOrchestrator.selector));
    _leafVoter.setOperator(1, address(0xdeadbeef));
  }

  function test_SetOperatorWhenTheCallerIsTheLeafMessageOrchestrator(uint256 _tokenId, address _operator) external {
    // it should emit the OperatorSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.OperatorSet(_tokenId, _operator);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.setOperator(_tokenId, _operator);

    // it should set the operator for the tokenId
    assertEq(_operatorOf(_tokenId), _operator);
  }

  /*////////////////////////////////////////////////////////////
                      APPLY COOLDOWN REDUCTION
  ////////////////////////////////////////////////////////////*/
  function test_ApplyCooldownReductionWhenTheCallerIsNotTheLeafMessageOrchestrator(
    address _caller,
    uint256 _tokenId,
    uint48 _reduction
  ) external {
    _caller = _boundNotEq(_caller, _LEAF_MESSAGE_ORCHESTRATOR);

    // it should revert with NotMessageOrchestrator
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.NotMessageOrchestrator.selector));
    _leafVoter.applyCooldownReduction(_tokenId, _reduction);
  }

  function test_ApplyCooldownReductionWhenThereIsNoPriorAccumulatedReduction(
    uint256 _tokenId,
    uint48 _reduction
  ) external {
    // The zero default disables accrual, so open the cap fully for the plain accrual path.
    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxAccumulatedCooldownReduction(type(uint48).max);

    // it should emit the CooldownReductionApplied event with the new accumulated total equal to the reduction
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.CooldownReductionApplied(_tokenId, _reduction, _reduction);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyCooldownReduction(_tokenId, _reduction);

    // it should accrue the reduction onto the accumulated balance
    assertEq(_leafVoter.accumulatedCooldownReduction(_tokenId), _reduction);
  }

  function test_ApplyCooldownReductionWhenAPriorReductionIsAlreadyAccumulated(
    uint256 _tokenId,
    uint48 _prior,
    uint48 _reduction
  ) external {
    // Bound so the sum stays within uint48 and under the fully-open cap.
    _prior = uint48(bound(_prior, 1, type(uint48).max - 1));
    _reduction = uint48(bound(_reduction, 1, type(uint48).max - _prior));
    uint48 _expectedAccumulated = _prior + _reduction;

    // The zero default disables accrual, so open the cap fully for the additive path.
    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxAccumulatedCooldownReduction(type(uint48).max);

    // Seed the prior accumulated balance directly rather than calling the function twice, keeping the
    // accrual path isolated.
    _mockAccumulatedCooldownReduction(_tokenId, _prior);

    // it should emit the CooldownReductionApplied event with the summed accumulated total
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.CooldownReductionApplied(_tokenId, _reduction, _expectedAccumulated);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyCooldownReduction(_tokenId, _reduction);

    // it should accrue additively onto the prior accumulated balance
    assertEq(_leafVoter.accumulatedCooldownReduction(_tokenId), _expectedAccumulated);
  }

  function test_ApplyCooldownReductionWhenTheAccruedReductionExceedsTheMaxAccumulatedCooldownReduction(
    uint256 _tokenId,
    uint48 _max,
    uint48 _prior,
    uint48 _reduction
  ) external {
    // Cap below the ceiling so an excess accrual is always constructible; the accrual runs in uint256,
    // so even `prior + reduction` past the uint48 ceiling clamps instead of reverting.
    _max = uint48(bound(_max, 0, type(uint48).max - 1));
    _prior = uint48(bound(_prior, 0, _max));
    _reduction = uint48(bound(_reduction, _max - _prior + 1, type(uint48).max));

    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxAccumulatedCooldownReduction(_max);
    _mockAccumulatedCooldownReduction(_tokenId, _prior);

    // it should emit the CooldownReductionApplied event with the clamped accumulated total
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.CooldownReductionApplied(_tokenId, _reduction, _max);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyCooldownReduction(_tokenId, _reduction);

    // it should clamp the accumulated balance at the max accumulated cooldown reduction
    assertEq(_leafVoter.accumulatedCooldownReduction(_tokenId), _max);
  }

  /*////////////////////////////////////////////////////////////
                            OPERATOR
  ////////////////////////////////////////////////////////////*/
  function test_OperatorWhenAnOperatorIsSetForTheTokenId(uint256 _tokenId, address _operator) external {
    // Exclude zero so the stored value is distinguishable from the unset default.
    _operator = _excludingAddressZero(_operator);

    // Seed the operator into the low 160 bits of the tokenId's packed TokenState slot.
    bytes32 _slot = keccak256(abi.encode(_tokenId, _TOKEN_STATE_SLOT));
    vm.store(address(_leafVoter), _slot, bytes32(uint256(uint160(_operator))));

    // it should return the stored operator
    assertEq(_leafVoter.operator(_tokenId), _operator);
  }

  function test_OperatorWhenNoOperatorIsSetForTheTokenId(uint256 _tokenId) external {
    // it should return the zero address
    assertEq(_leafVoter.operator(_tokenId), address(0));
  }

  /*////////////////////////////////////////////////////////////
                            IS ACTIVATED
  ////////////////////////////////////////////////////////////*/
  function test_IsActivatedWhenTheGaugeIsRegisteredAndActivated(address _gauge) external {
    _mockRegisterGauge(_gauge, true);
    // it should return true
    assertTrue(_leafVoter.isActivated(_gauge));
  }

  function test_IsActivatedWhenTheGaugeIsRegisteredButNotActivated(address _gauge) external {
    _mockRegisterGauge(_gauge, false);
    // it should return false
    assertFalse(_leafVoter.isActivated(_gauge));
  }

  function test_IsActivatedWhenTheGaugeIsNotRegistered(address _gauge) external view {
    // it should return false
    assertFalse(_leafVoter.isActivated(_gauge));
  }

  /*////////////////////////////////////////////////////////////
                       SET WHITELISTED TOKEN
  ////////////////////////////////////////////////////////////*/
  function test_SetCanVoteForZeroCapGaugesWhenTheCallerDoesNotHoldTheTokenWhitelistRole(address _caller) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _TOKEN_WHITELIST);

    bytes32 _role = Roles.TOKEN_WHITELIST_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _leafVoter.setCanVoteForZeroCapGauges(1, true);
  }

  function test_SetCanVoteForZeroCapGaugesWhenTheCallerHoldsTheTokenWhitelistRole(
    uint256 _tokenId,
    bool _allowed
  ) external {
    // it should emit the CanVoteForZeroCapGaugesSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.CanVoteForZeroCapGaugesSet(_tokenId, _allowed);

    vm.prank(_TOKEN_WHITELIST);
    _leafVoter.setCanVoteForZeroCapGauges(_tokenId, _allowed);

    // it should set the can vote for zero cap gauges flag for the tokenId
    assertEq(_canVoteForZeroCapGaugesOf(_tokenId), _allowed);
  }

  /*////////////////////////////////////////////////////////////
                     SET LOCAL VOTING ENABLED
  ////////////////////////////////////////////////////////////*/
  function test_SetLocalVotingEnabledWhenTheCallerDoesNotHoldTheVoterConfigRole(
    address _caller,
    bool _enabled
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _VOTER_CONFIG);

    bytes32 _role = Roles.VOTER_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _leafVoter.setLocalVotingEnabled(_enabled);
  }

  function test_SetLocalVotingEnabledWhenTheCallerHoldsTheVoterConfigRoleAndOpensLocalVoting() external {
    // it should emit the LocalVotingEnabledSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.LocalVotingEnabledSet(true);

    vm.prank(_VOTER_CONFIG);
    _leafVoter.setLocalVotingEnabled(true);

    // it should set local voting to enabled
    assertTrue(_leafVoter.localVotingEnabled());
  }

  function test_SetLocalVotingEnabledWhenTheCallerHoldsTheVoterConfigRoleAndClosesLocalVoting() external {
    // Seed the switch open directly in storage so the close is exercised without calling the setter twice.
    _mockLocalVotingEnabled(true);

    // it should emit the LocalVotingEnabledSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.LocalVotingEnabledSet(false);

    vm.prank(_VOTER_CONFIG);
    _leafVoter.setLocalVotingEnabled(false);

    // it should set local voting to disabled
    assertFalse(_leafVoter.localVotingEnabled());
  }

  /*////////////////////////////////////////////////////////////
                        SET VOTE COOLDOWN
  ////////////////////////////////////////////////////////////*/
  function test_SetAllocationCooldownWhenTheCallerDoesNotHoldTheVoterConfigRole(address _caller) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _VOTER_CONFIG);

    bytes32 _role = Roles.VOTER_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _leafVoter.setAllocationCooldown(1 days);
  }

  function test_SetAllocationCooldownWhenTheCallerHoldsTheVoterConfigRole(uint48 _allocationCooldown) external {
    // it should emit the AllocationCooldownSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.AllocationCooldownSet(_allocationCooldown);

    vm.prank(_VOTER_CONFIG);
    _leafVoter.setAllocationCooldown(_allocationCooldown);

    // it should set the vote cooldown
    assertEq(_leafVoter.allocationCooldown(), _allocationCooldown);
  }

  /*////////////////////////////////////////////////////////////
                   SET MAX COOLDOWN REDUCTION
  ////////////////////////////////////////////////////////////*/
  function test_SetMaxAccumulatedCooldownReductionWhenTheCallerDoesNotHoldTheVoterConfigRole(
    address _caller,
    uint48 _maxAccumulatedCooldownReduction
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _VOTER_CONFIG);

    bytes32 _role = Roles.VOTER_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _leafVoter.setMaxAccumulatedCooldownReduction(_maxAccumulatedCooldownReduction);
  }

  function test_SetMaxAccumulatedCooldownReductionWhenTheCallerHoldsTheVoterConfigRole(uint48 _maxAccumulatedCooldownReduction)
    external
  {
    // it should emit MaxAccumulatedCooldownReductionSet with the new value
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.MaxAccumulatedCooldownReductionSet(_maxAccumulatedCooldownReduction);

    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxAccumulatedCooldownReduction(_maxAccumulatedCooldownReduction);

    // it should set the max cooldown reduction to the new value
    assertEq(_leafVoter.maxAccumulatedCooldownReduction(), _maxAccumulatedCooldownReduction);
  }

  /*////////////////////////////////////////////////////////////
                          SET MAX GAUGES
  ////////////////////////////////////////////////////////////*/
  function test_SetMaxGaugesWhenTheCallerDoesNotHoldTheVoterConfigRole(address _caller, uint256 _maxGauges) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _VOTER_CONFIG);

    bytes32 _role = Roles.VOTER_CONFIG_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _leafVoter.setMaxGauges(_maxGauges);
  }

  function test_SetMaxGaugesWhenTheCallerHoldsTheVoterConfigRole(uint256 _maxGauges) external {
    // it should emit MaxGaugesSet with the new value
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.MaxGaugesSet(_maxGauges);

    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxGauges(_maxGauges);

    // it should set max gauges to the new value
    assertEq(_leafVoter.maxGauges(), _maxGauges);
  }

  function test_SetMaxGaugesWhenMaxGaugesIsLoweredBelowATokensCurrentAllocationListSize(uint256 _maxGauges) external {
    uint256 _tokenId = 1;
    address _operator = makeAddr('operator');
    // Keep the array small; the length check trips before any contents are read.
    _maxGauges = bound(_maxGauges, 0, 10);

    // Open the local voting switch, authorize the operator and seed a usable snapshot so the maxGauges
    // length check is the assertion that trips (not the earlier switch or live-snapshot guards).
    _mockLocalVotingEnabled(true);
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.setOperator(_tokenId, _operator);
    _mockTokenSnapshot({_tokenId: _tokenId, _staked: _MAX_AMOUNT, _stakeEnd: 0});

    // Lower the cap below the incoming allocation-list length.
    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxGauges(_maxGauges);
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](_maxGauges + 1);

    // it should revert the next vote with ExceedsMaxGauges
    vm.prank(_operator);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ExceedsMaxGauges.selector));
    _leafVoter.allocateGauges(_tokenId, _allocations);
  }

  /*////////////////////////////////////////////////////////////
                        SET CHAIN STATUS
  ////////////////////////////////////////////////////////////*/
  function test_SetChainStatusWhenTheCallerDoesNotHoldTheChainStatusRole(address _caller, uint8 _statusRaw) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, _CHAIN_STATUS);
    _statusRaw = uint8(bound(_statusRaw, 0, uint8(type(IVoterCommon.ChainStatus).max)));

    bytes32 _role = Roles.CHAIN_STATUS_ROLE;
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _role));
    vm.prank(_caller);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus(_statusRaw));
  }

  function test_SetChainStatusWhenTheTargetStatusIsNone() external {
    // The None guard is the first check, so no status mock is needed.
    // it should revert with InvalidStatus
    vm.expectRevert(IVoterCommon.InvalidStatus.selector);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.None);
  }

  function test_SetChainStatusWhenTheNewStatusMatchesTheCurrentStatus() external {
    // The chain deploys with the default `Active` status.
    // it should revert with ChainStatusUnchanged
    vm.expectRevert(IVoterCommon.ChainStatusUnchanged.selector);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Active);
  }

  function test_SetChainStatusWhenFlippingFromSuspendedToPaused() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);

    // it should revert with InvalidChainStatusTransition
    vm.expectRevert(IVoterCommon.InvalidChainStatusTransition.selector);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Paused);
  }

  function test_SetChainStatusWhenFlippingFromSuspendedToSunset() external {
    // Same matrix as root: Sunset keeps the rate parked at zero, so the wind-down flips directly without
    // reopening allocations through an Active hop.
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);

    // The suspend flip parked emissions per VP at zero and every suspended-state write keeps it there,
    // so the flip's settle walks the suspended window but accrues nothing.
    _mockChainAccumulator({_emissionsPerVP: 0, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Sunset);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Sunset);

    // it should leave the index flat across the suspended window
    assertEq(_leafVoter.index(), 1e18);
    // it should advance the last settlement to the flip timestamp
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should keep emissions per VP at zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Sunset));
  }

  function test_SetChainStatusWhenFlippingFromSunsetToPaused() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);

    // it should revert with InvalidChainStatusTransition
    vm.expectRevert(IVoterCommon.InvalidChainStatusTransition.selector);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Paused);
  }

  function test_SetChainStatusWhenFlippingFromSunsetToActive() external {
    // A reactivation must route through Suspended so the in-flight deallocation set drains first; the
    // direct resume is blocked.
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);

    // it should revert with InvalidChainStatusTransition
    vm.expectRevert(IVoterCommon.InvalidChainStatusTransition.selector);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Active);
  }

  function test_SetChainStatusWhenFlippingFromSunsetToSuspended() external {
    // The lone exit: the kill switch for a compromised or unreachable sunset chain and the first leg of
    // a reactivation.
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);
    _mockChainAccumulator({_emissionsPerVP: 0, _index: 1e18});

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Suspended);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Suspended);

    // it should keep emissions per VP at zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Suspended));
  }

  function test_SetChainStatusWhenFlippingFromSuspendedToActive() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);

    // The suspend flip parked emissions per VP at zero and every suspended-state write keeps it
    // there, so the only reachable suspended state carries a zero scalar: the resume settle walks
    // the window but accrues nothing.
    _mockChainAccumulator({_emissionsPerVP: 0, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Active);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Active);

    // it should leave the index flat across the suspended window
    assertEq(_leafVoter.index(), 1e18);
    // it should advance the last settlement to the flip timestamp
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should leave the chain rate at zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Active));
  }

  function test_SetChainStatusWhenFlippingFromActiveToPaused() external {
    // Active is the seeded default; no status mock needed.
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Paused);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Paused);

    // it should settle the index up to the flip timestamp
    assertEq(_leafVoter.index(), 1e18 + 200e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should leave emissions per VP unchanged
    assertEq(_leafVoter.emissionsPerVP(), 2e18);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Paused));
  }

  function test_SetChainStatusWhenSettlingAtTheMaximumSafeScalarNearTheTimestampHorizon() external {
    uint48 _finalBoundary = (type(uint48).max / _WEEK) * _WEEK;
    uint48 _to = _finalBoundary - 1;
    uint48 _from = _to - 1;
    uint256 _indexBefore = _MAX_SAFE_EMISSIONS_PER_VP * _from;
    uint256 _timeIndexBefore = _MAX_SAFE_EMISSIONS_PER_VP * uint256(_from) * _from;

    _mockChainAccumulator({_emissionsPerVP: _MAX_SAFE_EMISSIONS_PER_VP, _index: _indexBefore});
    _mockChainTimeIndex(_timeIndexBefore);
    _mockChainSettlement(_from);
    vm.warp(_to);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Paused);

    // it should advance the index without overflowing
    assertEq(_leafVoter.index(), _MAX_SAFE_EMISSIONS_PER_VP * _to);
    // it should advance the time index without overflowing
    assertEq(_leafVoter.timeIndex(), _MAX_SAFE_EMISSIONS_PER_VP * uint256(_to) * _to);
    // it should preserve the maximum safe emissions per voting power
    assertEq(_leafVoter.emissionsPerVP(), _MAX_SAFE_EMISSIONS_PER_VP);
    // it should advance the last settlement to the target timestamp
    assertEq(_leafVoter.lastSettlement(), _to);
  }

  function test_SetChainStatusWhenTheNewStatusIsSuspendedAndTheLastSettlementIsBeforeTheFlipTimestamp() external {
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Suspended);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Suspended);

    // it should settle the index at the old rate up to the flip timestamp
    assertEq(_leafVoter.index(), 1e18 + 200e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should zero emissions per VP
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Suspended));
  }

  function test_SetChainStatusWhenTheNewStatusIsSuspendedAndTheLastSettlementIsAtOrAfterTheFlipTimestamp() external {
    // A root message already advanced lastSettlement to a future settlement, so the flip's
    // _settleIndex(block.timestamp) is a no-op: index and lastSettlement stay put while the rate is still
    // zeroed and the status flips. Pins the documented max(flip, lastSettlement) suspend boundary.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    _mockChainSettlement(_SEED_TIMESTAMP + 200);
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Suspended);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Suspended);

    // it should leave the index and last settlement unchanged
    assertEq(_leafVoter.index(), 1e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 200);
    // it should zero emissions per VP
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Suspended));
  }

  function test_SetChainStatusWhenTheNewStatusIsSunset() external {
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Sunset);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Sunset);

    // it should settle the index at the old rate up to the flip timestamp
    assertEq(_leafVoter.index(), 1e18 + 200e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should zero emissions per VP
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Sunset));
  }

  function test_SetChainStatusWhenFlippingFromPausedToActive() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Paused);

    // A pause never parks emissions per VP, so a non-zero scalar is reachable under Paused.
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Active);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Active);

    // it should settle the index up to the flip timestamp
    assertEq(_leafVoter.index(), 1e18 + 200e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should leave emissions per VP unchanged
    assertEq(_leafVoter.emissionsPerVP(), 2e18);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Active));
  }

  function test_SetChainStatusWhenFlippingFromPausedToSuspended() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Paused);

    // A pause never parks emissions per VP, so the suspend flip must zero it from a non-zero seed.
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Suspended);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Suspended);

    // it should settle the index at the old rate up to the flip timestamp
    assertEq(_leafVoter.index(), 1e18 + 200e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should zero emissions per VP
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Suspended));
  }

  function test_SetChainStatusWhenFlippingFromPausedToSunset() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Paused);

    // A pause never parks emissions per VP, so the sunset flip must zero it from a non-zero seed.
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    // it should emit the ChainStatusSet event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainStatusSet(IVoterCommon.ChainStatus.Sunset);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Sunset);

    // it should settle the index at the old rate up to the flip timestamp
    assertEq(_leafVoter.index(), 1e18 + 200e18);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 100);
    // it should zero emissions per VP
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should set the chain status
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Sunset));
  }

  function test_SetChainStatusWhenRunningAFullSuspendMessageResumeSequence() external {
    // Hand-computed settle: 2e18 emissions per VP over 100 seconds adds 200e18 to the index before
    // the suspend flip parks emissions per VP at zero.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Suspended);

    uint256 _indexAtSuspend = _leafVoter.index();
    assertEq(_indexAtSuspend, 1e18 + 200e18);

    // Root keeps dispatching while suspended so the mirror self-repairs; the setter's mask parks
    // the applied scalar at zero even though the payload carries a positive emissions per VP.
    vm.warp(_SEED_TIMESTAMP + 200);
    IVoterCommon.TokenSnapshot memory _snapshot =
      IVoterCommon.TokenSnapshot({staked: 0, stakeEnd: 0, isPermanent: (0) == 0});
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: 0,
      _emissionsPerVP: 2e18,
      _refreshEmissionsPerVP: true,
      _refreshShape: true,
      _snapshot: _snapshot
    });

    // it should keep emissions per VP at zero across the suspended window
    assertEq(_leafVoter.emissionsPerVP(), 0);

    vm.warp(_SEED_TIMESTAMP + 300);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Active);

    // it should leave the index flat from the suspend flip to the resume flip
    assertEq(_leafVoter.index(), _indexAtSuspend);
    // it should advance the last settlement to the resume timestamp
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP + 300);
    // it should set the chain status back to Active
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Active));
  }

  function test_SetChainStatusWhenAChainAllocationRefreshesTheScalarWhileSunset() external {
    // Enter Sunset through the real flip so the stored status and the setter's mask agree.
    _mockChainAccumulator({_emissionsPerVP: 2e18, _index: 1e18});
    vm.warp(_SEED_TIMESTAMP + 100);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Sunset);

    // Root stops dispatching to a sunset chain, but an in-flight message can still land after the flip
    // carrying a positive scalar; the setter's mask must hold forever, not just until a resume.
    vm.warp(_SEED_TIMESTAMP + 200);
    IVoterCommon.TokenSnapshot memory _snapshot =
      IVoterCommon.TokenSnapshot({staked: 0, stakeEnd: 0, isPermanent: (0) == 0});
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: 0,
      _emissionsPerVP: 2e18,
      _refreshEmissionsPerVP: true,
      _refreshShape: true,
      _snapshot: _snapshot
    });

    // it should keep emissions per VP at zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
  }

  /*////////////////////////////////////////////////////////////
                        FORFEIT EMISSIONS
  ////////////////////////////////////////////////////////////*/
  function test_ForfeitEmissionsWhenTheCallerIsNotARegisteredGauge(address _caller, uint128 _amount) external {
    // ZERO_GAUGE (address zero) is the only address registered at deployment. DEALLOC_GAUGE is a pure
    // sentinel, never registered, so it reverts here like any other unregistered address.
    _caller = _excludingAddressZero(_caller);

    // it should revert with GaugeNotRegistered
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.GaugeNotRegistered.selector));
    _leafVoter.forfeitEmissions(_amount);
  }

  function test_ForfeitEmissionsWhenTheCallerIsARegisteredGaugeAndTheReportedAmountIsWithinTheClaimableHeadroom(
    uint128 _claimed,
    uint128 _priorSurplus,
    uint128 _headroom,
    uint128 _amount,
    uint256 _priorAccrued
  ) external {
    _claimed = uint128(bound(_claimed, 0, _MAX_AMOUNT));
    _priorSurplus = uint128(bound(_priorSurplus, 0, _MAX_AMOUNT));
    _headroom = uint128(bound(_headroom, 1, _MAX_AMOUNT));
    // A reported amount at or below the headroom accrues in full.
    _amount = uint128(bound(_amount, 0, _headroom));
    _priorAccrued = bound(_priorAccrued, 0, _MAX_AMOUNT);

    // ceiling - claimed - surplus == headroom.
    uint128 _ceiling = _claimed + _priorSurplus + _headroom;
    _mockGaugeState(_GAUGE_A, _buildGaugeState(_ceiling, _claimed, 0, true, _priorSurplus, 0, _buildPoint(0, 0, 0, 0)));
    _mockSurplusAccrued(_priorAccrued);

    // it should emit EmissionsForfeited with the reported amount
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmissionsForfeited(_GAUGE_A, _amount);

    vm.prank(_GAUGE_A);
    _leafVoter.forfeitEmissions(_amount);

    // it should add the full amount to the gauge surplus
    assertEq(_gaugeSurplus(_GAUGE_A), _priorSurplus + _amount);
    // it should add the full amount to the surplus accrued accumulator
    assertEq(_leafVoter.surplusAccrued(), _priorAccrued + _amount);
  }

  function test_ForfeitEmissionsWhenTheCallerIsARegisteredGaugeAndTheReportedAmountExceedsTheClaimableHeadroom(
    uint128 _claimed,
    uint128 _priorSurplus,
    uint128 _headroom,
    uint128 _excess,
    uint256 _priorAccrued
  ) external {
    _claimed = uint128(bound(_claimed, 0, _MAX_AMOUNT));
    _priorSurplus = uint128(bound(_priorSurplus, 0, _MAX_AMOUNT));
    _headroom = uint128(bound(_headroom, 0, _MAX_AMOUNT));
    // Report strictly above the headroom so the clamp engages.
    _excess = uint128(bound(_excess, 1, _MAX_AMOUNT));
    _priorAccrued = bound(_priorAccrued, 0, _MAX_AMOUNT);

    uint128 _ceiling = _claimed + _priorSurplus + _headroom;
    _mockGaugeState(_GAUGE_A, _buildGaugeState(_ceiling, _claimed, 0, true, _priorSurplus, 0, _buildPoint(0, 0, 0, 0)));
    _mockSurplusAccrued(_priorAccrued);

    uint128 _amount = _headroom + _excess;

    // it should clamp the amount to the claimable headroom
    // it should emit EmissionsForfeited with the clamped amount
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmissionsForfeited(_GAUGE_A, _headroom);

    vm.prank(_GAUGE_A);
    _leafVoter.forfeitEmissions(_amount);

    // it should add the clamped amount to the gauge surplus
    assertEq(_gaugeSurplus(_GAUGE_A), _priorSurplus + _headroom);
    // it should add the clamped amount to the surplus accrued accumulator
    assertEq(_leafVoter.surplusAccrued(), _priorAccrued + _headroom);
  }

  /*////////////////////////////////////////////////////////////
                             REDEEM
  ////////////////////////////////////////////////////////////*/
  function test_RedeemWhenTheChainStatusIsNeitherActiveNorSunset(
    uint256 _amount,
    address _recipient,
    uint256 _gasLimit,
    address _refundRecipient,
    uint8 _statusRaw
  ) external {
    // Bound to Paused or Suspended, the two statuses that close the exit paths.
    _statusRaw =
      uint8(bound(_statusRaw, uint8(IVoterCommon.ChainStatus.Paused), uint8(IVoterCommon.ChainStatus.Suspended)));
    _mockChainStatus(IVoterCommon.ChainStatus(_statusRaw));

    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(ILeafVoter.ChainNotActiveOrSunset.selector);
    _leafVoter.redeem(_amount, _recipient, _gasLimit, _refundRecipient);
  }

  function test_RedeemWhenTheChainStatusIsSunsetAndTheRedeemInputsAreValid(
    address _caller,
    uint256 _amount,
    address _recipient,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _surplusAccrued,
    uint256 _value
  ) external {
    // Sunset keeps the exit paths open: receipt tokens earned before the wind-down stay redeemable.
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);

    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, _MIN_REDEEM_AMOUNT, type(uint256).max);
    _value = bound(_value, 0, type(uint128).max);

    vm.deal(_caller, _value);
    vm.store(address(_leafVoter), bytes32(_SURPLUS_ACCRUED_SLOT), bytes32(_surplusAccrued));

    // it should burn _amount of receipt token from _caller
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IReceiptToken.burn, (_caller, _amount)), '');

    // it should dispatch a Redeem message encoding _amount, _recipient and surplusAccrued forwarding msg value
    bytes memory _payload = abi.encode(
      IVoterCommon.RedeemMessageBody({amount: _amount, recipient: _recipient, surplusAccrued: _surplusAccrued})
    );
    _mockAndExpectWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Redeem, _payload, _gasLimit, _refundRecipient, false)
      ),
      ''
    );

    // it should emit Redeemed with _redeemer, _recipient, _amount
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Redeemed(_caller, _recipient, _amount);

    vm.prank(_caller);
    _leafVoter.redeem{value: _value}(_amount, _recipient, _gasLimit, _refundRecipient);
  }

  modifier givenTheChainStatusIsActive() {
    _mockChainStatus(IVoterCommon.ChainStatus.Active);
    _;
  }

  function test_RedeemWhenTheAmountIsLessThanTheMinimumAmount(
    uint256 _amount,
    address _recipient,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenTheChainStatusIsActive {
    _amount = bound(_amount, 0, _MIN_REDEEM_AMOUNT - 1);

    // it should revert with AmountTooLow
    vm.expectRevert(ILeafVoter.AmountTooLow.selector);
    _leafVoter.redeem(_amount, _recipient, _gasLimit, _refundRecipient);
  }

  function test_RedeemWhenTheAmountEqualsTheMinimumAmount(
    address _caller,
    address _recipient,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _surplusAccrued,
    uint256 _value
  ) external givenTheChainStatusIsActive {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _value = bound(_value, 0, type(uint128).max);

    vm.deal(_caller, _value);
    vm.store(address(_leafVoter), bytes32(_SURPLUS_ACCRUED_SLOT), bytes32(_surplusAccrued));

    // pin the decisive inclusive edge: `_amount == MIN_REDEEM_AMOUNT` must pass the `< MIN_REDEEM_AMOUNT` guard
    uint256 _amount = _MIN_REDEEM_AMOUNT;

    // it should burn _amount of receipt token from _caller
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IReceiptToken.burn, (_caller, _amount)), '');

    // it should dispatch a Redeem message encoding _amount, _recipient and surplusAccrued forwarding msg value
    bytes memory _payload = abi.encode(
      IVoterCommon.RedeemMessageBody({amount: _amount, recipient: _recipient, surplusAccrued: _surplusAccrued})
    );
    _mockAndExpectWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Redeem, _payload, _gasLimit, _refundRecipient, false)
      ),
      ''
    );

    // it should emit Redeemed with _redeemer, _recipient, _amount
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Redeemed(_caller, _recipient, _amount);

    vm.prank(_caller);
    _leafVoter.redeem{value: _value}(_amount, _recipient, _gasLimit, _refundRecipient);
  }

  modifier givenTheAmountIsAtLeastTheMinimumAmount() {
    _;
  }

  function test_RedeemWhenTheRecipientIsTheZeroAddress(
    uint256 _amount,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenTheChainStatusIsActive givenTheAmountIsAtLeastTheMinimumAmount {
    _amount = bound(_amount, _MIN_REDEEM_AMOUNT, type(uint256).max);

    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    _leafVoter.redeem(_amount, address(0), _gasLimit, _refundRecipient);
  }

  modifier givenTheCallerIsNotTheZeroAddress(address _caller) {
    _assumeFuzzable(_caller);
    _;
  }

  function test_RedeemWhenAllInputsAreValid(
    address _caller,
    uint256 _amount,
    address _recipient,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _surplusAccrued,
    uint256 _value
  )
    external
    givenTheChainStatusIsActive
    givenTheAmountIsAtLeastTheMinimumAmount
    givenTheCallerIsNotTheZeroAddress(_caller)
  {
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, _MIN_REDEEM_AMOUNT, type(uint256).max);
    _value = bound(_value, 0, type(uint128).max);

    vm.deal(_caller, _value);
    vm.store(address(_leafVoter), bytes32(_SURPLUS_ACCRUED_SLOT), bytes32(_surplusAccrued));

    // it should burn _amount of receipt token from _caller
    _mockAndExpect(_RECEIPT_TOKEN, abi.encodeCall(IReceiptToken.burn, (_caller, _amount)), '');

    // it should dispatch a Redeem message encoding _amount, _recipient and surplusAccrued forwarding msg value
    bytes memory _payload = abi.encode(
      IVoterCommon.RedeemMessageBody({amount: _amount, recipient: _recipient, surplusAccrued: _surplusAccrued})
    );
    _mockAndExpectWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Redeem, _payload, _gasLimit, _refundRecipient, false)
      ),
      ''
    );

    // it should emit Redeemed with _redeemer, _recipient, _amount
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Redeemed(_caller, _recipient, _amount);

    vm.prank(_caller);
    _leafVoter.redeem{value: _value}(_amount, _recipient, _gasLimit, _refundRecipient);
  }

  /// @dev Regression test for raw-storage mock helper layout. Kept out of the Bulloak tree because it tests the
  ///      fixture, not LeafVoter behavior. Every raw-slot `_mock*` helper in `BaseLeafVoter` self-verifies against
  ///      its getter, but only when some test happens to call it; exercising each one here makes the slot-layout
  ///      check deterministic. Values are distinct and non-zero per field so a swapped slot constant cannot pass.
  function test_StorageMockHelpersWhenTheyAreUsedTogether() external {
    uint48 _boundary = _nextWeekBoundary(_SEED_TIMESTAMP);

    _mockChainAccumulator(11 ether, 22 ether);
    _mockChainTimeIndex(33 ether);
    _mockChainSettlement(_SEED_TIMESTAMP + 5 days);
    // Boundary twins share the key but sit in different mappings; distinct seeds catch a slot swap.
    _mockIndexAtBoundary(_boundary, 44 ether);
    _mockTimeIndexAtBoundary(_boundary, 55 ether);

    ILeafVoter.GaugeState memory _state = _buildGaugeState({
      _ceiling: 1 ether,
      _claimed: 2 ether,
      _lastSettlement: _SEED_TIMESTAMP - 1 days,
      _isRegistered: true,
      _surplus: 3 ether,
      _lastIndex: 4 ether,
      _point: _buildPoint({_bias: 5, _slope: 6, _ts: _SEED_TIMESTAMP - 2 days, _permanentStakeBalance: 7 ether})
    });
    _state.isActivated = true;
    // Adjacent to lastIndex in the struct layout; a distinct seed catches an offset swap.
    _state.lastTimeIndex = 8 ether;
    _mockGaugeState(_GAUGE_A, _state);
    _mockGaugeSlopeChange(_GAUGE_A, _boundary, -66);
    _mockRegisterGauge(_GAUGE_B, true);

    _mockTokenSnapshot(_TOKEN_ID, 77 ether, _SEED_TIMESTAMP + 10 weeks);
    _mockLatestTokenSnapshot(_TOKEN_ID, 88 ether, _SEED_TIMESTAMP + 20 weeks, true);
    _mockAllocation(_TOKEN_ID, _GAUGE_A, 99 ether);
    _mockChainAllocation(_TOKEN_ID, 111 ether);
    _mockAccumulatedCooldownReduction(_TOKEN_ID, 3 hours);
    _mockVotedGauge(_TOKEN_ID, _GAUGE_A);
    _mockSurplusAccrued(222 ether);

    // Both pack into the chain-status slot; writing the status after the flag proves neither clobbers the other.
    _mockLocalVotingEnabled(true);
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);
    assertTrue(_leafVoter.localVotingEnabled());
    assertEq(uint8(_leafVoter.chainStatus()), uint8(IVoterCommon.ChainStatus.Suspended));

    // The applied snapshot must survive the diverging latest overwrite: the two mappings hold separate slots.
    (uint128 _staked, uint48 _stakeEnd, bool _isPermanent) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, 77 ether);
    assertEq(_stakeEnd, _SEED_TIMESTAMP + 10 weeks);
    assertEq(_isPermanent, false);

    // The accumulator twins must hold their distinct seeds after all writes landed.
    assertEq(_leafVoter.index(), 22 ether);
    assertEq(_leafVoter.timeIndex(), 33 ether);
    assertEq(_leafVoter.indexAtBoundary(_boundary), 44 ether);
    assertEq(_leafVoter.timeIndexAtBoundary(_boundary), 55 ether);
  }
}
