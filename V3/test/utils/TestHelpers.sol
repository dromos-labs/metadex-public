// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';
import {Test} from 'forge-std/Test.sol';

import {Users} from 'V3-test/utils/TestUsers.sol';

interface IERC20PermitTest {
  function DOMAIN_SEPARATOR() external view returns (bytes32 _domainSeparator);
  function nonces(address _owner) external view returns (uint256 _nonce);
}

/**
 * @title TestHelpers
 * @notice Contains helper functions for tests
 */
contract TestHelpers is Test {
  using stdStorage for StdStorage;

  uint256 public constant MAX_TIME = 4 * 365 * 86_400;
  uint256 public constant PRECISION = 1e18;
  uint256 public constant FEE_ACCUMULATOR_PRECISION = 1e24;
  uint256 public constant TOKEN_1 = 1e18;
  uint256 public constant USDC_1 = 1e6;

  /// @dev Shared named test users
  Users public users = Users({
    owner: payable(makeAddr('Owner')),
    feeManager: payable(makeAddr('FeeManager')),
    alice: payable(makeAddr('Alice')),
    bob: payable(makeAddr('Bob')),
    charlie: payable(makeAddr('Charlie')),
    referral: payable(makeAddr('Referral')),
    deployer: payable(makeAddr('Deployer'))
  });

  bytes32 internal constant _ERC20_PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
  uint256 internal constant _SOLADY_ERC20_ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

  /**
   * @notice Returns the ceiling of the division of two numbers
   * @param _a The dividend
   * @param _b The divisor
   * @return _result The ceiling of the division
   */
  function _ceilDiv(uint256 _a, uint256 _b) internal pure returns (uint256 _result) {
    _result = (_a + _b - 1) / _b;
  }

  /**
   * @notice Ensures that a fuzzed address can be used for deployment and calls
   * @param _address The address to check
   */
  function _assumeFuzzable(address _address) internal pure {
    assumeNotForgeAddress(_address);
    assumeNotZeroAddress(_address);
    assumeNotPrecompile(_address);
  }

  /**
   * @notice Sets up a mock and expects a call to it
   * @param _receiver The address to have a mock on
   * @param _calldata The calldata to mock and expect
   * @param _returned The data to return from the mocked call
   */
  // solhint-disable-next-line ordering
  function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata);
  }

  /**
   * @notice Sets up a value-scoped mock and expects a call to it carrying that exact `msg.value`
   * @param _receiver The address to have a mock on
   * @param _value The exact `msg.value` to match for both the mock and the expectation
   * @param _calldata The calldata to mock and expect
   * @param _returned The data to return from the mocked call
   */
  function _mockAndExpectWithValue(
    address _receiver,
    uint256 _value,
    bytes memory _calldata,
    bytes memory _returned
  ) internal {
    vm.mockCall(_receiver, _value, _calldata, _returned);
    vm.expectCall(_receiver, _value, _calldata);
  }

  /**
   * @notice Sets up a mock and expects a call to it
   * @param _receiver The address to have a mock on
   * @param _calldata The calldata to mock and expect
   * @param _returned The data to return from the mocked call
   * @param _times The number of times to expect the call
   */
  function _mockAndExpectWithTimes(
    address _receiver,
    bytes memory _calldata,
    bytes memory _returned,
    uint8 _times
  ) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata, _times);
  }

  /**
   * @notice Sets up a mock that replays a sequence of responses and expects exactly that many calls
   * @param _receiver The address to have a mock on
   * @param _calldata The calldata to mock and expect
   * @param _returns The ordered responses returned one per call
   */
  function _mockAndExpectSequence(address _receiver, bytes memory _calldata, bytes[] memory _returns) internal {
    vm.mockCalls(_receiver, _calldata, _returns);
    vm.expectCall(_receiver, _calldata, uint64(_returns.length));
  }

  /**
   * @notice Creates a mock contract, labels it and etches some bytecode
   * @param _name The label to use for the mock contract
   * @return _contract The address of the mock contract
   */
  function _mockContract(string memory _name) internal returns (address _contract) {
    _contract = makeAddr(_name);
    vm.etch(_contract, hex'69');
  }

  /**
   * @notice Mocks `IERC20.balanceOf(_holder)` on `_token` to return `_balance` and expects the call
   */
  function _mockAndExpectTokenBalance(address _token, address _holder, uint256 _balance) internal {
    _mockAndExpect(_token, abi.encodeCall(IERC20.balanceOf, (_holder)), abi.encode(_balance));
  }

  /**
   * @notice Mocks `IERC20.balanceOf(_holder)` on `_token` with sequential responses and expects the call twice
   */
  function _mockAndExpectTokenBalancesTwice(address _token, address _holder, uint256[2] memory _balances) internal {
    uint256[] memory _sequence = new uint256[](2);
    _sequence[0] = _balances[0];
    _sequence[1] = _balances[1];
    _mockAndExpectTokenBalances(_token, _holder, _sequence);
  }

  /**
   * @notice Mocks `IERC20.balanceOf(_holder)` with sequential responses and expects the matching call count
   * @param _token The token to mock `balanceOf` on
   * @param _holder The holder whose balance is queried
   * @param _balances The balances returned on successive calls
   */
  function _mockAndExpectTokenBalances(address _token, address _holder, uint256[] memory _balances) internal {
    bytes[] memory _responses = new bytes[](_balances.length);
    for (uint256 _i; _i < _balances.length; ++_i) {
      _responses[_i] = abi.encode(_balances[_i]);
    }
    bytes memory _data = abi.encodeCall(IERC20.balanceOf, (_holder));
    vm.mockCalls(_token, _data, _responses);
    vm.expectCall(_token, _data, uint64(_balances.length));
  }

  /**
   * @notice Mocks `IERC20.transfer(_to, _amount)` to return true and expects the call
   */
  function _mockAndExpectTokenTransfer(address _token, address _to, uint256 _amount) internal {
    _mockAndExpect(_token, abi.encodeCall(IERC20.transfer, (_to, _amount)), abi.encode(true));
  }

  /**
   * @notice Sets an expectation for an event to be emitted
   * @param _contract The contract to expect the event on
   */
  function _expectEmit(address _contract) internal {
    vm.expectEmit(true, true, true, true, _contract);
  }

  function _mockApprove(address _token, address _owner, address _spender, uint256 _amount) internal {
    bytes32 _allowanceSlot;
    assembly {
      mstore(0x20, _spender)
      mstore(0x0c, _SOLADY_ERC20_ALLOWANCE_SLOT_SEED)
      mstore(0x00, _owner)
      _allowanceSlot := keccak256(0x0c, 0x34)
    }
    vm.store(_token, _allowanceSlot, bytes32(_amount));
  }

  /**
   * @notice Returns an address excluding address(0)
   * @param _addr The address to bound
   * @return _boundedAddress The address excluding address(0)
   */
  function _excludingAddressZero(address _addr) internal returns (address _boundedAddress) {
    _boundedAddress = _boundAddressBetween(_addr, address(1), address(type(uint160).max));
  }

  /**
   * @notice Clamps an address between a start and end range
   * @param _addr The address to clamp
   * @param _startRange The start of the range
   * @param _endRange The end of the range
   * @return _boundedAddress The clamped address
   */
  function _boundAddressBetween(
    address _addr,
    address _startRange,
    address _endRange
  ) internal returns (address _boundedAddress) {
    _boundedAddress = address(uint160(bound(uint160(_addr), uint160(_startRange), uint160(_endRange))));

    vm.label(_boundedAddress, 'random address');
  }

  /**
   * @notice Generates a random address that is not equal to a specific address (e.g. contract)
   * @param _addr The address to bound
   * @param _specificAddress The specific address to bound against
   * @return _boundedAddress The bounded address not equal to the specific address
   */
  function _boundNotEq(address _addr, address _specificAddress) internal returns (address _boundedAddress) {
    _boundedAddress = _excludingAddressZero(_addr);

    while (_boundedAddress == _specificAddress) {
      uint160 _seed = uint160(bytes20(keccak256(abi.encodePacked(_boundedAddress, _specificAddress))));
      _boundedAddress = _excludingAddressZero(address(_seed));
    }

    vm.label(_boundedAddress, 'random address');
  }

  function _expectedDomainSeparator(
    address _tokenAddress,
    string memory _tokenName
  ) internal view returns (bytes32 _domainSeparator) {
    bytes32 _domainTypeHash = keccak256(
      'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
    );
    bytes32 _nameHash = keccak256(bytes(_tokenName));
    bytes32 _versionHash = keccak256('1');
    uint256 _chainId = block.chainid;

    _domainSeparator = keccak256(abi.encode(_domainTypeHash, _nameHash, _versionHash, _chainId, _tokenAddress));
  }

  function _signedPermit(
    address _token,
    uint256 _ownerPk,
    address _owner,
    address _spender,
    uint256 _amount,
    uint256 _deadline
  ) internal view returns (uint8 _v, bytes32 _r, bytes32 _s) {
    IERC20PermitTest _permitToken = IERC20PermitTest(_token);
    bytes32 _structHash =
      keccak256(abi.encode(_ERC20_PERMIT_TYPEHASH, _owner, _spender, _amount, _permitToken.nonces(_owner), _deadline));
    bytes32 _digest = keccak256(abi.encodePacked('\x19\x01', _permitToken.DOMAIN_SEPARATOR(), _structHash));

    (_v, _r, _s) = vm.sign(_ownerPk, _digest);
  }

  /**
   * @notice Checks if an address is contained in an array of addresses
   * @param _address The address to check
   * @param _addresses The array of addresses to check
   * @return _contained Whether the address is contained in the array
   */
  function _containsAddress(address _address, address[] memory _addresses) internal pure returns (bool _contained) {
    for (uint256 _i; _i < _addresses.length; _i++) {
      if (_addresses[_i] == _address) {
        return true;
      }
    }

    return false;
  }

  /**
   * @notice Computes the address of a contract deployed using create
   * @param _deployer The address of the deployer
   * @param _nonce The nonce to use for the deployment
   * @return _address The address of the contract
   */
  function _computeCreate(address _deployer, uint256 _nonce) internal pure returns (address) {
    bytes memory data;
    if (_nonce == 0) {
      data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _deployer, bytes1(0x80));
    } else if (_nonce <= 0x7f) {
      data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), _deployer, bytes1(uint8(_nonce)));
    } else {
      revert('use full RLP for large nonce');
    }
    bytes32 h = keccak256(data);
    return address(uint160(uint256(h)));
  }

  /**
   * @notice Etches the CreateX factory at the given address by running its creation code there.
   * @dev Reads the creation bytecode from the compiled artifact so no AGPL-3.0-only source is
   *      incorporated into this contract.
   * @param _createX The address to etch the CreateX factory at
   */
  function _etchCreateX(address _createX) internal {
    bytes memory _creationCode = vm.getCode('node_modules/createx/artifacts/src/CreateX.sol/CreateX.json');
    require(_creationCode.length != 0, 'CreateX artifact missing');
    vm.etch(_createX, _creationCode);
    (bool _success, bytes memory _runtimeCode) = _createX.call('');
    require(_success, 'CreateX etch failed');
    vm.etch(_createX, _runtimeCode);
  }

  /**
   * @notice Sets a value in the storage of a contract
   * @param _value The value to set
   * @param _sig The signature of the function to set the value in
   */
  function _set(address _contract, uint256 _value, bytes4 _sig) internal {
    stdstore.target(_contract).sig(_sig).checked_write(_value);
  }
}
