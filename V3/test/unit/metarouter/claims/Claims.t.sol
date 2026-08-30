// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {ICLGauge} from 'V3/interfaces/gauges/ICLGauge.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';

/// @notice Claims module tests: the router custodies assets and sweeps leftovers to its caller.
contract UnitClaims is BaseMetarouter {
  /// @notice Gauge target exercised by the gauge-reward claim tests.
  address internal immutable _GAUGE = makeAddr('Gauge');
  /// @notice Pool target exercised by the V2 fee-claim tests.
  address internal immutable _POOL = _mockContract('Pool');
  /// @notice Pool factory the registry resolves as the pool's deployer.
  address internal immutable _POOL_FACTORY = makeAddr('PoolFactory');
  /// @notice Pool token0 tracked and swept by the V2 fee-claim tests.
  address internal immutable _TOKEN0 = _mockContract('token0');
  /// @notice Pool token1 tracked and swept by the V2 fee-claim tests.
  address internal immutable _TOKEN1 = _mockContract('token1');

  // --- claimGaugeRewards ---

  function test_ClaimGaugeRewardsGivenALiteDeploymentWithNoLeafVoter(address _caller) external {
    _assumeFuzzable(_caller);
    // A lite deployment carries no voting system, so the gauge commands are gated off. The guard is the first
    // statement of the dispatch branch, so the command reverts before the input is decoded and before any gauge or
    // Voter read; the input can stay empty.
    MetarouterHarness _liteMetarouter = _deployLiteMetarouter();

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = '';

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.CLAIM_GAUGE_REWARDS));
    _liteMetarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheRecipientIsTheZeroAddress(address _caller) external {
    _assumeFuzzable(_caller);
    // The recipient guard runs before target validation, so the gauge state is never read and no mock is needed.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, address(0), new uint256[](0), false);

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheGaugeIsNotRegistered(address _caller, address _recipient) external {
    _assumeFuzzable(_caller);
    // The zero recipient has its own guard branch, exercised above.
    _recipient = _boundNotEq(_recipient, address(0));
    // The Voter reports the gauge as never produced by an approved factory (isRegistered false).
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.gaugeStates, (_GAUGE)), _encodedGaugeState(false));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, new uint256[](0), false);

    // it should revert with GaugeNotRegistered
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.GaugeNotRegistered.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheGaugeIsRegistered() {
    // Report the gauge as produced by an approved factory so the target passes validation.
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.gaugeStates, (_GAUGE)), _encodedGaugeState(true));
    _;
  }

  function test_ClaimGaugeRewardsWhenTheRecipientIsTheMetarouter(
    address _caller,
    uint256 _amount
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    // Claiming to the router itself: a gauge claim delivers the deploy-wired emission token (a distinct address from
    // any receipt token), which lands in custody and is returned to the caller at close.
    _amount = bound(_amount, 1, type(uint256).max);
    _mockGaugeType(_GAUGE, 'cl');
    // it should claim all positions through the unbounded two argument overload for an empty token id list
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.claimEmissions, (_caller, address(_metarouter))), '');
    // it should hold the emission token
    _mockAndExpectTokenBalance(_EMISSION_TOKEN, address(_metarouter), _amount);
    // it should return the emission token to _msgSender()
    _mockAndExpectTokenTransfer(_EMISSION_TOKEN, _caller, _amount);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, address(_metarouter), new uint256[](0), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheRecipientIsAUserPointedAddress(
    address _caller,
    address _recipient
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    // A user-pointed address: the gauge delivers straight to it, so the router holds nothing and sweeps nothing.
    // The zero recipient has its own guard branch.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(0));
    _mockGaugeType(_GAUGE, 'cl');
    // it should claim all positions through the unbounded two argument overload for an empty token id list
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.claimEmissions, (_caller, _recipient)), '');
    // it should not sweep the emission token
    vm.mockCallRevert(
      _EMISSION_TOKEN, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), bytes('no emission sweep')
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, new uint256[](0), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheTokenIdListIsNotEmptyAndTheGaugeTypeIsCl(
    address _caller,
    address _recipient
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(0));
    uint256[] memory _tokenIds = new uint256[](2);
    _tokenIds[0] = 11;
    _tokenIds[1] = 42;
    _mockGaugeType(_GAUGE, 'cl');
    // it should claim only the requested token ids
    _mockAndExpect(_GAUGE, abi.encodeCall(ICLGauge.claimEmissions, (_caller, _recipient, _tokenIds)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, _tokenIds, false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheTokenIdListIsNotEmptyAndTheGaugeTypeIsNotCl(
    address _caller,
    address _recipient
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(0));
    uint256[] memory _tokenIds = new uint256[](1);
    _tokenIds[0] = 11;
    _mockGaugeType(_GAUGE, 'v2');
    vm.mockCallRevert(
      _GAUGE, abi.encodeCall(IGauge.claimEmissions, (_caller, _recipient)), bytes('no account-wide claim')
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, _tokenIds, false);

    // it should revert with InvalidGaugeType
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidGaugeType.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheV2GaugePenaltyIsActiveAndThePenaltyIsNotAllowed(
    address _caller,
    address _recipient
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(0));
    vm.roll(100);
    _mockGaugeType(_GAUGE, 'v2');
    _mockPenaltyConfig(_GAUGE, 5, 1_000_000);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), abi.encode(uint256(99)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, new uint256[](0), false);

    // it should revert with PenaltyNotAccepted
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.PenaltyNotAccepted.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheV2GaugePenaltyIsActiveAndThePenaltyIsAllowed(
    address _caller,
    address _recipient
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    // Claiming to the router itself is the custody branch, tested in
    // test_ClaimGaugeRewardsWhenTheRecipientIsTheMetarouter; here it would hit the unmocked close-out sweep.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(0));
    _mockGaugeType(_GAUGE, 'v2');
    vm.mockCallRevert(
      _GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.effectivePenaltyConfig, (_GAUGE)), bytes('no penalty config read')
    );
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), bytes('no deposit block read'));
    // it should claim despite the active penalty
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.claimEmissions, (_caller, _recipient)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, new uint256[](0), true);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimGaugeRewardsWhenTheV2GaugePenaltyWindowHasElapsed(
    address _caller,
    address _recipient
  ) external givenTheGaugeIsRegistered {
    _assumeFuzzable(_caller);
    // Claiming to the router itself is the custody branch, tested in
    // test_ClaimGaugeRewardsWhenTheRecipientIsTheMetarouter; here it would hit the unmocked close-out sweep.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(0));
    vm.roll(100);
    _mockGaugeType(_GAUGE, 'v2');
    _mockPenaltyConfig(_GAUGE, 5, 1_000_000);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), abi.encode(uint256(95)));
    // it should claim after the penalty window
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.claimEmissions, (_caller, _recipient)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_GAUGE_REWARDS)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, _recipient, new uint256[](0), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- claimV2PoolFees ---

  function test_ClaimV2PoolFeesWhenTheRecipientIsTheZeroAddress(address _caller) external {
    _assumeFuzzable(_caller);
    // The recipient guard runs before target validation, so the registry is never read and no mock is needed.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_V2_POOL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_POOL, address(0));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimV2PoolFeesWhenThePoolIsNotRegistered(address _caller, address _recipient) external {
    _assumeFuzzable(_caller);
    // The zero recipient has its own guard branch, exercised above.
    _recipient = _boundNotEq(_recipient, address(0));
    // The FactoryRegistry resolves the pool's deploying factory but does not vouch for it (unapproved or unknown),
    // so validation reverts before any claim.
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_POOL_FACTORY)
    );
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_POOL_FACTORY)), abi.encode(false)
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_V2_POOL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_POOL, _recipient);

    // it should revert with PoolNotRegistered
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.PoolNotRegistered.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenThePoolIsRegistered() {
    // The FactoryRegistry resolves the pool's deploying factory and vouches for it, so the target passes validation.
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_POOL_FACTORY)
    );
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_POOL_FACTORY)), abi.encode(true)
    );
    _;
  }

  function test_ClaimV2PoolFeesWhenTheRecipientIsTheMetarouter(
    address _caller,
    uint256 _amount0,
    uint256 _amount1
  ) external givenThePoolIsRegistered {
    _assumeFuzzable(_caller);
    // Claiming to the router itself: both pool tokens are tracked before the claim, land in custody, and return to
    // the caller at close.
    _amount0 = bound(_amount0, 1, type(uint256).max);
    _amount1 = bound(_amount1, 1, type(uint256).max);
    // it should track both pool tokens
    _mockAndExpect(_POOL, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN0));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.token1, ()), abi.encode(_TOKEN1));
    // it should call _pool claimFees with _msgSender() and _recipient
    _mockAndExpect(
      _POOL,
      abi.encodeWithSelector(bytes4(keccak256('claimFees(address,address)')), _caller, address(_metarouter)),
      abi.encode(_amount0, _amount1)
    );
    // it should return both pool tokens to _msgSender()
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _amount0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _amount1);
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _amount0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _amount1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_V2_POOL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_POOL, address(_metarouter));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimV2PoolFeesWhenThePoolHasNoFeesToClaim(address _caller) external givenThePoolIsRegistered {
    _assumeFuzzable(_caller);
    // No accrued fees with the router as recipient: both tokens are still tracked and the pool transfers nothing, so
    // closure finds a zero balance and sweeps nothing. A pass-through router does not revert on a zero claim.
    // it should track both pool tokens
    _mockAndExpect(_POOL, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN0));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.token1, ()), abi.encode(_TOKEN1));
    // it should call _pool claimFees with _msgSender() and _recipient
    _mockAndExpect(
      _POOL,
      abi.encodeWithSelector(bytes4(keccak256('claimFees(address,address)')), _caller, address(_metarouter)),
      abi.encode(uint256(0), uint256(0))
    );
    // it should not sweep either pool token
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), 0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), 0);
    vm.mockCallRevert(_TOKEN0, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no sweep'));
    vm.mockCallRevert(_TOKEN1, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no sweep'));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_V2_POOL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_POOL, address(_metarouter));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ClaimV2PoolFeesWhenTheRecipientIsAUserPointedAddress(
    address _caller,
    address _recipient
  ) external givenThePoolIsRegistered {
    _assumeFuzzable(_caller);
    // A user-pointed recipient: the pool delivers straight to it, so the router never reads the pool tokens, tracks
    // nothing, and sweeps nothing. The zero recipient has its own guard branch.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(0));
    // it should not track or sweep the pool tokens
    vm.mockCallRevert(_POOL, abi.encodeCall(IPool.token0, ()), bytes('no token0 read'));
    vm.mockCallRevert(_POOL, abi.encodeCall(IPool.token1, ()), bytes('no token1 read'));
    // it should call _pool claimFees with _msgSender() and _recipient
    _mockAndExpect(
      _POOL,
      abi.encodeWithSelector(bytes4(keccak256('claimFees(address,address)')), _caller, _recipient),
      abi.encode(uint256(0), uint256(0))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CLAIM_V2_POOL_FEES)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_POOL, _recipient);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- helpers ---

  /// @notice Builds the ABI-encoded `gaugeStates` getter tuple with only the `isRegistered` field toggled.
  /// @param _registered Whether the gauge is reported as produced by an approved factory.
  /// @return _state Encoded `gaugeStates` getter tuple.
  function _encodedGaugeState(bool _registered) internal pure returns (bytes memory _state) {
    // isRegistered is the fourth field of the `gaugeStates` getter tuple; other fields are irrelevant here.
    _state = abi.encode(
      uint128(0),
      uint128(0),
      uint48(0),
      _registered,
      false,
      uint128(0),
      uint256(0),
      uint256(0),
      IVoterCommon.Point({bias: 0, slope: 0, ts: 0, permanentStakeBalance: 0})
    );
  }
}
