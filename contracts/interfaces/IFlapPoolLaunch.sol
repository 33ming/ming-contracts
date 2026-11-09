// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Flap Pool Launch types and interfaces
 * @notice Only the parts of Flap's launch surface that MING uses. Flap's own base contracts are not
 *         copied: a vault inherits nothing from them, it only has to match these shapes.
 * @dev    Field order is load-bearing. Every struct below was taken from a verified source:
 *         the launch types from the Portal implementation
 *         (0x60c1a088bB5c5D7CB169F793c54A317970e8970f, src/interfaces/IDirectPoolLaunch.sol and
 *         src/types/Distribution.sol), and the schema types from the ABI of a live, verified Flap
 *         factory and vault (0x693e48e4…7663e and its beacon implementation 0xe03f598a…E882).
 *         test/FlapTypes.test.ts round-trips every struct against Flap's own ABI, so a reordered or
 *         renamed field fails the suite rather than a launch transaction.
 *
 *         One trap worth recording: the VAULT fee slot's `configData` is the TUPLE encoding of
 *         FeeConfigVault, i.e. abi.encode(FeeConfigVault), which carries a leading offset word
 *         because the struct holds a dynamic member. Encoding it as two loose values
 *         (abi.encode(address, bytes)) is accepted by the ABI decoder but resolves the factory
 *         address to garbage, and the launch then fails with CallReverted.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Launch types
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Fee slots a launch may declare. Non-NONE slots must sum to exactly 10000 bps, at most four.
enum FeeSlotType {
    NONE,
    DEFLATION,
    LP_BPS,
    MARKETING,
    VAULT,
    DIVIDEND
}

/// @notice One fee slot: its type, its share, and an opaque payload decoded according to the type.
struct FeeConfig {
    FeeSlotType feeType;
    uint16 bps;
    bytes configData;
}

/// @notice 'FeeConfig.configData' payload for FeeSlotType.MARKETING.
struct FeeConfigMarket {
    address marketingAddress;
}

/// @notice 'FeeConfig.configData' payload for FeeSlotType.VAULT. Encode with abi.encode(FeeConfigVault).
struct FeeConfigVault {
    address vaultFactory;
    bytes vaultData;
}

/// @notice 'FeeConfig.configData' payload for FeeSlotType.DIVIDEND.
struct FeeConfigDividend {
    address dividendToken;
    uint256 minimumShareBalance;
}

/// @notice Everything a Pool Launch needs. 'poolToken' plus the distributed remainder must cover
///         'totalSupply': a leftover above one token reverts ExcessiveRemainder.
struct CreateTaxTokenParams {
    string name;
    string symbol;
    string meta;
    uint256 totalSupply;
    bytes32 salt;
    address quoteToken;
    uint8 dexId;
    uint256 poolQuote;
    uint256 poolToken;
    uint16 buyTaxRate;
    uint16 sellTaxRate;
    uint32 taxDuration;
    uint32 antiFarmerDuration;
    FeeConfig[] feeConfigs;
    uint8 antiSniperMode;
    uint32 exemptWindow;
    address[] exemptAddrs;
    uint256 creatorBuyQuote;
    bytes32 extensionID;
    bytes extensionData;
    address commissionReceiver;
}

/// @notice Where the supply that is not seeded into the pool goes. There is no post-launch entry point.
enum DistributionTarget {
    NONE,
    EXPLICIT,
    VAULT
}

/// @notice The remainder hand-off. For VAULT, 'strategy' is overwritten with the resolved vault.
struct Distribution {
    DistributionTarget target;
    address strategy;
    uint128 amount;
    bytes configData;
}

/// @notice The optional creator buy that runs after the pool is seeded.
struct CreatorBuyParams {
    uint256 minOutputAmount;
    bytes permitData;
}

// ─────────────────────────────────────────────────────────────────────────────
// UI schema types (IVaultSchemasV1)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice One input or output field, rendered by Flap's generic vault UI.
struct FieldDescriptor {
    string name;
    string fieldType;
    string description;
    uint8 decimals;
}

