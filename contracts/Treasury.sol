// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GoldRequestBase} from "./GoldRequestBase.sol";
import {Timelocked} from "./Timelocked.sol";
import {IFlapPortalSwap} from "./interfaces/IFlapPortalSwap.sol";
import {IFlapTrigger, ITriggerReceiver} from "./interfaces/IFlapTrigger.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {BscAddresses} from "./lib/BscAddresses.sol";

/**
 * @title Treasury
 * @notice Takes 90% of the grid vault fee from GridMining and turns it into burnt MING, with 1/90 of
 *         each buy set aside as gold for stakers.
 *
 *         A buyback is a booked trigger, not a call anyone times. Once the held BNB reaches the
 *         threshold the Treasury books one with Flap's Trigger Service, no earlier than the last buy
 *         plus the interval, and pays the fee out of the BNB it holds. Flap runs the booking
 *         privately, so the buy cannot be sandwiched in its own block, and the cap per buy limits
 *         what a price pushed in earlier blocks could cost.
 *
 *         The buy goes through the launch Portal, priced by its own quote with the slippage setting
 *         taken off, and falls back to the PancakeSwap V2 router priced the same way. A failure keeps
 *         the BNB, is logged and books the next attempt.
 */
contract Treasury is Ownable2Step, ReentrancyGuard, GoldRequestBase, Timelocked, ITriggerReceiver {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Treasury holds 90% of the treasury fee T; spend / 90 is exactly 1% of T for stakers.
    uint256 public constant STAKER_GOLD_DIVISOR = 90;
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice How far below the quote a buy will still accept, and the ceiling on that setting
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 800;
    uint256 public constant MAX_SLIPPAGE_BPS = 1000;

    /// @notice Hard limits on the instant settings. The threshold and the cap per buy share the
    ///         range from MIN_BUYBACK_THRESHOLD to MAX_CAP_PER_BUY
    uint256 public constant MIN_BUYBACK_THRESHOLD = 0.01 ether;
    uint256 public constant MAX_CAP_PER_BUY = 5 ether;
    uint256 public constant MIN_BUYBACK_INTERVAL = 1 minutes;
    uint256 public constant MAX_BUYBACK_INTERVAL = 1 days;

    /// @notice Starting values
    uint256 public constant DEFAULT_CAP_PER_BUY = 0.2 ether;
    uint256 public constant DEFAULT_BUYBACK_INTERVAL = 1 minutes;

    /// @notice How long a booking may go unanswered before anyone can book a fresh one
    uint256 public constant TRIGGER_TIMEOUT = 10 minutes;

    // Every call a trigger callback makes out of this contract is capped, so a callee cannot burn
    // the callback's budget.

    /// @notice Gas for a buy through the Portal
    uint256 public constant PORTAL_SWAP_GAS = 700_000;
    /// @notice Gas for the Portal's quote, which is nonpayable and reads a route
    uint256 public constant PORTAL_QUOTE_GAS = 300_000;
    /// @notice Gas for a buy through the PancakeSwap fallback
    uint256 public constant ROUTER_SWAP_GAS = 400_000;
    /// @notice Gas for a read on another contract
    uint256 public constant VIEW_CALL_GAS = 30_000;
    /// @notice Gas for handing the stakers' gold to Staking
    uint256 public constant DISTRIBUTE_YIELD_GAS = 250_000;
    /// @notice The self-call that books a buyback, which contains the service's own requestTrigger.
    ///         An outer cap has to cover everything inside it.
    uint256 public constant BOOKING_CALL_GAS = 350_000;

    address public constant DEAD = BscAddresses.DEAD;
    IPancakeRouter02 public constant router = IPancakeRouter02(BscAddresses.PANCAKE_V2_ROUTER);
    IFlapPortalSwap public constant portal = IFlapPortalSwap(BscAddresses.FLAP_PORTAL);
    IFlapTrigger public constant triggerService = IFlapTrigger(BscAddresses.FLAP_TRIGGER_SERVICE);

    /// @dev The input side of a Portal buy: the native asset is `address(0)` with `msg.value` equal
    ///      to `inputAmount` and no permit data.
    address internal constant PORTAL_NATIVE = address(0);

    // ============ Immutables ============

    IERC20 public immutable ming;

    // ============ State ============

    IStaking public staking;
    address public gridMining;

    /// @notice The buyback bucket: BNB that will buy MING. Trigger fees come out of it, and the
    ///         stakers' share was taken out on arrival, so this is exactly what a buy can spend
    uint256 public vaultedBNB;

    /// @notice Instant settings, within the limits above
    uint256 public buybackThreshold;
    uint256 public capPerBuy;
    uint256 public buybackInterval;
    uint256 public slippageBps;

    /// @notice The open buyback booking, or 0 when none is
    uint256 public buybackRequestId;
    /// @notice When that booking was made, so a timeout runs per booking
    uint64 public buybackBookedAt;
    /// @notice When the last buy ran, which sets the earliest time for the next booking
    uint64 public lastBuybackAt;
    /// @notice The slot that booking asked for, so a buy booked for later cannot be rearmed early
    uint64 public buybackExecuteAfter;
    /// @notice Request ids this contract has already acted on, so a replay does nothing
    mapping(uint256 => bool) public requestConsumed;

    /// @notice XAUt held for stakers and not handed over yet
    uint256 public stakerGoldHeld;

    // Stats
    uint256 public totalBurned;            // MING sent to DEAD
    uint256 public totalGoldToStakers;     // XAUt sent to Staking
    uint256 public totalBuybacks;

    // ============ Events ============

    event VaultReceived(uint256 amount, uint256 toBuyback, uint256 toStakerGold, uint256 buybackBnb);
    event BuybackBooked(uint256 requestId, uint64 executeAfter);
    event BuybackRearmed(uint256 oldRequestId, uint256 newRequestId);
    event BuybackExecuted(uint256 bnbSpent, uint256 mingBurned, bool viaPortal);
    event BuybackFailedAndKept(uint256 bnb, bytes reason);
    event BuybackBelowMinimum(uint256 bnbSpent, uint256 received, uint256 minimum, bool viaPortal);
    event StakerGoldHeld(uint256 requestId, uint256 goldOut, uint256 heldNow);
    event StakerGoldPushed(uint256 goldOut, uint256 totalSoFar);
    event GoldRequested(uint256 requestId, uint256 bnbIn);
    event GoldRequestFailed(uint256 bnbPending, bytes reason);
    event GoldRefunded(uint256 requestId, uint256 wbnbBack);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event CapPerBuyUpdated(uint256 oldCap, uint256 newCap);
    event BuybackIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    // ============ Errors ============

    error OnlyGridMining();
    error WrongChain();
    error BelowThreshold();
    error SlippageTooHigh();
    error ZeroAddress();
    error RenounceDisabled();
    error ThresholdTooLow();
    error ThresholdTooHigh();
    error CapTooLow();
    error CapTooHigh();
    error IntervalOutOfRange();
    error BuybackAlreadyBooked();
    error NoBuybackBooked();
    error TriggerTimeoutNotReached(uint256 readyAt);
    error NoGoldToPush();
    error NoStakers();

    // ============ Modifiers ============

    modifier onlyGridMining() {
        if (msg.sender != gridMining) revert OnlyGridMining();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _ming,
        uint256 _buybackThreshold,
        address _guardian
    ) Ownable(msg.sender) GoldRequestBase() {
        if (_ming == address(0)) revert ZeroAddress();
        if (router.WETH() != address(wbnb)) revert WrongChain();
        if (_buybackThreshold < MIN_BUYBACK_THRESHOLD) revert ThresholdTooLow();
        if (_buybackThreshold > MAX_CAP_PER_BUY) revert ThresholdTooHigh();

        ming = IERC20(_ming);

        buybackThreshold = _buybackThreshold;
        capPerBuy = DEFAULT_CAP_PER_BUY;
        buybackInterval = DEFAULT_BUYBACK_INTERVAL;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
        // Reverts on zero and on the deployer, so this cannot exist without an independent veto
        _setGuardian(_guardian);
    }

    // ============ Admin Functions ============

    /// @dev Once the game is live only Flap's Guardian proposes one, and it waits out the timelock.
    function setGridMining(address _gridMining) external {
        if (_gridMining == address(0)) revert ZeroAddress();
        _requireProposer();
        _route(GRID_MINING_ACTION, abi.encode(_gridMining));
    }

    /// @notice address(0) disables the staker gold leg (100% of the spend goes to the buyback).
    /// @dev Once the game is live only Flap's Guardian proposes one, and it waits out the timelock.
    function setStaking(address _staking) external {
        _requireProposer();
        _route(STAKING_ACTION, abi.encode(_staking));
    }

    // ============ Timelock ============

    bytes32 public constant GRID_MINING_ACTION = keccak256("GRID_MINING");
    bytes32 public constant STAKING_ACTION = keccak256("STAKING");

    function _requireTimelockOwner() internal view override {
        _checkOwner();
    }

    /// @dev The game this Treasury serves decides when the settings stop being instant.
    function _gameIsLive() internal view override returns (bool) {
        if (gridMining == address(0)) return false;
        (bool ok, bytes memory data) = gridMining.staticcall(abi.encodeWithSignature("gameStarted()"));
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

    /// @inheritdoc Timelocked
    function _executeChange(bytes32 action, bytes memory data) internal override {
        if (action == GRID_MINING_ACTION) {
            gridMining = abi.decode(data, (address));
        } else if (action == STAKING_ACTION) {
            staking = IStaking(abi.decode(data, (address)));
        } else if (action == GUARDIAN_ACTION) {
            _setGuardian(abi.decode(data, (address)));
        } else {
            revert UnknownAction();
        }
    }

    function setBuybackThreshold(uint256 _threshold) external onlyOwner {
        if (_threshold < MIN_BUYBACK_THRESHOLD) revert ThresholdTooLow();
        if (_threshold > MAX_CAP_PER_BUY) revert ThresholdTooHigh();
        uint256 old = buybackThreshold;
        buybackThreshold = _threshold;
        emit ThresholdUpdated(old, _threshold);
    }

    function setCapPerBuy(uint256 _cap) external onlyOwner {
        if (_cap < MIN_BUYBACK_THRESHOLD) revert CapTooLow();
        if (_cap > MAX_CAP_PER_BUY) revert CapTooHigh();
        uint256 old = capPerBuy;
        capPerBuy = _cap;
        emit CapPerBuyUpdated(old, _cap);
    }

    function setBuybackInterval(uint256 _interval) external onlyOwner {
        if (_interval < MIN_BUYBACK_INTERVAL || _interval > MAX_BUYBACK_INTERVAL) revert IntervalOutOfRange();
        uint256 old = buybackInterval;
        buybackInterval = _interval;
        emit BuybackIntervalUpdated(old, _interval);
    }

    /// @notice How far below the Portal's quote a buy will still accept.
    function setSlippage(uint256 _slippageBps) external onlyOwner {
        if (_slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        uint256 old = slippageBps;
        slippageBps = _slippageBps;
        emit SlippageUpdated(old, _slippageBps);
    }

    // ============ Vault Functions ============

    /// @notice Receive vaulted BNB from GridMining, and book the next buy if there is enough for one.
    /// @dev The booking is caught: a settlement must not fail because a booking could not be made.
    function receiveVault() external payable onlyGridMining {
        // Split once, here, and never again: 1/90 of what arrives is the stakers' gold and the rest
        // buys MING. Neither bucket ever moves into the other.
        uint256 toGold = _stakerShare(msg.value);
        if (toGold > 0) goldPendingBnb += toGold;
        uint256 toBuyback = msg.value - toGold;
        vaultedBNB += toBuyback;
        emit VaultReceived(msg.value, toBuyback, toGold, vaultedBNB);

        // Booking the buy is caught, so a settlement never fails because a booking could not be made.
        // The stakers' gold is NOT asked for here: this call runs inside settlement under a gas cap,
        // and a VaultEx request on top of a booking does not fit it. The buy asks for it, and anyone
        // can call requestGold() in between.
        if (buybackRequestId == 0 && vaultedBNB >= buybackThreshold + triggerService.getFee()) {
            try this.bookBuyback{gas: BOOKING_CALL_GAS}() returns (uint256) {} catch {}
        }
    }

    /// @dev The stakers' share of an arriving amount, and 0 while nobody is staked (Treasury.sol's
    ///      long-standing rule): then the whole amount buys MING.
    function _stakerShare(uint256 amount) private view returns (uint256) {
        if (address(staking) == address(0)) return 0;
        uint256 staked;
        try staking.totalStaked{gas: VIEW_CALL_GAS}() returns (uint256 total) {
            staked = total;
        } catch {
            return 0;
        }
        if (staked == 0) return 0;
        return amount / STAKER_GOLD_DIVISOR;
    }

    /// @dev What the contract holds, so a swap's own effect on it can be measured
    struct Held {
        uint256 bnb;
        uint256 ming;
    }

    // ============ Booking ============

    /// @notice What a booking costs right now, as the service charges this contract
    function triggerFee() public view returns (uint256) {
        return triggerService.getFee();
    }

    /// @notice The earliest time the next buy may run: the interval after the last one.
    function nextBuybackAt() public view returns (uint64) {
        uint256 earliest = uint256(lastBuybackAt) + buybackInterval;
        return earliest > block.timestamp ? uint64(earliest) : 0;
    }

    /// @notice What the next buy would spend, 0 when there is not enough to book one.
    function buybackSpendable() public view returns (uint256) {
        uint256 fee = triggerService.getFee();
        if (vaultedBNB < buybackThreshold + fee) return 0;
        uint256 available = vaultedBNB - fee;
        return available > capPerBuy ? capPerBuy : available;
    }

    /// @notice Book the next buy. Callable by anyone once the threshold is met.
    function bookBuyback() external returns (uint256 requestId) {
        if (buybackRequestId != 0) revert BuybackAlreadyBooked();
        uint256 fee = triggerService.getFee();
        if (vaultedBNB < buybackThreshold + fee) revert BelowThreshold();
        return _book(fee, nextBuybackAt());
    }

    /// @notice Book a fresh buy when the booking has gone unanswered for TRIGGER_TIMEOUT.
    /// @dev The new id is the only one this will then accept, and the clock starts again.
    function rearmBuyback() external returns (uint256 requestId) {
        uint256 old = buybackRequestId;
        if (old == 0) revert NoBuybackBooked();
        uint256 readyAt = _rearmAt();
        if (block.timestamp < readyAt) revert TriggerTimeoutNotReached(readyAt);

        buybackRequestId = 0;
        requestId = _book(triggerService.getFee(), nextBuybackAt());
        emit BuybackRearmed(old, requestId);
    }

    /// @dev The timeout runs from the slot the booking asked for, not from when it was made: a buy
    ///      booked for later has not gone unanswered until that slot has passed. Each early rearm
    ///      would spend another fee out of the buyback's own BNB.
    function _rearmAt() private view returns (uint256) {
        uint64 from = buybackBookedAt > buybackExecuteAfter ? buybackBookedAt : buybackExecuteAfter;
        return uint256(from) + TRIGGER_TIMEOUT;
    }

    function _book(uint256 fee, uint64 executeAfter) private returns (uint256 requestId) {
        vaultedBNB -= fee;
        requestId = triggerService.requestTrigger{value: fee}(executeAfter);
        buybackRequestId = requestId;
        buybackBookedAt = uint64(block.timestamp);
        buybackExecuteAfter = executeAfter;
        emit BuybackBooked(requestId, executeAfter);
    }

    /// @dev The same booking from inside a callback, where nothing may revert.
    function _tryBook() private {
        if (buybackRequestId != 0) return;
        uint256 fee = triggerService.getFee();
        if (vaultedBNB < buybackThreshold + fee) return;
        try this.bookBuyback{gas: BOOKING_CALL_GAS}() returns (uint256) {} catch {}
    }

    // ============ The buy ============

    /**
     * @notice Run the booked buy. The Trigger Service calls this.
     * @dev Does nothing, and never reverts, unless the caller is the service, the id is the current
     *      booking and that id has not been acted on before. A failed buy keeps the BNB and books
     *      another attempt.
     */
    function trigger(uint256 requestId) external override nonReentrant {
        if (msg.sender != address(triggerService)) return;
        if (requestConsumed[requestId]) return;
        if (requestId != buybackRequestId) return;

        requestConsumed[requestId] = true;
        buybackRequestId = 0;
        lastBuybackAt = uint64(block.timestamp);

        // The stakers' share was taken out on arrival, so everything here is the buyback's
        uint256 spend = buybackSpendableNow();
        if (spend == 0) {
            _tryBook();
            return;
        }
        vaultedBNB -= spend;

        (bool bought, uint256 mingOut, bool viaPortal, bytes memory reason, uint256 spent) = _buy(spend);
        if (!bought) {
            // The buyback bucket keeps its BNB untouched, and the next attempt is booked
            vaultedBNB += spend;
            emit BuybackFailedAndKept(spend, reason);
            _tryBook();
            return;
        }
        // Whatever the route handed back inside the same call never left the bucket
        if (spent < spend) vaultedBNB += spend - spent;

        if (mingOut > 0) {
            ming.safeTransfer(DEAD, mingOut);
            totalBurned += mingOut;
        }
        totalBuybacks += 1;
        emit BuybackExecuted(spent, mingOut, viaPortal);

        _pushStakerGoldCaught();
        _tryRequestGold();
        _tryBook();
    }

    /// @notice What a buy running now would spend, ignoring the interval it has already waited out.
    function buybackSpendableNow() public view returns (uint256) {
        if (vaultedBNB == 0) return 0;
        return vaultedBNB > capPerBuy ? capPerBuy : vaultedBNB;
    }

    /**
     * @dev The buy itself: the Portal first, priced by its own quote, then the PancakeSwap V2 router
     *      priced by `getAmountsOut` made after-tax the same way. Both minimums are the quote less
     *      the slippage setting, and both measure what arrived here rather than what the pool sent,
     *      because the token taxes pool-side transfers.
     */
    function _buy(uint256 bnbAmount)
        private
        returns (bool bought, uint256 mingOut, bool viaPortal, bytes memory reason, uint256 spent)
    {
        Held memory held = _held();

        (bool quoted, uint256 minOut) = _portalMinOut(bnbAmount);
        if (quoted && minOut > 0) {
            // Low level for the same reason as the quote: the reply is not decoded, so a Portal
            // that answers with something unexpected cannot take the callback down.
            (bool ok, bytes memory err) = address(portal).call{value: bnbAmount, gas: PORTAL_SWAP_GAS}(
                abi.encodeCall(
                    IFlapPortalSwap.swapExactInput,
                    (IFlapPortalSwap.PortalExactInputParams({
                        inputToken: PORTAL_NATIVE,
                        outputToken: address(ming),
                        inputAmount: bnbAmount,
                        minOutputAmount: minOut,
                        permitData: ""
                    }))
                )
            );
            if (ok) {
                // The BNB has left, so this buy is over either way: a second attempt would spend
                // BNB that belongs to another bucket, and putting the spend back would claim BNB
                // that is gone. Burn what arrived, and say so if it came in under the minimum.
                (mingOut, spent) = _tally(held, minOut, true);
                return (true, mingOut, true, "", spent);
            }
            reason = err;
        }

        // Fallback: the same pricing through PancakeSwap V2
        (bool fallbackQuoted, uint256 fallbackMinOut) = _routerMinOut(bnbAmount);
        if (!fallbackQuoted || fallbackMinOut == 0) return (false, 0, false, reason, 0);

        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(ming);
        held = _held();
        try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount, gas: ROUTER_SWAP_GAS}(
            fallbackMinOut, path, address(this), block.timestamp
        ) {
            // As above: the route took the BNB, so what left stands whatever arrived
            (mingOut, spent) = _tally(held, fallbackMinOut, false);
            return (true, mingOut, false, "", spent);
        } catch (bytes memory err) {
            return (false, 0, false, err, 0);
        }
    }

    /// @dev What this contract holds, read before a swap so the swap's own effect can be measured.
    function _held() private view returns (Held memory held) {
        held.bnb = address(this).balance;
        held.ming = ming.balanceOf(address(this));
    }

    /**
     * @dev What a swap that returned actually did: the MING that arrived, and the BNB that actually
     *      left, which is the only amount the buyback bucket gives up. A route that returns without
     *      having swapped is the case this exists for - it says so, and the next attempt is booked.
     */
    function _tally(Held memory held, uint256 minOut, bool viaPortal)
        private
        returns (uint256 mingOut, uint256 spent)
    {
        mingOut = ming.balanceOf(address(this)) - held.ming;
        spent = held.bnb - address(this).balance;
        if (mingOut < minOut) emit BuybackBelowMinimum(spent, mingOut, minOut, viaPortal);
    }

    /**
     * @dev The Portal's quote already has the buy tax off it, so only the slippage setting comes off.
     *      Called low level and length-checked, because a `try` cannot catch a reply this contract
     *      fails to decode, and that would take the whole callback down with it.
     */
    function _portalMinOut(uint256 bnbAmount) private returns (bool quoted, uint256 minOut) {
        (bool ok, bytes memory data) = address(portal).call{gas: PORTAL_QUOTE_GAS}(
            abi.encodeCall(
                IFlapPortalSwap.quoteExactInput,
                (IFlapPortalSwap.QuoteExactInputParams({
                    inputToken: PORTAL_NATIVE,
                    outputToken: address(ming),
                    inputAmount: bnbAmount
                }))
            )
        );
        if (!ok || data.length != 32) return (false, 0);
        uint256 out = abi.decode(data, (uint256));
        if (out == 0) return (false, 0);
        return (true, (out * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR);
    }

    /**
     * @dev The fallback's minimum: the router's own quote, made after-tax with the token's live buy
     *      tax, less the slippage setting. A tax that cannot be read makes this a failed buy and the
     *      BNB stays, because a minimum priced without the tax would be refused by the pool anyway.
     */
    function _routerMinOut(uint256 bnbAmount) private view returns (bool quoted, uint256 minOut) {
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(ming);

        (bool ok, bytes memory data) = address(router).staticcall{gas: VIEW_CALL_GAS}(
            abi.encodeCall(IPancakeRouter02.getAmountsOut, (bnbAmount, path))
        );
        if (!ok || data.length < 128) return (false, 0);
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        if (amounts.length != path.length) return (false, 0);
        uint256 out = amounts[amounts.length - 1];
        if (out == 0) return (false, 0);

        (bool taxRead, uint256 taxBps) = _buyTaxBps();
        if (!taxRead) return (false, 0);

        uint256 afterTax = (out * (BPS_DENOMINATOR - taxBps)) / BPS_DENOMINATOR;
        return (true, (afterTax * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR);
    }

    /// @dev The buy tax the token charges right now, read from the token itself, so a tax that ends
    ///      or changes needs nothing here.
    function _buyTaxBps() private view returns (bool ok, uint256 bps) {
        (bool success, bytes memory data) =
            address(ming).staticcall{gas: VIEW_CALL_GAS}(abi.encodeWithSignature("buyTaxRate()"));
        if (success && data.length == 32) {
            uint256 value = abi.decode(data, (uint256));
            if (value <= BPS_DENOMINATOR) return (true, value);
        }
        return (false, 0);
    }

    // ============ Staker gold ============

    /// @inheritdoc GoldRequestBase
    function _creditGold(uint256 goldOut, uint256) internal override {
        stakerGoldHeld += goldOut;
    }

    function _onGoldRequested(uint256 requestId, uint256 amountIn) internal override {
        emit GoldRequested(requestId, amountIn);
    }

    function _onGoldFilled(uint256 requestId, uint256, uint256 goldOut) internal override {
        emit StakerGoldHeld(requestId, goldOut, stakerGoldHeld);
    }

    function _onGoldRefunded(uint256 requestId, uint256 wbnbBack) internal override {
        emit GoldRefunded(requestId, wbnbBack);
    }

    function _onGoldRequestFailed(uint256 pending, bytes memory reason) internal override {
        emit GoldRequestFailed(pending, reason);
    }

    /**
     * @notice Hand the gold held for stakers to Staking. Callable by anyone.
     * @dev Not done inside the vault's callback, because `distributeYield` reverts when nobody is
     *      staked and that callback must not revert.
     */
    function pushStakerGold() external nonReentrant {
        uint256 held = stakerGoldHeld;
        if (held == 0) revert NoGoldToPush();
        if (address(staking) == address(0) || staking.totalStaked() == 0) revert NoStakers();
        _pushStakerGold(held);
    }

    function _pushStakerGold(uint256 held) private {
        stakerGoldHeld = 0;
        // Staking fetches the gold itself and credits only what arrives, so it is approved for
        // exactly this distribution and the allowance is dropped again in the same transaction
        xaut.forceApprove(address(staking), held);
        staking.distributeYield(held);
        xaut.forceApprove(address(staking), 0);
        totalGoldToStakers += held;
        emit StakerGoldPushed(held, totalGoldToStakers);
    }

    /// @dev From inside a callback: hand the gold over if it can be handed over, and never revert.
    function _pushStakerGoldCaught() private {
        uint256 held = stakerGoldHeld;
        if (held == 0) return;
        if (address(staking) == address(0)) return;
        uint256 staked;
        try staking.totalStaked{gas: VIEW_CALL_GAS}() returns (uint256 total) {
            staked = total;
        } catch {
            return;
        }
        if (staked == 0) return;

        stakerGoldHeld = 0;
        xaut.forceApprove(address(staking), held);
        try staking.distributeYield{gas: DISTRIBUTE_YIELD_GAS}(held) {
            xaut.forceApprove(address(staking), 0);
            totalGoldToStakers += held;
            emit StakerGoldPushed(held, totalGoldToStakers);
        } catch {
            xaut.forceApprove(address(staking), 0);
            stakerGoldHeld = held;
        }
    }

    // ============ View Functions ============

    /// @notice The two buckets the vault fee was split into, so neither can hide the other: BNB for
    ///         buying, BNB still waiting to become the stakers' gold, and the gold already here.
    function getBuckets() external view returns (
        uint256 buybackBnb,
        uint256 stakerBnbPending,
        uint256 stakerWbnbHeld,
        uint256 stakerGoldHeldNow
    ) {
        return (vaultedBNB, goldPendingBnb, goldHeldWbnb, stakerGoldHeld);
    }

    function getStats() external view returns (
        uint256 _vaultedBNB,
        uint256 _totalBurned,
        uint256 _totalGoldToStakers,
        uint256 _totalBuybacks
    ) {
        return (vaultedBNB, totalBurned, totalGoldToStakers, totalBuybacks);
    }

    /// @notice The booking, when it was made, when a rearm becomes possible, and what a buy would spend.
    function getBuybackInfo() external view returns (
        uint256 requestId,
        uint64 bookedAt,
        uint256 rearmAt,
        uint256 spendable,
        uint256 fee
    ) {
        requestId = buybackRequestId;
        bookedAt = buybackBookedAt;
        rearmAt = requestId == 0 ? 0 : _rearmAt();
        spendable = buybackSpendable();
        fee = triggerService.getFee();
    }

    // ============ Receive ============

    receive() external payable {
        // Only accept BNB from GridMining through receiveVault()
        revert("Use receiveVault()");
    }

    // ============ Ownership ============

    /// @dev Only a buy takes BNB out of here, and that needs an owner to keep the settings workable,
    ///      so ownership cannot be dropped
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
