// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFlapTrigger, ITriggerReceiver} from "./interfaces/IFlapTrigger.sol";
import {IAutoMiner} from "./interfaces/IAutoMiner.sol";
import {BscAddresses} from "./lib/BscAddresses.sol";
import {Timelocked} from "./Timelocked.sol";

interface IGridMining {
    function MIN_DEPLOY() external pure returns (uint256);
    function deployFor(address user, uint8[] calldata blockIds) external payable;
    function currentRoundId() external view returns (uint64);
    function gameStarted() external view returns (bool);
    function rounds(uint64 roundId) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 totalDeployed,
        uint256 totalWinnings,
        uint256 winnersDeployed,
        uint8 winningBlock,
        address topMiner,
        uint256 topMinerReward,
        uint256 goldpotAmount,
        uint256 settlementRequestId,
        uint256 topMinerSeed,
        bool settled
    );
}

contract AutoMiner is Ownable2Step, ReentrancyGuard, Timelocked, ITriggerReceiver, IAutoMiner {
    // ============ Constants ============

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MAX_FLAT_FEE = 0.005 ether;
    uint8 public constant GRID_SIZE = 25;
    uint8 public constant SELECT_STRATEGY_ID = 2;

    /// @notice Users per slice
    uint32 public constant SLICE_SIZE = 7;
    /// @notice Slices one dispatch books before handing the rest to another dispatch
    uint32 public constant MAX_SLICES_PER_DISPATCH = 13;
    /// @notice Nothing is booked later than this before the round ends, because a "now" trigger
    ///         takes 8-13 seconds to run
    uint256 public constant CUTOFF_BEFORE_END = 15 seconds;
    /// @notice What the reserve aims to hold, kept back when fees are collected
    uint256 public constant TRIGGER_RESERVE_TARGET = 0.05 ether;
    IFlapTrigger public constant triggerService = IFlapTrigger(BscAddresses.FLAP_TRIGGER_SERVICE);

    // Every call a trigger callback makes out of this contract is capped, so one user or one
    // booking cannot burn the whole slice's budget.

    /// @notice Gas for a read of the game's round
    uint256 public constant VIEW_CALL_GAS = 40_000;

    // ============ Types ============

    struct StrategyDef {
        uint8 fixedBlocks;  // 0 = user specifies numBlocks, 1-25 = enforced count
        bool exists;
        bool active;
    }

    // ============ State ============

    /// @dev Fixed at deployment. Users' per-round bookkeeping is kept against one game, so pointing
    ///      this at another one would carry stale state across; a new game always needs a new AutoMiner
    IGridMining public immutable gridMining;
    /// @notice Who alone collects the earned fees. Never the one who triggers anything
    address public feeRecipient;
    uint256 public executorFeeBps;
    uint256 public executorFlatFee;
    uint256 public minDeploy;           // Cached from GridMining.MIN_DEPLOY()

    mapping(uint8 => StrategyDef) public strategies;
    uint8 public strategyCount;

    struct AutoConfig {
        // Slot 0 (9 bytes used, 23 free)
        uint8 strategyId;              // uint8 - references strategies mapping
        uint8 numBlocks;               // uint8 - resolved block count
        bool active;                   // bool
        uint16 executorFeeBps;         // uint16 - frozen at config time
        uint32 selectedBlockMask;      // uint32 - bitmask for Select strategy (0 = not Select)

        // Slot 1
        uint128 amountPerBlock;        // uint128 (calculated, not user-provided)
        uint64 numRounds;              // uint64 (user-specified execution limit)
        uint64 roundsExecuted;         // uint64 (successful executions count)

        // Slot 2
        uint128 depositAmount;         // uint128 (original deposit for refunds)
        uint32 depositTimestamp;       // uint32 (config creation time)
        uint96 executorFlatFee;        // uint96 (frozen flat fee at config time)
    }

    mapping(address => AutoConfig) public configs;
    mapping(address => uint64) public lastRoundPlayed;

    // Track active users
    address[] public activeUsers;
    mapping(address => uint256) public activeUserIndex;  // index + 1 (0 means not in array)

    // Accumulated fees, collected by the fee recipient
    uint256 public accumulatedFees;

    /// @notice BNB held for this contract's own trigger fees. Users' deposits are never part of it
    uint256 public triggerReserve;

    /// @notice What a booked trigger is for: a dispatch books slices, a slice plays its users
    struct Job {
        uint64 roundId;
        uint32 from;        // a dispatch: how many of the round's users earlier dispatches booked slices for
        uint32 users;       // a slice: how many users it takes from the pointer
        bool isDispatch;
    }

    /// @notice How far the round's slices have got. They take users downward from `index`, and
    ///         `total` is how many were on the list when the round's first dispatch ran.
    struct Pointer {
        uint64 roundId;
        uint32 index;
        uint32 total;
    }

    mapping(uint256 => Job) public jobs;
    /// @notice Request ids this contract has already acted on, so a replay does nothing
    mapping(uint256 => bool) public requestConsumed;
    /// @notice Rounds a dispatch has already been booked for, so one round books one first dispatch
    mapping(uint64 => bool) public dispatched;
    Pointer public pointer;

    // Gas the slice loop works to, through setGasLimits
    uint256 public gasPerUser = 200_000;        // the least a later user is started with
    uint256 public gasFollowUpReserve = 150_000; // kept back, with bookingCallGas, to book the rest
    uint256 public bookingCallGas = 150_000;     // what a booking through the service may take

    // ============ Events ============

    event ConfigUpdated(
        address indexed user,
        uint8 strategyId,
        uint8 numBlocks,
        uint256 amountPerBlock,
        uint256 numRounds,
        uint256 depositAmount,
        bool active,
        uint32 selectedBlockMask
    );
    event ExecutedFor(
        address indexed user,
        uint64 indexed roundId,
        uint8[] blocks,
        uint256 totalDeployed,
        uint256 fee,
        uint256 roundsExecuted
    );
    event ConfigDeactivated(address indexed user, uint256 roundsCompleted);
    event Stopped(address indexed user, uint256 refundAmount, uint256 roundsCompleted);
    event DispatchBooked(uint64 indexed roundId, uint256 requestId, uint32 from, uint32 slices);
    /// @notice A slice that takes up to `users` users from the pointer
    event SliceBooked(uint64 indexed roundId, uint256 requestId, uint32 users);
    /// @notice The places a slice visited on the list, `to - 1` down to `from`
    event SliceExecuted(uint64 indexed roundId, uint256 requestId, uint32 from, uint32 to, uint32 played, uint32 skipped);
    /// @notice A slice ran short of gas and booked a follow-up for its last `users`
    event SliceFollowUp(uint64 indexed roundId, uint256 requestId, uint32 users);
    event UserSkipped(uint64 indexed roundId, address indexed user, bytes reason);
    /// @notice A booking refused at the cut-off: `left` of the round's `total` users go without one
    event CutOffReached(uint64 indexed roundId, uint32 left, uint32 total);
    /// @notice A round that wanted a dispatch did not get one: past the cut-off, or the reserve could
    ///         not pay for it. The round stays open, so `bookDispatch` can still be called for it.
    event DispatchNotBooked(uint64 indexed roundId, uint32 activeUsers);
    /// @notice A booking arrived for a round that is no longer the one in play, and did nothing
    event JobStale(uint64 indexed roundId, uint256 requestId, uint64 currentRoundId);
    event TriggerReserveFunded(address indexed from, uint256 amount, uint256 reserveNow);
    event TriggerReserveToppedUp(uint256 amount, uint256 reserveNow);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ExecutorFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event ExecutorFlatFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesCollected(address indexed recipient, uint256 amount);
    event GasLimitsUpdated(uint256 gasPerUser, uint256 followUpReserve, uint256 bookingCallGas);
    event StrategyAdded(uint8 indexed strategyId, uint8 fixedBlocks);
    event StrategyUpdated(uint8 indexed strategyId, bool active);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error NotFeeRecipient();
    error NotGridMining();
    error InvalidNumBlocks();
    error ConfigNotActive();
    error AlreadyPlayedThisRound();
    error GameNotStarted();
    error RoundNotActive();
    error FeeTooHigh();
    error NoFeesToCollect();
    error ConfigAlreadyActive();
    error InvalidDeposit();
    error InvalidNumRounds();
    error InsufficientDeposit();
    error RoundLimitReached();
    error InvalidStrategy();
    error InvalidFixedBlocks();
    error StrategyNotFound();
    error RenounceDisabled();
    error InvalidGasLimits();
    error InvalidBlockMask();

    // ============ Modifiers ============

    modifier onlyFeeRecipient() {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _gridMining,
        address _feeRecipient,
        uint256 _executorFeeBps,
        uint256 _executorFlatFee,
        address _guardian
    ) payable Ownable(msg.sender) {
        if (_gridMining == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_executorFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_executorFlatFee > MAX_FLAT_FEE) revert FeeTooHigh();

        gridMining = IGridMining(_gridMining);
        feeRecipient = _feeRecipient;
        executorFeeBps = _executorFeeBps;
        // Seeded at deploy with the reserve the fees then keep topped up
        if (msg.value > 0) {
            triggerReserve = msg.value;
            emit TriggerReserveFunded(msg.sender, msg.value, msg.value);
        }
        executorFlatFee = _executorFlatFee;
        minDeploy = IGridMining(_gridMining).MIN_DEPLOY();
        // Reverts on zero and on the deployer, so this cannot exist without an independent veto
        _setGuardian(_guardian);

        // Seed default strategies: 0=Random, 1=All, 2=Select
        strategies[0] = StrategyDef({fixedBlocks: 0, exists: true, active: true});
        strategies[1] = StrategyDef({fixedBlocks: GRID_SIZE, exists: true, active: true});
        strategies[2] = StrategyDef({fixedBlocks: 0, exists: true, active: true});
        strategyCount = 3;
    }

    // ============ User Functions ============

    /**
     * @notice Set auto-mining configuration with deposit
     * @param strategyId Strategy ID from the registry
     * @param numRounds Number of rounds to execute
     * @param numBlocks Number of blocks (used for strategy 0; ignored for strategy 1 and 2)
     * @param blockMask Bitmask of selected blocks (only used for Select strategy 2; pass 0 otherwise)
     */
    function setConfig(
        uint8 strategyId,
        uint256 numRounds,
        uint8 numBlocks,
        uint32 blockMask
    ) external payable nonReentrant {
        // Validate: Must not have active config (must stop first)
        if (configs[msg.sender].active) revert ConfigAlreadyActive();
        if (msg.value == 0) revert InvalidDeposit();
        if (numRounds == 0) revert InvalidNumRounds();

        // Resolve blocks + validate strategy
        (uint8 actualNumBlocks, uint32 storedBlockMask) = _resolveBlocks(strategyId, numBlocks, blockMask);

        // Calculate amountPerBlock with hybrid fee
        uint256 amountPerBlock = _calculateAmountPerBlock(actualNumBlocks, numRounds);

        // Validate minimum deposit
        if (amountPerBlock < minDeploy) revert InsufficientDeposit();

        // Validate deposit covers all rounds + fees
        {
            uint256 deployPerRound = amountPerBlock * actualNumBlocks;
            uint256 feePerRound = _calculateFee(deployPerRound, uint16(executorFeeBps), uint96(executorFlatFee));
            if (msg.value < (deployPerRound + feePerRound) * numRounds) revert InsufficientDeposit();
        }

        // Store config
        configs[msg.sender] = AutoConfig({
            strategyId: strategyId,
            numBlocks: actualNumBlocks,
            active: true,
            executorFeeBps: uint16(executorFeeBps),
            selectedBlockMask: storedBlockMask,
            amountPerBlock: uint128(amountPerBlock),
            numRounds: uint64(numRounds),
            roundsExecuted: 0,
            depositAmount: uint128(msg.value),
            depositTimestamp: uint32(block.timestamp),
            executorFlatFee: uint96(executorFlatFee)
        });

        // Add to active users
        _addToActiveUsers(msg.sender);

        emit ConfigUpdated(msg.sender, strategyId, actualNumBlocks, amountPerBlock, numRounds, msg.value, true, storedBlockMask);
    }

    /**
     * @notice Stop auto-mining and refund remaining rounds
     */
    function stop() external nonReentrant {
        AutoConfig storage config = configs[msg.sender];

        // Validate active config
        if (!config.active) revert ConfigNotActive();

        // Calculate remaining rounds
        uint256 remainingRounds = config.numRounds - config.roundsExecuted;

        if (remainingRounds == 0) {
            _deactivateUser(msg.sender);
            emit Stopped(msg.sender, 0, config.roundsExecuted);
            return;
        }

        // Calculate refund: cost per round * remaining rounds
        uint256 deployPerRound = config.amountPerBlock * config.numBlocks;
        uint256 feePerRound = _calculateFee(deployPerRound, config.executorFeeBps, config.executorFlatFee);
        uint256 costPerRound = deployPerRound + feePerRound;

        // Use actual remaining deposit and handle rounding dust
        uint256 totalSpent = costPerRound * config.roundsExecuted;
        uint256 refundAmount = config.depositAmount - totalSpent;

        // Deactivate before transfer
        uint256 roundsCompleted = config.roundsExecuted;
        _deactivateUser(msg.sender);

        // Transfer refund
        if (refundAmount > 0) {
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            require(success, "Transfer failed");
        }

        // Only once the refund is actually out: retire the unused rounds, so the read-only views stop
        // showing rounds and BNB that have already been returned.
        config.numRounds = uint64(roundsCompleted);

        emit Stopped(msg.sender, refundAmount, roundsCompleted);
    }

    // ============ Triggers ============

    /// @notice What a booking costs right now, as the service charges this contract
    function triggerFee() public view returns (uint256) {
        return triggerService.getFee();
    }

    /// @notice Top the reserve up. Callable by anyone, and the deploy seeds it.
    function fundTriggerReserve() external payable {
        if (msg.value == 0) revert ZeroAmount();
        triggerReserve += msg.value;
        emit TriggerReserveFunded(msg.sender, msg.value, triggerReserve);
    }

    /**
     * @notice GridMining tells this a round has started. It books one dispatch and nothing else.
     * @dev Deliberately small: the game calls it inside settlement with a capped amount of gas, and
     *      a deposit can start a round too, so this may be re-entered from inside a slice. Booking
     *      is all it does, and a failure here never reaches the round.
     */
    function onRoundStarted(uint64 roundId) external override {
        if (msg.sender != address(gridMining)) revert NotGridMining();
        if (activeUsers.length == 0) return;
        if (dispatched[roundId]) return;
        // Set before the booking, so a re-entrant call cannot book the round twice, and cleared
        // again when nothing was booked, so the round is still open to a later attempt
        dispatched[roundId] = true;
        if (_bookDispatch(roundId, 0, uint32(activeUsers.length)) == 0) {
            dispatched[roundId] = false;
            emit DispatchNotBooked(roundId, uint32(activeUsers.length));
        }
    }

    /// @notice Book a dispatch for the round in play, for anyone to call if the game's was missed.
    function bookDispatch() external returns (uint256 requestId) {
        uint64 roundId = gridMining.currentRoundId();
        if (activeUsers.length == 0) revert ConfigNotActive();
        if (dispatched[roundId]) revert AlreadyPlayedThisRound();
        dispatched[roundId] = true;
        requestId = _bookDispatch(roundId, 0, uint32(activeUsers.length));
        if (requestId == 0) {
            dispatched[roundId] = false;
            emit DispatchNotBooked(roundId, uint32(activeUsers.length));
        }
    }

    /**
     * @notice Run a booked dispatch or slice. The Trigger Service calls this.
     * @dev Does nothing, and never reverts, unless the caller is the service, the id is one of ours
     *      and it has not been acted on before. A user whose own deposit fails is logged and skipped.
     */
    function trigger(uint256 requestId) external override nonReentrant {
        if (msg.sender != address(triggerService)) return;
        if (requestConsumed[requestId]) return;

        Job memory job = jobs[requestId];
        if (job.roundId == 0) return;

        requestConsumed[requestId] = true;

        // A job belongs to one round. If that round has moved on, its users are played by the new
        // round's own dispatch, not by a booking that checked a different round's cut-off.
        uint64 current;
        try gridMining.currentRoundId{gas: VIEW_CALL_GAS}() returns (uint64 id) {
            current = id;
        } catch {}
        if (current == 0 || current != job.roundId) {
            emit JobStale(job.roundId, requestId, current);
            return;
        }

        if (job.isDispatch) {
            _runDispatch(requestId, job);
        } else {
            _runSlice(requestId, job);
        }
    }

    /// @dev Book slices for this round, up to MAX_SLICES_PER_DISPATCH, then another dispatch for the rest.
    function _runDispatch(uint256 requestId, Job memory job) private {
        // The round's first dispatch sets the pointer above everyone on the list
        Pointer memory ptr = pointer;
        if (ptr.roundId != job.roundId) {
            uint32 listed = uint32(activeUsers.length);
            ptr = Pointer({roundId: job.roundId, index: listed, total: listed});
            pointer = ptr;
        }
        uint32 total = ptr.total;
        uint32 from = job.from;
        if (from >= total) return;

        uint32 slices;
        while (from < total && slices < MAX_SLICES_PER_DISPATCH) {
            uint32 users = total - from < SLICE_SIZE ? total - from : SLICE_SIZE;
            if (_bookSlice(job.roundId, users, total - from, total) == 0) break;
            from += users;
            slices++;
        }

        emit DispatchBooked(job.roundId, requestId, job.from, slices);

        // More users than this dispatch could book: the next dispatch takes the rest
        if (from < total && slices == MAX_SLICES_PER_DISPATCH) _bookDispatch(job.roundId, from, total);
    }

    /// @dev Play up to `job.users` users downward from the pointer, each caught, and book a follow-up
    ///      when the gas runs short. A user who has already played this round is passed over, and one
    ///      who runs out of gas after others had their turn is left for the follow-up, where they go first.
    function _runSlice(uint256 requestId, Job memory job) private {
        Pointer memory ptr = pointer;
        uint32 top = ptr.index;
        if (top > activeUsers.length) top = uint32(activeUsers.length);
        uint32 i = top;
        uint32 taken;
        uint32 played;
        uint32 skipped;
        bool tried;

        for (; taken < job.users && i > 0; taken++) {
            // Before each user after the first, keep enough to book the rest and finish
            if (taken > 0 && gasleft() < gasPerUser + _keepBack()) break;
            address user = activeUsers[--i];
            if (lastRoundPlayed[user] >= job.roundId) continue;

            // Never hand out gas the slice needs to book the rest: a deposit that burns everything
            // it is given would otherwise take the whole callback down, and the Trigger Service
            // marks a callback that reverts FAILED, which anyone can then retry in a block of their
            // own choosing - and the tiles are drawn from the previous block's hash.
            uint256 allowance = _executeAllowance();
            uint256 before = gasleft();
            try this.executeOne{gas: allowance}(user) {
                played++;
            } catch (bytes memory reason) {
                // Out of gas after others had their turn: no reason given, and nearly all of it used, as
                // each call level that runs out leaves a sixty-fourth behind. Back on the list for the follow-up
                if (tried && reason.length == 0 && before - gasleft() >= allowance - allowance / 16) {
                    i++;
                    break;
                }
                skipped++;
                emit UserSkipped(job.roundId, user, reason);
            }
            tried = true;
        }
        pointer.index = i;

        if (taken < job.users && i > 0) {
            uint32 rest = job.users - taken;
            _bookSlice(job.roundId, rest, rest, ptr.total);
            emit SliceFollowUp(job.roundId, requestId, rest);
        }

        emit SliceExecuted(job.roundId, requestId, i, top, played, skipped);
    }

    /// @dev What the slice must keep to book a follow-up and emit its events, whatever a deposit does.
    function _keepBack() private view returns (uint256) {
        return bookingCallGas + gasFollowUpReserve;
    }

    /// @dev What one more deposit may take: everything above what the slice keeps back.
    function _executeAllowance() private view returns (uint256) {
        uint256 keep = _keepBack();
        uint256 left = gasleft();
        return left > keep ? left - keep : 0;
    }

    /// @notice One user's deposit, from inside a slice. Not callable by anyone else.
    function executeOne(address user) external {
        require(msg.sender == address(this), "Only self");
        _executeFor(user);
    }

    /// @dev A dispatch books itself for "now"; the backend runs it about 10 seconds later.
    function _bookDispatch(uint64 roundId, uint32 from, uint32 total) private returns (uint256 requestId) {
        if (!_beforeCutOff(roundId)) {
            emit CutOffReached(roundId, total - from, total);
            return 0;
        }
        requestId = _book(roundId, from, 0, true);
        if (requestId != 0) emit DispatchBooked(roundId, requestId, from, 0);
    }

    /// @dev `left` is how many of the round's users go without a slice if the cut-off has passed.
    function _bookSlice(uint64 roundId, uint32 users, uint32 left, uint32 total) private returns (uint256 requestId) {
        if (!_beforeCutOff(roundId)) {
            emit CutOffReached(roundId, left, total);
            return 0;
        }
        requestId = _book(roundId, 0, users, false);
        if (requestId != 0) emit SliceBooked(roundId, requestId, users);
    }

    /// @dev One booking, paid from the reserve. Returns 0 when it could not be made; never reverts.
    function _book(uint64 roundId, uint32 from, uint32 users, bool isDispatch) private returns (uint256 requestId) {
        uint256 fee = triggerService.getFee();
        if (fee > triggerReserve) return 0;
        triggerReserve -= fee;
        try triggerService.requestTrigger{value: fee, gas: bookingCallGas}(0) returns (uint256 id) {
            requestId = id;
            jobs[id] = Job({roundId: roundId, from: from, users: users, isDispatch: isDispatch});
        } catch {
            triggerReserve += fee;
        }
    }

    /// @dev Whether there is still time for a booking to run before deposits close.
    function _beforeCutOff(uint64 roundId) private view returns (bool) {
        (, uint256 endTime, , , , , , , , , , bool settled) = gridMining.rounds{gas: VIEW_CALL_GAS}(roundId);
        if (settled || endTime == 0) return false;
        return block.timestamp + CUTOFF_BEFORE_END <= endTime;
    }

    /**
     * @notice Collect the fees earned so far.
     * @dev The reserve comes first: collecting never leaves the contract unable to book.
     */
    function collectFees() external onlyFeeRecipient nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToCollect();
        accumulatedFees = 0;

        amount = _reserveFirst(amount);
        // The reserve took all of it, so there is nothing to send
        if (amount == 0) return;

        (bool success, ) = feeRecipient.call{value: amount}("");
        require(success, "Transfer failed");

        emit FeesCollected(feeRecipient, amount);
    }

    // ============ Internal Functions ============

    /**
     * @notice Resolve block count and mask from strategy + params
     */
    function _resolveBlocks(
        uint8 strategyId,
        uint8 numBlocks,
        uint32 blockMask
    ) internal view returns (uint8 actualNumBlocks, uint32 storedBlockMask) {
        StrategyDef storage strat = strategies[strategyId];
        if (!strat.exists || !strat.active) revert InvalidStrategy();

        if (strategyId == SELECT_STRATEGY_ID) {
            if (blockMask == 0) revert InvalidBlockMask();
            if (blockMask >= (1 << GRID_SIZE)) revert InvalidBlockMask();
            actualNumBlocks = _popcount(blockMask);
            storedBlockMask = blockMask;
        } else if (strat.fixedBlocks > 0) {
            actualNumBlocks = strat.fixedBlocks;
        } else {
            if (numBlocks == 0 || numBlocks > GRID_SIZE) revert InvalidNumBlocks();
            actualNumBlocks = numBlocks;
        }
    }

    /**
     * @notice Calculate amountPerBlock with hybrid fee (% first then fallback to flat)
     */
    function _calculateAmountPerBlock(
        uint8 actualNumBlocks,
        uint256 numRounds
    ) internal view returns (uint256 amountPerBlock) {
        uint256 totalBlocks = uint256(actualNumBlocks) * numRounds;

        // Try percentage
        amountPerBlock = (msg.value * BPS_DENOMINATOR) / (totalBlocks * (BPS_DENOMINATOR + executorFeeBps));

        // Check if flat fee should override
        uint256 pctFee = (amountPerBlock * actualNumBlocks * executorFeeBps) / BPS_DENOMINATOR;
        if (pctFee < executorFlatFee) {
            // Flat fee wins = recalculate
            uint256 totalFlatFees = executorFlatFee * numRounds;
            if (msg.value <= totalFlatFees) revert InsufficientDeposit();
            amountPerBlock = (msg.value - totalFlatFees) / totalBlocks;
        }
    }

    function _executeFor(address user) internal {
        AutoConfig storage config = configs[user];

        // Validations
        if (!config.active) revert ConfigNotActive();
        if (!gridMining.gameStarted()) revert GameNotStarted();

        uint64 currentRound = gridMining.currentRoundId();
        if (lastRoundPlayed[user] >= currentRound) revert AlreadyPlayedThisRound();

        // Check round limit before execution
        if (config.roundsExecuted >= config.numRounds) {
            _deactivateUser(user);
            revert RoundLimitReached();
        }

        // Calculate costs using frozen hybrid fee
        uint256 deployAmount = config.amountPerBlock * config.numBlocks;
        uint256 fee = _calculateFee(deployAmount, config.executorFeeBps, config.executorFlatFee);

        // Check round is still active
        (, uint256 endTime, , , , , , , , , , bool settled) = gridMining.rounds(currentRound);
        if (settled || block.timestamp >= endTime) revert RoundNotActive();

        // The reserve comes first, as GridMining's float takes the admin fee: a long run of rounds
        // with no collectFees can never leave this unable to book
        accumulatedFees += _reserveFirst(fee);
        lastRoundPlayed[user] = currentRound;

        uint8[] memory deployBlocks = _blocksFor(config, currentRound, user);
        gridMining.deployFor{value: deployAmount}(user, deployBlocks);

        config.roundsExecuted++;
        if (config.roundsExecuted >= config.numRounds) {
            _deactivateUser(user);
        }
        emit ExecutedFor(user, currentRound, deployBlocks, deployAmount, fee, config.roundsExecuted);
    }

    /**
     * @dev The tiles this user plays. Select uses the mask it stored, a full-grid strategy takes
     *      every tile, and anything else is drawn here from the previous block's hash, the round and
     *      the user - the same source the game settles with, read inside Flap's own transaction.
     */
    function _blocksFor(AutoConfig storage config, uint64 roundId, address user)
        private
        view
        returns (uint8[] memory deployBlocks)
    {
        if (config.selectedBlockMask != 0) {
            return _maskToBlocks(config.selectedBlockMask, config.numBlocks);
        }
        if (config.numBlocks == GRID_SIZE) {
            deployBlocks = new uint8[](GRID_SIZE);
            for (uint8 i; i < GRID_SIZE; i++) deployBlocks[i] = i;
            return deployBlocks;
        }
        return _randomBlocks(config.numBlocks, roundId, user);
    }

    /// @dev A partial shuffle of the 25 tiles, so the picks are distinct without rejection sampling.
    function _randomBlocks(uint8 count, uint64 roundId, address user)
        private
        view
        returns (uint8[] memory out)
    {
        out = new uint8[](count);
        uint8[GRID_SIZE] memory pool;
        for (uint8 i; i < GRID_SIZE; i++) pool[i] = i;

        uint256 seed = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), roundId, user)));
        uint8 remaining = GRID_SIZE;
        for (uint8 i; i < count; i++) {
            uint8 j = uint8(seed % remaining);
            out[i] = pool[j];
            pool[j] = pool[remaining - 1];
            remaining--;
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
        }
    }

    /**
     * @notice Hybrid fee: max(flatFee, percentageFee)
     */
    function _calculateFee(
        uint256 deployAmount,
        uint16 feeBps,
        uint96 flatFee
    ) internal pure returns (uint256) {
        uint256 pctFee = (deployAmount * feeBps) / BPS_DENOMINATOR;
        return pctFee > flatFee ? pctFee : flatFee;
    }

    /**
     * @notice Count set bits in a bitmask
     */
    function _popcount(uint32 x) internal pure returns (uint8 count) {
        while (x != 0) {
            x &= x - 1;
            count++;
        }
    }

    /**
     * @notice Convert a block bitmask to a uint8[] array
     */
    function _maskToBlocks(uint32 mask, uint8 count) internal pure returns (uint8[] memory blockIds) {
        blockIds = new uint8[](count);
        uint256 idx = 0;
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            if ((mask & (1 << i)) != 0) {
                blockIds[idx++] = i;
            }
        }
    }

    function _deactivateUser(address user) internal {
        configs[user].active = false;
        _removeFromActiveUsers(user);
        emit ConfigDeactivated(user, configs[user].roundsExecuted);
    }

    function _addToActiveUsers(address user) internal {
        if (activeUserIndex[user] == 0) {
            activeUsers.push(user);
            activeUserIndex[user] = activeUsers.length;  // Store index + 1
        }
    }

    function _removeFromActiveUsers(address user) internal {
        uint256 indexPlusOne = activeUserIndex[user];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = activeUsers.length - 1;

        if (index != lastIndex) {
            // Move last element to deleted position
            address lastUser = activeUsers[lastIndex];
            activeUsers[index] = lastUser;
            activeUserIndex[lastUser] = indexPlusOne;
        }

        activeUsers.pop();
        activeUserIndex[user] = 0;
    }

    // ============ Admin Functions ============

    /// @dev Timelocked once the game is live: the recipient is where the fees go.
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        _route(FEE_RECIPIENT_ACTION, abi.encode(_feeRecipient));
    }

    // ============ Timelock ============

    bytes32 public constant FEE_RECIPIENT_ACTION = keccak256("FEE_RECIPIENT");
    bytes32 public constant EXECUTOR_FEE_BPS_ACTION = keccak256("EXECUTOR_FEE_BPS");
    bytes32 public constant EXECUTOR_FLAT_FEE_ACTION = keccak256("EXECUTOR_FLAT_FEE");

    function _requireTimelockOwner() internal view override {
        _checkOwner();
    }

    function _gameIsLive() internal view override returns (bool) {
        (bool ok, bytes memory data) = address(gridMining).staticcall(abi.encodeWithSignature("gameStarted()"));
        return ok && data.length == 32 && abi.decode(data, (bool));
    }

    function _timelockOwner() internal view override returns (address) {
        return owner();
    }

    /// @dev A guardian that owns this is no veto, so ownership cannot move to it. Checked here
    ///      rather than in transferOwnership, so acceptOwnership is covered too.
    function _transferOwnership(address newOwner) internal override {
        if (newOwner != address(0) && newOwner == guardian) revert GuardianNotIndependent();
        super._transferOwnership(newOwner);
    }

    /// @dev Put a fee toward the reserve first and return what is left for the fee recipient.
    function _reserveFirst(uint256 fee) private returns (uint256) {
        if (triggerReserve >= TRIGGER_RESERVE_TARGET) return fee;
        uint256 room = TRIGGER_RESERVE_TARGET - triggerReserve;
        uint256 topUp = fee > room ? room : fee;
        triggerReserve += topUp;
        emit TriggerReserveToppedUp(topUp, triggerReserve);
        return fee - topUp;
    }

    /// @inheritdoc Timelocked
    function _executeChange(bytes32 action, bytes memory data) internal override {
        if (action == FEE_RECIPIENT_ACTION) {
            address next = abi.decode(data, (address));
            emit FeeRecipientUpdated(feeRecipient, next);
            feeRecipient = next;
        } else if (action == EXECUTOR_FEE_BPS_ACTION) {
            uint256 next = abi.decode(data, (uint256));
            emit ExecutorFeeBpsUpdated(executorFeeBps, next);
            executorFeeBps = next;
        } else if (action == EXECUTOR_FLAT_FEE_ACTION) {
            uint256 next = abi.decode(data, (uint256));
            emit ExecutorFlatFeeUpdated(executorFlatFee, next);
            executorFlatFee = next;
        } else if (action == GUARDIAN_ACTION) {
            _setGuardian(abi.decode(data, (address)));
        } else {
            revert UnknownAction();
        }
    }

    /// @dev Dropping ownership would freeze the fee recipient and fee setters permanently
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function addStrategy(uint8 fixedBlocks) external onlyOwner returns (uint8 strategyId) {
        if (fixedBlocks > GRID_SIZE) revert InvalidFixedBlocks();

        strategyId = strategyCount;
        strategies[strategyId] = StrategyDef({
            fixedBlocks: fixedBlocks,
            exists: true,
            active: true
        });
        strategyCount++;

        emit StrategyAdded(strategyId, fixedBlocks);
    }

    function setStrategyActive(uint8 strategyId, bool active) external onlyOwner {
        if (!strategies[strategyId].exists) revert StrategyNotFound();
        strategies[strategyId].active = active;
        emit StrategyUpdated(strategyId, active);
    }

    /// @dev Once the game is live only Flap's Guardian proposes it, and it waits out the timelock: this
    ///      is what a deposit pays the fee recipient.
    function setExecutorFeeBps(uint256 _feeBps) external {
        _requireProposer();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _route(EXECUTOR_FEE_BPS_ACTION, abi.encode(_feeBps));
    }

    /// @dev Once the game is live only Flap's Guardian proposes it, and it waits out the timelock: the
    ///      floor under the percentage fee.
    function setExecutorFlatFee(uint256 _flatFee) external {
        _requireProposer();
        if (_flatFee > MAX_FLAT_FEE) revert FeeTooHigh();
        _route(EXECUTOR_FLAT_FEE_ACTION, abi.encode(_flatFee));
    }

    /// @notice The figures the slice loop works to: the least gas a later user is started with, and
    ///         the two it keeps back to book the rest of the slice, the second being what a booking
    ///         through the service may take.
    function setGasLimits(uint256 _gasPerUser, uint256 _followUpReserve, uint256 _bookingCallGas) external onlyOwner {
        if (_gasPerUser < 100_000 || _gasPerUser > 1_000_000) revert InvalidGasLimits();
        if (_followUpReserve < 120_000 || _followUpReserve > 500_000) revert InvalidGasLimits();
        if (_bookingCallGas < 100_000 || _bookingCallGas > 500_000) revert InvalidGasLimits();
        gasPerUser = _gasPerUser;
        gasFollowUpReserve = _followUpReserve;
        bookingCallGas = _bookingCallGas;
        emit GasLimitsUpdated(_gasPerUser, _followUpReserve, _bookingCallGas);
    }

    // ============ View Functions ============

    /**
     * @notice Get user's full auto-mining state
     */
    function getUserState(address user) external view returns (
        AutoConfig memory config,
        uint64 lastRound,
        uint256 costPerRound,
        uint256 roundsRemaining,
        uint256 totalRefundable
    ) {
        config = configs[user];
        lastRound = lastRoundPlayed[user];

        if (config.amountPerBlock > 0 && config.numBlocks > 0) {
            uint256 deployAmount = config.amountPerBlock * config.numBlocks;
            uint256 fee = _calculateFee(deployAmount, config.executorFeeBps, config.executorFlatFee);
            costPerRound = deployAmount + fee;

            if (config.roundsExecuted < config.numRounds) {
                roundsRemaining = config.numRounds - config.roundsExecuted;
                totalRefundable = costPerRound * roundsRemaining;
            }
        }
    }

    /**
     * @notice Get rounds remaining for a user
     */
    function getRoundsRemaining(address user) external view returns (uint256) {
        AutoConfig storage config = configs[user];
        if (config.roundsExecuted >= config.numRounds) return 0;
        return config.numRounds - config.roundsExecuted;
    }

    /**
     * @notice Get execution progress for a user
     */
    function getConfigProgress(address user) external view returns (
        bool active,
        uint256 numRounds,
        uint256 roundsExecuted,
        uint256 roundsRemaining,
        uint256 percentComplete
    ) {
        AutoConfig storage config = configs[user];
        active = config.active;
        numRounds = config.numRounds;
        roundsExecuted = config.roundsExecuted;

        if (roundsExecuted >= numRounds) {
            roundsRemaining = 0;
            percentComplete = 100;
        } else {
            roundsRemaining = numRounds - roundsExecuted;
            percentComplete = (roundsExecuted * 100) / numRounds;
        }
    }

    /**
     * @notice Get strategy definition
     */
    function getStrategy(uint8 strategyId) external view returns (uint8 fixedBlocks, bool exists, bool active) {
        StrategyDef storage s = strategies[strategyId];
        return (s.fixedBlocks, s.exists, s.active);
    }

    /**
     * @notice Get number of active users
     */
    function getActiveUserCount() external view returns (uint256) {
        return activeUsers.length;
    }

    /**
     * @notice Get active users (paginated)
     * @param offset Starting index
     * @param limit Max number to return
     */
    function getActiveUsers(uint256 offset, uint256 limit) external view returns (address[] memory users) {
        uint256 total = activeUsers.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;

        users = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            users[i] = activeUsers[offset + i];
        }
    }

    /**
     * @notice Check if user can be executed this round
     */
    function canExecute(address user) external view returns (bool executable, string memory reason) {
        AutoConfig storage config = configs[user];

        if (!config.active) return (false, "Not active");
        if (!gridMining.gameStarted()) return (false, "Game not started");

        uint64 currentRound = gridMining.currentRoundId();
        if (lastRoundPlayed[user] >= currentRound) return (false, "Already played");

        if (config.roundsExecuted >= config.numRounds) return (false, "Round limit reached");

        (,uint256 endTime, , , , , , , , , , bool settled) = gridMining.rounds(currentRound);
        if (settled || block.timestamp >= endTime) return (false, "Round not active");

        return (true, "");
    }

    /// @notice What a job covers, for the backend: the round, where a dispatch starts or how many users
    ///         a slice takes, and whether it dispatches.
    function getJob(uint256 requestId) external view returns (
        uint64 roundId,
        uint32 from,
        uint32 users,
        bool isDispatch,
        bool consumed
    ) {
        Job memory job = jobs[requestId];
        return (job.roundId, job.from, job.users, job.isDispatch, requestConsumed[requestId]);
    }

    /// @notice The reserve, what a booking costs, and how many bookings are left in the reserve.
    function getTriggerInfo() external view returns (uint256 reserve, uint256 fee, uint256 bookingsLeft) {
        reserve = triggerReserve;
        fee = triggerService.getFee();
        bookingsLeft = fee == 0 ? 0 : reserve / fee;
    }

    // ============ Receive ============

    /// @dev A plain transfer is a subsidy to the reserve, so nothing arrives that cannot be spent
    receive() external payable {
        triggerReserve += msg.value;
        emit TriggerReserveFunded(msg.sender, msg.value, triggerReserve);
    }
}
