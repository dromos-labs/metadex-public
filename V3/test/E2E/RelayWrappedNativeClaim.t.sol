// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MockWETH} from 'V3-test/mocks/MockWETH.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

/**
 * @title E2ERelayWrappedNativeClaim
 * @notice A root reward claim resolves its recipient to the Relay itself and
 *         `VotingRewardsManager` unwraps a wrapped-native payout before sending it. This runs a
 *         real manager against a real Relay, the pair the mocked unit suites cannot exercise.
 */
contract E2ERelayWrappedNativeClaim is BaseRelay {
  /// @dev The veNFT the manager checkpoints and pays: the Relay's own sAERO.
  uint256 internal constant _TOKEN_ID = 1;

  /// @dev Voting power the single staker holds for the whole window, so it owns every credited fee.
  uint128 internal constant _WEIGHT = 1000e18;

  /// @dev Fees the gauge reports and hands to the manager, one leg per reward token.
  uint256 internal constant _FEE = 2000e18;

  address internal _vrmVoter;
  address internal _gauge;
  address internal _gaugeFactory;

  TestERC20 internal _otherToken;
  VotingRewardsManager internal _manager;

  function setUp() public override {
    super.setUp();
    _deployMaxi(true);

    _vrmVoter = _mockContract('VrmVoter');
    _gauge = _mockContract('VrmGauge');
    _gaugeFactory = _mockContract('VrmGaugeFactory');
    address _factoryRegistry = _mockContract('VrmFactoryRegistry');
    _otherToken = new TestERC20('Other', 'OTHER', 18);

    address[] memory _rewards = new address[](2);
    _rewards[0] = _weth;
    _rewards[1] = address(_otherToken);
    _manager = new VotingRewardsManager(_vrmVoter, _gauge, _gaugeFactory, _weth, _rewards);

    vm.mockCall(_vrmVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistry));
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.tokenRegistry, ()), abi.encode(_mockContract('VrmRegistry'))
    );
    vm.mockCall(_gauge, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(uint256(0), uint256(0)));
  }

  /// @dev The fixture's relays wrap into a real WETH here, so the unwrap and the rewrap both run.
  function _deployWrappedNative() internal override returns (address _wrappedNative) {
    _wrappedNative = address(new MockWETH());
  }

  /// @notice A wrapped-native fee leg paid to a root Relay lands as wrapped native on the Relay,
  ///         and the harvest lane can pull it out like any other un-accounted reward balance.
  function test_WhenAWrappedNativeFeeLegPaysARootRelay() external {
    _creditFees();

    // it should complete the claim instead of reverting on the unwrapped leg
    vm.prank(_vrmVoter);
    _manager.claimFees(_TOKEN_ID, address(_relay), 1);

    // it should hand the Relay the wrapped-native leg as an ERC-20 balance, holding no native
    assertEq(IERC20(_weth).balanceOf(address(_relay)), _FEE);
    assertEq(address(_relay).balance, 0);

    // it should leave the plain ERC-20 leg untouched
    assertEq(_otherToken.balanceOf(address(_relay)), _FEE);

    // it should account neither leg, so the harvest lane can pull both to an entrypoint
    vm.prank(_converter);
    _relay.pull(_weth, _FEE);
    assertEq(IERC20(_weth).balanceOf(_converter), _FEE);
  }

  /// @dev Runs the manager's fee cycle: two checkpoints around a reported accrual, then the flush
  ///      that credits it, funding the manager with the tokens a real gauge collection would send.
  function _creditFees() private {
    vm.warp(_INITIAL_TIMESTAMP + 1 weeks);
    vm.prank(_vrmVoter);
    _manager.checkpoint({_tokenId: _TOKEN_ID, _allocated: _WEIGHT, _stakeEnd: 0, _data: ''});

    vm.warp(_INITIAL_TIMESTAMP + 2 weeks);
    vm.mockCall(_gauge, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_FEE, _FEE));
    vm.prank(_vrmVoter);
    _manager.checkpoint({_tokenId: _TOKEN_ID, _allocated: _WEIGHT, _stakeEnd: 0, _data: ''});

    vm.mockCall(_gauge, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_FEE, _FEE));
    vm.deal(address(this), _FEE);
    MockWETH(payable(_weth)).deposit{value: _FEE}();
    MockWETH(payable(_weth)).transfer(address(_manager), _FEE);
    _otherToken.mint(address(_manager), _FEE);
    vm.prank(_gaugeFactory);
    _manager.flushFees();

    // The claim must not collect again; the flush already banked everything.
    vm.mockCallRevert(_gauge, abi.encodeCall(IGauge.collectFees, ()), '');
  }
}
