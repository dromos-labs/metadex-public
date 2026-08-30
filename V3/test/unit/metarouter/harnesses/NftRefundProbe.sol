// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/// @title NftRefundProbe
/// @notice Deployed fake position manager that doubles as the batch caller, so it holds the flow during the closure
///         native refund.
/// @dev The router accepts receiver-hook calls only from its `POSITION_MANAGER`, so the probe is wired in as that
///      immutable and calls the hook from its own `receive`. That happens while the refund is being sent, which is the
///      last point a batch hands control to an outside address, letting the closure NFT check be exercised against a
///      position that arrives after the commands are done. `ownerOf` reports the router so the check sees the position
///      as still held.
contract NftRefundProbe {
  /// @notice Position the probe reports into the router's custody tracking.
  uint256 internal immutable _TOKEN_ID;

  /// @notice Router the probe calls back into; set after deployment because the router takes the probe as an immutable.
  IMetarouter internal _router;

  /// @notice Records the position the probe pushes into the router.
  /// @param _tokenId Position id reported through the receiver hook.
  constructor(uint256 _tokenId) {
    _TOKEN_ID = _tokenId;
  }

  /// @notice Pushes the position into the router's tracking while the closure refund is in flight.
  receive() external payable {
    IERC721Receiver(address(_router)).onERC721Received(address(0), address(0), _TOKEN_ID, '');
  }

  /// @notice Wires the router the probe reaches back into.
  /// @param _metarouter Router deployed with this probe as its position manager.
  function setRouter(IMetarouter _metarouter) external {
    _router = _metarouter;
  }

  /// @notice Opens a batch as the logical sender, making the probe the closure refund recipient.
  /// @param _value Native ETH introduced into the batch, refunded to the probe at closure.
  function execute(uint256 _value) external {
    _router.execute{value: _value}('', new bytes[](0), type(uint256).max);
  }

  /// @notice Reports the router as the position's owner so the closure check treats it as still held.
  /// @return _owner The router address.
  function ownerOf(uint256) external view returns (address _owner) {
    _owner = address(_router);
  }
}
