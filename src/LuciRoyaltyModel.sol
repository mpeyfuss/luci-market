// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable2Step.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

/// @title Luci Royalty Model
/// @notice Contract to calculate dynamic royalites based on piece mint price.
/// @dev Royalty percentage is based on profit above mint price.
///          - Sale <= mint price -> 0%
///          - Sale >= 2x mint price -> 10%
///          - Sliding scale otherwise between 0% and 10% fees
/// @dev This collection does not gate which collections can or can't be traded. That is up to the marketplace contract(s).
/// @author mpeyfuss
/// @author Sam Spratt
contract LuciRoyaltyModel is Ownable2Step {
    /////////////////////////////////////////////////////////////////////
    // TYPES
    /////////////////////////////////////////////////////////////////////

    struct CollectionConfig {
        bool configured;
        uint192 mintPrice;
    }

    struct TokenOverride {
        bool enabled;
        uint192 mintPrice;
    }

    /////////////////////////////////////////////////////////////////////
    // STORAGE
    /////////////////////////////////////////////////////////////////////

    uint256 public constant BASIS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 1_000; // 10%

    address public royaltyRecipient;

    mapping(address collection => CollectionConfig) public collections;
    mapping(address collection => mapping(uint256 tokenId => TokenOverride)) public tokenOverrides;

    /////////////////////////////////////////////////////////////////////
    // EVENTS
    /////////////////////////////////////////////////////////////////////

    event CollectionConfigured(address indexed collection, uint192 indexed mintPrice);
    event RoyaltyRecipientUpdated(address indexed oldRoyaltyRecipient, address indexed newRoyaltyRecipient);
    event TokenOverriden(address indexed collection, uint256 indexed tokenId, uint192 indexed mintPrice);

    /////////////////////////////////////////////////////////////////////
    // ERRORS
    /////////////////////////////////////////////////////////////////////

    error ZeroAddress();

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
    function calculateRoyalty(address collection, uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address recipient, uint256 royaltyToPay)
    {
        // set recipient
        recipient = royaltyRecipient;

        // determine mint price
        uint256 mintPrice;
        TokenOverride memory tokenOverride = tokenOverrides[collection][tokenId];
        if (tokenOverride.enabled) {
            mintPrice = tokenOverride.mintPrice;
        } else {
            CollectionConfig memory collectionConfig = collections[collection];
            mintPrice = collectionConfig.mintPrice;
        }

        // calculate royalty
        if (salePrice <= mintPrice) {
            royaltyToPay = 0;
        } else if (salePrice >= mintPrice * 2) {
            royaltyToPay = Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS);
        } else {
            // sliding scale
            uint256 profit = salePrice - mintPrice;
            royaltyToPay = Math.mulDiv(salePrice, profit * MAX_ROYALTY_BPS, mintPrice * BASIS); // royalty perc is based on profit and then calculated against total sale price
        }
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
    function configureCollection(address collection, uint192 mintPrice) external onlyOwner {
        collections[collection] = CollectionConfig({configured: true, mintPrice: mintPrice});

        emit CollectionConfigured(collection, mintPrice);
    }

    /// @notice Overrides the mint price for a particular token in a collection
    /// @dev Only owner
    function overrideToken(address collection, uint256 tokenId, uint192 mintPrice) external onlyOwner {
        tokenOverrides[collection][tokenId] = TokenOverride({enabled: true, mintPrice: mintPrice});

        emit TokenOverriden(collection, tokenId, mintPrice);
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
}
