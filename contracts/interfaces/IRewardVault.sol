// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardVault {
    /// @notice Release up to `amount` reward tokens to the calling game. Never reverts on its own logic.
    /// @return sent min(amount, accrued allowance, vault balance); 0 for non-games / not-yet-live games.
    function release(uint256 amount) external returns (uint256 sent);
    function available(address game) external view returns (uint256);
    function isLive(address game) external view returns (bool);
}
