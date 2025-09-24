// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @title IInterchainAccountRouter
 * @notice Minimal view of the Hyperlane Interchain Account Router (v3) used by the Metarouter's cross-chain commands.
 * @dev Hyperlane's `@hyperlane-xyz/core` ships no interface for its `InterchainAccountRouter`; the methods used here
 *      exist only on the concrete contract, which is an upgradeable `^0.8.13` implementation with a large dependency
 *      tree. This minimal interface mirrors that contract's selectors instead of importing it. The `_hook` argument
 *      is typed as `address` because interface types encode as `address` in the function selector, so it matches
 *      Hyperlane's `IPostDispatchHook` parameter without importing it.
 */
interface IInterchainAccountRouter {
  /**
   * @notice Dispatches a commitment and its reveal to a destination interchain account.
   * @param _destination Destination Hyperlane domain.
   * @param _router Destination router address, as bytes32.
   * @param _ism Destination interchain security module, as bytes32.
   * @param _hookMetadata Post-dispatch hook metadata for the reveal message.
   * @param _hook Post-dispatch hook to run after dispatching to the mailbox.
   * @param _salt User-provided salt controlling account derivation.
   * @param _commitment Commitment to the destination calls.
   * @return _commitmentMsgId Hyperlane message id of the commitment message.
   * @return _revealMsgId Hyperlane message id of the reveal message.
   */
  function callRemoteCommitReveal(
    uint32 _destination,
    bytes32 _router,
    bytes32 _ism,
    bytes calldata _hookMetadata,
    address _hook,
    bytes32 _salt,
    bytes32 _commitment
  ) external payable returns (bytes32 _commitmentMsgId, bytes32 _revealMsgId);

  /**
   * @notice Derives the deterministic interchain account owned by `_owner` on `_destination`.
   * @dev The account is not guaranteed to be deployed; the address depends on the destination router and ISM
   *      configured for `_destination` and on the user salt.
   * @param _destination Destination Hyperlane domain.
   * @param _owner Local owner of the interchain account.
   * @param _userSalt User-provided salt controlling account derivation.
   * @return _account Remote address of the interchain account.
   */
  function getRemoteInterchainAccount(
    uint32 _destination,
    address _owner,
    bytes32 _userSalt
  ) external view returns (address _account);

  /**
   * @notice Derives a deterministic remote interchain account from a custom destination router and ISM.
   * @dev The account is not guaranteed to be deployed. A zero `_ism` remains part of the account derivation and
   *      delegates message verification to Hyperlane's default ISM.
   * @param _owner Local owner of the interchain account.
   * @param _router Custom destination interchain account router.
   * @param _ism Custom destination interchain security module, or zero to use Hyperlane's default verifier.
   * @param _userSalt User-provided salt controlling account derivation.
   * @return _account Remote address of the interchain account.
   */
  function getRemoteInterchainAccount(
    address _owner,
    address _router,
    address _ism,
    bytes32 _userSalt
  ) external view returns (address _account);

  /**
   * @notice Returns the destination router registered for a domain.
   * @param _domain Destination Hyperlane domain.
   * @return _router Destination router address, as bytes32.
   */
  function routers(uint32 _domain) external view returns (bytes32 _router);

  /**
   * @notice Returns the interchain security module registered for a domain.
   * @param _domain Destination Hyperlane domain.
   * @return _ism Destination interchain security module, as bytes32.
   */
  function isms(uint32 _domain) external view returns (bytes32 _ism);
}
