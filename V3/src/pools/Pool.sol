// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {PoolOracle} from 'V3/libraries/PoolOracle.sol';

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IPoolCallee} from 'V3/interfaces/pools/IPoolCallee.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';

import {PoolFees} from 'V3/pools/PoolFees.sol';

/// @title Pool
/// @author velodrome.finance, Solidly, Uniswap Labs, @figs999, @pegahcarter
/// @notice Abstract base for Aerodrome V2 token pools. Curve-specific math is supplied by child contracts.
abstract contract Pool is IPool, ERC20, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using PoolOracle for PoolOracle.ObservationBuffer;

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPool
  uint256 public constant PERIOD_SIZE = 1 minutes;
  /// @notice The minimum liquidity for a pool
  uint256 internal constant _MINIMUM_LIQUIDITY = 10 ** 3;
  /// @notice Basis points scale used as the fee denominator (100%)
  uint256 internal constant _MAX_BPS = 10_000;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @notice The name of the pool
  // slither-disable-next-line shadowing-state
  string private _name;
  /// @notice The symbol of the pool
  // slither-disable-next-line shadowing-state
  string private _symbol;

  /// @inheritdoc IPool
  address public token0;
  /// @inheritdoc IPool
  address public token1;
  /// @inheritdoc IPool
  address public poolFees;
  /// @inheritdoc IPool
  address public factory;

  /// @notice Circular buffer of TWAP observations with its write index and cardinality metadata.
  PoolOracle.ObservationBuffer public observationBuffer;

  /// @notice The number of decimals of token0
  uint256 internal _decimals0;
  /// @notice The number of decimals of token1
  uint256 internal _decimals1;

  /// @inheritdoc IPool
  uint256 public reserve0;
  /// @inheritdoc IPool
  uint256 public reserve1;
  /// @inheritdoc IPool
  uint256 public blockTimestampLast;

  /// @inheritdoc IPool
  uint256 public reserve0CumulativeLast;
  /// @inheritdoc IPool
  uint256 public reserve1CumulativeLast;

  /// @inheritdoc IPool
  uint256 public index0;
  /// @inheritdoc IPool
  uint256 public index1;

  /// @inheritdoc IPool
  mapping(address => uint256) public supplyIndex0;
  /// @inheritdoc IPool
  mapping(address => uint256) public supplyIndex1;

  /// @inheritdoc IPool
  mapping(address => uint256) public claimable0;
  /// @inheritdoc IPool
  mapping(address => uint256) public claimable1;
  /// @inheritdoc IPool
  mapping(address _account => mapping(address _operator => bool _approved)) public approvedForClaim;

  /*////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  constructor() ERC20('', '') {}

  /*////////////////////////////////////////////////////////////
                  EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPool
  function approveForClaim(address _operator, bool _approved) external {
    if (_operator == address(0)) revert ZeroAddress();
    approvedForClaim[msg.sender][_operator] = _approved;
    emit ClaimApproval(msg.sender, _operator, _approved);
  }

  /// @inheritdoc IPool
  function claimFees(address _recipient) external returns (uint256, uint256) {
    if (_recipient == address(0)) revert ZeroAddress();
    return _claimFees(msg.sender, _recipient);
  }

  /// @inheritdoc IPool
  function claimFees(address _account, address _recipient) external returns (uint256, uint256) {
    if (_recipient == address(0)) revert ZeroAddress();
    if (msg.sender != _account && !approvedForClaim[_account][msg.sender]) revert NotAuthorized();
    return _claimFees(_account, _recipient);
  }

  /// @inheritdoc IPool
  function getK() external nonReentrant returns (uint256) {
    return _k(reserve0, reserve1);
  }

  /// @inheritdoc IPool
  function setName(string calldata __name) external {
    if (msg.sender != IPoolFactory(factory).poolAdmin()) revert IPoolFactory.NotPoolAdmin();
    _name = __name;
  }

  /// @inheritdoc IPool
  function setSymbol(string calldata __symbol) external {
    if (msg.sender != IPoolFactory(factory).poolAdmin()) revert IPoolFactory.NotPoolAdmin();
    _symbol = __symbol;
  }

  // slither-disable-start reentrancy-no-eth
  /// @inheritdoc IPool
  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
    if (IPoolFactory(factory).isPaused()) revert IsPaused();
    if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
    (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
    if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

    uint256 _balance0;
    uint256 _balance1;
    {
      // scope for _token{0,1}, avoids stack too deep errors
      (address _token0, address _token1) = (token0, token1);
      if (to == _token0 || to == _token1) revert InvalidTo();
      if (amount0Out > 0) IERC20(_token0).safeTransfer(to, amount0Out); // optimistically transfer tokens
      if (amount1Out > 0) IERC20(_token1).safeTransfer(to, amount1Out); // optimistically transfer tokens
      if (data.length > 0) IPoolCallee(to).hook(msg.sender, amount0Out, amount1Out, data); // callback, used for flash loans
      _balance0 = IERC20(_token0).balanceOf(address(this));
      _balance1 = IERC20(_token1).balanceOf(address(this));
    }
    uint256 amount0In = _balance0 > _reserve0 - amount0Out ? _balance0 - (_reserve0 - amount0Out) : 0;
    uint256 amount1In = _balance1 > _reserve1 - amount1Out ? _balance1 - (_reserve1 - amount1Out) : 0;
    if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
    {
      // scope for reserve{0,1}Adjusted, avoids stack too deep errors
      // slither-disable-next-line uninitialized-local
      IPoolTape.PoolTapeData memory _tapeData;
      _tapeData.volume0 = uint128(amount0In + amount0Out);
      _tapeData.volume1 = uint128(amount1In + amount1Out);
      (address _token0, address _token1) = (token0, token1);
      // Calls _getSwapFee to avoid stack too dep errors
      (uint256 _fee, uint256 _mevFee, bool _toxic) = _getSwapFee(amount0In, amount1In, _reserve0, _reserve1);
      if (amount0In > 0) {
        uint256 _feeAmount0 = (amount0In * _fee) / _MAX_BPS;
        _update0(_feeAmount0);
        _tapeData.fee0 = uint128(_feeAmount0);
        _tapeData.mevFee0 = uint128((amount0In * _mevFee) / _MAX_BPS);
      }
      if (amount1In > 0) {
        uint256 _feeAmount1 = (amount1In * _fee) / _MAX_BPS;
        _update1(_feeAmount1);
        _tapeData.fee1 = uint128(_feeAmount1);
        _tapeData.mevFee1 = uint128((amount1In * _mevFee) / _MAX_BPS);
      }
      if (_toxic) {
        _tapeData.mevVolume0 = _tapeData.volume0;
        _tapeData.mevVolume1 = _tapeData.volume1;
      }
      // since we removed tokens, we need to reconfirm balances
      _balance0 = IERC20(_token0).balanceOf(address(this));
      _balance1 = IERC20(_token1).balanceOf(address(this));
      // The curve invariant, supplied by the child contract
      if (_k(_balance0, _balance1) < _k(_reserve0, _reserve1)) revert K();
      IPoolFactory(factory).recordPoolTape(_tapeData);
    }

    _update(_balance0, _balance1, _reserve0, _reserve1);
    emit Swap(msg.sender, to, amount0In, amount1In, amount0Out, amount1Out);
  }

  // slither-disable-end reentrancy-no-eth
  /// @inheritdoc IPool
  function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
    (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
    (address _token0, address _token1) = (token0, token1);
    uint256 _balance0 = IERC20(_token0).balanceOf(address(this));
    uint256 _balance1 = IERC20(_token1).balanceOf(address(this));
    uint256 _liquidity = balanceOf(address(this));

    uint256 _totalSupply = totalSupply(); // gas savings, must be defined here since totalSupply can update in _mintFee
    amount0 = (_liquidity * _balance0) / _totalSupply; // using balances ensures pro-rata distribution
    amount1 = (_liquidity * _balance1) / _totalSupply; // using balances ensures pro-rata distribution
    if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
    _burn(address(this), _liquidity);
    IERC20(_token0).safeTransfer(to, amount0);
    IERC20(_token1).safeTransfer(to, amount1);
    _balance0 = IERC20(_token0).balanceOf(address(this));
    _balance1 = IERC20(_token1).balanceOf(address(this));

    _kThresholdValidation(_balance0, _balance1);

    _update(_balance0, _balance1, _reserve0, _reserve1);
    emit Burn(msg.sender, to, amount0, amount1);
  }

  /// @inheritdoc IPool
  function mint(address to) external nonReentrant returns (uint256 liquidity) {
    (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
    uint256 _balance0 = IERC20(token0).balanceOf(address(this));
    uint256 _balance1 = IERC20(token1).balanceOf(address(this));
    uint256 _amount0 = _balance0 - _reserve0;
    uint256 _amount1 = _balance1 - _reserve1;

    uint256 _totalSupply = totalSupply(); // gas savings, must be defined here since totalSupply can update in _mintFee
    if (_totalSupply == 0) {
      liquidity = Math.sqrt(_amount0 * _amount1) - _MINIMUM_LIQUIDITY;
      _mint(address(1), _MINIMUM_LIQUIDITY); // permanently lock the first _MINIMUM_LIQUIDITY tokens - cannot be address(0)
      _mintValidation(_amount0, _amount1);
      if (liquidity < _MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
    } else {
      liquidity = Math.min((_amount0 * _totalSupply) / _reserve0, (_amount1 * _totalSupply) / _reserve1);
      if (liquidity == 0) revert InsufficientLiquidityMinted();
    }
    _mint(to, liquidity);

    _update(_balance0, _balance1, _reserve0, _reserve1);
    emit Mint(msg.sender, to, _amount0, _amount1);
  }

  /// @inheritdoc IPool
  function skim(address to) external nonReentrant {
    (address _token0, address _token1) = (token0, token1);
    IERC20(_token0).safeTransfer(to, IERC20(_token0).balanceOf(address(this)) - (reserve0));
    IERC20(_token1).safeTransfer(to, IERC20(_token1).balanceOf(address(this)) - (reserve1));
  }

  /// @inheritdoc IPool
  function sync() external nonReentrant {
    if (totalSupply() == 0) revert InsufficientLiquidity();
    _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
  }

  /// @inheritdoc IPool
  function initialize(address _token0, address _token1) external {
    if (factory != address(0)) revert FactoryAlreadySet();
    factory = msg.sender;
    (token0, token1) = (_token0, _token1);
    poolFees = address(new PoolFees(_token0, _token1));
    string memory symbol0 = ERC20(_token0).symbol();
    string memory symbol1 = ERC20(_token1).symbol();
    _name = _poolName(symbol0, symbol1);
    _symbol = _poolSymbol(symbol0, symbol1);

    _decimals0 = 10 ** ERC20(_token0).decimals();
    _decimals1 = 10 ** ERC20(_token1).decimals();

    observationBuffer.initialize();
  }

  /// @inheritdoc IPool
  /// @dev Pre-initialises buffer slots so observation writes hit warm storage.
  function increaseObservationCardinalityNext(uint16 _observationCardinalityNext) external {
    uint16 _currentCardinalityNext = observationBuffer.cardinalityNext;
    uint16 _updatedCardinalityNext = observationBuffer.grow(_observationCardinalityNext);
    if (_updatedCardinalityNext != _currentCardinalityNext) {
      emit IncreaseObservationCardinalityNext(msg.sender, _currentCardinalityNext, _updatedCardinalityNext);
    }
  }

  /*////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @dev Claims `_account`'s accumulated fees to `_recipient`.
  function _claimFees(address _account, address _recipient) internal returns (uint256 _claimed0, uint256 _claimed1) {
    _updateFor(_account);

    _claimed0 = claimable0[_account];
    _claimed1 = claimable1[_account];

    if (_claimed0 > 0 || _claimed1 > 0) {
      delete claimable0[_account];
      delete claimable1[_account];

      PoolFees(poolFees).claimFeesFor({_recipient: _recipient, _amount0: _claimed0, _amount1: _claimed1});

      emit Claim({caller: msg.sender, account: _account, recipient: _recipient, amount0: _claimed0, amount1: _claimed1});
    }
  }

  /// @dev Accrue fees on token0
  function _update0(uint256 amount) internal {
    // Only update on this pool if there is a fee
    if (amount == 0) return;
    IERC20(token0).safeTransfer(poolFees, amount); // transfer the fees out to PoolFees
    uint256 _ratio = (amount * 1e18) / totalSupply(); // 1e18 adjustment is removed during claim
    if (_ratio > 0) {
      index0 += _ratio;
    }
    emit Fees(msg.sender, amount, 0);
  }

  /// @dev Accrue fees on token1
  function _update1(uint256 amount) internal {
    // Only update on this pool if there is a fee
    if (amount == 0) return;
    IERC20(token1).safeTransfer(poolFees, amount);
    uint256 _ratio = (amount * 1e18) / totalSupply();
    if (_ratio > 0) {
      index1 += _ratio;
    }
    emit Fees(msg.sender, 0, amount);
  }

  /// @dev This function MUST be called on any balance changes, otherwise can be used to infinitely claim fees
  ///      Fees are segregated from core funds, so fees can never put liquidity at risk.
  function _updateFor(address recipient) internal {
    uint256 _supplied = balanceOf(recipient); // get LP balance of `recipient`
    if (_supplied > 0) {
      uint256 _supplyIndex0 = supplyIndex0[recipient]; // get last adjusted index0 for recipient
      uint256 _supplyIndex1 = supplyIndex1[recipient];
      uint256 _index0 = index0; // get global index0 for accumulated fees
      uint256 _index1 = index1;
      supplyIndex0[recipient] = _index0; // update user current position to global position
      supplyIndex1[recipient] = _index1;
      uint256 _delta0 = _index0 - _supplyIndex0; // see if there is any difference that need to be accrued
      uint256 _delta1 = _index1 - _supplyIndex1;
      if (_delta0 > 0) {
        uint256 _share = (_supplied * _delta0) / 1e18; // add accrued difference for each supplied token
        claimable0[recipient] += _share;
      }
      if (_delta1 > 0) {
        uint256 _share = (_supplied * _delta1) / 1e18;
        claimable1[recipient] += _share;
      }
    } else {
      supplyIndex0[recipient] = index0; // new users are set to the default global state
      supplyIndex1[recipient] = index1;
    }
  }

  /// @notice Commits new balances to reserves and writes a new observation when due.
  /// @dev Cumulative accumulators advance by `_reserve* * timeElapsed` when previous reserves were
  ///      nonzero. The observation write is delegated to `PoolOracle.write`, which advances the buffer
  ///      only when more than `PERIOD_SIZE` has elapsed since the newest observation.
  /// @param  balance0 New token0 balance.
  /// @param  balance1 New token1 balance.
  /// @param  _reserve0 Previous token0 reserve
  /// @param  _reserve1 Previous token1 reserve
  function _update(uint256 balance0, uint256 balance1, uint256 _reserve0, uint256 _reserve1) internal {
    uint256 blockTimestamp = block.timestamp;
    uint256 timeElapsed = blockTimestamp - blockTimestampLast;
    if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
      reserve0CumulativeLast += _reserve0 * timeElapsed;
      reserve1CumulativeLast += _reserve1 * timeElapsed;
    }

    observationBuffer.write(reserve0CumulativeLast, reserve1CumulativeLast, PERIOD_SIZE);

    reserve0 = balance0;
    reserve1 = balance1;
    blockTimestampLast = blockTimestamp;
    emit Sync(balance0, balance1);
  }

  /// @dev Resolves the swap fee via the factory.
  function _getSwapFee(
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view returns (uint256 _fee, uint256 _mevFee, bool _toxic) {
    // slither-disable-next-line unused-return
    return IPoolFactory(factory).getFee(address(this), msg.sender, _amount0In, _amount1In, _reserve0, _reserve1);
  }

  /// @dev Curve invariant. The child contract supplies either the constant-product or
  ///      stable-swap formula.
  function _k(uint256 x, uint256 y) internal view virtual returns (uint256);

  /// @dev Output amount given an input and reserve snapshot. The child contract supplies
  ///      the curve-specific pricing.
  function _getAmountOut(
    uint256 amountIn,
    address tokenIn,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view virtual returns (uint256);

  /// @dev Input amount required for a requested output, before the swap fee. The child contract
  ///      supplies the curve-specific pricing.
  /// @param  amountOut The output amount to receive
  /// @param  tokenOut The output token
  /// @param  _reserve0 The token0 reserve to quote against
  /// @param  _reserve1 The token1 reserve to quote against
  /// @return The input amount before the fee
  function _getAmountIn(
    uint256 amountOut,
    address tokenOut,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view virtual returns (uint256);

  /// @dev Curve-specific validation invoked on the first mint.
  function _mintValidation(uint256 _amount0, uint256 _amount1) internal view virtual {}

  /// @dev Curve-specific post-burn check on remaining reserves
  function _kThresholdValidation(uint256 _x, uint256 _y) internal view virtual {}

  /// @dev Curve-specific full pool name used during initialization.
  function _poolName(string memory _symbol0, string memory _symbol1) internal pure virtual returns (string memory);

  /// @dev Curve-specific full pool symbol used during initialization.
  function _poolSymbol(string memory _symbol0, string memory _symbol1) internal pure virtual returns (string memory);

  function _update(address from, address to, uint256 amount) internal override {
    if (from != address(0)) _updateFor(from);
    if (to != address(0)) _updateFor(to);
    super._update(from, to, amount);
  }

  /*////////////////////////////////////////////////////////////
                      VIEW & PURE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPool
  function pendingFees(address _account) external view returns (uint256 _amount0, uint256 _amount1) {
    _amount0 = claimable0[_account];
    _amount1 = claimable1[_account];

    uint256 _supplied = balanceOf(_account);
    if (_supplied > 0) {
      _amount0 += (_supplied * (index0 - supplyIndex0[_account])) / 1e18;
      _amount1 += (_supplied * (index1 - supplyIndex1[_account])) / 1e18;
    }
  }

  /// @inheritdoc IPool
  function metadata()
    external
    view
    returns (uint256 dec0, uint256 dec1, uint256 r0, uint256 r1, address t0, address t1)
  {
    return (_decimals0, _decimals1, reserve0, reserve1, token0, token1);
  }

  /// @inheritdoc IPool
  function tokens() external view returns (address, address) {
    return (token0, token1);
  }

  /// @inheritdoc IPool
  function observe(uint32[] calldata _secondsAgos)
    external
    view
    returns (uint256[] memory _reserve0Cumulatives, uint256[] memory _reserve1Cumulatives)
  {
    (uint256 _r0Now, uint256 _r1Now,) = currentCumulativePrices();
    // slither-disable-next-line unused-return
    return observationBuffer.observe(_secondsAgos, _r0Now, _r1Now);
  }

  /// @inheritdoc IPool
  function observations(uint256 _index)
    external
    view
    returns (uint32 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative)
  {
    PoolOracle.Observation memory _observation = observationBuffer.observations[_index];
    return (_observation.timestamp, _observation.reserve0Cumulative, _observation.reserve1Cumulative);
  }

  /// @inheritdoc IPool
  function getAmountOut(
    uint256 amountIn,
    address tokenIn,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256) {
    (uint256 _amount0In, uint256 _amount1In) = tokenIn == token0 ? (amountIn, uint256(0)) : (uint256(0), amountIn);
    amountIn -= (amountIn
        * IPoolFactory(factory).getBaseFee(address(this), address(0), _amount0In, _amount1In, _reserve0, _reserve1))
      / _MAX_BPS;
    return _getAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
  }

  /// @inheritdoc IPool
  function currentCumulativePrices()
    public
    view
    returns (uint256 reserve0Cumulative, uint256 reserve1Cumulative, uint256 blockTimestamp)
  {
    blockTimestamp = block.timestamp;
    reserve0Cumulative = reserve0CumulativeLast;
    reserve1Cumulative = reserve1CumulativeLast;

    // if time has elapsed since the last update on the pool, mock the accumulated price values
    (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast) = getReserves();
    if (_blockTimestampLast != blockTimestamp) {
      // subtraction overflow is desired
      uint256 timeElapsed = blockTimestamp - _blockTimestampLast;
      reserve0Cumulative += _reserve0 * timeElapsed;
      reserve1Cumulative += _reserve1 * timeElapsed;
    }
  }

  /// @inheritdoc IPool
  function getReserves() public view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast) {
    _reserve0 = reserve0;
    _reserve1 = reserve1;
    _blockTimestampLast = blockTimestampLast;
  }

  /// @inheritdoc IPool
  function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256) {
    (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
    (uint256 _amount0In, uint256 _amount1In) = tokenIn == token0 ? (amountIn, uint256(0)) : (uint256(0), amountIn);
    // remove fee from amount received
    amountIn -= (amountIn
        * IPoolFactory(factory).getBaseFee(address(this), address(0), _amount0In, _amount1In, _reserve0, _reserve1))
      / _MAX_BPS;
    return _getAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
  }

  /// @inheritdoc IPool
  function getAmountOutWithTotalFee(uint256 amountIn, address tokenIn) external view returns (uint256) {
    (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
    (uint256 _amount0In, uint256 _amount1In) = tokenIn == token0 ? (amountIn, uint256(0)) : (uint256(0), amountIn);
    (uint256 _fee,,) = _getSwapFee(_amount0In, _amount1In, _reserve0, _reserve1);
    // remove fee from amount received
    amountIn -= (amountIn * _fee) / _MAX_BPS;
    return _getAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
  }

  /// @inheritdoc IPool
  function getAmountInWithTotalFee(uint256 amountOut, address tokenOut) external view returns (uint256) {
    if (amountOut == 0) return 0;
    (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
    if (amountOut >= (tokenOut == token0 ? _reserve0 : _reserve1)) revert InsufficientLiquidity();

    uint256 _amountInAfterFee = _getAmountIn(amountOut, tokenOut, _reserve0, _reserve1);

    // this sanity check prevents underflow while calculating the grossed up input.
    // a swap with amount zero will revert due to insufficient liquidity.
    if (_amountInAfterFee == 0) return 0;

    (uint256 _amount0In, uint256 _amount1In) =
      tokenOut == token0 ? (uint256(0), _amountInAfterFee) : (_amountInAfterFee, uint256(0));
    uint256 _fee =
      IPoolFactory(factory).getFeeForAmountIn(address(this), msg.sender, _amount0In, _amount1In, _reserve0, _reserve1);
    return _amountInAfterFee + Math.mulDiv(_fee, _amountInAfterFee - 1, _MAX_BPS - _fee);
  }

  function name() public view override returns (string memory) {
    return _name;
  }

  function symbol() public view override returns (string memory) {
    return _symbol;
  }
}
