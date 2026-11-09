// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Flap Trigger Service
/// @notice Books a call back to the booking contract, to be made by Flap's backend.
/// @dev    Written from the verified implementation behind the service's proxy.
///         What the implementation does, and what the contracts here rely on:
///         - `requestTrigger` requires `msg.value >= getFee()`, stores the whole value, and forwards
///           it when the callback succeeds, so an overpayment is lost. Send exactly `getFee()`.
///         - `executeAfter` is the earliest time, and 0 means "no earlier bound".
///         - the callback is `ITriggerReceiver.trigger(uint256)` with `getMaxCallbackGas()` gas.
///         - a request's status is set to EXECUTED before the callback and to FAILED only if the
///           callback reverts. `retryTrigger` requires FAILED, so a callback that never reverts can
///           never be retried. A retry forwards all the caller's gas, not the capped amount.
///         - an unknown id, a non-pending status or a call before `executeAfter` does not revert;
///           the service skips it.
interface IFlapTrigger {
    enum TriggerStatus {
        PENDING,
        EXECUTED,
        FAILED
    }

    struct TriggerRequest {
        address requester;
        uint64 executeAfter;
        TriggerStatus status;
        uint128 feePaid;
    }

    /// @notice Book a callback for no earlier than `executeAfter`; 0 for as soon as possible.
    function requestTrigger(uint64 executeAfter) external payable returns (uint256 requestId);

    /// @notice The fee this caller must send with a booking. Answers per caller.
    function getFee() external view returns (uint256);

    /// @notice The gas the service gives a callback.
    function getMaxCallbackGas() external view returns (uint256);

    /// @notice A booked request, including whose it is and whether it has run.
    function getRequest(uint256 requestId) external view returns (TriggerRequest memory);

    /// @notice Whether the service would run this request now.
    function isRequestReady(uint256 requestId) external view returns (bool);
}

/// @title What the Trigger Service calls
/// @notice The service calls this and nothing else: one function, one argument, no calldata of ours.
interface ITriggerReceiver {
    function trigger(uint256 requestId) external;
}
