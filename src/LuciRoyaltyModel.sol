// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable2Step.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title Luci Royalty Model
/// @notice Contract to calculate dynamic royalites based on piece mint price.
/// @dev Mint prices are denominated in USD with `USD_DECIMALS` decimals. The royalty percentage is derived by
///      converting the sale price into USD via a registered price feed, and that percentage is then applied to the
///      sale price in its original currency.
/// @dev Royalty percentage is based on profit above mint price.
///          - Sale <= mint price -> 0%
///          - Sale >= 2x mint price -> 10%
///          - Sliding scale otherwise between 0% and 10% fees
/// @dev If the sale price cannot be converted to USD (unregistered currency, stale or invalid feed answer, reverting
///      feed), the model falls back to `MAX_ROYALTY_BPS` so that trading is never blocked and royalties are never
///      under-charged.
/// @dev This collection does not gate which collections can or can't be traded. That is up to the marketplace contract(s).
/// @author mpeyfuss
/// @author Sam Spratt
contract LuciRoyaltyModel is Ownable2Step {
    /////////////////////////////////////////////////////////////////////
    // TYPES
    /////////////////////////////////////////////////////////////////////

    struct CollectionConfig {
        bool configured;
        uint192 mintPriceUsd; // `USD_DECIMALS` decimals
    }

    struct TokenOverride {
        bool enabled;
        uint192 mintPriceUsd; // `USD_DECIMALS` decimals
    }

    struct CurrencyConfig {
        bool allowed; // 1 byte
        uint8 currencyDecimals; // 1 byte - decimals of the currency itself (18 for native ETH)
        uint8 oracleDecimals; // 1 byte - cached from `oracle.decimals()` at configuration time
        uint32 maxAge; // 4 bytes - staleness window in seconds
        address oracle; // 20 bytes - <currency>/USD price feed
    }

    /////////////////////////////////////////////////////////////////////
    // STORAGE
    /////////////////////////////////////////////////////////////////////

    uint256 public constant BASIS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 1_000; // 10%
    uint256 public constant USD_DECIMALS = 8;
    uint8 public constant MAX_CURRENCY_DECIMALS = 36;

    /// @notice Sentinel currency address representing the chain's native asset
    address public constant NATIVE_CURRENCY = address(0);

    address public royaltyRecipient;

    mapping(address collection => CollectionConfig) public collections;
    mapping(address collection => mapping(uint256 tokenId => TokenOverride)) public tokenOverrides;
    mapping(address currency => CurrencyConfig) public currencies;

    /////////////////////////////////////////////////////////////////////
    // EVENTS
    /////////////////////////////////////////////////////////////////////

    event CollectionConfigured(address indexed collection, uint192 indexed mintPriceUsd);
    event RoyaltyRecipientUpdated(address indexed oldRoyaltyRecipient, address indexed newRoyaltyRecipient);
    event TokenOverriden(address indexed collection, uint256 indexed tokenId, uint192 indexed mintPriceUsd);
    event CurrencyConfigured(
        address indexed currency, address indexed oracle, uint8 currencyDecimals, uint8 oracleDecimals, uint32 maxAge
    );
    event CurrencyRemoved(address indexed currency);

    /////////////////////////////////////////////////////////////////////
    // ERRORS
    /////////////////////////////////////////////////////////////////////

    error ZeroAddress();
    error InvalidMaxAge();
    error InvalidCurrencyDecimals();

    /////////////////////////////////////////////////////////////////////
    // CONSTRUCTOR
    /////////////////////////////////////////////////////////////////////

    constructor(address initOwner, address initRoyaltyRecipient) Ownable(initOwner) {
        _setRoyaltyRecipient(initRoyaltyRecipient);
    }

    /////////////////////////////////////////////////////////////////////
    // ROYALTY FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Function to calculate royalty according to the model where royalty percent is based on the profit over the original mint price.
    /// @dev The royalty percentage is determined in USD terms, then applied to `salePrice` in its own currency.
    /// @param collection The collection being sold
    /// @param tokenId The token being sold
    /// @param salePrice The sale price, denominated in `currency`
    /// @param currency The sale currency, `NATIVE_CURRENCY` for the chain's native asset
    function calculateRoyalty(address collection, uint256 tokenId, uint256 salePrice, address currency)
        external
        view
        returns (address recipient, uint256 royaltyToPay)
    {
        // set recipient
        recipient = royaltyRecipient;

        // determine mint price
        uint256 mintPriceUsd;
        TokenOverride memory tokenOverride = tokenOverrides[collection][tokenId];
        if (tokenOverride.enabled) {
            mintPriceUsd = tokenOverride.mintPriceUsd;
        } else {
            CollectionConfig memory collectionConfig = collections[collection];
            mintPriceUsd = collectionConfig.mintPriceUsd;
        }

        // unconfigured mint price pays the max royalty
        if (mintPriceUsd == 0) {
            return (recipient, Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS));
        }

        // convert the sale price to USD, falling back to the max royalty if conversion is not possible
        (uint256 saleUsd, bool ok) = _toUsd(salePrice, currency);
        if (!ok) {
            return (recipient, Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS));
        }

        // determine the royalty percentage in USD terms
        uint256 bps;
        if (saleUsd <= mintPriceUsd) {
            bps = 0;
        } else if (saleUsd >= mintPriceUsd * 2) {
            bps = MAX_ROYALTY_BPS;
        } else {
            // sliding scale - royalty perc is based on profit and then calculated against total sale price
            bps = Math.mulDiv(saleUsd - mintPriceUsd, MAX_ROYALTY_BPS, mintPriceUsd);
        }

        // apply the percentage to the sale price in its original currency
        royaltyToPay = Math.mulDiv(salePrice, bps, BASIS);
    }

    /////////////////////////////////////////////////////////////////////
    // ADMIN FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Sets royalty recipeint
    /// @dev Only owner
    function setRoyaltyRecipient(address newRoyaltyRecipient) external onlyOwner {
        _setRoyaltyRecipient(newRoyaltyRecipient);
    }

    /// @notice Configures a collection's mint price
    /// @dev Only owner
    /// @param mintPriceUsd The mint price in USD, with `USD_DECIMALS` decimals
    function configureCollection(address collection, uint192 mintPriceUsd) external onlyOwner {
        collections[collection] = CollectionConfig({configured: true, mintPriceUsd: mintPriceUsd});

        emit CollectionConfigured(collection, mintPriceUsd);
    }

    /// @notice Overrides the mint price for a particular token in a collection
    /// @dev Only owner
    /// @param mintPriceUsd The mint price in USD, with `USD_DECIMALS` decimals
    function overrideToken(address collection, uint256 tokenId, uint192 mintPriceUsd) external onlyOwner {
        tokenOverrides[collection][tokenId] = TokenOverride({enabled: true, mintPriceUsd: mintPriceUsd});

        emit TokenOverriden(collection, tokenId, mintPriceUsd);
    }

    /// @notice Registers a sale currency and the price feed used to convert it to USD
    /// @dev Only owner. `currency` may be `NATIVE_CURRENCY` to configure the chain's native asset.
    /// @dev The oracle's decimals are read once here so that a misconfigured feed surfaces immediately.
    /// @param currency The currency address, `NATIVE_CURRENCY` for the native asset
    /// @param oracle The <currency>/USD price feed
    /// @param currencyDecimals The decimals of the currency (18 for native ETH)
    /// @param maxAge The maximum age of a feed answer, in seconds, before it is considered stale
    function configureCurrency(address currency, address oracle, uint8 currencyDecimals, uint32 maxAge)
        external
        onlyOwner
    {
        if (oracle == address(0)) revert ZeroAddress();
        if (maxAge == 0) revert InvalidMaxAge();
        if (currencyDecimals > MAX_CURRENCY_DECIMALS) revert InvalidCurrencyDecimals();

        uint8 oracleDecimals = IAggregatorV3(oracle).decimals();
        if (oracleDecimals > MAX_CURRENCY_DECIMALS) revert InvalidCurrencyDecimals();

        currencies[currency] = CurrencyConfig({
            allowed: true,
            currencyDecimals: currencyDecimals,
            oracleDecimals: oracleDecimals,
            maxAge: maxAge,
            oracle: oracle
        });

        emit CurrencyConfigured(currency, oracle, currencyDecimals, oracleDecimals, maxAge);
    }

    /// @notice Removes a sale currency, causing sales in it to fall back to the max royalty
    /// @dev Only owner
    function removeCurrency(address currency) external onlyOwner {
        delete currencies[currency];

        emit CurrencyRemoved(currency);
    }

    /////////////////////////////////////////////////////////////////////
    // INTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    function _setRoyaltyRecipient(address newRoyaltyRecipient) internal {
        if (newRoyaltyRecipient == address(0)) revert ZeroAddress();
        address oldRoyaltyRecipient = royaltyRecipient;
        royaltyRecipient = newRoyaltyRecipient;

        emit RoyaltyRecipientUpdated(oldRoyaltyRecipient, newRoyaltyRecipient);
    }

    /// @dev Converts `amount` of `currency` into USD with `USD_DECIMALS` decimals
    /// @return usd The USD value, or zero when conversion is not possible
    /// @return ok Whether the conversion succeeded
    function _toUsd(uint256 amount, address currency) internal view returns (uint256 usd, bool ok) {
        CurrencyConfig memory config = currencies[currency];
        if (!config.allowed) return (0, false);

        try IAggregatorV3(config.oracle).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (0, false);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > config.maxAge) return (0, false);

            usd = Math.mulDiv(
                amount,
                uint256(answer) * 10 ** USD_DECIMALS,
                10 ** uint256(config.currencyDecimals) * 10 ** uint256(config.oracleDecimals)
            );
            ok = true;
        } catch {
            return (0, false);
        }
    }
}
