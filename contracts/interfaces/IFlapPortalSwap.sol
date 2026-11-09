// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title The launch Portal's swap, for buying the token it launched
/// @notice Struct shapes and mutability taken from the Portal's verified ABI at
///         0x000042108465206185A077Edc3F3fd2b49060000 on chain 56.
/// @dev    What the contracts here rely on:
///         - `quoteExactInput` is NOT a view. It is nonpayable, so no view of ours can quote and the
///           quote is read inside the buying transaction.
///         - the quote already has the token's buy tax taken off, so it compares directly against
///           what arrives here.
///         - a token this Portal did not DEX reverts `TokenNotDEXed(address)` (0xffe6d071).
///         - `swapExactInput` is payable, and the Portal also exposes `nativeToQuoteEnabled(address)`,
///           so the native asset is an input it handles rather than something to wrap first.
interface IFlapPortalSwap {
    struct QuoteExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
    }

    struct PortalExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    /// @notice What `inputAmount` of `inputToken` would buy, after the output token's tax.
    function quoteExactInput(QuoteExactInputParams calldata params) external returns (uint256 outputAmount);

    /// @notice Buy `outputToken`, reverting unless at least `minOutputAmount` arrives.
    function swapExactInput(PortalExactInputParams calldata params) external payable returns (uint256 outputAmount);

    /// @notice Whether the Portal converts the native asset into this quote token itself.
    function nativeToQuoteEnabled(address quoteToken) external view returns (bool);
}
