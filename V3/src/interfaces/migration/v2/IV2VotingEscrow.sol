// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 VotingEscrow Interface
 * @notice Minimal V2 VotingEscrow interface used by Migration
 */
interface IV2VotingEscrow {
  /**
   * @notice Type of a v2 veNFT
   * @dev NORMAL is a typical veNFT, LOCKED is deposited into a managed veNFT, and MANAGED accepts deposits
   */
  enum EscrowType {
    NORMAL,
    LOCKED,
    MANAGED
  }

  /**
   * @notice Locked balance of a v2 veNFT
   * @param amount Amount of tokens locked
   * @param end Lock expiration timestamp
   * @param isPermanent Whether the lock is permanent
   */
  struct LockedBalance {
    int128 amount;
    uint256 end;
    bool isPermanent;
  }

  /**
   * @notice Creates a v2 veNFT for the caller
   * @param _value Amount of tokens to lock
   * @param _lockDuration Duration of the lock in seconds
   * @return _tokenId Identifier of the created v2 veNFT
   */
  function createLock(uint256 _value, uint256 _lockDuration) external returns (uint256 _tokenId);

  /**
   * @notice Deposit `_value` additional tokens for `_tokenId` without modifying the unlock time
   * @param _tokenId Identifier of the v2 veNFT whose lock is increased
   * @param _value Amount of tokens to deposit and add to the lock
   */
  function increaseAmount(uint256 _tokenId, uint256 _value) external;

  /**
   * @notice Merges one v2 veNFT into another
   * @param _from Identifier of the v2 veNFT to merge
   * @param _to Identifier of the destination v2 veNFT
   */
  function merge(uint256 _from, uint256 _to) external;

  /**
   * @notice Permanently locks a v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   */
  function lockPermanent(uint256 _tokenId) external;

  /**
   * @notice Unlocks a permanently locked v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   */
  function unlockPermanent(uint256 _tokenId) external;

  /**
   * @notice Returns the escrow type of a v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   * @return _escrowType Escrow type of the v2 veNFT
   */
  function escrowType(uint256 _tokenId) external view returns (EscrowType _escrowType);

  /**
   * @notice Returns the owner of a v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   * @return _owner Owner of the v2 veNFT
   */
  function ownerOf(uint256 _tokenId) external view returns (address _owner);

  /**
   * @notice Returns the locked balance of a v2 veNFT
   * @param _tokenId Identifier of the v2 veNFT
   * @return _locked Locked balance of the v2 veNFT
   */
  function locked(uint256 _tokenId) external view returns (LockedBalance memory _locked);

  /**
   * @notice Returns whether a v2 veNFT has actively voted
   * @param _tokenId Identifier of the v2 veNFT
   * @return _voted Whether the v2 veNFT has actively voted
   */
  function voted(uint256 _tokenId) external view returns (bool _voted);
}
