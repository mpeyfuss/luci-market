// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable2Step.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

/// @title Luci Royalty Model
/// @notice Contract to calculate dynamic royalites based on piece mint price.
/// @author mpeyfuss
/// @author Sam Spratt (designed the dynamic royalties based on mint price)
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

    uint256 constant public BASIS = 10_000;
    uint256 constant public MAX_ROYALTY_BPS = 1_000;

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

    error CollectionOrTokenNotAllowed();
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

    function calculateRoyalty(address collection, uint256 tokenId, uint256 salePrice) external view returns (address recipient, uint256 royaltyToPay) {
        // set recipient
        recipient = royaltyRecipient;

        // cache data
        CollectionConfig memory collectionConfig = collections[collection];
        TokenOverride memory tokenOverride = tokenOverrides[collection][tokenId];
        
        // determine mint price
        uint256 mintPrice = collectionConfig.mintPrice;
        if (tokenOverride.enabled) {
            mintPrice = tokenOverride.mintPrice;
        }

        // calculate royalty bps
        if (salePrice <= mintPrice) {
            royaltyToPay = 0;
        } else if (salePrice >= mintPrice * 2) {
            royaltyToPay = Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS);
        } else {
            // sliding scale
            uint256 profit = salePrice - mintPrice;
            royaltyToPay = Math.mulDiv(salePrice, profit * MAX_ROYALTY_BPS, mintPrice * BASIS);
        }
    }

    /////////////////////////////////////////////////////////////////////
    // ADMIN FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    function setRoyaltyRecipient(address newRoyaltyRecipient) external onlyOwner {
        _setRoyaltyRecipient(newRoyaltyRecipient);
    }

    function configureCollection(address collection, uint192 mintPrice) external onlyOwner {
        collections[collection] = CollectionConfig({
            configured: true,
            mintPrice: mintPrice
        });

        emit CollectionConfigured(collection, mintPrice);
    }

    function overrideToken(address collection, uint256 tokenId, uint192 mintPrice) external onlyOwner {
        tokenOverrides[collection][tokenId] = TokenOverride({
            enabled: true,
            mintPrice: mintPrice
        });

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