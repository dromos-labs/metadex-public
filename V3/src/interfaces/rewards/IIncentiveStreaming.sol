// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IIncentiveStreaming {
  /**
   * @notice Incentive stream configuration
   * @param token Token streamed by the program
   * @param amount Total token amount deposited for the program
   * @param rate Token amount streamed per second, scaled by `PRECISION`
   * @param start Timestamp when streaming starts
   * @param end Timestamp when streaming ends
   * @param creator Address that created the program
   */
  struct IncentiveProgram {
    address token;
    uint256 amount;
    uint256 rate;
    uint48 start;
    uint48 end;
    address creator;
  }

  /**
   * @notice Program-agnostic prefix accumulators of the global vote supply over time, snapshotted at each
   *         global reward checkpoint. They describe only supply-over-time, so a single pair prices every
   *         incentive program: a claim reads the deltas between two checkpoint indices and multiplies by the
   *         program rate and the voter's voting power. Both are scaled by the accumulator precision and skip
   *         intervals with zero supply.
   * @param sharePerVote Sum over prior intervals of `dt / supply` - reward share accrued per unit of voting
   *        power per unit of stream rate; prices a permanent (constant) voter directly
   * @param weightedSharePerVote Sum over prior intervals of `(intervalEnd - 1 - origin) * dt / supply` - the
   *        time-weighted companion needed to price a decaying voter, whose voting power shrinks each second.
   */
  struct SupplyAccumulator {
    uint256 sharePerVote;
    uint256 weightedSharePerVote;
  }

  /**
   * @notice Emitted when a new incentive program is created
   * @param _programId Incentive program ID
   * @param _token Token streamed by the program
   * @param _creator Address that created the program
   * @param _amount Total token amount deposited for the program
   * @param _start Timestamp when streaming starts
   * @param _duration Duration of the program in seconds
   */
  event IncentiveCreated(
    uint256 indexed _programId,
    address indexed _token,
    address indexed _creator,
    uint256 _amount,
    uint48 _start,
    uint48 _duration
  );

  /**
   * @notice Emitted when a creator sweeps tokens streamed during zero-voter intervals
   * @param _programId Incentive program ID
   * @param _creator Address that received the swept tokens
   * @param _amount Amount of tokens swept
   */
  event IncentiveSwept(uint256 indexed _programId, address indexed _creator, uint256 _amount);

  /// @notice Thrown when a token is not listed in the token registry
  error NotListed();

  /// @notice Thrown when a program starts before the current timestamp
  error InvalidStart();

  /// @notice Thrown when program duration is shorter than the minimum duration
  error InsufficientDuration();

  /// @notice Thrown when program amount is too small for its duration
  error InsufficientAmount();

  /// @notice Thrown when reaching the required timestamp would take more than `MAX_CHECKPOINT_ITERATIONS`
  error StaleCheckpointHistory();

  /// @notice Thrown when a payout exceeds the program's remaining balance
  error InsufficientProgramBalance();

  /// @notice Thrown when the incentive program ID is invalid
  error InvalidProgramId();

  /// @notice Thrown when the address passed is the zero address
  error ZeroAddress();

  /// @notice Thrown when the program ID does not correspond to an existing program
  error ProgramNotFound();

  /// @notice Thrown when sweep is called before the program has ended
  error ProgramNotEnded();

  /// @notice Thrown when the caller is not the program creator
  error NotCreator();

  /**
   * @notice Creates a new incentive program that streams tokens at a constant rate
   * @dev The deposited amount is rounded down to match the calculated rate.
   *      The token must be listed on the token registry.
   *      Reverts with StaleCheckpointHistory if reaching the current timestamp exceeds the iteration limit
   * @param _token The reward token address
   * @param _amount The amount of tokens intended for the program
   * @param _start The timestamp when streaming begins
   * @param _duration The duration of the program in seconds
   * @return The unique identifier of the created program
   */
  function createIncentiveProgram(
    address _token,
    uint256 _amount,
    uint48 _start,
    uint48 _duration
  ) external returns (uint256);

  /**
   * @notice Recovers tokens that were streamed during zero-voter intervals to the program creator
   * @dev Only callable by the program creator after the program ends
   *      Advance global checkpoints before retrying if the program end cannot be reached within the iteration limit
   * @param _programId The program to sweep
   */
  function sweep(uint256 _programId) external;

  /**
   * @notice Returns the address of the Voter contract
   * @return The Voter contract address
   */
  function voter() external view returns (address);

  /**
   * @notice Returns the address of the TokenRegistry used for token listing, resolved through the Voter's FactoryRegistry
   * @return The TokenRegistry contract address
   */
  function tokenRegistry() external view returns (address);

  /**
   * @notice The total number of incentive programs created
   * @return The current incentive program count
   */
  function incentiveCount() external view returns (uint256);

  /**
   * @notice Returns the incentive program for a given program ID
   * @param _programId The unique identifier of the program
   * @return The program struct
   */
  function incentive(uint256 _programId) external view returns (IncentiveProgram memory);

  /**
   * @notice Returns the incentive programs for a given list of program IDs
   * @param _programIds The program IDs to fetch
   * @return The program structs
   */
  function incentives(uint256[] calldata _programIds) external view returns (IncentiveProgram[] memory);

  /**
   * @notice Returns the number of incentive programs for a given token
   * @param _token The reward token address
   * @return The number of programs streaming this token
   */
  function incentiveCountByToken(address _token) external view returns (uint256);

  /**
   * @notice Returns a paginated list of program IDs for a given token
   * @param _token The reward token address
   * @param _start The start index (inclusive)
   * @param _end The end index (exclusive)
   * @return The program IDs in the specified range
   */
  function incentivesByToken(address _token, uint256 _start, uint256 _end) external view returns (uint256[] memory);

  /**
   * @notice Returns the number of incentive programs created by a given address
   * @param _creator The creator address
   * @return The number of programs created by this address
   */
  function incentiveCountByCreator(address _creator) external view returns (uint256);

  /**
   * @notice Returns a paginated list of program IDs for a given creator
   * @param _creator The creator address
   * @param _start The start index (inclusive)
   * @param _end The end index (exclusive)
   * @return The program IDs in the specified range
   */
  function incentivesByCreator(address _creator, uint256 _start, uint256 _end) external view returns (uint256[] memory);

  /**
   * @notice Returns the reward token at a position in the reward tokens list
   * @param _index Position in the reward tokens list
   * @return The reward token address at the given index
   */
  function rewards(uint256 _index) external view returns (address);

  /**
   * @notice Returns whether a token is registered as a reward token
   * @param _token Token address to check
   * @return True if the token is registered as a reward token (fee token or incentive program token)
   */
  function isReward(address _token) external view returns (bool);

  /**
   * @notice Returns the number of distinct reward tokens registered
   * @return The number of distinct reward tokens
   */
  function rewardsListLength() external view returns (uint256);

  /**
   * @notice Returns the program-agnostic supply/time accumulators snapshotted at a global reward checkpoint
   * @param _checkpointIndex The global reward checkpoint index
   * @return sharePerVote Accumulated `dt / supply` through the checkpoint, scaled by the accumulator precision
   * @return weightedSharePerVote Accumulated `(intervalEnd - 1 - origin) * dt / supply`, scaled likewise
   */
  function supplyAccumulatorAt(uint256 _checkpointIndex)
    external
    view
    returns (uint256 sharePerVote, uint256 weightedSharePerVote);

  /**
   * @notice Returns the remaining balance available for a program
   * @param _programId The incentive program ID
   * @return The program's remaining token balance
   */
  function remainingAmount(uint256 _programId) external view returns (uint256);

  /**
   * @notice Returns the amount already swept for a program
   * @param _programId The incentive program ID
   * @return The cumulative amount swept to the program creator
   */
  function sweptAmount(uint256 _programId) external view returns (uint256);
}
