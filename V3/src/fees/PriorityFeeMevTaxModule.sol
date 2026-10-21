// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';

/// @title PriorityFeeMevTaxModule
/// @notice Computes the MEV tax for a swap from the transaction priority fee.
/// @dev Deposit transactions on OP Stack chains carry a zero gas price, so the priority fee
///      computation is skipped and the tax is zero.
/// @dev The module must stay unset on chains like Celo where the gas price can be denominated
///      in a fee currency while the base fee stays in the native token. Otherwise `getMevTax`
///      returns an invalid value.
contract PriorityFeeMevTaxModule is Ownable2Step, IMevTaxModule {
  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMevTaxModule
  uint24 public constant MEV_TAX_CAP = 100_000; // 10%

  /// @inheritdoc IMevTaxModule
  uint256 public constant PRECISION = 1e12;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMevTaxModule
  uint64 public priorityFeeMultiplier;

  /// @inheritdoc IMevTaxModule
  uint96 public minThreshold;

  /// @inheritdoc IMevTaxModule
  uint96 public baseFeeFactor;

  /*////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Deploys the module with its chain wide parameters.
  /// @param _initialOwner The initial owner.
  /// @param _priorityFeeMultiplier The chain wide priority fee multiplier.
  /// @param _minThreshold The floor of the adaptive retail threshold, in wei.
  /// @param _baseFeeFactor The congestion factor of the adaptive retail threshold.
  constructor(
    address _initialOwner,
    uint64 _priorityFeeMultiplier,
    uint96 _minThreshold,
    uint96 _baseFeeFactor
  ) Ownable(_initialOwner) {
    priorityFeeMultiplier = _priorityFeeMultiplier;
    minThreshold = _minThreshold;
    baseFeeFactor = _baseFeeFactor;
    emit MultiplierSet(_priorityFeeMultiplier);
    emit MinThresholdSet(_minThreshold);
    emit BaseFeeFactorSet(_baseFeeFactor);
  }

  /*////////////////////////////////////////////////////////////
                        AUTHORIZED FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMevTaxModule
  function setMultiplier(uint64 _priorityFeeMultiplier) external onlyOwner {
    priorityFeeMultiplier = _priorityFeeMultiplier;
    emit MultiplierSet(_priorityFeeMultiplier);
  }

  /// @inheritdoc IMevTaxModule
  function setMinThreshold(uint96 _minThreshold) external onlyOwner {
    minThreshold = _minThreshold;
    emit MinThresholdSet(_minThreshold);
  }

  /// @inheritdoc IMevTaxModule
  function setBaseFeeFactor(uint96 _baseFeeFactor) external onlyOwner {
    baseFeeFactor = _baseFeeFactor;
    emit BaseFeeFactorSet(_baseFeeFactor);
  }

  /*////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IMevTaxModule
  function getMevTax() external view returns (uint24, bool) {
    if (tx.gasprice <= block.basefee) return (0, false);

    uint256 _priorityFee = tx.gasprice - block.basefee;

    /// @dev Retail flow at or below the threshold is never taxed.
    uint256 _threshold = FixedPointMathLib.max(baseFeeFactor * block.basefee, minThreshold);
    if (_priorityFee <= _threshold) return (0, false);

    uint24 _mevTax = uint24(
      FixedPointMathLib.min(
        FixedPointMathLib.mulDivUp(_priorityFee - _threshold, priorityFeeMultiplier, PRECISION), MEV_TAX_CAP
      )
    );
    /// @dev Toxicity is independent of the tax outcome.
    return (_mevTax, true);
  }
}
