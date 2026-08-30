// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeRecordVolatility is UnitClPoolTapeBase {
  function test_WhenTheCallerIsNotTheElasticFeeModule(address _invalidCaller) external {
    vm.assume(_invalidCaller != _elasticFeeModule);

    // it reverts with Unauthorized
    vm.expectRevert(IBasePoolTape.Unauthorized.selector);
    vm.prank(_invalidCaller);
    _tape.recordVolatility(_pool, 0, 0);
  }

  function test_WhenTheCallerIsTheElasticFeeModule(
    uint48 _volatilityCorrob,
    uint8 _nOver,
    uint16 _index,
    uint16 _cardinality,
    uint16 _cardinalityNext
  ) external {
    _cardinalityNext = uint16(bound(_cardinalityNext, 1, type(uint16).max - 1));
    _cardinality = uint16(bound(_cardinality, 1, _cardinalityNext));
    _index = uint16(bound(_index, 0, _cardinality - 1));
    _setObservationInformationSlot({_index: _index, _cardinality: _cardinality, _cardinalityNext: _cardinalityNext});

    // it emits VolatilityRecorded
    vm.expectEmit();
    emit ICLPoolTape.VolatilityRecorded(_pool, _volatilityCorrob, _nOver);
    vm.prank(_elasticFeeModule);
    _tape.recordVolatility(_pool, _volatilityCorrob, _nOver);

    // it writes volatilityCorrob onto the latest committed observation
    assertEq(_tape.getObservation(_pool, _index).volatilityCorrob, _volatilityCorrob);
    // it stores volatilityCorrob in the accumulator
    assertEq(_tape.accumulators(_pool).volatilityCorrob, _volatilityCorrob);
    // it stores nOver in the accumulator
    assertEq(_tape.accumulators(_pool).nOver, _nOver);
  }
}
