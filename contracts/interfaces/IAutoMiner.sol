// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title What GridMining needs from the AutoMiner
/// @notice The game tells the AutoMiner a round has started so it can book its own dispatch. The
///         call is capped and caught, so a failure there does not stop the round.
interface IAutoMiner {
    function onRoundStarted(uint64 roundId) external;
}
