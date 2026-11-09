// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BscAddresses
/// @notice External dependencies, hardcoded per network, so the deployed bytecode names the exact
///         router and token it will use, the gold token included.
/// @dev    GENERATED FILE - do not edit by hand. Source: config/addresses/bsc.json,
///         generator: scripts/addresses.ts. Deploy scripts refuse to run when CHAIN_ID does not
///         match the network they are pointed at.
///         Network: bsc (chain 56).
library BscAddresses {
    /// @notice The chain this build is pinned to. Deploy scripts compare it against the live chain id.
    uint256 internal constant CHAIN_ID = 56;

    // DEX
    address internal constant PANCAKE_V2_ROUTER      = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant WBNB                   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant XAUT                   = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

    // Flap launch platform
    address internal constant FLAP_PORTAL            = 0x000042108465206185A077Edc3F3fd2b49060000;
    address internal constant FLAP_GUARDIAN          = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address internal constant FLAP_TOKEN_DOCK_ROUTER = 0x000048E888aBf09f690a952E1b386b2D031a0000;
    address internal constant FLAP_TRIGGER_SERVICE   = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
    address internal constant FLAP_VAULT_EX          = 0x000048Df69f3d2af22Df6DC2d3B01FB592b90000;

    // Constants
    address internal constant DEAD                   = 0x000000000000000000000000000000000000dEaD;
}
