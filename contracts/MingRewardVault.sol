// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {BscAddresses} from "./lib/BscAddresses.sol";
import {
    IFlapDistributionStrategy,
    IFlapLaunchVault,
    ITokenDockRouter,
    VaultUISchema,
    VaultMethodSchema,
    FieldDescriptor,
    ApproveAction
} from "./interfaces/IFlapPoolLaunch.sol";

/// @notice The part of a game this vault and its factory need: which token it pays out
interface IGame {
    function ming() external view returns (address);
}

/**
 * @title MingRewardVault
 * @notice Deployed behind a beacon proxy, so this contract holds no constructor state and is initialised
 *         once by the factory. The beacon's upgrade authority belongs to Flap's Guardian.
 */
contract MingRewardVault is Initializable, IFlapDistributionStrategy, IFlapLaunchVault {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant PROPOSAL_DELAY = 24 hours;
    uint256 public constant PROPOSAL_COOLDOWN = 24 hours;
    /// @notice Delay between proposing a fee wallet and being able to apply it
    uint256 public constant FEE_WALLET_DELAY = 24 hours;
    /// @notice The reserve is divided by this to get the daily cap: a 480 day run at full draw
    uint256 public constant RESERVE_PER_DAY_DIVISOR = 480;
    /// @notice Tokens all live games together may take per day, on top of each game's own cap
    uint256 public constant GLOBAL_DAILY_CAP = 10_000e18;
    uint256 private constant SECONDS_PER_DAY = 86_400;

    // ============ Storage (beacon proxy: append only, never reorder) ============

    IERC20 public token;
    /// @notice Tokens a single live game may take per day, and the most it can bank. Derived from the
    ///         launch reserve at creation and fixed: there is no setter, and the only input is the
    ///         token's total supply
    uint256 public dailyCap;
    /// @notice Where tax revenue is forwarded
    address public feeWallet;
    /// @notice Fee wallet waiting out FEE_WALLET_DELAY before it can be applied
    address public pendingFeeWallet;
    /// @notice When the pending fee wallet was proposed; zero when none is pending
    uint256 public feeWalletProposedAt;
    /// @notice Our own veto role. Flap's Guardian is accepted everywhere this address is
    address public guardian;
    address public pendingGuardian;
    address public owner;
    /// @notice Owner waiting to accept; only this address can complete the transfer
    address public pendingOwner;

    struct Game {
        uint64 liveAt;
        uint64 lastAccrual;
        uint128 banked;
    }

    mapping(address => Game) private _games;
    address private _proposedGame;
    uint256 public lastProposalAt;
    bool public frozen;
    /// @notice Tax revenue seen so far, cumulative
    uint256 public totalRevenueReceived;
    /// @notice Tax revenue already sent to the fee wallet, cumulative
    uint256 public totalRevenueForwarded;
    /// @notice Revenue recognised and not yet spent. Every inflow is recognised as the balance above
    ///         this baseline, and every outflow decrements it in the same transaction
    uint256 public accountedQuote;
    /// @notice Single-use flag for the launch distribution, not inferred from other state
    bool public distributionDone;
    /// @notice Every address ever registered as a game, in registration order, so description() can
    ///         name each party that can receive reserved tokens
    address[] private _gameList;
    /// @notice Keeps a removed game that is proposed again from being listed twice
    mapping(address => bool) private _listed;
    /// @notice When the shared allowance last accrued, and what of it is banked
    uint64 public globalLastAccrual;
    uint128 public globalBanked;

    // ============ Events ============

    event GameRegistered(address indexed game, uint256 liveAt);
    event GameProposed(address indexed game, uint256 liveAt);
    event GameRemoved(address indexed game, address indexed by);
    event GamesFrozen();
    event GuardianTransferStarted(address indexed guardian, address indexed pendingGuardian);
    event GuardianTransferred(address indexed oldGuardian, address indexed newGuardian);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event Released(address indexed game, uint256 requested, uint256 sent);
    event Deposited(address indexed from, uint256 amount);
    /// @dev Flap's IStrategy event, declared exactly as their interface does: both arguments
    ///      unindexed and no distributor, so the topic matches what their indexer expects.
    event FlapDistributionInitialized(address token, uint256 amount);
    event Docked(uint256 amount);
    event Undocked(uint256 amount);
    event RevenueReceived(address indexed from, uint256 amount);
    event RevenueRecognised(uint256 amount, uint256 accountedQuote);
    event RevenueForwarded(address indexed feeWallet, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event FeeWalletProposed(address indexed newWallet, uint256 applyAt);
    event FeeWalletApplied(address indexed oldWallet, address indexed newWallet);
    event FeeWalletProposalCancelled(address indexed newWallet);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);

    // ============ Initialiser ============

    constructor() {
        _disableInitializers();
    }

    /**
     * @param token_ The launched token
     * @param owner_ The launch creator
     * @param guardian_ Our veto role. Flap's Guardian is always accepted as well
     * @param feeWallet_ Where tax revenue is forwarded
     * @param game_ The game that may release the reserve from the moment of the launch
     * @param reserve_ The reserve this vault will receive, which fixes the daily cap
     */
    function initialize(
        address token_,
        address owner_,
        address guardian_,
        address feeWallet_,
        address game_,
        uint256 reserve_
    ) external initializer {
        _requireNotZero(token_);
        _requireNotZero(owner_);
        _requireNotZero(guardian_);
        _requireNotZero(feeWallet_);
        _requireNotZero(game_);
        require(reserve_ >= RESERVE_PER_DAY_DIVISOR, "Reserve too small");

        dailyCap = reserve_ / RESERVE_PER_DAY_DIVISOR;
        token = IERC20(token_);
        owner = owner_;
        guardian = guardian_;
        feeWallet = feeWallet_;

        // The game exists before the launch, so it is registered here rather than in a later call
        _games[game_] = Game({liveAt: uint64(block.timestamp), lastAccrual: uint64(block.timestamp), banked: 0});
        globalLastAccrual = uint64(block.timestamp);
        _list(game_);
        emit GameRegistered(game_, block.timestamp);
    }

    // ============ Modifiers ============

    /**
     * @dev Everything that moves the reserve or hands the vault on. The project guardian is not here:
     *      it can stop things, not start them. Flap's Guardian is accepted, as on every other
     *      permissioned function.
     */
    modifier onlyOwner() {
        _requireOwner();
        _;
    }

    /// @dev The cancelling side, which the project guardian does hold: it can undo what is pending
    ///      without being able to propose anything itself
    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    modifier onlyHub() {
        require(msg.sender == BscAddresses.FLAP_PORTAL, "Not hub");
        _;
    }

    /**
     * @dev The repeated checks, each in one place.
     *
     * A modifier is inlined into every function that carries it, and a message inlined with it is
     * stored once per use. Routing each repeated guard through one function keeps a single copy of
     * its string in the deployed code, which is what keeps this contract inside the size limit.
     */
    function _requireOwner() private view {
        require(msg.sender == owner || msg.sender == BscAddresses.FLAP_GUARDIAN, "Not owner");
    }

    function _requireAdmin() private view {
        require(
            msg.sender == owner || msg.sender == guardian || msg.sender == BscAddresses.FLAP_GUARDIAN,
            "Not owner or guardian"
        );
    }

    function _requireGuardian() private view {
        require(msg.sender == guardian || msg.sender == BscAddresses.FLAP_GUARDIAN, "Not guardian");
    }

    function _requireNotZero(address a) private pure {
        require(a != address(0), "Zero address");
    }

    function _requireNotFrozen() private view {
        require(!frozen, "Games are frozen");
    }

    function _requireNoProposalPending() private view {
        require(pendingGame() == address(0), "Proposal pending");
    }

    /// @dev The pending fee wallet, or a revert when there is none
    function _pendingFeeWalletOrRevert() private view returns (address next) {
        next = pendingFeeWallet;
        require(next != address(0), "No fee wallet proposal");
    }

    // ============ Flap: distribution ============

    /// @inheritdoc IFlapDistributionStrategy
    /// @dev Portal only, one-shot. Pulls exactly 'amount', verifies it arrived, and parks it in the dock,
    ///      verifying again that the dock credited the full amount. A fee-on-transfer or a partially
    ///      crediting dock therefore reverts the launch rather than silently shorting the reserve.
    function initializeDistribution(address token_, uint256 amount, bytes calldata, bytes32) external onlyHub {
        require(!distributionDone, "Already distributed");
        require(token_ == address(token), "Wrong token");
        distributionDone = true;

        uint256 balanceBefore = IERC20(token_).balanceOf(address(this));
        IERC20(token_).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token_).balanceOf(address(this)) - balanceBefore;
        require(received == amount, "Distribution amount mismatch");

        emit FlapDistributionInitialized(token_, amount);

        address router = BscAddresses.FLAP_TOKEN_DOCK_ROUTER;
        uint256 dockedBefore = ITokenDockRouter(router).balanceOf(token_, address(this));
        _dock(amount);
        uint256 credited = ITokenDockRouter(router).balanceOf(token_, address(this)) - dockedBefore;
        require(credited == amount, "Dock amount mismatch");
    }

    // ============ Flap: revenue ============

    /// @notice Tax revenue in BNB, and Flap's wake call. Recognises new revenue by balance delta and
    ///         returns: no external calls, no loops, and a wake that finds nothing is a silent no-op.
    /// @dev Flap forwards the dispatcher's gas here and ignores a revert, so this must stay cheap.
    receive() external payable {
        _sync();
    }

    /// @notice Recognise any revenue that arrived without a wake call. Permissionless, side-effect free.
    /// @dev The recovery path Flap's spec recommends: donations and missed pings land here.
    function sync() external returns (uint256 recognised) {
        return _sync();
    }

    /// @notice Send the recognised revenue to the fee wallet. Callable by anyone.
    /// @dev Recognises first, then decrements the baseline before the transfer, so a failed send reverts
    ///      the whole call and leaves the baseline matching the balance.
    function forwardRevenue() external returns (uint256 amount) {
        _sync();

        amount = accountedQuote;
        require(amount != 0, "Nothing to forward");

        accountedQuote = 0;
        totalRevenueForwarded += amount;
        emit RevenueForwarded(feeWallet, amount);

        (bool ok,) = payable(feeWallet).call{value: amount}("");
        require(ok, "Forward failed");
    }

    /// @dev Credit only the delta above the baseline, never the raw balance
    function _sync() private returns (uint256 recognised) {
        uint256 balance = address(this).balance;
        if (balance <= accountedQuote) return 0; // rule 2: a zero-delta wake does nothing

        unchecked {
            recognised = balance - accountedQuote;
        }
        accountedQuote = balance;
        totalRevenueReceived += recognised;

        emit RevenueReceived(msg.sender, recognised);
        emit RevenueRecognised(recognised, balance);
    }

    /// @notice Start a fee wallet change. It can be applied once FEE_WALLET_DELAY has passed
    function proposeFeeWallet(address newWallet) external onlyOwner {
        _requireNotZero(newWallet);
        pendingFeeWallet = newWallet;
        feeWalletProposedAt = block.timestamp;
        emit FeeWalletProposed(newWallet, block.timestamp + FEE_WALLET_DELAY);
    }

    /// @notice Apply the proposed fee wallet, once the delay has passed
    function applyFeeWallet() external onlyOwner {
        address next = _pendingFeeWalletOrRevert();
        require(block.timestamp >= feeWalletProposedAt + FEE_WALLET_DELAY, "Fee wallet delay pending");

        emit FeeWalletApplied(feeWallet, next);
        feeWallet = next;
        pendingFeeWallet = address(0);
        feeWalletProposedAt = 0;
    }

    /// @notice Drop a pending fee wallet change
    function cancelFeeWallet() external onlyAdmin {
        address next = _pendingFeeWalletOrRevert();
        pendingFeeWallet = address(0);
        feeWalletProposedAt = 0;
        emit FeeWalletProposalCancelled(next);
    }

    // ============ Dock ============

    /// @notice Move idle float into the dock
    function dock(uint256 amount) external onlyOwner {
        _dock(amount);
    }

    /// @notice Pull reserve out of the dock, back into this vault
    function undock(uint256 amount) external onlyOwner {
        _undock(amount);
    }

    function _dock(uint256 amount) private {
        if (amount == 0) return;
        address router = BscAddresses.FLAP_TOKEN_DOCK_ROUTER;
        token.forceApprove(router, amount);
        ITokenDockRouter(router).deposit(address(token), amount);
        emit Docked(amount);
    }

    /// @dev Withdraws to this vault and checks what actually arrived. A dock that reverts, or delivers
    ///      less than asked, takes the caller down with it: paying a game short would be worse
    function _undock(uint256 amount) private {
        if (amount == 0) return;
        uint256 before = token.balanceOf(address(this));
        ITokenDockRouter(BscAddresses.FLAP_TOKEN_DOCK_ROUTER).withdraw(address(token), amount, address(this));
        uint256 delivered = token.balanceOf(address(this)) - before;
        require(delivered >= amount, "Dock shortfall");
        emit Undocked(amount);
    }

    /// @dev What the dock holds for this vault right now. Read on every path that needs it, so no
    ///      local counter can drift from the dock's own books
    function _docked() private view returns (uint256) {
        return ITokenDockRouter(BscAddresses.FLAP_TOKEN_DOCK_ROUTER).balanceOf(address(token), address(this));
    }

    /// @notice Send the whole balance of some other token to the fee wallet. Tokens arrive here by
    ///         accident or airdrop and would otherwise be stuck; the reward token is refused, because
    ///         that is the reserve
    function sweep(address other) external onlyOwner returns (uint256 amount) {
        require(other != address(token), "Cannot sweep reward token");
        amount = IERC20(other).balanceOf(address(this));
        require(amount != 0, "Nothing to sweep");
        emit Swept(other, feeWallet, amount);
        IERC20(other).safeTransfer(feeWallet, amount);
    }

    // ============ Game registry ============

    /// @notice Propose a further game, callable by Flap's Guardian alone. Live PROPOSAL_DELAY later,
    ///         one proposal per PROPOSAL_COOLDOWN. The owner and our guardian cannot add a game; they
    ///         can cancel a pending one through removeGame
    function proposeGame(address game) external {
        require(msg.sender == BscAddresses.FLAP_GUARDIAN, "Not Flap guardian");
        _requireNotZero(game);
        _requireNotFrozen();
        require(_games[game].liveAt == 0, "Already registered");
        _requireNoProposalPending();
        require(lastProposalAt == 0 || block.timestamp >= lastProposalAt + PROPOSAL_COOLDOWN, "Proposal cooldown");

        // The same check the launch makes: a game has to exist and pay out this token
        require(game.code.length != 0, "Game has no code");
        address gameToken = IGame(game).ming();
        require(gameToken == address(token), "Game token mismatch");

        uint64 liveAt = uint64(block.timestamp + PROPOSAL_DELAY);
        _games[game] = Game({liveAt: liveAt, lastAccrual: liveAt, banked: 0});
        _list(game);
        _proposedGame = game;
        lastProposalAt = block.timestamp;

        emit GameProposed(game, liveAt);
    }

    /// @notice Permanently disable proposeGame. Our guardian or Flap's Guardian only, not the owner,
    ///         and only once a game is live, so the vault can never be frozen with nothing able to
    ///         release. Reverts while a proposal is pending
    function freezeGames() external {
        _requireGuardian();
        _requireNotFrozen();
        _requireNoProposalPending();
        require(_liveGames() != 0, "No live game");
        frozen = true;
        emit GamesFrozen();
    }

    /// @notice Remove a registered or pending game. Refused if it would leave no live game, because
    ///         the reserve would then be stranded with nothing able to release it. A pending game does
    ///         not count: it cannot release yet. Removing a game that is already live is Flap's
    ///         Guardian's call alone; the owner and the project guardian can only cancel one still pending
    function removeGame(address game) external onlyAdmin {
        Game storage g = _games[game];
        require(g.liveAt != 0, "Not registered");

        bool wasLive = block.timestamp >= g.liveAt;
        require(!wasLive || msg.sender == BscAddresses.FLAP_GUARDIAN, "Flap guardian removes live");
        require(!wasLive || _liveGames() != 1, "Last live game");

        delete _games[game];
        if (_proposedGame == game) _proposedGame = address(0);
        emit GameRemoved(game, msg.sender);
    }

    // ============ Guardian and owner ============

    /// @notice Start a guardian transfer. address(0) cancels. Our guardian or Flap's may call it;
    ///         accepting the handover stays with the pending guardian alone
    function transferGuardian(address newGuardian) external {
        _requireGuardian();
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(guardian, newGuardian);
    }

    function acceptGuardian() external {
        require(msg.sender != address(0) && msg.sender == pendingGuardian, "Not pending guardian");
        emit GuardianTransferred(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
    }

    /// @notice Start an ownership transfer. Only the pending owner can complete it, so a wrong
    ///         address cannot lock the vault out
    function transferOwnership(address newOwner) external onlyOwner {
        _requireNotZero(newOwner);
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete an ownership transfer
    function acceptOwnership() external {
        require(msg.sender != address(0) && msg.sender == pendingOwner, "Not pending owner");
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }


    // ============ Game ============

    /**
     * @notice Release up to 'amount' to the calling game, paying from float first and then the dock.
     * @dev Two behaviours, both deliberate. If float plus dock cannot cover the claim, it pays what
     *      exists, possibly nothing, and does not revert, so a round still settles. If the dock itself
     *      fails, or hands back less than asked, it reverts, which stalls the round until the dock
     *      works again rather than paying the game short.
     *
     *      Bounded by this game's own allowance and the one shared by every game; both are debited
     *      by what goes out.
     */
    function release(uint256 amount) external returns (uint256 sent) {
        Game storage g = _games[msg.sender];
        if (g.liveAt == 0) return 0;
        if (block.timestamp < g.liveAt) {
            emit Released(msg.sender, amount, 0);
            return 0;
        }

        uint256 accrued = _accrued(g);
        uint256 shared = _globalAccrued();
        uint256 float = token.balanceOf(address(this));
        uint256 total = float + _docked();

        sent = amount;
        if (sent > accrued) sent = accrued;
        if (sent > shared) sent = shared;
        if (sent > total) sent = total;

        g.banked = uint128(accrued - sent);
        g.lastAccrual = uint64(block.timestamp);
        globalBanked = uint128(shared - sent);
        globalLastAccrual = uint64(block.timestamp);

        if (sent != 0) {
            // Withdraw only the shortfall, so the dock keeps custody of the rest
            if (sent > float) _undock(sent - float);
            token.safeTransfer(msg.sender, sent);
        }

        emit Released(msg.sender, amount, sent);
    }

    /// @notice Pull tokens in. Plain transfers work too; call dock() afterwards to park them.
    function deposit(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    // ============ Views ============

    /// @notice Implementation version. Bumped on every change to this contract, so an operator can tell
    ///         which logic a beacon proxy is running.
    function version() external pure returns (string memory) {
        return "1.1.0";
    }

    /// @notice The launch token, under the name Flap's UI uses for it. Their approval flow knows
    ///         "taxToken" and "lpToken" and ignores any other tokenType, so the schema below names
    ///         this one and this view answers it.
    function taxToken() external view returns (address) {
        return address(token);
    }

    /// @notice What release(type(uint256).max) would send the game right now.
    function available(address game) external view returns (uint256) {
        Game storage g = _games[game];
        if (g.liveAt == 0 || block.timestamp < g.liveAt) return 0;
        uint256 accrued = _accrued(g);
        uint256 shared = _globalAccrued();
        if (shared < accrued) accrued = shared;
        uint256 total = token.balanceOf(address(this)) + _docked();
        return accrued < total ? accrued : total;
    }

    /// @notice The allowance shared by every game right now, before the reserve is considered
    function globalAvailable() external view returns (uint256) {
        return _globalAccrued();
    }

    /// @notice Reserve still held for this vault: float here plus whatever the dock holds for it
    function totalReserve() external view returns (uint256) {
        return token.balanceOf(address(this)) + _docked();
    }

    /// @notice What Flap's dock currently holds for this vault
    function reserveDocked() external view returns (uint256) {
        return _docked();
    }

    function pendingGame() public view returns (address) {
        address p = _proposedGame;
        if (p == address(0)) return address(0);
        return block.timestamp < _games[p].liveAt ? p : address(0);
    }

    function isLive(address game) external view returns (bool) {
        Game storage g = _games[game];
        return g.liveAt != 0 && block.timestamp >= g.liveAt;
    }

    function games(address game) external view returns (uint64 liveAt, uint64 lastAccrual, uint128 banked) {
        Game storage g = _games[game];
        return (g.liveAt, g.lastAccrual, g.banked);
    }

    /// @notice How many registered games can release right now
    function liveGameCount() external view returns (uint256) {
        return _liveGames();
    }

    /// @notice How many addresses have ever been registered as a game, removed ones included
    function gameCount() external view returns (uint256) {
        return _gameList.length;
    }

    /// @notice The game at 'index' in registration order
    function gameAt(uint256 index) external view returns (address) {
        return _gameList[index];
    }

    /// @notice Every address ever registered as a game, in registration order. A removed game stays
    ///         in the list, because it did have access to the reserve while it was live
    function registeredGames() external view returns (address[] memory) {
        return _gameList;
    }

    /// @notice The dock entry this vault uses. Looked up on every deposit and withdrawal.
    function tokenDockRouter() external pure returns (address) {
        return BscAddresses.FLAP_TOKEN_DOCK_ROUTER;
    }

    // ============ Flap: disclosure ============

    /// @inheritdoc IFlapLaunchVault
    /// @dev One line per subject. The sections are separate functions and joined in two halves,
    ///      because one expression holding all of them runs the stack out
    function description() external view returns (string memory) {
        return string.concat(
            string.concat(
                "MING Grid Mining is live at ming.family.\n",
                _tokens(token.balanceOf(address(this)) + _docked()),
                " MING left to mine, paid out at 1 MING a round when at least one miner is on the drawn tile.\n",
                _capsSection()
            ),
            _taxSection(),
            _roundSection(),
            _controlSection(),
            _gamesSection()
        );
    }

    function _capsSection() private view returns (string memory) {
        return string.concat(
            "Releases at most ", _tokens(dailyCap), " MING a day per game, ",
            _tokens(GLOBAL_DAILY_CAP), " across all games.\n"
        );
    }

    function _taxSection() private view returns (string memory) {
        return string.concat(
            "Tax: 3% on every MING trade, paid in BNB. After Flap's protocol share, the rest arrives here and is ",
            "forwarded to the team fee wallet ",
            _toHexString(feeWallet),
            ". The team intends to use 67% of it for the gold reserve and 33% for the team.\n"
        );
    }

    /// @dev What the game does with the BNB players put in
    function _roundSection() private pure returns (string memory) {
        return "Each round: 1% of all deposits is the admin fee. The drawn tile's miners are paid their stake back less 1%, plus the other tiles' deposits less 1% and a 10% vault fee, shared by stake. If nobody is on the drawn tile, nobody is paid: 1% is the admin fee and 99% the vault fee. The vault fee goes 90% to the Treasury, which buys MING and burns it, setting 1.11% of it aside as gold for stakers while anyone is staked, and 10% to the Goldpot, which pays the drawn tile's miners on a 0.11% chance each round. Claiming mined MING costs 10%; an early unstake burns 10%.\n";
    }

    function _controlSection() private view returns (string memory) {
        return string.concat(
            "Control: the owner is ",
            _toHexString(owner),
            " and the guardian is ",
            _toHexString(guardian),
            ". Flap's Guardian can do everything the owner and the guardian can, and only it can add a game ",
            "(live 24 hours later), remove a live game (never the last one) or upgrade this vault. The guardian ",
            "can only cancel a pending fee wallet or game, freeze the game list or hand its role on. Changing the ",
            "fee wallet takes two steps 24 hours apart. Ownership moves in two steps.\n"
        );
    }

    /// @dev Names the games that can take reserve out of this vault now, or will be able to, and
    ///      counts the ones that no longer can, so the text stays bounded however many are removed;
    ///      registeredGames() and gameAt() carry the whole history
    function _gamesSection() private view returns (string memory section) {
        uint256 n = _gameList.length;
        if (n == 0) return "No game is registered yet, so nothing can take the reserve.";

        uint256 removed;
        for (uint256 i; i < n; i++) {
            address game = _gameList[i];
            uint64 liveAt = _games[game].liveAt;
            if (liveAt == 0) {
                removed++;
                continue;
            }
            section = string.concat(
                section,
                bytes(section).length == 0 ? "Game: " : "\nGame: ",
                _toHexString(game),
                block.timestamp >= liveAt ? ", live." : string.concat(", pending until ", _toString(liveAt), ".")
            );
        }
        if (removed != 0) {
            section = string.concat(
                section,
                bytes(section).length == 0 ? "plus " : "\nplus ",
                _toString(removed),
                " removed, which can no longer release; registeredGames() lists them."
            );
        }
    }

    /// @inheritdoc IFlapLaunchVault
    function vaultUISchema() external pure returns (VaultUISchema memory) {
        VaultMethodSchema[] memory methods = new VaultMethodSchema[](6);

        methods[0] = VaultMethodSchema({
            name: "totalReserve",
            description: "MING left to mine: held here plus in Flap's Token Dock",
            inputs: new FieldDescriptor[](0),
            outputs: _one("amount", "uint256", "Raw token units", 18),
            approvals: new ApproveAction[](0),
            isInputArray: false,
            isOutputArray: false,
            isWriteMethod: false
        });
        methods[1] = VaultMethodSchema({
            name: "totalRevenueReceived",
            description: "Tax received by this vault so far, in BNB",
            inputs: new FieldDescriptor[](0),
            outputs: _one("amount", "uint256", "wei", 18),
            approvals: new ApproveAction[](0),
            isInputArray: false,
            isOutputArray: false,
            isWriteMethod: false
        });
        methods[2] = VaultMethodSchema({
            name: "available",
            description: "MING the game can release right now, within its daily cap and the shared cap",
            inputs: _one("game", "address", "The game contract", 0),
            outputs: _one("amount", "uint256", "Raw token units", 18),
            approvals: new ApproveAction[](0),
            isInputArray: false,
            isOutputArray: false,
            isWriteMethod: false
        });
        methods[3] = VaultMethodSchema({
            name: "deposit",
            description: "Add MING to the reserve. Needs an approval first",
            inputs: _one("amount", "uint256", "Raw token units", 18),
            outputs: new FieldDescriptor[](0),
            approvals: _approve("taxToken", "amount"),
            isInputArray: false,
            isOutputArray: false,
            isWriteMethod: true
        });
        methods[4] = VaultMethodSchema({
            name: "sync",
            description: "Count BNB that arrived without a call. Anyone can call it",
            inputs: new FieldDescriptor[](0),
            outputs: _one("recognised", "uint256", "wei newly recognised", 18),
            approvals: new ApproveAction[](0),
            isInputArray: false,
            isOutputArray: false,
            isWriteMethod: true
        });
        methods[5] = VaultMethodSchema({
            name: "forwardRevenue",
            description: "Send the tax held here to the team fee wallet. Anyone can call it",
            inputs: new FieldDescriptor[](0),
            outputs: _one("amount", "uint256", "wei forwarded", 18),
            approvals: new ApproveAction[](0),
            isInputArray: false,
            isOutputArray: false,
            isWriteMethod: true
        });

        return VaultUISchema({
            vaultType: "MING Grid Mining",
            description: "Mine MING on a 25-tile grid. Every 60 seconds one tile is drawn and its miners are paid, plus 1 MING from this reserve.",
            methods: methods
        });
    }

    // ============ Internal ============

    /// @dev How many listed games can release right now. Counted rather than stored, because a game
    ///      becomes live as time passes, with no transaction in which to update a counter
    function _liveGames() private view returns (uint256 live) {
        uint256 n = _gameList.length;
        for (uint256 i; i < n; i++) {
            uint64 liveAt = _games[_gameList[i]].liveAt;
            if (liveAt != 0 && block.timestamp >= liveAt) live++;
        }
    }

    /// @dev Append 'game' to the disclosure list once, however many times it is registered
    function _list(address game) private {
        if (_listed[game]) return;
        _listed[game] = true;
        _gameList.push(game);
    }

    /// @dev The shared allowance, accruing per second to GLOBAL_DAILY_CAP and banking at most one
    ///      day, exactly as a game's own does
    function _globalAccrued() private view returns (uint256) {
        uint256 cap = GLOBAL_DAILY_CAP;
        uint256 accrued =
            uint256(globalBanked) + ((block.timestamp - globalLastAccrual) * cap) / SECONDS_PER_DAY;
        return accrued > cap ? cap : accrued;
    }

    function _accrued(Game storage g) private view returns (uint256) {
        uint256 cap = dailyCap;
        uint256 accrued = uint256(g.banked) + ((block.timestamp - g.lastAccrual) * cap) / SECONDS_PER_DAY;
        return accrued > cap ? cap : accrued;
    }

    function _one(string memory name, string memory fieldType, string memory desc, uint8 decimals)
        private
        pure
        returns (FieldDescriptor[] memory f)
    {
        f = new FieldDescriptor[](1);
        f[0] = FieldDescriptor({name: name, fieldType: fieldType, description: desc, decimals: decimals});
    }

    function _approve(string memory tokenType, string memory amountFieldName)
        private
        pure
        returns (ApproveAction[] memory a)
    {
        a = new ApproveAction[](1);
        a[0] = ApproveAction({tokenType: tokenType, amountFieldName: amountFieldName});
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) digits++;
        bytes memory buffer = new bytes(digits);
        for (uint256 v = value; v != 0; v /= 10) buffer[--digits] = bytes1(uint8(48 + (v % 10)));
        return string(buffer);
    }

    /// @dev Whole tokens, with thousands separators
    function _tokens(uint256 raw) private pure returns (string memory) {
        uint256 v = raw / 1e18;
        if (v == 0) return "0";
        uint256 digits;
        for (uint256 t = v; t != 0; t /= 10) digits++;
        bytes memory out = new bytes(digits + (digits - 1) / 3);
        uint256 i = out.length;
        for (uint256 d; v != 0; d++) {
            if (d != 0 && d % 3 == 0) out[--i] = ",";
            out[--i] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(out);
    }

    function _toHexString(address a) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 41; i > 1; i--) {
            out[i] = alphabet[v & 0xf];
            v >>= 4;
        }
        return string(out);
    }
}
