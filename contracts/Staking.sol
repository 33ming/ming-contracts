// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BscAddresses} from "./lib/BscAddresses.sol";
import {Timelocked} from "./Timelocked.sol";

/**
 * @title Staking
 * @notice Revenue-sharing staking: users stake MING, yield is paid in gold (XAUt) bought by the Treasury.
 *         O(1) per-share accumulator, the standard pattern.
 *         Unstaking waits UNSTAKE_DELAY. requestUnstake moves tokens out of earning stake into a
 *         request; the request is claimable in full once its matured, or early for a penalty
 *         that is burned. Tokens in a request earn nothing and are not part of totalStaked, so the
 *         accumulator and the Treasury's no-stakers check only ever see earning stake.
 */
contract Staking is Ownable2Step, ReentrancyGuard, Timelocked {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @dev 1e36: yield is 6-decimal gold against an 18-decimal stake; 1e18 would truncate small distributions.
    uint256 public constant PRECISION = 1e36;

    /// @notice How long an unstake request waits before it can be claimed in full
    uint256 public constant UNSTAKE_DELAY = 24 hours;

    /// @notice Share of an early exit that is burned, in basis points
    uint256 public constant EMERGENCY_PENALTY_BPS = 1000;

    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Open unstake requests one address may hold at once
    uint256 public constant MAX_OPEN_REQUESTS = 10;

    /// @dev The token has no burn(), so the penalty is burned by transfer
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ============ External Contracts ============

    IERC20 public immutable ming;
    IERC20 public immutable xaut;
    address public treasury;

    // ============ Global State ============

    uint256 public totalStaked;                // Earning stake only; requests are not counted here
    uint256 public totalPending;               // Sum of every open unstake request
    uint256 public accYieldPerShare;           // Accumulated gold per staked token (scaled by PRECISION)
    uint256 public totalYieldDistributed;

    // ============ Config ============

    uint256 public minStake = 1e18 / 10;       // 0.1 MING minimum

    // ============ Per-User State ============

    struct StakeInfo {
        uint256 balance;              // Staked MING
        uint256 pendingRewards;       // Accumulated unclaimed gold
        uint64 lastClaimAt;
        uint64 lastDepositAt;
        uint64 lastWithdrawAt;
    }

    /// @dev One unstake request. Entries are never deleted, so an id stays valid and is never reused
    struct UnstakeRequest {
        uint256 amount;
        uint64 unlockAt;
        bool claimed;
    }

    mapping(address => StakeInfo) public stakes;
    mapping(address => uint256) public userRewardsDebt;

    /// @dev Every request a user has ever made. The index is the id
    mapping(address => UnstakeRequest[]) private _requests;

    /// @dev Ids of the requests still open, at most MAX_OPEN_REQUESTS, so every loop is bounded.
    ///      Closing a request swaps the last id into its place, so this order is not stable
    mapping(address => uint256[]) private _openIds;

    // ============ Events ============

    event Deposited(address indexed user, uint256 amount, uint256 newBalance);
    event UnstakeRequested(address indexed user, uint256 indexed id, uint256 amount, uint64 unlockAt);
    event UnstakeClaimed(address indexed user, uint256 indexed id, uint256 amount);
    event EmergencyUnstaked(address indexed user, uint256 amount, uint256 penalty);
    event EmergencyClaimed(address indexed user, uint256 indexed id, uint256 amount, uint256 penalty);
    event YieldClaimed(address indexed user, uint256 amount);
    event YieldDistributed(uint256 amount, uint256 newAccYieldPerShare);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientPendingRewards();
    error BelowMinimumStake();
    error OnlyTreasury();
    error NoStakers();
    error NothingReceived();
    error TooManyRequests();
    error NoSuchRequest(uint256 id);
    error AlreadyClaimed(uint256 id);
    error StillLocked(uint64 unlockAt);
    error AlreadyUnlocked(uint256 id);
    error NothingUnlocked();
    error RenounceDisabled();

    // ============ Modifiers ============

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    // ============ Constructor ============

    constructor(address _ming, address _treasury, address _guardian) Ownable(msg.sender) {
        if (_ming == address(0) || _treasury == address(0)) revert ZeroAddress();

        ming = IERC20(_ming);
        xaut = IERC20(BscAddresses.XAUT);
        treasury = _treasury;
        // Reverts on zero and on the deployer, so this cannot exist without an independent veto
        _setGuardian(_guardian);
    }

    // ============ Core Staking Functions ============

    /// @notice Stake MING
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakeInfo storage stake = stakes[msg.sender];

        // Update rewards before modifying balance (also sets userRewardsDebt for existing stakers)
        _updateRewards(msg.sender);

        // Credit what arrived, not what was asked for. A token that skims the transfer would
        // otherwise leave this contract crediting more than it holds, and the last stakers out
        // unable to close anything.
        uint256 heldBefore = ming.balanceOf(address(this));
        ming.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ming.balanceOf(address(this)) - heldBefore;
        if (received == 0) revert NothingReceived();

        uint256 newBalance = stake.balance + received;
        if (newBalance < minStake) revert BelowMinimumStake();

        stake.balance = newBalance;
        stake.lastDepositAt = uint64(block.timestamp);
        if (stake.lastClaimAt == 0) {
            stake.lastClaimAt = uint64(block.timestamp);
        }
        totalStaked += received;

        // New stakers: _updateRewards returned early with debt untouched, so sync it here
        userRewardsDebt[msg.sender] = accYieldPerShare;

        emit Deposited(msg.sender, received, newBalance);
    }

    // ============ Unstaking ============

    /**
     * @notice Start an unstake. The tokens stop earning immediately and can be claimed in full once
     *         UNSTAKE_DELAY has passed, or early through emergencyClaim for a burned penalty.
     * @dev Asking for more than is staked reverts rather than being capped, so a wallet that is out
     *      of date cannot silently unstake everything.
     * @return id The request's id, stable for the life of the contract
     */
    function requestUnstake(uint256 amount) external nonReentrant returns (uint256 id) {
        if (_openIds[msg.sender].length >= MAX_OPEN_REQUESTS) revert TooManyRequests();

        amount = _leaveStake(amount);

        uint64 unlockAt = uint64(block.timestamp + UNSTAKE_DELAY);
        _requests[msg.sender].push(UnstakeRequest({amount: amount, unlockAt: unlockAt, claimed: false}));
        id = _requests[msg.sender].length - 1;
        _openIds[msg.sender].push(id);
        totalPending += amount;

        emit UnstakeRequested(msg.sender, id, amount, unlockAt);
    }

    /// @notice Claim one unlocked request in full
    function claimUnstaked(uint256 id) external nonReentrant returns (uint256 amount) {
        UnstakeRequest storage request = _openRequest(id);
        if (block.timestamp < request.unlockAt) revert StillLocked(request.unlockAt);

        amount = _closeRequest(id);
        stakes[msg.sender].lastWithdrawAt = uint64(block.timestamp);
        ming.safeTransfer(msg.sender, amount);

        emit UnstakeClaimed(msg.sender, id, amount);
    }

    /// @notice Claim every matured request in one transfer. Bounded by
    ///         MAX_OPEN_REQUESTS, and locked requests are left alone
    function claimAllUnlocked() external nonReentrant returns (uint256 total) {
        uint256[] storage open = _openIds[msg.sender];

        // Backwards, because closing a request swaps the last id into the slot it leaves
        for (uint256 i = open.length; i > 0; --i) {
            uint256 id = open[i - 1];
            if (block.timestamp < _requests[msg.sender][id].unlockAt) continue;

            uint256 amount = _closeRequest(id);
            total += amount;
            emit UnstakeClaimed(msg.sender, id, amount);
        }
        if (total == 0) revert NothingUnlocked();

        stakes[msg.sender].lastWithdrawAt = uint64(block.timestamp);
        ming.safeTransfer(msg.sender, total);
    }

    /// @notice Leave staked tokens at once, paying EMERGENCY_PENALTY_BPS of them as a burn
    function emergencyUnstake(uint256 amount) external nonReentrant returns (uint256 payout, uint256 penalty) {
        amount = _leaveStake(amount);
        (payout, penalty) = _payWithPenalty(amount);

        emit EmergencyUnstaked(msg.sender, amount, penalty);
    }

    /**
     * @notice Take one still-locked request early, paying EMERGENCY_PENALTY_BPS of it as a burn.
     * @dev Refused once the request is unlocked: at that point claimUnstaked pays all of it, and the
     *      penalty must never reach tokens that are already claimable. One call per request.
     */
    function emergencyClaim(uint256 id) external nonReentrant returns (uint256 payout, uint256 penalty) {
        UnstakeRequest storage request = _openRequest(id);
        if (block.timestamp >= request.unlockAt) revert AlreadyUnlocked(id);

        uint256 amount = _closeRequest(id);
        (payout, penalty) = _payWithPenalty(amount);

        emit EmergencyClaimed(msg.sender, id, amount, penalty);
    }

    // ============ Unstaking internals ============

    /**
     * @dev Shared by both exits: settle gold, apply dust rule and take the tokens out of earning
     *      stake. Returns the amount actually leaving, which the dust rule may have raised to the
     *      whole balance. Balances move here, before any transfer the caller makes.
     */
    function _leaveStake(uint256 amount) internal returns (uint256) {
        if (amount == 0) revert ZeroAmount();

        StakeInfo storage stake = stakes[msg.sender];
        uint256 balance = stake.balance;
        if (amount > balance) revert InsufficientBalance();

        // Gold earned so far stays claimable, so it is booked before the balance moves
        _updateRewards(msg.sender);

        // A remainder below minStake could never be topped up or left, since deposit enforces the
        // same floor, so the whole balance leaves instead
        uint256 remaining = balance - amount;
        if (remaining != 0 && remaining < minStake) amount = balance;

        stake.balance = balance - amount;
        totalStaked -= amount;
        return amount;
    }

    /// @dev The caller's own open request, or a revert naming why it is not one
    function _openRequest(uint256 id) internal view returns (UnstakeRequest storage request) {
        UnstakeRequest[] storage all = _requests[msg.sender];
        if (id >= all.length) revert NoSuchRequest(id);
        request = all[id];
        if (request.claimed) revert AlreadyClaimed(id);
    }

    /// @dev Marks the request claimed and drops it from the open set, before any transfer
    function _closeRequest(uint256 id) internal returns (uint256 amount) {
        UnstakeRequest storage request = _requests[msg.sender][id];
        amount = request.amount;
        request.claimed = true;

        uint256[] storage open = _openIds[msg.sender];
        for (uint256 i; i < open.length; ++i) {
            if (open[i] == id) {
                open[i] = open[open.length - 1];
                open.pop();
                break;
            }
        }
        totalPending -= amount;
    }

    /// @dev Balances are already reduced by the caller, so the transfers come last. The penalty
    ///      rounds down, which favours the user
    function _payWithPenalty(uint256 amount) internal returns (uint256 payout, uint256 penalty) {
        penalty = (amount * EMERGENCY_PENALTY_BPS) / BPS_DENOMINATOR;
        payout = amount - penalty;

        stakes[msg.sender].lastWithdrawAt = uint64(block.timestamp);
        if (penalty != 0) ming.safeTransfer(DEAD, penalty);
        ming.safeTransfer(msg.sender, payout);
    }

    // ============ Claim Functions ============

    /// @notice Claim all pending gold
    function claimYield() external nonReentrant {
        _updateRewards(msg.sender);

        StakeInfo storage stake = stakes[msg.sender];
        uint256 pending = stake.pendingRewards;
        if (pending == 0) revert InsufficientPendingRewards();

        // Safety net: cap at gold held; keep the unpaid remainder pending
        uint256 availableYield = xaut.balanceOf(address(this));
        if (pending > availableYield) {
            stake.pendingRewards = pending - availableYield;
            pending = availableYield;
        } else {
            stake.pendingRewards = 0;
        }
        stake.lastClaimAt = uint64(block.timestamp);

        xaut.safeTransfer(msg.sender, pending);

        emit YieldClaimed(msg.sender, pending);
    }

    /// @notice Claim part of the pending gold
    function claimYieldPartial(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateRewards(msg.sender);

        StakeInfo storage stake = stakes[msg.sender];
        if (amount > stake.pendingRewards) revert InsufficientPendingRewards();

        uint256 availableYield = xaut.balanceOf(address(this));
        if (amount > availableYield) {
            amount = availableYield;
        }

        stake.pendingRewards -= amount;
        stake.lastClaimAt = uint64(block.timestamp);

        xaut.safeTransfer(msg.sender, amount);

        emit YieldClaimed(msg.sender, amount);
    }

    // ============ Yield Distribution Functions ============

    /**
     * @notice Distribute gold from the Treasury, which must have approved this contract for it.
     * @dev Reverts NoStakers when nobody is staked: the Treasury checks totalStaked() first and
     *      routes the gold share into the buyback instead.
     */
    function distributeYield(uint256 amount) external nonReentrant onlyTreasury {
        _pullAndCredit(msg.sender, amount);
    }

    /// @notice Donate gold to the stakers.
    function donateYield(uint256 amount) external nonReentrant {
        _pullAndCredit(msg.sender, amount);
    }

    /**
     * @dev Every distribution fetches its own gold and credits only what arrived, measured as a
     *      balance delta, so a credit can never be larger than its backing and a caller cannot
     *      distribute gold it did not send. The delta is taken against whatever is held at the time
     *      and nothing is required of that figure, so a burn or a freeze of earlier holdings cannot
     *      wedge later distributions.
     */
    function _pullAndCredit(address from, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (totalStaked == 0) revert NoStakers();

        uint256 heldBefore = xaut.balanceOf(address(this));
        xaut.safeTransferFrom(from, address(this), amount);
        uint256 received = xaut.balanceOf(address(this)) - heldBefore;
        if (received == 0) revert NothingReceived();

        accYieldPerShare += (received * PRECISION) / totalStaked;
        totalYieldDistributed += received;

        emit YieldDistributed(received, accYieldPerShare);
    }

    // ============ Core Math ============

    /// @dev Must be called BEFORE modifying a user's balance.
    function _updateRewards(address user) internal {
        StakeInfo storage stake = stakes[user];

        if (stake.balance == 0) return;

        uint256 debt = userRewardsDebt[user];
        if (accYieldPerShare > debt) {
            uint256 accumulated = accYieldPerShare - debt;
            stake.pendingRewards += (accumulated * stake.balance) / PRECISION;
        }

        userRewardsDebt[user] = accYieldPerShare;
    }

    // ============ Admin Functions ============

    /// @dev Once the game is live only Flap's Guardian proposes one, and it waits out the timelock
    function setTreasury(address _treasury) external {
        if (_treasury == address(0)) revert ZeroAddress();
        _requireProposer();
        _route(TREASURY_ACTION, abi.encode(_treasury));
    }

    /// @dev Dropping ownership would freeze setTreasury, so the gold route could never be repaired
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev Timelocked once the game is live
    function setMinStake(uint256 _minStake) external onlyOwner {
        _route(MIN_STAKE_ACTION, abi.encode(_minStake));
    }

    // ============ Timelock ============

    bytes32 public constant MIN_STAKE_ACTION = keccak256("MIN_STAKE");
    bytes32 public constant TREASURY_ACTION = keccak256("TREASURY");

    function _requireTimelockOwner() internal view override {
        _checkOwner();
    }

    function _timelockOwner() internal view override returns (address) {
        return owner();
    }

    /// @dev The game the Treasury serves decides when the settings stop being instant.
    function _gameIsLive() internal view override returns (bool) {
        (bool ok, bytes memory data) = treasury.staticcall(abi.encodeWithSignature("gridMining()"));
        if (!ok || data.length != 32) return false;
        uint256 word = abi.decode(data, (uint256));
        if (word == 0 || word >> 160 != 0) return false;
        (ok, data) = address(uint160(word)).staticcall(abi.encodeWithSignature("gameStarted()"));
        return ok && data.length == 32 && abi.decode(data, (bool));
    }

    /// @dev A guardian that owns this is no veto, so ownership cannot move to it. Checked here
    ///      rather than in transferOwnership, so acceptOwnership is covered too.
    function _transferOwnership(address newOwner) internal override {
        if (newOwner != address(0) && newOwner == guardian) revert GuardianNotIndependent();
        super._transferOwnership(newOwner);
    }

    /// @inheritdoc Timelocked
    function _executeChange(bytes32 action, bytes memory data) internal override {
        if (action == MIN_STAKE_ACTION) {
            uint256 next = abi.decode(data, (uint256));
            emit ConfigUpdated("minStake", minStake, next);
            minStake = next;
        } else if (action == TREASURY_ACTION) {
            address next = abi.decode(data, (address));
            emit TreasuryUpdated(treasury, next);
            treasury = next;
        } else if (action == GUARDIAN_ACTION) {
            _setGuardian(abi.decode(data, (address)));
        } else {
            revert UnknownAction();
        }
    }

    // ============ View Functions ============

    /// @notice Pending gold for a user, including the not-yet-booked accumulator delta.
    function getPendingRewards(address user) public view returns (uint256 pending) {
        StakeInfo storage stake = stakes[user];
        pending = stake.pendingRewards;

        if (stake.balance > 0) {
            uint256 debt = userRewardsDebt[user];
            if (accYieldPerShare > debt) {
                pending += ((accYieldPerShare - debt) * stake.balance) / PRECISION;
            }
        }
    }

    function getStakeInfo(address user) external view returns (
        uint256 balance,
        uint256 pendingRewards,
        uint64 lastClaimAt,
        uint64 lastDepositAt,
        uint64 lastWithdrawAt
    ) {
        StakeInfo storage stake = stakes[user];
        return (stake.balance, getPendingRewards(user), stake.lastClaimAt, stake.lastDepositAt, stake.lastWithdrawAt);
    }

    /// @notice How many requests this address has ever made. Ids run from 0 to this minus one
    function requestCount(address user) external view returns (uint256) {
        return _requests[user].length;
    }

    /// @notice One request by id, open or already claimed
    function getRequest(address user, uint256 id)
        external
        view
        returns (uint256 amount, uint64 unlockAt, bool claimed, bool unlocked)
    {
        UnstakeRequest[] storage all = _requests[user];
        if (id >= all.length) revert NoSuchRequest(id);
        UnstakeRequest storage request = all[id];
        return (request.amount, request.unlockAt, request.claimed, block.timestamp >= request.unlockAt);
    }

    /// @notice Every open request this address holds. Ids are stable; their order here is not
    function openRequests(address user)
        external
        view
        returns (uint256[] memory ids, uint256[] memory amounts, uint64[] memory unlockAts, bool[] memory unlocked)
    {
        uint256[] storage open = _openIds[user];
        uint256 n = open.length;
        ids = new uint256[](n);
        amounts = new uint256[](n);
        unlockAts = new uint64[](n);
        unlocked = new bool[](n);

        for (uint256 i; i < n; ++i) {
            UnstakeRequest storage request = _requests[user][open[i]];
            ids[i] = open[i];
            amounts[i] = request.amount;
            unlockAts[i] = request.unlockAt;
            unlocked[i] = block.timestamp >= request.unlockAt;
        }
    }

    /// @notice MING this address holds in open requests, earning nothing
    function pendingOf(address user) public view returns (uint256 total) {
        uint256[] storage open = _openIds[user];
        for (uint256 i; i < open.length; ++i) {
            total += _requests[user][open[i]].amount;
        }
    }

    /// @notice MING this address could claim right now, penalty free
    function claimableUnstaked(address user) external view returns (uint256 total) {
        uint256[] storage open = _openIds[user];
        for (uint256 i; i < open.length; ++i) {
            UnstakeRequest storage request = _requests[user][open[i]];
            if (block.timestamp >= request.unlockAt) total += request.amount;
        }
    }

    /// @notice The unstake side of one address in one call: earning stake, tokens in requests, how
    ///         many are open and how much of it is claimable now
    function getUnstakeInfo(address user)
        external
        view
        returns (uint256 staked, uint256 pending, uint256 openCount, uint256 claimableNow)
    {
        uint256[] storage open = _openIds[user];
        openCount = open.length;
        for (uint256 i; i < openCount; ++i) {
            UnstakeRequest storage request = _requests[user][open[i]];
            pending += request.amount;
            if (block.timestamp >= request.unlockAt) claimableNow += request.amount;
        }
        staked = stakes[user].balance;
    }

    function getGlobalStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalYieldDistributed,
        uint256 _accYieldPerShare
    ) {
        return (totalStaked, totalYieldDistributed, accYieldPerShare);
    }
}
