// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

abstract contract BasePoolClaimFees is UnitPool {
  using stdStorage for StdStorage;

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }

  function _setBalance(address _account, uint256 _balance) internal {
    stdstore.target(address(_pool)).sig(IERC20.balanceOf.selector).with_key(_account).checked_write(_balance);
  }

  function _setClaimable(address _account, uint256 _claimable0, uint256 _claimable1) internal {
    stdstore.target(address(_pool)).sig(IPool.claimable0.selector).with_key(_account).checked_write(_claimable0);
    stdstore.target(address(_pool)).sig(IPool.claimable1.selector).with_key(_account).checked_write(_claimable1);
  }

  function _setSupplyIndexes(address _account, uint256 _supplyIndex0, uint256 _supplyIndex1) internal {
    stdstore.target(address(_pool)).sig(IPool.supplyIndex0.selector).with_key(_account).checked_write(_supplyIndex0);
    stdstore.target(address(_pool)).sig(IPool.supplyIndex1.selector).with_key(_account).checked_write(_supplyIndex1);
  }

  function _setIndexes(uint256 _index0, uint256 _index1) internal {
    _set(address(_pool), _index0, IPool.index0.selector);
    _set(address(_pool), _index1, IPool.index1.selector);
  }

  function _setApprovedForClaim(address _account, address _operator, bool _approved) internal {
    stdstore.target(address(_pool)).sig(IPool.approvedForClaim.selector).with_key(_account).with_key(_operator)
      .checked_write(_approved);
  }

  function _assertPendingFees(address _account, uint256 _expected0, uint256 _expected1) internal view {
    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_account);
    assertEq(_pending0, _expected0);
    assertEq(_pending1, _expected1);
  }
}
