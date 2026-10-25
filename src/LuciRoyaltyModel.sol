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
/// @dev Appreciation above mint price determines the royalty percentage, up to a cap configured per collection or
///      token. That percentage is applied to the gross sale price; the royalty is not a percentage of profit.
///          - Sale <= mint price -> 0%
///          - Sale >= 2x mint price -> cap
///          - Sliding scale otherwise between 0% and the cap
/// @dev The cap is set alongside the mint price and can never exceed `MAX_ROYALTY_BPS`. A token override carries its
///      own cap, which takes precedence over the collection's.
/// @dev If the mint price is zero or the sale price cannot be converted to USD, the model falls back to the cap.
///      A collection with no configuration and no token override pays `MAX_ROYALTY_BPS`.
/// @dev This collection does not gate which collections can or can't be traded. That is up to the marketplace contract(s).
/// @author mpeyfuss
/// @author Sam Spratt
contract LuciRoyaltyModel is Ownable2Step {
    /////////////////////////////////////////////////////////////////////
    // TYPES
    /////////////////////////////////////////////////////////////////////

    struct CollectionConfig {
        bool configured;
        uint16 maxRoyaltyBps; // cap on the sliding scale, at most `MAX_ROYALTY_BPS`
        uint192 mintPriceUsd; // `USD_DECIMALS` decimals
    }

    struct TokenOverride {
        bool enabled;
        uint16 maxRoyaltyBps; // cap on the sliding scale, at most `MAX_ROYALTY_BPS`
        uint192 mintPriceUsd; // `USD_DECIMALS` decimals
    }

    struct CurrencyConfig {
        bool allowed; // 1 byte
        uint8 currencyDecimals; // 1 byte - decimals of the currency itself (18 for native ETH)
        uint8 oracleDecimals; // 1 byte - feed decimals declared at configure time
        uint32 maxAge; // 4 bytes - staleness window in seconds
        address oracle; // 20 bytes - <currency>/USD price feed
    }

    /////////////////////////////////////////////////////////////////////
    // STORAGE
    /////////////////////////////////////////////////////////////////////

    uint256 public constant BASIS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 1_000; // 10%
    uint256 public constant USD_DECIMALS = 8;
    uint8 public constant MAX_CURRENCY_DECIMALS = 18;

    /// @notice Sentinel currency address representing the chain's native asset
    address public constant NATIVE_CURRENCY = address(0);

    address public royaltyRecipient;

    mapping(address collection => CollectionConfig) public collections;
    mapping(address collection => mapping(uint256 tokenId => TokenOverride)) public tokenOverrides;
    mapping(address currency => CurrencyConfig) public currencies;

    /////////////////////////////////////////////////////////////////////
    // EVENTS
    /////////////////////////////////////////////////////////////////////

    event CollectionConfigured(address indexed collection, uint192 indexed mintPriceUsd, uint16 maxRoyaltyBps);
    event RoyaltyRecipientUpdated(address indexed oldRoyaltyRecipient, address indexed newRoyaltyRecipient);
    event TokenOverriden(
        address indexed collection, uint256 indexed tokenId, uint192 indexed mintPriceUsd, uint16 maxRoyaltyBps
    );
    event TokenOverrideCleared(address indexed collection, uint256 indexed tokenId);
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
    error InvalidRoyaltyBps();

    /////////////////////////////////////////////////////////////////////
    // CONSTRUCTOR
    /////////////////////////////////////////////////////////////////////

    constructor(address initOwner, address initRoyaltyRecipient) Ownable(initOwner) {
        _setRoyaltyRecipient(initRoyaltyRecipient);
    }

    /////////////////////////////////////////////////////////////////////
    // ROYALTY FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Calculates a gross-sale royalty whose percentage is determined by appreciation over the mint price.
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

        // determine mint price and royalty cap
        uint256 mintPriceUsd;
        uint256 maxRoyaltyBps;
        TokenOverride memory tokenOverride = tokenOverrides[collection][tokenId];
        if (tokenOverride.enabled) {
            mintPriceUsd = tokenOverride.mintPriceUsd;
            maxRoyaltyBps = tokenOverride.maxRoyaltyBps;
        } else {
            CollectionConfig memory collectionConfig = collections[collection];
            // an unconfigured collection has no cap of its own and pays the max royalty
            if (!collectionConfig.configured) {
                return (recipient, Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS));
            }
            mintPriceUsd = collectionConfig.mintPriceUsd;
            maxRoyaltyBps = collectionConfig.maxRoyaltyBps;
        }

        // a zero cap is royalty free, no need to consult the price feed
        if (maxRoyaltyBps == 0) {
            return (recipient, 0);
        }

        // unconfigured mint price pays the cap
        if (mintPriceUsd == 0) {
            return (recipient, Math.mulDiv(salePrice, maxRoyaltyBps, BASIS));
        }

        // convert the sale price to USD, falling back to the cap if conversion is not possible
        (uint256 saleUsd, bool ok) = _toUsd(salePrice, currency);
        if (!ok) {
            return (recipient, Math.mulDiv(salePrice, maxRoyaltyBps, BASIS));
        }

        // determine the royalty percentage based on USD values
        if (saleUsd <= mintPriceUsd) {
            return (recipient, 0);
        }
        if (saleUsd >= mintPriceUsd * 2) {
            return (recipient, Math.mulDiv(salePrice, maxRoyaltyBps, BASIS));
        }
        // sliding scale
        royaltyToPay = Math.mulDiv(salePrice, (saleUsd - mintPriceUsd) * maxRoyaltyBps, mintPriceUsd * BASIS);
    }

    /////////////////////////////////////////////////////////////////////
    // ADMIN FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Sets royalty recipeint
    /// @dev Only owner
    function setRoyaltyRecipient(address newRoyaltyRecipient) external onlyOwner {
        _setRoyaltyRecipient(newRoyaltyRecipient);
    }

    /// @notice Configures a collection's mint price and royalty cap
    /// @dev Only owner
    /// @param mintPriceUsd The mint price in USD, with `USD_DECIMALS` decimals
    /// @param maxRoyaltyBps The royalty charged at or above 2x mint price, at most `MAX_ROYALTY_BPS`. Zero is royalty free.
    function configureCollection(address collection, uint192 mintPriceUsd, uint16 maxRoyaltyBps) external onlyOwner {
        if (maxRoyaltyBps > MAX_ROYALTY_BPS) revert InvalidRoyaltyBps();

        collections[collection] =
            CollectionConfig({configured: true, maxRoyaltyBps: maxRoyaltyBps, mintPriceUsd: mintPriceUsd});

        emit CollectionConfigured(collection, mintPriceUsd, maxRoyaltyBps);
    }

    /// @notice Overrides the mint price and royalty cap for a particular token in a collection
    /// @dev Only owner
    /// @param mintPriceUsd The mint price in USD, with `USD_DECIMALS` decimals
    /// @param maxRoyaltyBps The royalty charged at or above 2x mint price, at most `MAX_ROYALTY_BPS`. Zero is royalty free.
    function overrideToken(address collection, uint256 tokenId, uint192 mintPriceUsd, uint16 maxRoyaltyBps)
        external
        onlyOwner
    {
        if (maxRoyaltyBps > MAX_ROYALTY_BPS) revert InvalidRoyaltyBps();

        tokenOverrides[collection][tokenId] =
            TokenOverride({enabled: true, maxRoyaltyBps: maxRoyaltyBps, mintPriceUsd: mintPriceUsd});

        emit TokenOverriden(collection, tokenId, mintPriceUsd, maxRoyaltyBps);
    }

    /// @notice Clears a token override so the collection mint price and royalty cap apply again
    /// @dev Only owner
    function clearTokenOverride(address collection, uint256 tokenId) external onlyOwner {
        delete tokenOverrides[collection][tokenId];

        emit TokenOverrideCleared(collection, tokenId);
    }

    /// @notice Registers a sale currency and the price feed used to convert it to USD
    /// @dev Only owner. `currency` may be `NATIVE_CURRENCY` to configure the chain's native asset.
    /// @dev The feed is not probed at configure time: `oracleDecimals` is owner-declared, and conversion re-reads
    ///      `decimals()` live and falls back to the royalty cap if it differs, so a wrong declaration or a scale
    ///      change without a matching `answer` rescaling fails closed.
    /// @param currency The currency address, `NATIVE_CURRENCY` for the native asset
    /// @param oracle The <currency>/USD price feed
    /// @param currencyDecimals The decimals of the currency (18 for native ETH)
    /// @param oracleDecimals The decimals of the feed's answers
    /// @param maxAge The maximum age of a feed answer, in seconds, before it is considered stale
    function configureCurrency(
        address currency,
        address oracle,
        uint8 currencyDecimals,
        uint8 oracleDecimals,
        uint32 maxAge
    ) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        if (maxAge == 0) revert InvalidMaxAge();
        if (currencyDecimals > MAX_CURRENCY_DECIMALS) revert InvalidCurrencyDecimals();
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

    /// @notice Removes a sale currency, causing sales in it to fall back to the royalty cap
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
            if (!_isUsableRound(answer, updatedAt, config.maxAge)) return (0, false);

            // a revert inside a `try` success block is not caught by its `catch`, so `decimals()` gets its own guard
            try IAggregatorV3(config.oracle).decimals() returns (uint8 liveDecimals) {
                if (liveDecimals != config.oracleDecimals) return (0, false);
            } catch {
                return (0, false);
            }

            uint256 scale = uint256(answer) * 10 ** USD_DECIMALS;
            uint256 denominator = 10 ** uint256(config.currencyDecimals) * 10 ** uint256(config.oracleDecimals);
            // a conversion result that would overflow is treated as a failed conversion
            // the conversion overflows when amount * scale / denominator exceeds uint256
            if (scale > denominator && amount > Math.mulDiv(type(uint256).max, denominator, scale)) {
                return (0, false);
            }

            usd = Math.mulDiv(amount, scale, denominator);
            ok = true;
        } catch {
            return (0, false);
        }
    }

    /// @dev Whether `answer` / `updatedAt` is a currently usable feed tick for `maxAge`
    function _isUsableRound(int256 answer, uint256 updatedAt, uint32 maxAge) internal view returns (bool) {
        if (answer <= 0) return false;
        if (updatedAt == 0 || updatedAt > block.timestamp) return false;
        if (block.timestamp - updatedAt > maxAge) return false;
        if (uint256(answer) > type(uint256).max / 10 ** USD_DECIMALS) return false; // overflow check
        return true;
    }
}
