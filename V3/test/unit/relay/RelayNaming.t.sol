// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@solady/auth/Ownable.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';

import {RelayToken} from 'V3/relay/RelayToken.sol';

/// @notice The Relay's display name: what a frontend or an analytics reader labels it with. It is
///         mutable, ADMIN-gated, and deliberately not any token's ERC-20 `name()`.
contract UnitRelayNaming is BaseRelay {
  string internal constant _NEW_NAME = 'Renamed Relay';

  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @notice The name is the only thing ADMIN can change that has no effect on any balance, and it is
  ///         still ADMIN's alone: a keeper or a holder relabelling a Relay is a phishing lever.
  function test_WhenTheCallerIsNotTheAdmin(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _admin);

    // it should revert with Unauthorized
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(_caller);
    _relay.setName(_NEW_NAME);
  }

  /// @notice A rename replaces the whole string and says so in the log, old value included, so a reader
  ///         reconstructs the history without having to have watched the state.
  function test_WhenTheAdminRenamesTheRelay() external {
    string memory _oldName = _relay.relayConfig().name;
    string memory _ptName = _principalToken.name();
    string memory _ytName = _yieldToken.name();

    // it should emit NameChanged carrying both values
    vm.expectEmit(address(_relay));
    emit IRelay.NameChanged(_oldName, _NEW_NAME);
    vm.prank(_admin);
    _relay.setName(_NEW_NAME);

    // it should replace the whole string
    assertEq(_relay.relayConfig().name, _NEW_NAME);

    // it should leave the satellite token names alone
    // Their names were fixed when the clones initialized, and keeping the rename off them is what keeps
    // it off the ERC-20 surface: no `name()` a wallet reads moves, so no EIP-712 domain moves with it and
    // no outstanding permit or delegation signature is voided.
    assertEq(_principalToken.name(), _ptName);
    assertEq(_yieldToken.name(), _ytName);
    // it should leave the symbol where it is: only the name is mutable
    assertEq(_relay.relayConfig().symbol, 'tREL');

    // it should expose the same surface on every tier
    // No tier gates the name, so a Protocol Relay renames exactly like the Maxi one above.
    _deployProtocol(false);
    vm.prank(_admin);
    _relay.setName(_NEW_NAME);
    assertEq(_relay.relayConfig().name, _NEW_NAME);
  }

  /// @notice The reason the rename stays off the tokens, asserted where it actually lives. Solady
  ///         rebuilds the EIP-712 name hash from `name()` on every call, because `RelayToken` leaves
  ///         `_constantNameHash` unpinned so each clone reports its own. A name a rename could move
  ///         would therefore move the domain with it. Pinning the hash is no escape: wallets build the
  ///         domain by reading `name()`, so a pinned hash that disagrees with it rejects every
  ///         wallet-made signature, always. The only clean answer is the one taken here, the name that
  ///         feeds the domain never moves.
  function test_WhenReadingTheSatelliteDomainsAcrossARename() external {
    bytes32 _ptDomain = _principalToken.DOMAIN_SEPARATOR();
    bytes32 _ytDomain = _yieldToken.DOMAIN_SEPARATOR();

    // it should build each domain from the token name and version one
    assertEq(_ptDomain, _expectedDomain(_principalToken));
    assertEq(_ytDomain, _expectedDomain(_yieldToken));

    vm.prank(_admin);
    _relay.setName(_NEW_NAME);

    // it should leave both domains where they were
    assertEq(_principalToken.DOMAIN_SEPARATOR(), _ptDomain);
    assertEq(_yieldToken.DOMAIN_SEPARATOR(), _ytDomain);
  }

  /// @notice End to end on the YT, which is the transferable half and so the one whose permits a
  ///         spender can actually use. Signing before and spending after covers the whole chain the
  ///         domain assertions only cover a link of: name, name hash, domain, ecrecover.
  function test_WhenAPermitWasSignedBeforeTheRename() external {
    (address _holder, uint256 _key) = makeAddrAndKey('ytHolder');
    address _spender = makeAddr('ytSpender');
    (uint8 _v, bytes32 _r, bytes32 _s) = _signPermit(_yieldToken, _key, _holder, _spender);

    vm.prank(_admin);
    _relay.setName(_NEW_NAME);

    // it should still set the allowance after it
    _yieldToken.permit(_holder, _spender, _PERMIT_VALUE, type(uint256).max, _v, _r, _s);
    assertEq(_yieldToken.allowance(_holder, _spender), _PERMIT_VALUE);
  }

  /// @notice The half that matters more: the PT is soulbound, so its permits are inert, but its
  ///         delegations are the governance surface. A rename that voided them would silently cost
  ///         holders their votes.
  function test_WhenADelegationWasSignedBeforeTheRename() external {
    (address _holder, uint256 _key) = makeAddrAndKey('ptHolder');
    address _delegatee = makeAddr('delegatee');
    uint256 _nonce = _principalToken.nonces(_holder);
    (uint8 _v, bytes32 _r, bytes32 _s) = _signDelegation(_principalToken, _key, _delegatee, _nonce);

    vm.prank(_admin);
    _relay.setName(_NEW_NAME);

    // it should still set the delegate after it
    _principalToken.delegateBySig(_delegatee, _nonce, type(uint256).max, _v, _r, _s);
    assertEq(_principalToken.delegates(_holder), _delegatee);
  }

  /// @notice Rebuild a clone's EIP-712 domain the way an outside signer has to: from the name the
  ///         token reports, the version Solady defaults to, the chain and the clone's own address.
  /// @param _relayToken The clone to build the domain for.
  /// @return _domain The domain separator that name implies.
  function _expectedDomain(RelayToken _relayToken) internal view returns (bytes32 _domain) {
    _domain = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256(bytes(_relayToken.name())),
        keccak256('1'),
        block.chainid,
        address(_relayToken)
      )
    );
  }
}
