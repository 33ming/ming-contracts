// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStaking {
    function distributeYield(uint256 amount) external;
    function totalStaked() external view returns (uint256);
}
