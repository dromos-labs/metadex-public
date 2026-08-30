// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/**
 * @title BaseEntrypoints
 * @notice Shared base for the entrypoint suites: mocked dependencies (MetaRouter, Relay, input/output
 *         tokens) and helpers that stage the keeper gate and the pull→approve→swap→approve-reset
 *         sequence `_pullSwapAndValidate` runs, so each suite presets exactly the calls its path makes.
 * @dev The Relay is mocked as an `IRelayEntrypoint` surface; the entrypoints resolve it from
 *      `SwapParams.relay`, never from a constructor binding on the Single variants.
 */
abstract contract BaseEntrypoints is TestHelpers {
  /// @dev The KEEPER role bit the Relay reports and the pull-swap gate checks.
  uint256 internal constant _KEEPER = 1 << 0;

  /// @dev Fallback deadline for the revert paths that never reach the router.
  uint256 internal constant _DEFAULT_DEADLINE = 1_800_000_000;

  address internal _factoryRegistry;
  address internal _metaRouter;
  address internal _relayAddr;
  address internal _tokenIn;
  address internal _tokenOut;

  function setUp() public virtual {
    _factoryRegistry = _mockContract('FactoryRegistry');
    _metaRouter = _mockContract('MetaRouter');
    _relayAddr = _mockContract('Relay');
    _tokenIn = _mockContract('tokenIn');
    _tokenOut = _mockContract('tokenOut');
    // Approved by default; a branch that needs a revoked router overrides this.
    _mockRouterApproval(_metaRouter, true);
  }

  /// @dev A fuzzed deadline for a test that stages a router call. Bounded to a future timestamp,
  ///      the only range a keeper can usefully sign, and re-drawn per run so an entrypoint that
  ///      hardcoded a deadline instead of forwarding this one fails the staged expectCall.
  /// @param _seed Raw fuzz input.
  /// @return _bounded Deadline to pass to `_swapParams` and `_mockPullSwapFlow`.
  function _boundDeadline(uint256 _seed) internal view returns (uint256 _bounded) {
    _bounded = bound(_seed, block.timestamp + 1, type(uint256).max);
  }

  /// @dev Mock the registry's verdict on `_router`.
  function _mockRouterApproval(address _router, bool _approved) internal {
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isMetaRouterApproved, (_router)), abi.encode(_approved)
    );
  }

  /// @dev A swap request on the default router with empty commands (the router is mocked, so opcodes
  ///      are inert).
  function _swapParams(
    address _relay,
    address _in,
    uint256 _amountIn,
    uint256 _minAmountOut,
    uint256 _deadline
  ) internal view returns (IBaseEntrypoint.SwapParams memory _params) {
    _params = _swapParamsOn(_metaRouter, _relay, _in, _amountIn, _minAmountOut, _deadline);
  }

  /// @dev A swap request naming an explicit router.
  function _swapParamsOn(
    address _router,
    address _relay,
    address _in,
    uint256 _amountIn,
    uint256 _minAmountOut,
    uint256 _deadline
  ) internal pure returns (IBaseEntrypoint.SwapParams memory _params) {
    _params = IBaseEntrypoint.SwapParams({
      relay: _relay,
      router: _router,
      tokenIn: _in,
      amountIn: _amountIn,
      minAmountOut: _minAmountOut,
      deadline: _deadline,
      commands: '',
      inputs: new bytes[](0)
    });
  }

  /// @dev Stage the two reads an idle-balance path makes on `_relay` for `_token`: its balance and
  ///      the part of it already owed to reward claimants. The unaccounted difference is what the
  ///      path processes. Registers matching expectCalls.
  function _mockIdleBalance(address _relay, address _token, uint256 _balance, uint256 _accounted) internal {
    _mockAndExpectTokenBalance(_token, _relay, _balance);
    _mockAndExpect(_relay, abi.encodeCall(IRelayEntrypoint.accountedBalance, (_token)), abi.encode(_accounted));
  }

  /// @dev Mock the Relay's KEEPER role and whether `_caller` holds it.
  function _mockKeeper(address _relay, address _caller, bool _ok) internal {
    vm.mockCall(_relay, abi.encodeCall(IRelayEntrypoint.KEEPER, ()), abi.encode(_KEEPER));
    vm.mockCall(_relay, abi.encodeCall(IRelayEntrypoint.hasAnyRole, (_caller, _KEEPER)), abi.encode(_ok));
  }

  /// @dev Stage the whole transient-custody sequence for a swap of `_amountIn` `_in` landing
  ///      `_delta` of `_out` on `_entrypoint`: the before/after balance reads, the pull, both router
  ///      approvals (set then reset) and the router execute. Registers matching expectCalls, so the
  ///      test fails if the entrypoint skips any step. The forward to `_relay` is only mocked: the
  ///      below-minimum revert path stops before it. `_balanceBefore + _delta` must not overflow.
  function _mockPullSwapFlow(
    address _entrypoint,
    address _relay,
    address _in,
    address _out,
    uint256 _amountIn,
    uint256 _balanceBefore,
    uint256 _delta,
    uint256 _deadline
  ) internal {
    _mockAndExpectTokenBalancesTwice(_out, _entrypoint, [_balanceBefore, _balanceBefore + _delta]);
    _mockAndExpect(_relay, abi.encodeCall(IRelayEntrypoint.pull, (_in, _amountIn)), bytes(''));
    _mockAndExpect(_in, abi.encodeCall(IERC20.approve, (_metaRouter, _amountIn)), abi.encode(true));
    _mockAndExpect(_in, abi.encodeCall(IERC20.approve, (_metaRouter, uint256(0))), abi.encode(true));
    _mockAndExpect(_metaRouter, abi.encodeCall(IMetarouter.execute, (bytes(''), new bytes[](0), _deadline)), bytes(''));
    vm.mockCall(_out, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
    // The router consumed the whole input, so the entrypoint holds none of it when the swap returns
    // and the leftover sweep moves nothing. A suite that stages a partial spend overrides this with
    // a mock for its own entrypoint address, which takes precedence over this catch-all.
    vm.mockCall(_in, abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(uint256(0)));
  }
}
