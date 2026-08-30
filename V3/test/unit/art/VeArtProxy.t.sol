// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Base64} from '@solady/utils/Base64.sol';
import {LibString} from '@solady/utils/LibString.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {VeArtProxy} from 'V3/art/VeArtProxy.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVeArtProxy is TestHelpers {
  uint256 internal constant _REFERENCE_TOKEN_ID = 321_241;
  uint128 internal constant _REFERENCE_AMOUNT = 7500e18;
  uint48 internal constant _REFERENCE_END = 1_864_454_400;
  address internal _ve = makeAddr('VotingEscrow');
  address internal _voter = makeAddr('Voter');
  VeArtProxy internal _proxy;

  function setUp() external {
    _proxy = new VeArtProxy(_ve, _voter);
  }

  /*//////////////////////////////////////////////////////////////
                                 svg
  //////////////////////////////////////////////////////////////*/

  function test_SvgWhenRenderingTheCanonicalFixture() external {
    _mockState(_REFERENCE_TOKEN_ID, _REFERENCE_AMOUNT, _REFERENCE_END, false, _REFERENCE_AMOUNT);

    // it should match the sAERO reference svg exactly
    assertEq(_proxy.svg(_REFERENCE_TOKEN_ID), vm.readFile('V3/test/fixtures/art/saero.svg'));
  }

  function test_SvgWhenTheStakeAndAllocationAmountsVary(
    uint256 _tokenId,
    uint128 _stakeAmount,
    uint128 _allocation
  ) external {
    _tokenId = bound(_tokenId, 1, 1e9);
    _stakeAmount = uint128(bound(_stakeAmount, 0, type(uint128).max));
    _allocation = uint128(bound(_allocation, 0, type(uint128).max));

    _mockState(_tokenId, _stakeAmount, _REFERENCE_END, false, _allocation);

    string memory _svg = _proxy.svg(_tokenId);

    // it should render the live VotingEscrow stake and stored Voter allocation
    assertTrue(LibString.contains(_svg, string.concat('STAKED:</tspan> <tspan>', _formatAmount(_stakeAmount, ' AERO'))));
    assertTrue(
      LibString.contains(_svg, string.concat('ALLOCATION POWER:</tspan> <tspan>', _formatAmount(_allocation, ' sAERO')))
    );
  }

  function test_SvgWhenTheStakeIsPermanent(uint256 _tokenId, uint128 _amount, uint128 _allocation) external {
    _tokenId = bound(_tokenId, 1, 1e9);
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _allocation = uint128(bound(_allocation, 0, type(uint128).max));

    _mockState(_tokenId, _amount, 0, true, _allocation);

    // it should render a permanent unstake label
    assertTrue(LibString.contains(_proxy.svg(_tokenId), 'UNSTAKE DATE:</tspan> <tspan>PERMANENT'));
  }

  function test_SvgWhenTheStakeHasBeenWithdrawn(uint256 _tokenId, uint128 _allocation) external {
    _tokenId = bound(_tokenId, 1, 1e9);
    _allocation = uint128(bound(_allocation, 0, type(uint128).max));

    _mockState(_tokenId, 0, 0, false, _allocation);

    // it should render a withdrawn no stake label
    assertTrue(LibString.contains(_proxy.svg(_tokenId), 'UNSTAKE DATE:</tspan> <tspan>WITHDRAWN / NO STAKE'));
  }

  function test_SvgWhenTheStakeHasAnUnstakeTimestamp() external {
    _mockState(_REFERENCE_TOKEN_ID, _REFERENCE_AMOUNT, _REFERENCE_END, false, _REFERENCE_AMOUNT);

    // it should render the formatted unstake date
    assertTrue(LibString.contains(_proxy.svg(_REFERENCE_TOKEN_ID), 'UNSTAKE DATE:</tspan> <tspan>30 JAN, 2029'));
  }

  /*//////////////////////////////////////////////////////////////
                              tokenURI
  //////////////////////////////////////////////////////////////*/

  function test_TokenURIWhenTheTokenMetadataIsGenerated(
    uint256 _tokenId,
    uint128 _amount,
    uint128 _allocation
  ) external {
    _tokenId = bound(_tokenId, 1, 1e9);
    _amount = uint128(bound(_amount, 0, type(uint128).max));
    _allocation = uint128(bound(_allocation, 0, type(uint128).max));

    _mockState(_tokenId, _amount, _REFERENCE_END, false, _allocation);
    string memory _expectedImage =
      string.concat('data:image/svg+xml;base64,', Base64.encode(bytes(_proxy.svg(_tokenId))));

    string memory _json = string(Base64.decode(LibString.slice(_proxy.tokenURI(_tokenId), 29)));

    // it should embed the generated base64 svg
    assertTrue(LibString.contains(_json, _expectedImage));
  }

  function _mockState(
    uint256 _tokenId,
    uint128 _stakeAmount,
    uint48 _end,
    bool _isPermanent,
    uint128 _allocation
  ) internal {
    vm.mockCall(
      _ve,
      abi.encodeCall(IVotingEscrow.staked, (_tokenId)),
      abi.encode(IVotingEscrow.StakedBalance({amount: _stakeAmount, end: _end, isPermanent: _isPermanent}))
    );
    vm.mockCall(
      _voter, abi.encodeCall(IVoter.tokenStates, (_tokenId)), abi.encode(_allocation, uint48(0), uint48(0), false)
    );
  }

  function _formatAmount(uint256 _value, string memory _suffix) internal pure returns (string memory _amount) {
    uint256 _whole = _value / 1e18;
    uint256 _cents = (_value % 1e18) / 1e16;

    _amount =
      string.concat(_formatWholeNumber(_whole), '.', _cents < 10 ? '0' : '', LibString.toString(_cents), _suffix);
  }

  function _formatWholeNumber(uint256 _value) internal pure returns (string memory _formatted) {
    string memory _digits = LibString.toString(_value);
    bytes memory _raw = bytes(_digits);
    uint256 _commaCount = (_raw.length - 1) / 3;
    if (_commaCount == 0) return _digits;

    bytes memory _withCommas = new bytes(_raw.length + _commaCount);
    uint256 _readIndex = _raw.length;
    uint256 _writeIndex = _withCommas.length;
    uint256 _groupDigits;

    while (_readIndex != 0) {
      if (_groupDigits == 3) {
        _withCommas[--_writeIndex] = ',';
        _groupDigits = 0;
      }
      _withCommas[--_writeIndex] = _raw[--_readIndex];
      ++_groupDigits;
    }

    _formatted = string(_withCommas);
  }
}
