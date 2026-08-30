// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';

/// @title NftReturnProbe
/// @notice Deployed stand-in for a CL gauge, used to observe the expected-NFT-sender handshake that a mocked call
///         cannot reach.
/// @dev `vm.mockCall` returns data without running code, so a mocked `withdrawFrom` can neither report the armed sender
///      nor return a position. This probe records the expected sender set at the moment the router hands it control,
///      then returns a position by driving the router's receiver hook through the position manager, the way a real
///      `safeTransferFrom` would. The delivery is routed through `_positionManager` because the hook accepts only the
///      router's canonical collection; tests etch this same code at that address so `deliver` is callable there.
contract NftReturnProbe {
  /// @notice Router the probe observes and delivers into.
  MetarouterHarness internal _router;
  /// @notice Collection the delivery is routed through, so the receiver hook sees its canonical position manager.
  address internal _positionManager;
  /// @notice Position the probe returns.
  uint256 internal _tokenId;
  /// @notice Expected sender the router had set while the withdrawal call was executing.
  address public expectedSenderDuringWithdrawal;
  /// @notice Expected position the router had set while the withdrawal call was executing.
  uint256 public expectedTokenIdDuringWithdrawal;

  /// @notice Wires the probe to the router and the collection its delivery is routed through.
  /// @param _metarouter Router the probe observes and delivers into.
  /// @param _collection Position manager address the delivery is routed through.
  /// @param _position Position id returned.
  function configure(MetarouterHarness _metarouter, address _collection, uint256 _position) external {
    _router = _metarouter;
    _positionManager = _collection;
    _tokenId = _position;
  }

  /// @notice Gauge withdrawal entry point; records the armed sender and returns the position.
  function withdrawFrom(uint256, address) external {
    _returnPosition();
  }

  /// @notice Drives the router's receiver hook, standing in for the collection during a `safeTransferFrom`.
  /// @param _metarouter Router whose hook is called.
  /// @param _from Sender the transfer reports, which the router matches against its armed sender.
  /// @param _position Position id delivered.
  function deliver(MetarouterHarness _metarouter, address _from, uint256 _position) external {
    IERC721Receiver(address(_metarouter)).onERC721Received(_from, _from, _position, '');
  }

  /// @notice Records the expected NFT, then returns the position through the collection.
  function _returnPosition() private {
    (expectedSenderDuringWithdrawal, expectedTokenIdDuringWithdrawal) = _router.expectedNft();
    NftReturnProbe(_positionManager).deliver(_router, address(this), _tokenId);
  }
}
