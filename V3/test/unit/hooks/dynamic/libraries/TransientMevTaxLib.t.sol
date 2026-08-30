// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {LibTransient} from '@solady/utils/LibTransient.sol';

import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';

import {TransientMevTaxLib} from 'V3/hooks/dynamic/libraries/TransientMevTaxLib.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitTransientMevTaxLib is UnitDynamicSwapFeeHookBase {
  using TransientMevTaxLib for mapping(address => LibTransient.TBytes32);

  mapping(address _pool => LibTransient.TBytes32 _mevData) internal _transientMevData;

  function test_WriteAndReadPacksDynamicFeeAndToxicAndStoresItInTransientStorage(
    uint24 _dynamicFee,
    bool _toxic
  ) external {
    _transientMevData.write(pool, _dynamicFee, _toxic);

    vm.record();
    (uint24 _storedDynamicFee, bool _storedToxic) = _transientMevData.read(pool);

    (, bytes32[] memory _sstores) = vm.accesses(address(this));
    assertEq(_sstores.length, 0);

    // it packs dynamic fee and toxic and stores it in transient storage
    assertEq(_storedDynamicFee, _dynamicFee);
    assertEq(_storedToxic, _toxic);
  }

  function test_MevTaxWhenMevTaxModuleIsAddressZero() external {
    // it doesn't call getMevTax
    (uint24 _mevTax, bool _toxic) = TransientMevTaxLib.mevTax(IMevTaxModule(address(0)));

    assertEq(_mevTax, 0);
    assertFalse(_toxic);
  }

  modifier whenMevTaxModuleIsntAddressZero() {
    _;
  }

  function test_MevTaxWhenGetMevTaxCallFails() external whenMevTaxModuleIsntAddressZero {
    vm.mockCallRevert(mevTaxModule, abi.encodeCall(IMevTaxModule.getMevTax, ()), abi.encode(1, true));

    (uint24 _mevTaxGot, bool _toxicGot) = TransientMevTaxLib.mevTax(IMevTaxModule(mevTaxModule));

    // it returns (0, false)
    assertEq(_mevTaxGot, 0);
    assertEq(_toxicGot, false);
  }

  function test_MevTaxWhenGetMevTaxCallSucceeds(uint24 _mevTax, bool _toxic) external whenMevTaxModuleIsntAddressZero {
    _mockAndExpectGetMevTax(_mevTax, _toxic);

    (uint24 _mevTaxGot, bool _toxicGot) = TransientMevTaxLib.mevTax(IMevTaxModule(mevTaxModule));

    // it returns mev tax and toxic
    assertEq(_mevTaxGot, _mevTax);
    assertEq(_toxicGot, _toxic);
  }
}
