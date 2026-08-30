// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseLiquidity} from 'V3-test/unit/metarouter/liquidity/BaseLiquidity.sol';

/// @notice V2 remove-liquidity command tests covering registry validation, LP funding, burns, minimums, tracking,
///         and closure sweeps. Every external dependency is mocked.
contract UnitLiquidityRemoveLiquidity is BaseLiquidity {
  function test_WhenTheRecipientIsTheZeroAddress(address _caller, address _pool) external {
    IMetarouter.RemoveLiquidityParams memory _params;
    // The pool is never touched: the zero-recipient guard reverts before validation, so it is fuzzed freely.
    _params.pool = _pool;
    _params.recipient = address(0);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice Constrains the recipient to a fuzzable non-zero address, the passing branch of the recipient guard.
  modifier givenTheRecipientIsNotTheZeroAddress(address _recipient) {
    _assumeFuzzable(_recipient);
    _;
  }

  function test_WhenThePoolIsNotRegistered(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) {
    _mockAndExpect(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_FACTORY));
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_FACTORY)), abi.encode(false)
    );

    IMetarouter.RemoveLiquidityParams memory _params;
    _params.pool = _POOL;
    _params.recipient = _recipient;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with PoolNotRegistered
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.PoolNotRegistered.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The FactoryRegistry reports the pool's deploying factory as approved, so the target passes validation.
  modifier givenThePoolIsRegistered() {
    _mockAndExpect(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_FACTORY));
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.isTargetFactoryApproved, (_FACTORY)), abi.encode(true)
    );
    _;
  }

  modifier whenTheLpIsSpentFromTheExecutionBalance() {
    // Spending the LP from the execution balance is expressed through the params in each test.
    _;
  }

  function test_WhenTheRecipientIsTheRouter(
    address _caller,
    uint256 _liquidity,
    uint256 _returned0,
    uint256 _returned1
  )
    external
    givenTheRecipientIsNotTheZeroAddress(address(_metarouter))
    givenThePoolIsRegistered
    whenTheLpIsSpentFromTheExecutionBalance
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The burn must credit the router with something to sweep, so both returned amounts are at least one.
    _returned0 = bound(_returned0, 1, type(uint256).max);
    _returned1 = bound(_returned1, 1, type(uint256).max);
    // The resolved LP is fully pushed, so the closure read of the router's LP balance returns zero.
    _mockAndExpectTokenBalancesTwice(_POOL, address(_metarouter), [_liquidity, uint256(0)]);
    // it should track both pool tokens
    _mockAndExpect(_POOL, abi.encodeCall(IPool.tokens, ()), abi.encode(_TOKEN0, _TOKEN1));
    _mockAndExpectTokenBalance(_TOKEN0, address(_metarouter), _returned0);
    _mockAndExpectTokenBalance(_TOKEN1, address(_metarouter), _returned1);
    // it should push the resolved lp to the pool
    _mockAndExpectTokenTransfer(_POOL, _POOL, _liquidity);
    // it should burn to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.burn, (address(_metarouter))), abi.encode(_returned0, _returned1));
    // it should sweep the returned tokens to _caller at closure
    _mockAndExpectTokenTransfer(_TOKEN0, _caller, _returned0);
    _mockAndExpectTokenTransfer(_TOKEN1, _caller, _returned1);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_removeParams(_liquidity, false, address(_metarouter)));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheRecipientIsNotTheRouter(
    address _caller,
    address _recipient,
    uint256 _liquidity,
    uint256 _returned0,
    uint256 _returned1
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenThePoolIsRegistered
    whenTheLpIsSpentFromTheExecutionBalance
  {
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _mockAndExpectTokenBalancesTwice(_POOL, address(_metarouter), [_liquidity, uint256(0)]);
    // it should not track any pool token
    vm.mockCallRevert(_POOL, abi.encodeCall(IPool.tokens, ()), bytes('no track'));
    // it should push the resolved lp to the pool
    _mockAndExpectTokenTransfer(_POOL, _POOL, _liquidity);
    // it should burn to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.burn, (_recipient)), abi.encode(_returned0, _returned1));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_removeParams(_liquidity, false, _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheReturnedTokenZeroIsBelowItsMinimum(
    address _caller,
    address _recipient,
    uint256 _liquidity,
    uint256 _returned0,
    uint256 _returned1
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenThePoolIsRegistered
    whenTheLpIsSpentFromTheExecutionBalance
  {
    // A router recipient would trigger the untracked pool-token reads, so the burn output goes to a non-router address.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _returned0 = bound(_returned0, 0, type(uint256).max - 1);
    _mockAndExpectTokenBalance(_POOL, address(_metarouter), _liquidity);
    _mockAndExpectTokenTransfer(_POOL, _POOL, _liquidity);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.burn, (_recipient)), abi.encode(_returned0, _returned1));

    IMetarouter.RemoveLiquidityParams memory _params = _removeParams(_liquidity, false, _recipient);
    // The returned token0 sits one unit below its minimum.
    _params.amount0Min = _returned0 + 1;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InsufficientAmount0
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InsufficientAmount0.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheReturnedTokenOneIsBelowItsMinimum(
    address _caller,
    address _recipient,
    uint256 _liquidity,
    uint256 _returned0,
    uint256 _returned1
  )
    external
    givenTheRecipientIsNotTheZeroAddress(_recipient)
    givenThePoolIsRegistered
    whenTheLpIsSpentFromTheExecutionBalance
  {
    // A router recipient would trigger the untracked pool-token reads, so the burn output goes to a non-router address.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _returned1 = bound(_returned1, 0, type(uint256).max - 1);
    _mockAndExpectTokenBalance(_POOL, address(_metarouter), _liquidity);
    _mockAndExpectTokenTransfer(_POOL, _POOL, _liquidity);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.burn, (_recipient)), abi.encode(_returned0, _returned1));

    IMetarouter.RemoveLiquidityParams memory _params = _removeParams(_liquidity, false, _recipient);
    // The returned token1 sits one unit below its minimum.
    _params.amount1Min = _returned1 + 1;

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_params);

    // it should revert with InsufficientAmount1
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InsufficientAmount1.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_WhenTheLpIsPulledFromTheCaller(
    address _caller,
    address _recipient,
    uint256 _liquidity,
    uint256 _returned0,
    uint256 _returned1
  ) external givenTheRecipientIsNotTheZeroAddress(_recipient) givenThePoolIsRegistered {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The external pull measures the received delta: zero before, then the pulled amount, then zero left at closure.
    uint256[] memory _balances = new uint256[](3);
    _balances[1] = _liquidity;
    _mockAndExpectTokenBalances(_POOL, address(_metarouter), _balances);
    // it should pull the exact lp amount from _caller
    _mockAndExpect(
      _POOL, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _liquidity)), abi.encode(true)
    );
    // it should push the pulled lp to the pool
    _mockAndExpectTokenTransfer(_POOL, _POOL, _liquidity);
    // it should burn to _recipient
    _mockAndExpect(_POOL, abi.encodeCall(IPool.burn, (_recipient)), abi.encode(_returned0, _returned1));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.REMOVE_LIQUIDITY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_removeParams(_liquidity, true, _recipient));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }
}
