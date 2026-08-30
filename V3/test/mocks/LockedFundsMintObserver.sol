// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';

import {TokenRegistry} from 'V3/tokenRegistry/TokenRegistry.sol';

/// @notice Mock mint implementation that checks the registry's escrow accounting during the NFT callback.
contract LockedFundsMintObserver {
  /// @notice Emitted after the mint callback observes that the deposit remains locked.
  event DepositObserved();

  TokenRegistry internal immutable _REGISTRY;
  uint256 internal immutable _EXPECTED_LOCKED_FUNDS;

  /**
   * @notice Sets the registry and locked-funds value the mocked mint must observe.
   * @param _registryAddress Registry whose live accounting is checked.
   * @param _expectedLockedFundsValue Expected locked funds during the callback.
   */
  constructor(TokenRegistry _registryAddress, uint256 _expectedLockedFundsValue) {
    _REGISTRY = _registryAddress;
    _EXPECTED_LOCKED_FUNDS = _expectedLockedFundsValue;
  }

  /// @notice Replaces the NFT mint call and checks escrow accounting at the interaction boundary.
  function mint(uint256, address, ITokenNFT.TextRecord[] calldata) external {
    assert(_REGISTRY.lockedFunds() == _EXPECTED_LOCKED_FUNDS);
    emit DepositObserved();
  }
}
