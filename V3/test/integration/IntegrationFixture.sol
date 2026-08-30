// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Constants} from 'V3-script/Constants.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Shared base for integration fixtures: the deployment mode and the funded actors.
/// @dev Suites deploy locally by default. Set `FORK=true` to run them on a fork instead, or set
///      `_deploymentType` in a suite that only works on a fork. Fork runs target Base at a pinned
///      block, and inheriting fixtures can target another chain by overriding `_forkAlias` and
///      `_forkBlockNumber`.
abstract contract IntegrationFixture is TestHelpers, Constants {
  /// @notice Where the suite gets its chain state from
  enum Deployment {
    DEFAULT,
    FORK
  }

  Deployment internal _deploymentType = vm.envOr('FORK', false) ? Deployment.FORK : Deployment.DEFAULT;
  string internal _forkAlias = 'base';
  uint256 internal _forkBlockNumber = 40_497_200;

  function setUp() public virtual {
    if (_deploymentType == Deployment.FORK) {
      vm.createSelectFork({urlOrAlias: _forkAlias, blockNumber: _forkBlockNumber});
    } else {
      _etchCreateX(CREATEX_ADDRESS);
    }
  }

  /// @dev Creates a labeled address funded with native tokens.
  function _createActor(string memory _name) internal returns (address payable _actor) {
    _actor = payable(makeAddr({name: _name}));
    vm.deal({account: _actor, newBalance: TOKEN_1 * 1000});
  }
}
