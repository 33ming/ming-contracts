// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FlapVaultEx
/// @notice Asks Flap's executor for a swap and is told the result in a callback.
/// @dev    Written from the verified implementation behind the proxy.
///         What the implementation does, and what the contracts here rely on:
///         - the requester must be a contract, because the callback is mandatory.
///         - the native asset is on the blocked-token list, so the input is WBNB, approved to the
///           vault before the request and pulled by it.
///         - the fee is a percentage of the input, snapshotted at request time, and it is charged on
///           a refund as well, so a refund comes back that much short.
///         - the callback is `onFlapVaultExSettled` with `maxCallbackGas()` gas, and if it reverts
///           the settlement reverts with it, leaving the request pending.
interface IFlapVaultEx {
    enum RequestStatus {
        NONE,
        PENDING,
        FULFILLED,
        REFUNDED,
        FAILED
    }

    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
    }

    struct SwapRequestView {
        uint256 requestId;
        address consumer;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 swapInputAmount;
        bool feeInInput;
        uint64 feeBps;
        uint64 createdAt;
        RequestStatus status;
    }

    /// @notice Ask for `inputAmount` of `inputToken` to be swapped for `outputToken`.
    function requestSwap(ExactInputParams calldata params) external payable returns (uint256 requestId);

    /// @notice A request as the vault holds it.
    function getRequest(uint256 requestId) external view returns (SwapRequestView memory);

    /// @notice The gas a settlement callback is given.
    function maxCallbackGas() external view returns (uint256);

    /// @notice Whether this token can be swapped at all.
    function isTokenBlocked(address token) external view returns (bool);

    /// @notice Whether this requester is refused.
    function isCallerBlocked(address caller) external view returns (bool);

    /// @notice Whether the vault is taking requests.
    function paused() external view returns (bool);
}

/// @title What FlapVaultEx calls when a request settles
/// @dev `status` is FULFILLED (2) or REFUNDED (3); `token` and `amount` are what was delivered or
///      returned, after fees.
interface IFlapVaultExConsumer {
    function onFlapVaultExSettled(uint256 requestId, uint8 status, address token, uint256 amount) external;
}

/// @notice The wrapped native token, for turning the pending BNB into the vault's input.
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