/// @notice Shape of a factory's 'FeeConfigVault.vaultData', so a launch form can be generated.
struct VaultDataSchema {
    string description;
    FieldDescriptor[] fields;
    bool isArray;
}

/// @notice A constraint a factory places on the launches it will accept, declared for UIs.
struct FactoryPolicy {
    string target;
    string operator;
    bytes value;
    string description;
}

/// @notice An approval the UI must perform before calling a write method.
struct ApproveAction {
    string tokenType;
    string amountFieldName;
}

/// @notice One user-facing vault method, as rendered by the generic UI.
struct VaultMethodSchema {
    string name;
    string description;
    FieldDescriptor[] inputs;
    FieldDescriptor[] outputs;
    ApproveAction[] approvals;
    bool isInputArray;
    bool isOutputArray;
    bool isWriteMethod;
}

/// @notice The vault's whole user-facing surface.
struct VaultUISchema {
    string vaultType;
    string description;
    VaultMethodSchema[] methods;
}

// ─────────────────────────────────────────────────────────────────────────────
// Interfaces
// ─────────────────────────────────────────────────────────────────────────────

/// @notice The one Portal entry point MING uses.
interface IFlapPortal {
    function launchTaxTokenV2(
        CreateTaxTokenParams calldata p,
        Distribution calldata distribution,
        CreatorBuyParams calldata creatorBuy
    ) external payable returns (address token, address pool);

    /// @notice Whether a (launch kind, quote token) pair is open, and the quote's USD price in 18 decimals.
    /// @dev    The price is admin-set and moves; read it at launch time rather than caching it.
    function launchQuoteConfig(uint8 kind, address quoteToken)
        external
        view
        returns (bool enabled, uint256 quotePriceUsd);
}

/// @notice What Flap's Portal and UI expect from a vault factory.
/// @dev    Only 'newVault' is exercised on the launch path today; the rest is read by Flap's UI and
///         by whoever reviews a factory before it is rated.
interface IFlapVaultFactory {
    /// @notice Deploy and initialise the launch's vault. Portal only. Must never call 'token'.
    /// @param launchParams abi.encode(CreateTaxTokenParams, Distribution) for this launch.
    function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        external
        returns (address vault);

    /// @notice Whether this factory's vault can account for revenue in 'quoteToken' (0 = native).
    function isQuoteTokenSupported(address quoteToken) external view returns (bool);

    /// @notice The Pool Launch spec version this factory implements. Must start with "pl";
    ///         currently "pl-v1".
    function factorySpecVersion() external pure returns (string memory);

    /// @notice Shape of this factory's 'FeeConfigVault.vaultData'.
    function vaultDataSchema() external pure returns (VaultDataSchema memory schema);

    /// @notice The constraints this factory enforces on a launch.
    function tokenCreationPolicies() external pure returns (FactoryPolicy[] memory policies);

    /// @notice Point the vault beacon at a new implementation. Flap Guardian only.
    function upgradeVaultImplementation(address newImplementation) external;
}

/// @notice The two methods every Pool Launch vault must expose.
interface IFlapLaunchVault {
    /// @notice Human-readable status. Must disclose fees, commission and every party that receives
    ///         revenue or reserved tokens.
    function description() external view returns (string memory);

    /// @notice The vault's user-facing methods, for Flap's generic UI.
    function vaultUISchema() external pure returns (VaultUISchema memory);
}

/// @notice The hand-off Flap's Portal calls to deliver the launch remainder.
interface IFlapDistributionStrategy {
    /// @notice Pull exactly 'amount' of `token` from the caller. Portal only, once per launch.
    /// @dev    Must emit FlapDistributionInitialized(distributor, token, amount).
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external;
}

/// @notice Flap's Token Dock entry point. Routing between the open and verified docks lives behind it.
/// @dev    Never cache the dock address: look the router up on every deposit and withdrawal, because
///         Flap moves a vault's balance across when it is certified.
interface ITokenDockRouter {
    function deposit(address token, uint256 amount) external;

    function withdraw(address token, uint256 amount, address to) external;

    function balanceOf(address token, address owner) external view returns (uint256);
}
