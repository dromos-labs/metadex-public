// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FlatFeeQuoter} from 'V3/fees/FlatFeeQuoter.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitFlatFeeQuoter is TestHelpers {
  address internal _factory = _mockContract('factory');

  FlatFeeQuoter internal _quoter;

  function setUp() public {
    _quoter = new FlatFeeQuoter({_factory: _factory});
  }

  function test_ConstructorShouldSetFactoryToTheProvidedFactoryAddress() external view {
    // it should set factory to the provided factory address
    assertEq(address(_quoter.FACTORY()), _factory);
  }

  function test_GetFeeForAmountInWhenTheFactoryQuotesAFee(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee,
    uint256 _mevFee,
    bool _toxic
  ) external {
    // it should forward the pool caller amounts and reserves to the factory
    _mockAndExpect(
      _factory,
      abi.encodeCall(
        IPoolFactory.getFee, (_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1)
      ),
      abi.encode(_fee, _mevFee, _toxic)
    );

    // it should return the total fee the factory quotes
    assertEq(
      _quoter.getFeeForAmountIn(_pool, _caller, _amount0InAfterFee, _amount1InAfterFee, _reserve0, _reserve1), _fee
    );
  }
}
