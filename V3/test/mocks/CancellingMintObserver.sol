// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';

import {TokenRegistry} from 'V3/tokenRegistry/TokenRegistry.sol';

/// @notice Mock mint implementation that cancels the token's open request from inside the NFT callback.
contract CancellingMintObserver {
  TokenRegistry internal immutable _REGISTRY;
  address internal immutable _TOKEN;

  /**
   * @notice Sets the registry and the token whose request the mint callback cancels.
   * @param _registryAddress Registry reentered during the mint.
   * @param _tokenAddress Token whose open request is cancelled.
   */
  constructor(TokenRegistry _registryAddress, address _tokenAddress) {
    _REGISTRY = _registryAddress;
    _TOKEN = _tokenAddress;
  }

  /// @notice Replaces the NFT mint call and reenters `cancel` while the registration is mid-flight.
  function mint(uint256, address, ITokenNFT.TextRecord[] calldata) external {
    _REGISTRY.cancel(_TOKEN);
  }
}
