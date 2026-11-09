// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GoldRequestBase} from "./GoldRequestBase.sol";
import {Timelocked} from "./Timelocked.sol";
import {IFlapTrigger, ITriggerReceiver} from "./interfaces/IFlapTrigger.sol";
import {IAutoMiner} from "./interfaces/IAutoMiner.sol";
import {IRewardVault} from "./interfaces/IRewardVault.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {BscAddresses} from "./lib/BscAddresses.sol";

/**
 * @title GridMining
 * @notice 5x5 grid game, 60-second rounds, settled by a booked trigger
 */
/**
 * @notice The getters this contract reads before it points at another contract. Declared here rather
 *         than on the shared interfaces, because the implementations expose them as typed state
 *         variables and Solidity will not let an interface declaration override those.
 *
 *         token() is the standalone vault's reward token. A launch vault does not answer it, and
 *         proves the same thing through isLive: its factory refused to create it for a game whose
 *         ming() differed from the launch token.
 */
interface IWiringCheck {
    function gridMining() external view returns (address);
    function ming() external view returns (address);
    function token() external view returns (address);
}

contract GridMining is Ownable2Step, ReentrancyGuard, GoldRequestBase, Timelocked, ITriggerReceiver {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant ROUND_DURATION = 60 seconds;
    uint256 public constant MIN_DEPLOY = 0.0007 ether; // per block
    uint256 public constant GRID_SIZE = 25;

    uint256 public constant ADMIN_FEE_BPS = 100;        // 1% of everything deployed
    uint256 public constant VAULT_FEE_BPS = 1000;       // 10% of the losers' pool after admin
    uint256 public constant PROCESSING_FEE_BPS = 1000;    // 10% of claimed mined MING
    uint256 public constant GOLDPOT_SHARE_BPS = 1000;   // 10% of the vault fee stays here as gold
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public constant ONE_MING = 1e18;            // reward requested from the vault per round
    /// @notice One roll in this many pays the pot
    uint256 public constant GOLDPOT_CHANCE = 888;

    // Every call settlement makes out of this contract is capped, so a callee cannot burn the
    // callback's gas and make it revert. The gold request's cap is GOLD_REQUEST_CALL_GAS in
    // GoldRequestBase.

    /// @notice The least gas a settlement callback will start the settlement on. Below this it books
    ///         a fresh request and returns, so the request stays EXECUTED and cannot be retried
    uint256 public constant MIN_SETTLEMENT_GAS = 1_800_000;

    /// @notice Gas for a re-booking made from inside a callback, inside the reserve kept for it
    uint256 internal constant SETTLEMENT_BOOKING_GAS = 180_000;

    /// @notice Gas the AutoMiner gets to book its dispatch when a round starts
    uint256 internal constant AUTOMINER_NOTIFY_GAS = 350_000;

    /// @notice Gas kept back from the release, and the only limit on it. The release is the round's
    ///         reason to settle, so it gets everything else the callback has; this reserve is what
    ///         the failure path needs: the catch, one re-booking and the ReleaseFailed event
    uint256 internal constant RELEASE_RESERVE_GAS = 250_000;

    /// @notice Gas the Treasury gets to take the vault fee
    uint256 internal constant TREASURY_CALL_GAS = 450_000;

    /// @notice Gas the fee collector gets to take the admin fee
    uint256 internal constant FEE_TRANSFER_GAS = 60_000;

    /// @notice How long a booking may go unanswered before anyone can book a fresh one
    uint256 public constant TRIGGER_TIMEOUT = 10 minutes;

    /// @notice What the float aims to hold, in BNB, topped up from the admin fee before the collector
    uint256 public constant TRIGGER_FLOAT_TARGET = 0.3 ether;

    /// @notice How far ahead a round books its next attempt when the reward could not be released
    uint256 public constant RELEASE_RETRY_DELAY = 1 minutes;

    address public constant DEAD = BscAddresses.DEAD;

    IFlapTrigger public constant triggerService = IFlapTrigger(BscAddresses.FLAP_TRIGGER_SERVICE);

    // ============ Trigger float ============

    /// @notice BNB held for trigger fees. Player money is never part of it
    uint256 public triggerFloat;

    /// @notice When each round's current booking was made, so a timeout runs per booking
    mapping(uint64 => uint64) public settlementBookedAt;

    /// @notice Request ids this contract has already acted on, so a replay does nothing
    mapping(uint256 => bool) internal requestConsumed;

    /// @notice The Treasury's share that a settlement could not hand over. It goes with the next
    ///         one, so it is split exactly once, there, and never becomes Goldpot gold
    uint256 public treasuryOwed;

    /// @notice The admin fee the collector would not take. Paid with the next one, or pulled
    uint256 public feeOwed;

    // ============ External Contracts ============

    IERC20 public immutable ming;
    IRewardVault public vault;      // one-shot via setVault()
    ITreasury public treasury;
    address public feeCollector;
    address public autoMiner;

    // ============ Board State ============

    uint64 public currentRoundId;
    bool public gameStarted;
    /// @notice Above this many miners in a round the reward is split across the winning tile rather
    ///         than paid to one. Fixed: the walk for a single winner stops fitting inside a
    ///         trigger's gas well before twice this. Named in lower camel case because it was a
    ///         setting and is read by that name.
    uint256 public constant maxMinersForSingleWinner = 100;

    // ============ Round State ============

    struct Round {
        uint256 startTime;
        uint256 endTime;
        uint256[25] deployed;           // BNB per block
        uint256 totalDeployed;
        uint256 totalWinnings;          // After fees, for winners to claim
        uint256 winnersDeployed;        // Amount on winning block
        uint8 winningBlock;
        address topMiner;               // Single winner address, or address(0) if split
        uint256 topMinerReward;         // MING reward amount
        uint256 goldpotAmount;          // Goldpot payout (XAUt) if triggered
        uint256 settlementRequestId;
        uint256 topMinerSeed;
        bool settled;
        uint256 minerCount;             // Number of unique deployers this round
    }

    struct FeeCalc {
        uint256 adminFee;
        uint256 goldShare;
        uint256 treasuryShare;
        uint256 totalWinnings;
    }

    mapping(uint64 => Round) public rounds;
    mapping(uint256 => uint64) internal requestToRound;


    // ============ Miner State ============

    struct Miner {
        uint256 deployedMask;           // Bitmask of blocks deployed to
        uint256 amountPerBlock;         // BNB per block
        bool checkpointed;
    }

    // roundId => user => Miner
    mapping(uint64 => mapping(address => Miner)) internal miners;

    // roundId => deployIndex => deployer address
    mapping(uint64 => mapping(uint256 => address)) internal minerByIndex;

    // ============ Global Rewards State ============

    uint256 public goldpotPool;     // XAUt waiting for a roll
    uint256 public goldpotBNB;      // BNB accrued for gold, not yet swapped

    // Processing fee redistribution
    uint256 public totalUnclaimed;
    uint256 public accProcessingPerUnclaimed;
    mapping(address => uint256) internal userProcessingDebt;
    mapping(address => uint256) internal userUnclaimedMING;
    mapping(address => uint256) internal userUnclaimedBNB;
    mapping(address => uint256) internal userUnclaimedGold;
    mapping(address => uint256) internal userProcessedMING;
    mapping(address => uint64) internal userLastRound;

    // ============ Events ============

    event GameStarted(uint64 indexed roundId, uint256 startTime, uint256 endTime);
    event Deployed(uint64 indexed roundId, address indexed user, uint256 amountPerBlock, uint256 blockMask, uint256 totalAmount);
    event SettlementBooked(uint64 indexed roundId, uint256 requestId, uint64 executeAfter);
    /// @notice The service handed the callback less gas than a settlement needs, so it booked again
    event SettlementUnderfunded(uint64 indexed roundId, uint256 requestId, uint256 gasGiven, uint256 newRequestId);
    event TriggerFloatFunded(address indexed from, uint256 amount, uint256 floatNow);
    event TriggerFloatToppedUp(uint64 indexed roundId, uint256 amount, uint256 floatNow);
    event RoundSettled(
        uint64 indexed roundId,
        uint8 winningBlock,
        address topMiner,
        uint256 totalWinnings,
        uint256 topMinerReward,
        uint256 goldpotAmount,
        bool isSplit,
        uint256 topMinerSeed,
        uint256 winnersDeployed
    );
    event DeployedFor(
        uint64 indexed roundId,
        address indexed user,
        address indexed executor,
        uint256 amountPerBlock,
        uint256 blockMask,
        uint256 totalAmount
    );
    event AutoMinerUpdated(address indexed oldAutoMiner, address indexed newAutoMiner);
    event VaultSet(address indexed vault);
    event Checkpointed(uint64 indexed roundId, address indexed user, uint256 bnbReward, uint256 mingReward);
    event GoldCredited(uint64 indexed roundId, address indexed user, uint256 amount);
    event ClaimedBNB(address indexed user, uint256 bnbAmount, uint256 goldAmount);
    event ClaimedMING(address indexed user, uint256 minedMing, uint256 processedMing, uint256 fee, uint256 net);
    event Rearmed(uint64 indexed roundId, uint256 oldRequestId, uint256 newRequestId);
    event ReleaseFailed(uint64 indexed roundId, bytes reason, uint256 newRequestId);
    event GoldRequested(uint64 indexed roundId, uint256 requestId, uint256 bnbIn);
    event GoldRequestFailed(uint64 indexed roundId, uint256 bnbPending, bytes reason);
    event GoldRefunded(uint256 requestId, uint256 wbnbBack);
    event GoldpotFunded(uint64 indexed roundId, uint256 requestId, uint256 bnbIn, uint256 goldOut, uint256 goldpotPool);
    event FeePaymentFailed(uint64 indexed roundId, address collector, uint256 amount);
    event TreasuryShareHeld(uint64 indexed roundId, uint256 owedNow);
    event OwedFeeWithdrawn(address indexed collector, uint256 amount);


    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error GameNotStarted();
    error GameAlreadyStarted();
    error RoundNotActive();
    error RoundNotEnded();
    error RoundAlreadySettled();
    error InvalidBlockId();
    error InsufficientDeployAmount();
    error NoBlocksSelected();
    error AlreadyDeployedThisRound();
    error NothingToClaim();
    error TransferFailed();
    error NoSettlementBooked();
    error TriggerFloatEmpty(uint256 need, uint256 have);
    error TriggerTimeoutNotReached(uint256 readyAt);
    error RoundHasDeposits();
    error NotAutoMiner();
    error VaultNotSet();
    error VaultAlreadySet();
    error WrongWiring();
    error OnlySelf();
    error NotFeeCollector();
    error RenounceDisabled();

    // ============ Constructor ============

    /// @param _ming the token the game pays out
    /// @param _treasury where the vault fee goes
    /// @param _feeCollector where the admin fee goes, after the float has what it needs
    constructor(
        address _ming,
        address _treasury,
        address _feeCollector,
        address _guardian
    ) Ownable(msg.sender) GoldRequestBase() {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_feeCollector == address(0)) revert ZeroAddress();
        if (_ming == address(0)) revert ZeroAddress();

        ming = IERC20(_ming);
        treasury = ITreasury(_treasury);
        feeCollector = _feeCollector;
        // Reverts on zero and on the deployer, so the game cannot exist without an independent veto
        _setGuardian(_guardian);
    }

    /// @notice Add BNB to the float, so rounds can book their settlement. Callable by anyone.
    function fundTriggerFloat() external payable {
        if (msg.value == 0) revert ZeroAmount();
        triggerFloat += msg.value;
        emit TriggerFloatFunded(msg.sender, msg.value, triggerFloat);
    }

    // ============ Admin Functions ============

    /**
     * @notice Wire the RewardVault once. The vault is constructed with this contract as its initial game.
     * @dev One-shot, and behind the timelock once the game is live like every other address here.
     *
     *      The vault must already have this game live, which is the check that matters: a launch
     *      vault is only created for a game whose ming() is the launch token, so being live in one
     *      proves the reward token too. The standalone vault names its token, so where that answers
     *      it is checked directly.
     */
    function setVault(address _vault) external onlyOwner {
        if (address(vault) != address(0)) revert VaultAlreadySet();
        if (_vault == address(0)) revert ZeroAddress();
        if (!IRewardVault(_vault).isLive(address(this))) revert WrongWiring();
        _wired(_vault, IWiringCheck.token.selector, address(ming), true);
        _route(VAULT_ACTION, abi.encode(_vault));
    }

    /// @notice Take an admin fee an earlier settlement could not pay. The collector's own call, so
    ///         a fee is never stranded waiting for the next round.
    function withdrawOwedFee() external nonReentrant {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        uint256 amount = feeOwed;
        if (amount == 0) revert NothingToClaim();
        feeOwed = 0;
        emit OwedFeeWithdrawn(msg.sender, amount);
        _safeTransferBNB(msg.sender, amount);
    }

    /// @notice What a booking costs right now, as the service charges this contract
    function triggerFee() public view returns (uint256) {
        return triggerService.getFee();
    }

    /// @dev Book a settlement for `roundId`, to run no earlier than `executeAfter`. Reverts when the
    ///      float cannot pay, which is what stops a round opening without a booking.
    function _bookSettlement(uint64 roundId, uint64 executeAfter) private returns (uint256 requestId) {
        uint256 fee = triggerService.getFee();
        if (fee > triggerFloat) revert TriggerFloatEmpty(fee, triggerFloat);
        triggerFloat -= fee;
        requestId = triggerService.requestTrigger{value: fee}(executeAfter);
        _recordBooking(roundId, requestId, executeAfter);
    }

    /// @dev The same booking from inside a callback, where nothing may revert. 0 means it was not
    ///      booked and the round waits for someone to fund the float and call `rearm()`.
    function _tryBookSettlement(uint64 roundId, uint64 executeAfter) private returns (uint256 requestId) {
        uint256 fee = triggerService.getFee();
        if (fee > triggerFloat) return 0;
        triggerFloat -= fee;
        try triggerService.requestTrigger{value: fee, gas: SETTLEMENT_BOOKING_GAS}(executeAfter) returns (uint256 id) {
            requestId = id;
            _recordBooking(roundId, requestId, executeAfter);
        } catch {
            triggerFloat += fee;
        }
    }

    function _recordBooking(uint64 roundId, uint256 requestId, uint64 executeAfter) private {
        rounds[roundId].settlementRequestId = requestId;
        requestToRound[requestId] = roundId;
        settlementBookedAt[roundId] = uint64(block.timestamp);
        emit SettlementBooked(roundId, requestId, executeAfter);
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        if (_feeCollector == address(0)) revert ZeroAddress();
        _route(FEE_COLLECTOR_ACTION, abi.encode(_feeCollector));
    }

    /**
     * @notice Point the game at a Treasury.
     * @dev The owner wires it before the game starts, as part of the deploy. Once the game is live
     *      only Flap's Guardian may propose one, and it waits out the timelock like every other
     *      address here; the project guardian or the owner can cancel what is waiting. A Treasury
     *      must already point back at this game and buy this token.
     */
    function setTreasury(address _treasury) external {
        if (_treasury == address(0)) revert ZeroAddress();
        _requireProposer();
        _wired(_treasury, IWiringCheck.gridMining.selector, address(this), false);
        _wired(_treasury, IWiringCheck.ming.selector, address(ming), false);
        _route(TREASURY_ACTION, abi.encode(_treasury));
    }

    /// @notice Point the game at an AutoMiner, or at address(0) to switch it off; users recover a
    ///         prepaid run through its own stop(). One that is set must play this game. The owner sets
    ///         it until the game is live, then only Flap's Guardian, and it applies at once.
    function setAutoMiner(address _autoMiner) external {
        _requireProposer();
        if (_autoMiner != address(0)) {
            _wired(_autoMiner, IWiringCheck.gridMining.selector, address(this), false);
        }
        emit AutoMinerUpdated(autoMiner, _autoMiner);
        autoMiner = _autoMiner;
    }

    // ============ Timelock ============

    /// @dev Internal, not public: each one is keccak256 of its own name, so an operator derives it
    ///      off chain with ethers.id("FEE_COLLECTOR") rather than reading a getter.
    bytes32 internal constant VAULT_ACTION = keccak256("VAULT");
    bytes32 internal constant FEE_COLLECTOR_ACTION = keccak256("FEE_COLLECTOR");
    bytes32 internal constant TREASURY_ACTION = keccak256("TREASURY");

    function _requireTimelockOwner() internal view override {
        _checkOwner();
    }

    function _gameIsLive() internal view override returns (bool) {
        return gameStarted;
    }

    /**
     * @dev Read an address-returning getter and require it to answer `want`.
     *
     *      `optional` is for a getter that need not exist: a missing one, or an answer in a shape
     *      this cannot read, then passes. Anything that answers must answer correctly.
     */
    function _wired(address target, bytes4 selector, address want, bool optional) private view {
        (bool ok, bytes memory reply) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || reply.length != 32) {
            if (optional) return;
            revert WrongWiring();
        }
        if (abi.decode(reply, (address)) != want) revert WrongWiring();
    }

    function _timelockOwner() internal view override returns (address) {
        return owner();
    }

    /// @dev A guardian that owns the contract is no veto, so ownership cannot move to it. Checked
    ///      here rather than in transferOwnership, so acceptOwnership is covered too.
    /// @dev Ownership cannot be renounced
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _transferOwnership(address newOwner) internal override {
        if (newOwner != address(0) && newOwner == guardian) revert GuardianNotIndependent();
        super._transferOwnership(newOwner);
    }

    /// @inheritdoc Timelocked
    function _executeChange(bytes32 action, bytes memory data) internal override {
        if (action == FEE_COLLECTOR_ACTION) {
            feeCollector = abi.decode(data, (address));
        } else if (action == TREASURY_ACTION) {
            treasury = ITreasury(abi.decode(data, (address)));
        } else if (action == VAULT_ACTION) {
            address next = abi.decode(data, (address));
            if (address(vault) != address(0)) revert VaultAlreadySet();
            vault = IRewardVault(next);
            emit VaultSet(next);
        } else if (action == GUARDIAN_ACTION) {
            _setGuardian(abi.decode(data, (address)));
        } else {
            revert UnknownAction();
        }
    }

    function startFirstRound() external onlyOwner {
        if (address(vault) == address(0)) revert VaultNotSet();
        if (gameStarted) revert GameAlreadyStarted();

        gameStarted = true;
        currentRoundId = 1;
        // Settings are instant until the game starts; from here they wait
        _arm();

        Round storage round = rounds[1];
        round.startTime = block.timestamp;
        round.endTime = block.timestamp + ROUND_DURATION;

        emit GameStarted(1, round.startTime, round.endTime);
    }

    // ============ Core Game Functions ============

    /**
     * @notice Deploy BNB to selected blocks in the current round
     * @param blockIds Array of block IDs (0-24) to deploy to
     * @dev Deploys msg.value / blockIds.length to each selected block
     */
    function deploy(uint8[] calldata blockIds) external payable nonReentrant {
        if (!gameStarted) revert GameNotStarted();

        // Auto-checkpoint previous round
        _autoCheckpointPrevious(msg.sender);

        Round storage round = rounds[currentRoundId];

        // An ended round with nothing in it starts the next one here, so a late keeper never locks
        // players out. An ended round with deposits has a booking, and only that settles it.
        if (block.timestamp >= round.endTime) {
            if (round.totalDeployed != 0) revert RoundNotActive();
            round.settled = true;
            _startNextRound();
            round = rounds[currentRoundId];
        }

        // The round's first deposit books its settlement, so money is never in a round without one
        if (round.settlementRequestId == 0) _bookSettlement(currentRoundId, uint64(round.endTime));

        uint256 numBlocks = blockIds.length;
        if (numBlocks == 0) revert NoBlocksSelected();

        uint256 amountPerBlock = msg.value / numBlocks;
        if (amountPerBlock < MIN_DEPLOY) revert InsufficientDeployAmount();

        Miner storage miner = miners[currentRoundId][msg.sender];

        // One deploy per round
        if (miner.deployedMask != 0) revert AlreadyDeployedThisRound();

        // Assign deploy index for lazy top miner resolution
        minerByIndex[currentRoundId][round.minerCount] = msg.sender;
        round.minerCount++;

        uint256 blockMask;
        uint256 totalAmount;

        for (uint256 i; i < numBlocks; ) {
            uint8 blockId = blockIds[i];
            if (blockId >= GRID_SIZE) revert InvalidBlockId();

            uint256 bit = 1 << blockId;
            if ((blockMask & bit) != 0) revert InvalidBlockId();
            blockMask |= bit;

            uint256 currentDeployed = round.deployed[blockId];
            round.deployed[blockId] = currentDeployed + amountPerBlock;

            unchecked {
                totalAmount += amountPerBlock;
                ++i;
            }
        }

        // Write miner state
        miner.deployedMask = blockMask;
        miner.amountPerBlock = amountPerBlock;

        round.totalDeployed += totalAmount;

        // Track user's last played round
        userLastRound[msg.sender] = currentRoundId;

        emit Deployed(currentRoundId, msg.sender, amountPerBlock, blockMask, totalAmount);
    }

    /**
     * @notice Deploy BNB to selected blocks on behalf of a user (AutoMiner only)
     * @param user The address to credit deposits to
     * @param blockIds Array of block IDs (0-24) to deploy to
     * @dev Deploys msg.value / blockIds.length to each selected block
     */
    function deployFor(address user, uint8[] calldata blockIds) external payable nonReentrant {
        if (msg.sender != autoMiner) revert NotAutoMiner();
        if (user == address(0)) revert ZeroAddress();
        if (!gameStarted) revert GameNotStarted();

        // Auto-checkpoint previous round for the USER
        _autoCheckpointPrevious(user);

        Round storage round = rounds[currentRoundId];

        // An ended round with nothing in it starts the next one here, so a late keeper never locks
        // players out. An ended round with deposits has a booking, and only that settles it.
        if (block.timestamp >= round.endTime) {
            if (round.totalDeployed != 0) revert RoundNotActive();
            round.settled = true;
            _startNextRound();
            round = rounds[currentRoundId];
        }

        // The round's first deposit books its settlement, so money is never in a round without one
        if (round.settlementRequestId == 0) _bookSettlement(currentRoundId, uint64(round.endTime));

        uint256 numBlocks = blockIds.length;
        if (numBlocks == 0) revert NoBlocksSelected();

        uint256 amountPerBlock = msg.value / numBlocks;
        if (amountPerBlock < MIN_DEPLOY) revert InsufficientDeployAmount();

        // Use USER's miner state
        Miner storage miner = miners[currentRoundId][user];

        // One deploy per round
        if (miner.deployedMask != 0) revert AlreadyDeployedThisRound();

        // Assign deploy index for lazy top miner resolution
        minerByIndex[currentRoundId][round.minerCount] = user;
        round.minerCount++;

        uint256 blockMask;
        uint256 totalAmount;

        for (uint256 i; i < numBlocks; ) {
            uint8 blockId = blockIds[i];
            if (blockId >= GRID_SIZE) revert InvalidBlockId();

            uint256 bit = 1 << blockId;
            if ((blockMask & bit) != 0) revert InvalidBlockId();
            blockMask |= bit;

            uint256 currentDeployed = round.deployed[blockId];
            round.deployed[blockId] = currentDeployed + amountPerBlock;

            unchecked {
                totalAmount += amountPerBlock;
                ++i;
            }
        }

        // Write miner state
        miner.deployedMask = blockMask;
        miner.amountPerBlock = amountPerBlock;

        round.totalDeployed += totalAmount;

        // Track USER's last played round
        userLastRound[user] = currentRoundId;

        emit DeployedFor(currentRoundId, user, msg.sender, amountPerBlock, blockMask, totalAmount);
    }

    /**
     * @notice Start the next round when this one ended with nobody in it.
     * @dev Anyone can call it, and it needs no randomness: an empty round has nothing to settle. A
     *      round with a deposit has a booking, and only that booking settles it.
     */
    function reset() external nonReentrant {
        if (!gameStarted) revert GameNotStarted();

        Round storage round = rounds[currentRoundId];

        if (block.timestamp < round.endTime) revert RoundNotEnded();
        if (round.settled) revert RoundAlreadySettled();
        if (round.totalDeployed != 0) revert RoundHasDeposits();

        round.settled = true;
        _startNextRound();
    }

    /**
     * @notice Settle the round this request was booked for. The Trigger Service calls this.
     * @dev Does nothing, and never reverts, unless the caller is the service, the id is the round's
     *      current booking, the round is unsettled and the id has not been acted on before. The last
     *      of those is what makes a replay harmless, including Flap's own retry.
     */
    function trigger(uint256 requestId) external override nonReentrant {
        if (msg.sender != address(triggerService)) return;
        if (requestConsumed[requestId]) return;

        uint64 roundId = requestToRound[requestId];
        if (roundId == 0) return;

        Round storage round = rounds[roundId];
        if (round.settled) return;
        if (round.settlementRequestId != requestId) return;

        // Too little gas to finish: book again rather than revert, so the request cannot be retried
        if (gasleft() < MIN_SETTLEMENT_GAS) {
            requestConsumed[requestId] = true;
            uint256 newRequestId = _tryBookSettlement(roundId, 0);
            emit SettlementUnderfunded(roundId, requestId, gasleft(), newRequestId);
            return;
        }

        requestConsumed[requestId] = true;
        _settle(roundId);
    }

    /**
     * @notice Book a fresh settlement for a round whose booking has gone unanswered.
     * @dev Anyone can call it once TRIGGER_TIMEOUT has passed since the round's current booking. The
     *      new id is the only one the round will then accept, and the clock starts again, so a second
     *      rearm waits a full timeout. The caller cannot choose when it runs: Flap's backend does.
     */
    function rearm() external nonReentrant {
        if (!gameStarted) revert GameNotStarted();
        Round storage round = rounds[currentRoundId];
        uint256 oldRequestId = round.settlementRequestId;
        if (oldRequestId == 0) revert NoSettlementBooked();
        if (round.settled) revert RoundAlreadySettled();

        uint256 readyAt = uint256(settlementBookedAt[currentRoundId]) + TRIGGER_TIMEOUT;
        if (block.timestamp < readyAt) revert TriggerTimeoutNotReached(readyAt);

        delete requestToRound[oldRequestId];
        uint256 newRequestId = _bookSettlement(currentRoundId, 0);
        emit Rearmed(currentRoundId, oldRequestId, newRequestId);
    }

    /// @dev One word per decision, from the previous block's hash and the round id
    function _randomWords(uint64 roundId) private view returns (uint256[3] memory words) {
        uint256 seed = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), roundId)));
        words[0] = uint256(keccak256(abi.encodePacked(seed, uint256(0))));
        words[1] = uint256(keccak256(abi.encodePacked(seed, uint256(1))));
        words[2] = uint256(keccak256(abi.encodePacked(seed, uint256(2))));
    }

    function _settle(uint64 roundId) private {
        Round storage round = rounds[roundId];

        uint256[3] memory randomWords = _randomWords(roundId);

        uint8 winningBlock = uint8(randomWords[0] % GRID_SIZE);
        round.winningBlock = winningBlock;
        round.winnersDeployed = round.deployed[winningBlock];

        if (round.winnersDeployed == 0) {
            _settleNoWinners(roundId, round, winningBlock);
            return;
        }

        // A round never settles without its MING. The reward is taken before anything is paid out,
        // and a release that reverts leaves the round unsettled with a fresh attempt booked.
        // Everything the callback has left, less what the failure path needs. A limit, not a budget:
        // a release that costs less leaves the rest for the work below
        uint256 sent;
        {
            bool released;
            (released, sent) = _releaseOrWait(roundId);
            if (!released) return;
        }

        FeeCalc memory fees = _calculateSettlementFees(round.totalDeployed, round.winnersDeployed);
        round.totalWinnings = fees.totalWinnings;

        bool isSplit = _processRewards(round, randomWords, sent);

        round.settled = true;

        _distributeFees(roundId, fees);

        _startNextRound();

        emit RoundSettled(roundId, winningBlock, round.topMiner, round.totalWinnings, round.topMinerReward, round.goldpotAmount, isSplit, round.topMinerSeed, round.winnersDeployed);

        _fundGoldpot(roundId);
    }

    function _settleNoWinners(uint64 roundId, Round storage round, uint8 winningBlock) internal {
        uint256 adminFee = (round.totalDeployed * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 vaultAmount = round.totalDeployed - adminFee;
        uint256 goldShare = (vaultAmount * GOLDPOT_SHARE_BPS) / BPS_DENOMINATOR;

        round.settled = true;

        _distributeFees(roundId, FeeCalc(adminFee, goldShare, vaultAmount - goldShare, 0));

        _startNextRound();

        emit RoundSettled(roundId, winningBlock, address(0), 0, 0, 0, false, 0, 0);

        _fundGoldpot(roundId);
    }

    function _calculateSettlementFees(uint256 totalDeployed, uint256 winnersDeployed) internal pure returns (FeeCalc memory fees) {
        uint256 losersPool = totalDeployed - winnersDeployed;
        fees.adminFee = (totalDeployed * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 losersAdminShare = (losersPool * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 losersAfterAdmin = losersPool - losersAdminShare;
        uint256 vaultAmount = (losersAfterAdmin * VAULT_FEE_BPS) / BPS_DENOMINATOR;
        fees.totalWinnings = losersAfterAdmin - vaultAmount;
        fees.goldShare = (vaultAmount * GOLDPOT_SHARE_BPS) / BPS_DENOMINATOR;
        fees.treasuryShare = vaultAmount - fees.goldShare;
    }

    /// @dev Admin fee out, 90% of the vault fee to the Treasury, 10% retained for gold.
    function _distributeFees(uint64 roundId, FeeCalc memory fees) internal {
        // The float comes first, up to its target: a round that cannot book its settlement cannot
        // be played, so the fee that pays for bookings is taken before the collector's share
        uint256 adminFee = fees.adminFee;
        if (adminFee > 0 && triggerFloat < TRIGGER_FLOAT_TARGET) {
            uint256 room = TRIGGER_FLOAT_TARGET - triggerFloat;
            uint256 topUp = adminFee > room ? room : adminFee;
            triggerFloat += topUp;
            adminFee -= topUp;
            emit TriggerFloatToppedUp(roundId, topUp, triggerFloat);
        }
        // A collector that refuses the BNB, or burns the gas it is given, keeps the round settling.
        // What it would not take stays owed to it, not re-divided: the next settlement pays both, and
        // withdrawOwedFee() is there in the meantime
        uint256 feeToPay = adminFee + feeOwed;
        if (feeToPay > 0) {
            (bool paid, ) = feeCollector.call{value: feeToPay, gas: FEE_TRANSFER_GAS}("");
            if (paid) {
                if (feeOwed != 0) feeOwed = 0;
            } else {
                feeOwed = feeToPay;
                emit FeePaymentFailed(roundId, feeCollector, feeToPay);
            }
        }

        // The Treasury's share, plus anything an earlier settlement could not hand over. A failure
        // leaves it owed and untouched, so it is split once - in the Treasury, when it arrives
        uint256 treasuryToSend = fees.treasuryShare + treasuryOwed;
        if (treasuryToSend > 0) {
            try treasury.receiveVault{value: treasuryToSend, gas: TREASURY_CALL_GAS}() {
                if (treasuryOwed != 0) treasuryOwed = 0;
            } catch {
                treasuryOwed = treasuryToSend;
                emit TreasuryShareHeld(roundId, treasuryToSend);
            }
        }
        goldpotBNB += fees.goldShare;
    }

    /// @dev Decide single winner or split, hand over the MING the vault released, and roll the Goldpot.
    function _processRewards(Round storage round, uint256[3] memory randomWords, uint256 sent)
        internal
        returns (bool isSplit)
    {
        isSplit = (randomWords[1] % 2 == 0);
        if (sent == 0) isSplit = true; // nothing to award: skip the single-winner iteration

        round.topMinerSeed = randomWords[1];
        round.topMinerReward = sent;
        round.topMiner = isSplit ? address(0) : address(1);

        if (randomWords[2] % GOLDPOT_CHANCE == 0 && goldpotPool > 0) {
            round.goldpotAmount = goldpotPool;
            goldpotPool = 0;
        }
    }

    /// @dev Hand the round's gold share to the vault to convert, when enough has built up. The gold
    ///      arrives later, in the callback, and lands in a later round's pot - as it does today.
    function _fundGoldpot(uint64 roundId) internal {
        if (goldpotBNB == 0) return;
        goldPendingBnb += goldpotBNB;
        goldpotBNB = 0;
        _goldRound = roundId;
        _tryRequestGold();
    }

    /// @dev The round a gold request was made in, for the events the backend reads
    uint64 private _goldRound;

    /// @inheritdoc GoldRequestBase
    function _creditGold(uint256 goldOut, uint256) internal override {
        goldpotPool += goldOut;
    }

    function _onGoldRequested(uint256 requestId, uint256 amountIn) internal override {
        emit GoldRequested(_goldRound, requestId, amountIn);
    }

    function _onGoldFilled(uint256 requestId, uint256 amountIn, uint256 goldOut) internal override {
        emit GoldpotFunded(_goldRound, requestId, amountIn, goldOut, goldpotPool);
    }

    function _onGoldRefunded(uint256 requestId, uint256 wbnbBack) internal override {
        emit GoldRefunded(requestId, wbnbBack);
    }

    function _onGoldRequestFailed(uint256 pending, bytes memory reason) internal override {
        emit GoldRequestFailed(_goldRound, pending, reason);
    }

    /// @notice Self-call target for the caught gold payout in claimBNB. Not callable by anyone else
    function payGoldSelf(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        xaut.safeTransfer(to, amount);
    }

    function _checkpoint(uint64 roundId, address user) internal {
        Round storage round = rounds[roundId];
        Miner storage miner = miners[roundId][user];

        // Skip if already checkpointed or round not settled
        if (miner.checkpointed || !round.settled) return;

        uint8 winningBlock = round.winningBlock;

        // Bitmask check
        uint256 userDeployed = (miner.deployedMask & (1 << winningBlock)) != 0
            ? miner.amountPerBlock
            : 0;

        // If user didn't deploy to winning block, mark as checkpointed and return
        if (userDeployed == 0) {
            miner.checkpointed = true;
            emit Checkpointed(roundId, user, 0, 0);
            return;
        }

        uint256 winnersDeployed = round.winnersDeployed;

        // Calculate BNB rewards: proportional share of actual retained BNB
        uint256 bnbReward;
        unchecked {
            uint256 claimablePool = _getClaimablePool(round.totalDeployed, winnersDeployed);
            bnbReward = (claimablePool * userDeployed) / winnersDeployed;
        }

        // Calculate MING rewards
        uint256 mingReward;

        if (round.topMiner == address(0)) {
            mingReward = (round.topMinerReward * userDeployed) / winnersDeployed;
        } else if (round.topMiner == address(1)) {
            if (round.minerCount > maxMinersForSingleWinner) {
                // Too many miners: force proportional split
                round.topMiner = address(0);
                mingReward = (round.topMinerReward * userDeployed) / winnersDeployed;
            } else {
                // Safe to iterate: resolve single winner
                _resolveTopMiner(roundId, round);
                if (round.topMiner == user) {
                    mingReward = round.topMinerReward;
                }
            }
        } else if (round.topMiner == user) {
            mingReward = round.topMinerReward;
        }

        if (round.goldpotAmount != 0) {
            _creditGold(roundId, user, userDeployed, winnersDeployed);
        }

        miner.checkpointed = true;

        // Snapshot pending processed rewards before modifying unclaimed or debt
        _updateProcessingRewards(user);

        // Conditional unclaimed updates
        if (bnbReward != 0) {
            userUnclaimedBNB[user] += bnbReward;
        }
        if (mingReward != 0) {
            userUnclaimedMING[user] += mingReward;
            totalUnclaimed += mingReward;
        }

        // Update user's processing debt
        userProcessingDebt[user] = accProcessingPerUnclaimed;

        emit Checkpointed(roundId, user, bnbReward, mingReward);
    }

    /// @dev Goldpot share of the winning tile, pro-rata (XAUt, 6 decimals, no 18-dp assumptions)
    function _creditGold(uint64 roundId, address user, uint256 userDeployed, uint256 winnersDeployed) internal {
        uint256 goldReward = (rounds[roundId].goldpotAmount * userDeployed) / winnersDeployed;
        if (goldReward == 0) return;
        userUnclaimedGold[user] += goldReward;
        emit GoldCredited(roundId, user, goldReward);
    }

    /**
     * @notice Checkpoint rewards for a specific round
     * @param roundId The round to checkpoint
     */
    function checkpoint(uint64 roundId) external nonReentrant {
        _checkpoint(roundId, msg.sender);
    }

    function _autoCheckpointPrevious(address user) internal {
        uint64 lastRound = userLastRound[user];
        if (lastRound == 0) return;
        if (lastRound >= currentRoundId) return;

        _checkpoint(lastRound, user);
    }

    /**
     * @notice Claim accumulated BNB rewards and Goldpot gold (XAUt)
     */
    function claimBNB() external nonReentrant {
        // Auto-checkpoint previous round
        _autoCheckpointPrevious(msg.sender);

        uint256 bnbAmount = userUnclaimedBNB[msg.sender];
        uint256 goldAmount = userUnclaimedGold[msg.sender];
        if (bnbAmount == 0 && goldAmount == 0) revert NothingToClaim();

        uint256 bnbOwed = bnbAmount;
        if (bnbAmount != 0) {
            // Safety net: a claim is paid out of players' BNB only. Every other bucket this
            // contract holds comes off first, so a shortfall can never be covered with the trigger
            // float, an owed fee or BNB waiting to become gold, and a balance already below them
            // leaves nothing available rather than reverting on the subtraction.
            uint256 reserved = goldpotBNB + goldPendingBnb + triggerFloat + feeOwed + treasuryOwed;
            uint256 held = address(this).balance;
            uint256 available = held > reserved ? held - reserved : 0;
            if (bnbAmount > available) {
                bnbAmount = available;
            }
            userUnclaimedBNB[msg.sender] = bnbOwed - bnbAmount;
        }

        uint256 goldOwed = goldAmount;
        if (goldAmount != 0) {
            // Safety net: the un-rolled pool is not claimable, and a gold balance that has fallen
            // below the pool leaves nothing available rather than reverting on the subtraction
            uint256 goldHeld = xaut.balanceOf(address(this));
            uint256 availableGold = goldHeld > goldpotPool ? goldHeld - goldpotPool : 0;
            if (goldAmount > availableGold) {
                goldAmount = availableGold;
            }
            userUnclaimedGold[msg.sender] = goldOwed - goldAmount;
        }

        if (bnbAmount != 0) _safeTransferBNB(msg.sender, bnbAmount);

        if (goldAmount != 0) {
            // The gold leg must never hold up the BNB: if the token refuses the transfer, the whole
            // gold credit goes back, including any part already set aside above, and the event
            // reports no gold paid
            try this.payGoldSelf(msg.sender, goldAmount) {
            } catch {
                userUnclaimedGold[msg.sender] = goldOwed;
                goldAmount = 0;
            }
        }

        emit ClaimedBNB(msg.sender, bnbAmount, goldAmount);
    }

    /**
     * @notice Claim accumulated MING rewards with processing fee
     */
    function claimMING() external nonReentrant {
        // Auto-checkpoint previous round
        _autoCheckpointPrevious(msg.sender);

        // Update user's processing bonus
        _updateProcessingRewards(msg.sender);

        uint256 minedMING = userUnclaimedMING[msg.sender];
        uint256 processedMING = userProcessedMING[msg.sender];
        uint256 gross = minedMING + processedMING;

        if (gross == 0) revert NothingToClaim();

        // Calculate processing fee (only on mined, not on processed bonus)
        uint256 fee = 0;
        if (minedMING > 0 && totalUnclaimed > 0) {
            fee = (minedMING * PROCESSING_FEE_BPS) / BPS_DENOMINATOR;

            // Distribute fee to remaining unclaimed holders
            // Subtract user's unclaimed first since they're claiming
            uint256 remainingUnclaimed = totalUnclaimed - minedMING;
            if (remainingUnclaimed > 0) {
                accProcessingPerUnclaimed += (fee * 1e18) / remainingUnclaimed;
            } else {
                // No other unclaimed holders: burn the fee (transfer to DEAD)
                ming.safeTransfer(DEAD, fee);
            }
        }

        uint256 net = gross - fee;

        // Safety net: cap at contract MING balance to prevent revert from rounding dust
        uint256 contractBalance = ming.balanceOf(address(this));
        if (net > contractBalance) {
            net = contractBalance;
        }

        // Update state
        totalUnclaimed -= minedMING;
        userUnclaimedMING[msg.sender] = 0;
        userProcessedMING[msg.sender] = 0;
        userProcessingDebt[msg.sender] = accProcessingPerUnclaimed;

        // Transfer MING
        ming.safeTransfer(msg.sender, net);

        emit ClaimedMING(msg.sender, minedMING, processedMING, fee, net);
    }

    // ============ Internal Functions ============

    function _startNextRound() internal {
        currentRoundId += 1;

        Round storage nextRound = rounds[currentRoundId];
        nextRound.startTime = block.timestamp;
        nextRound.endTime = block.timestamp + ROUND_DURATION;

        emit GameStarted(currentRoundId, nextRound.startTime, nextRound.endTime);

        _notifyAutoMiner(currentRoundId);
    }

    /// @dev Tell the AutoMiner a round has started, so it can book its own dispatch. Capped and
    ///      caught: whatever it does there, the round has already started.
    function _notifyAutoMiner(uint64 roundId) private {
        address target = autoMiner;
        if (target == address(0)) return;
        try IAutoMiner(target).onRoundStarted{gas: AUTOMINER_NOTIFY_GAS}(roundId) {} catch {}
    }

    /**
     * @dev Ask the vault for the round's MING. Called low level so a reply this contract cannot
     *      decode takes the waiting path rather than reverting the callback: a `try` catches a
     *      revert, not a return of the wrong shape. A release that fails, or replies in a shape
     *      this contract cannot read, leaves the round waiting with a fresh attempt booked and the
     *      reply as the reason; a release that returns 0 still settles the round.
     */
    function _releaseOrWait(uint64 roundId) private returns (bool released, uint256 sent) {
        uint256 held = ming.balanceOf(address(this));
        (bool ok, bytes memory reply) = address(vault).call{gas: _releaseGas()}(
            abi.encodeCall(IRewardVault.release, (ONE_MING))
        );
        if (!ok || reply.length < 32) {
            _waitForRelease(roundId, reply);
            return (false, 0);
        }
        // What arrived, not what the vault said it sent
        return (true, ming.balanceOf(address(this)) - held);
    }

    /// @dev What the release may spend: everything the callback has, bar the reserve.
    function _releaseGas() private view returns (uint256) {
        uint256 available = gasleft();
        return available > RELEASE_RESERVE_GAS ? available - RELEASE_RESERVE_GAS : 0;
    }

    /// @dev The round stays open and books a fresh attempt RELEASE_RETRY_DELAY ahead. The id that
    ///      brought us here is already consumed, so only the new one can settle this round. A float
    ///      too thin to book emits a 0 id and leaves the round for `rearm()`; nothing reverts.
    function _waitForRelease(uint64 roundId, bytes memory reason) private {
        uint256 newRequestId = _tryBookSettlement(roundId, uint64(block.timestamp + RELEASE_RETRY_DELAY));
        emit ReleaseFailed(roundId, reason, newRequestId);
    }

    /**
     * @notice Resolve top miner by iterating deployers in index order
     * @dev Called once per single-winner round on first checkpoint. Builds cumulative
     *      ranges on the fly for the winning block and finds whose range contains the sample.
     */
    function _resolveTopMiner(uint64 roundId, Round storage round) internal {
        uint8 winningBlock = round.winningBlock;
        uint256 sample = round.topMinerSeed % round.winnersDeployed;
        uint256 cumulative;
        uint256 count = round.minerCount;

        for (uint256 i; i < count; ) {
            address addr = minerByIndex[roundId][i];
            Miner storage m = miners[roundId][addr];

            if ((m.deployedMask & (1 << winningBlock)) != 0) {
                uint256 amt = m.amountPerBlock;
                if (sample >= cumulative && sample < cumulative + amt) {
                    round.topMiner = addr;
                    return;
                }
                cumulative += amt;
            }

            unchecked { ++i; }
        }
    }

    /// @dev View-only version of _resolveTopMiner for getTotalPendingRewards
    function _viewResolveTopMiner(uint64 roundId, Round storage round) internal view returns (address) {
        uint8 winningBlock = round.winningBlock;
        uint256 sample = round.topMinerSeed % round.winnersDeployed;
        uint256 cumulative;
        uint256 count = round.minerCount;

        for (uint256 i; i < count; ) {
            address addr = minerByIndex[roundId][i];
            Miner storage m = miners[roundId][addr];

            if ((m.deployedMask & (1 << winningBlock)) != 0) {
                uint256 amt = m.amountPerBlock;
                if (sample >= cumulative && sample < cumulative + amt) {
                    return addr;
                }
                cumulative += amt;
            }

            unchecked { ++i; }
        }
        return address(0);
    }

    function _getClaimablePool(uint256 totalDeployed, uint256 winnersDeployed) internal pure returns (uint256) {
        uint256 adminFee = (totalDeployed * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 losersPool = totalDeployed - winnersDeployed;
        uint256 losersAdminShare = (losersPool * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 vaultAmount = ((losersPool - losersAdminShare) * VAULT_FEE_BPS) / BPS_DENOMINATOR;
        return totalDeployed - adminFee - vaultAmount;
    }

    function _updateProcessingRewards(address user) internal {
        uint256 unclaimed = userUnclaimedMING[user];
        if (unclaimed == 0) return;

        uint256 accumulatedPerToken = accProcessingPerUnclaimed - userProcessingDebt[user];
        uint256 pending = (unclaimed * accumulatedPerToken) / 1e18;

        userProcessedMING[user] += pending;
        userProcessingDebt[user] = accProcessingPerUnclaimed;
    }

    function _safeTransferBNB(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }



    // ============ View Functions ============


    function getRoundDeployed(uint64 roundId) external view returns (uint256[25] memory) {
        return rounds[roundId].deployed;
    }

    function getMinerInfo(uint64 roundId, address user) external view returns (
        uint256 deployedMask,
        uint256 amountPerBlock,
        bool checkpointed
    ) {
        Miner storage miner = miners[roundId][user];
        return (miner.deployedMask, miner.amountPerBlock, miner.checkpointed);
    }



    /// @notice The gold in the pot, the BNB still waiting to become gold (this round's share, what a
    ///         request has not taken yet and what a refund returned), and the roll's odds.
    function getGoldpotInfo() external view returns (uint256 pool, uint256 pendingBNB, uint256 chance) {
        return (goldpotPool, goldpotBNB + goldPendingBnb + goldHeldWbnb, GOLDPOT_CHANCE);
    }


    function getTotalPendingRewards(address user) external view returns (
        uint256 pendingBNB,
        uint256 pendingUnprocessedMING,
        uint256 pendingProcessedMING,
        uint256 pendingGold,
        uint64 uncheckpointedRound
    ) {
        // 1. Already checkpointed rewards
        pendingBNB = userUnclaimedBNB[user];
        pendingUnprocessedMING = userUnclaimedMING[user];
        pendingGold = userUnclaimedGold[user];

        // 2. Processing bonus (stored + pending)
        pendingProcessedMING = userProcessedMING[user]
            + (userUnclaimedMING[user] * (accProcessingPerUnclaimed - userProcessingDebt[user])) / 1e18;

        // 3. Check for uncheckpointed round
        uint64 lastRound = userLastRound[user];
        if (lastRound == 0) return (pendingBNB, pendingUnprocessedMING, pendingProcessedMING, pendingGold, 0);

        Round storage round = rounds[lastRound];
        Miner storage miner = miners[lastRound][user];

        if (miner.checkpointed || !round.settled) {
            return (pendingBNB, pendingUnprocessedMING, pendingProcessedMING, pendingGold, 0);
        }

        // 4. Calculate uncheckpointed rewards
        {
            uint8 winningBlock = round.winningBlock;
            uint256 userDeployed = (miner.deployedMask & (1 << winningBlock)) != 0
                ? miner.amountPerBlock
                : 0;

            if (userDeployed == 0) {
                return (pendingBNB, pendingUnprocessedMING, pendingProcessedMING, pendingGold, 0);
            }

            uncheckpointedRound = lastRound;
            uint256 winnersDeployed = round.winnersDeployed;

            // BNB: proportional share of actual retained BNB
            pendingBNB += (_getClaimablePool(round.totalDeployed, winnersDeployed) * userDeployed) / winnersDeployed;

            // Gold: pro-rata share of a Goldpot hit
            if (round.goldpotAmount != 0) {
                pendingGold += (round.goldpotAmount * userDeployed) / winnersDeployed;
            }

            // MING (uncheckpointed goes to unprocessed)
            uint256 mingReward;

            if (round.topMiner == address(0)) {
                mingReward = (round.topMinerReward * userDeployed) / winnersDeployed;
            } else if (round.topMiner == address(1)) {
                if (round.minerCount > maxMinersForSingleWinner) {
                    // Over cap: would be forced to split on checkpoint
                    mingReward = (round.topMinerReward * userDeployed) / winnersDeployed;
                } else {
                    // Unresolved single winner: iterate deployers to check
                    if (_viewResolveTopMiner(lastRound, round) == user) {
                        mingReward = round.topMinerReward;
                    }
                }
            } else if (round.topMiner == user) {
                mingReward = round.topMinerReward;
            }

            pendingUnprocessedMING += mingReward;
        }
    }

    function getCurrentRoundInfo() external view returns (
        uint64 roundId,
        uint256 startTime,
        uint256 endTime,
        uint256 totalDeployed,
        uint256 timeRemaining,
        bool isActive
    ) {
        Round storage round = rounds[currentRoundId];

        roundId = currentRoundId;
        startTime = round.startTime;
        endTime = round.endTime;
        totalDeployed = round.totalDeployed;
        timeRemaining = block.timestamp >= round.endTime ? 0 : round.endTime - block.timestamp;
        isActive = gameStarted && block.timestamp < round.endTime && !round.settled;
    }

    // ============ Receive ============

    receive() external payable {}
}
