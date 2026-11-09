// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFlapVaultEx, IFlapVaultExConsumer, IWrappedNative} from "./interfaces/IFlapVaultEx.sol";
import {BscAddresses} from "./lib/BscAddresses.sol";

/**
 * @title GoldRequestBase
 * @notice Turns BNB set aside for gold into XAUt by asking FlapVaultEx, and takes the answer in a
 *         callback. Shared by GridMining, which adds the gold to the Goldpot, and the Treasury,
 *         which holds it for stakers.
 *
 *         One request is open at a time. BNB keeps accruing while it is, and goes out with the next
 *         request. A request's BNB is wrapped to WBNB first, because the vault refuses the native
 *         asset. A refund comes back as WBNB, less the vault's fee, and is kept for the next request
 *         rather than unwrapped, so nothing here ever sends BNB to a contract that may refuse it.
 *
 *         The callback never reverts for the vault: a revert there would undo the settlement and
 *         leave the request pending. It credits whatever arrives, however late.
 */
abstract contract GoldRequestBase is IFlapVaultExConsumer {
    // ============ Constants ============

    IFlapVaultEx public constant vaultEx = IFlapVaultEx(BscAddresses.FLAP_VAULT_EX);
    IWrappedNative public constant wbnb = IWrappedNative(BscAddresses.WBNB);

    /// @notice Smallest request worth making, since the vault's fee is a percentage
    uint256 internal constant MIN_GOLD_REQUEST = 0.001 ether;
    /// @notice Largest single request
    uint256 internal constant MAX_GOLD_REQUEST = 20 ether;

    /// @notice Gas a request gets when it is made from inside a callback, so the vault cannot burn
    ///         the caller's budget
    uint256 internal constant GOLD_REQUEST_CALL_GAS = 400_000;

    // ============ Immutables ============

    IERC20 public immutable xaut;
    uint8 public immutable goldDecimals;

    // ============ State ============

    /// @notice BNB set aside for gold and not yet asked for
    uint256 public goldPendingBnb;
    /// @notice WBNB a refund returned, which the next request spends first
    uint256 public goldHeldWbnb;
    /// @notice The open request, or 0 when none is
    uint256 public goldRequestId;
    /// @notice What the open request was for
    uint256 public goldRequestAmount;

    // ============ Errors ============

    error GoldZeroAddress();
    error GoldRequestOpen();
    error GoldBelowMinimum(uint256 available);

    constructor() {
        address gold = BscAddresses.XAUT;
        if (gold == address(0)) revert GoldZeroAddress();
        xaut = IERC20(gold);
        goldDecimals = IERC20Metadata(gold).decimals();
    }

    // ============ Views ============

    /// @notice What the next request would ask for, 0 when there is nothing to ask for
    function goldRequestable() public view returns (uint256) {
        if (goldRequestId != 0) return 0;
        uint256 available = goldPendingBnb + goldHeldWbnb;
        if (available < MIN_GOLD_REQUEST) return 0;
        return available > MAX_GOLD_REQUEST ? MAX_GOLD_REQUEST : available;
    }

    // ============ Requesting ============

    /// @notice Ask the vault to turn the gold BNB into XAUt. Callable by anyone.
    function requestGold() external returns (uint256 requestId) {
        if (goldRequestId != 0) revert GoldRequestOpen();
        uint256 amount = goldRequestable();
        if (amount == 0) revert GoldBelowMinimum(goldPendingBnb + goldHeldWbnb);
        return _sendGoldRequest(amount);
    }

    /// @dev For a caller that must not be taken down by a failure here, such as settlement.
    function _tryRequestGold() internal returns (bool sent) {
        uint256 amount = goldRequestable();
        if (amount == 0) return false;
        try this.requestGold{gas: GOLD_REQUEST_CALL_GAS}() returns (uint256) {
            return true;
        } catch (bytes memory reason) {
            _onGoldRequestFailed(goldPendingBnb + goldHeldWbnb, reason);
            return false;
        }
    }

    function _sendGoldRequest(uint256 amount) private returns (uint256 requestId) {
        // Spend what a refund returned first, then wrap as much BNB as the rest needs
        uint256 fromWbnb = goldHeldWbnb >= amount ? amount : goldHeldWbnb;
        uint256 fromBnb = amount - fromWbnb;
        goldHeldWbnb -= fromWbnb;
        goldPendingBnb -= fromBnb;
        if (fromBnb > 0) wbnb.deposit{value: fromBnb}();

        wbnb.approve(address(vaultEx), amount);
        requestId = vaultEx.requestSwap(
            IFlapVaultEx.ExactInputParams({
                inputToken: address(wbnb),
                outputToken: address(xaut),
                inputAmount: amount
            })
        );
        goldRequestId = requestId;
        goldRequestAmount = amount;
        _onGoldRequested(requestId, amount);
    }

    // ============ The vault's answer ============

    /// @inheritdoc IFlapVaultExConsumer
    function onFlapVaultExSettled(uint256 requestId, uint8 status, address token, uint256 amount) external {
        // A foreign caller is refused; the vault's own call never is, whatever it carries
        require(msg.sender == address(vaultEx), "not the vault");
        if (requestId != goldRequestId) return;

        uint256 asked = goldRequestAmount;
        goldRequestId = 0;
        goldRequestAmount = 0;

        if (status == uint8(IFlapVaultEx.RequestStatus.FULFILLED)) {
            if (token == address(xaut)) _creditGold(amount, asked);
            _onGoldFilled(requestId, asked, amount);
            return;
        }

        // A refund returns the input, less the vault's fee, and waits here for the next request
        if (token == address(wbnb)) goldHeldWbnb += amount;
        _onGoldRefunded(requestId, amount);
    }

    // ============ Hooks ============

    /// @dev Where the gold goes: the Goldpot in the game, the stakers' share in the Treasury.
    function _creditGold(uint256 goldOut, uint256 bnbIn) internal virtual;

    /// @dev Each child names its own events, because the game's carry a round id and the Treasury's do not.
    function _onGoldRequested(uint256 requestId, uint256 amountIn) internal virtual {}

    function _onGoldFilled(uint256 requestId, uint256 amountIn, uint256 goldOut) internal virtual {}

    function _onGoldRefunded(uint256 requestId, uint256 wbnbBack) internal virtual {}

    function _onGoldRequestFailed(uint256 pending, bytes memory reason) internal virtual {}
}
