// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BscAddresses} from "./lib/BscAddresses.sol";

/**
 * @title Timelocked
 * @notice The owner proposes a change, it can be applied once the delay has passed, and either the
 *         project's guardian or Flap's Guardian can cancel it while it waits. The project's guardian
 *         proposes nothing and applies nothing. A child can hand a setting to Flap's Guardian once the
 *         game is live: then only Flap's Guardian proposes it, and the owner still applies it.
 *
 *         Before the game is live the timelock is not armed and every setting applies at once, so a
 *         deploy can wire the stack up in one go. Arming happens on its own once the game starts and
 *         cannot be undone.
 *
 *         One proposal at a time per setting, each named by an action id the child defines.
 */
abstract contract Timelocked {
    // ============ Constants ============

    /// @notice How long a change waits before it can be applied
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // ============ State ============

    /// @notice Can cancel a waiting change, and nothing else. Flap's Guardian can do the same
    address public guardian;

    /// @notice Until this is set, changes apply immediately
    bool public timelockArmed;

    struct Proposal {
        bytes data;
        uint64 proposedAt;
    }

    mapping(bytes32 => Proposal) public proposals;

    // ============ Events ============

    event ChangeProposed(bytes32 indexed action, bytes data, uint256 readyAt);
    event ChangeApplied(bytes32 indexed action, bytes data);
    event ChangeCancelled(bytes32 indexed action, bytes data, address by);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event TimelockArmed(uint256 armedAt);

    // ============ Errors ============

    error NothingPending();
    error ProposalPending();
    error TimelockNotReady(uint256 readyAt);
    error UnknownAction();
    error AlreadyArmed();
    error GameNotLive();
    error GuardianNotIndependent();
    error NotFlapGuardian();

    // ============ Hooks for the child ============

    /// @dev The owner check the child already has.
    function _requireTimelockOwner() internal view virtual;

    /// @dev The child's owner, so a guardian can be checked against it.
    function _timelockOwner() internal view virtual returns (address);

    /// @dev Carry out a change that has waited its delay, or that was made before arming.
    function _executeChange(bytes32 action, bytes memory data) internal virtual;

    /// @dev Whether the game this contract belongs to is live, which is what arms the timelock.
    function _gameIsLive() internal view virtual returns (bool);

    // ============ Arming ============

    /**
     * @notice Arm the timelock. Callable by anyone once the game is live, so engaging it does not
     *         depend on the owner remembering to.
     */
    function armTimelock() external {
        if (timelockArmed) revert AlreadyArmed();
        if (!_gameIsLive()) revert GameNotLive();
        _arm();
    }

    function _arm() internal {
        if (timelockArmed) return;
        timelockArmed = true;
        emit TimelockArmed(block.timestamp);
    }

    // ============ Proposing, applying, cancelling ============

    /// @notice Set the guardian. Behind the timelock like every other address, once armed.
    function setGuardian(address newGuardian) external {
        _requireTimelockOwner();
        _route(GUARDIAN_ACTION, abi.encode(newGuardian));
    }

    /// @notice Apply a change that has waited its delay.
    function applyChange(bytes32 action) external {
        _requireTimelockOwner();
        Proposal memory p = proposals[action];
        if (p.proposedAt == 0) revert NothingPending();
        uint256 readyAt = uint256(p.proposedAt) + TIMELOCK_DELAY;
        if (block.timestamp < readyAt) revert TimelockNotReady(readyAt);

        delete proposals[action];
        _executeChange(action, p.data);
        emit ChangeApplied(action, p.data);
    }

    /// @notice Drop a waiting change. Either guardian's only power, and the owner's own way back out.
    function cancelChange(bytes32 action) external {
        if (msg.sender != guardian && msg.sender != BscAddresses.FLAP_GUARDIAN) _requireTimelockOwner();
        Proposal memory p = proposals[action];
        if (p.proposedAt == 0) revert NothingPending();

        delete proposals[action];
        emit ChangeCancelled(action, p.data, msg.sender);
    }

    /// @notice What is waiting under this action, and when it can be applied.
    function pendingChange(bytes32 action) external view returns (bytes memory data, uint256 readyAt) {
        Proposal memory p = proposals[action];
        if (p.proposedAt == 0) return ("", 0);
        return (p.data, uint256(p.proposedAt) + TIMELOCK_DELAY);
    }

    /// @dev A setting either applies now, or starts its wait. One proposal at a time per action.
    ///      A contract whose game has gone live arms itself here, so instant settings do not depend
    ///      on anyone having called `armTimelock`.
    function _route(bytes32 action, bytes memory data) internal {
        if (!timelockArmed && _gameIsLive()) _arm();
        if (!timelockArmed) {
            _executeChange(action, data);
            emit ChangeApplied(action, data);
            return;
        }
        if (proposals[action].proposedAt != 0) revert ProposalPending();
        proposals[action] = Proposal({data: data, proposedAt: uint64(block.timestamp)});
        emit ChangeProposed(action, data, block.timestamp + TIMELOCK_DELAY);
    }

    /// @dev Who may set or propose a setting held for Flap: the owner until the game is live, then only
    ///      Flap's Guardian.
    function _requireProposer() internal view {
        if (timelockArmed || _gameIsLive()) {
            if (msg.sender != BscAddresses.FLAP_GUARDIAN) revert NotFlapGuardian();
        } else {
            _requireTimelockOwner();
        }
    }

    /// @dev Set the guardian, from the constructor or from a change the child routed here. It must
    ///      exist and must not be the owner: a guardian that is the owner is no veto at all.
    function _setGuardian(address newGuardian) internal {
        if (newGuardian == address(0) || newGuardian == _timelockOwner()) revert GuardianNotIndependent();
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ============ Action ids ============

    /// @notice The guardian change's own action id, so an operator can watch and cancel it
    bytes32 public constant GUARDIAN_ACTION = keccak256("GUARDIAN");
}
