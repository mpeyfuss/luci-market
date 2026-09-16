// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";
import {LuciRoyaltyModel} from "../src/LuciRoyaltyModel.sol";
import {LuciTestBase} from "./LuciTestBase.sol";
import {MockAggregatorV3} from "./mocks/MarketplaceMocks.sol";

contract LuciRoyaltyModelTest is LuciTestBase {
    address internal constant NATIVE = address(0);

    function test_constructorSetsOwnerAndRecipient() public view {
        assertEq(royaltyModel.owner(), owner);
        assertEq(royaltyModel.royaltyRecipient(), royaltyRecipient);
    }

    function test_constructorRevertsForZeroRecipient() public {
        vm.expectRevert(LuciRoyaltyModel.ZeroAddress.selector);
        new LuciRoyaltyModel(owner, address(0));
    }

    function test_onlyOwnerCanSetRoyaltyRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.setRoyaltyRecipient(newRecipient);
    }

    function test_setRoyaltyRecipientUpdatesAndEmits() public {
        address newRecipient = makeAddr("newRecipient");

        vm.expectEmit(true, true, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.RoyaltyRecipientUpdated(royaltyRecipient, newRecipient);

        vm.prank(owner);
        royaltyModel.setRoyaltyRecipient(newRecipient);

        assertEq(royaltyModel.royaltyRecipient(), newRecipient);
    }

    function test_setRoyaltyRecipientRevertsForZeroAddress() public {
        vm.expectRevert(LuciRoyaltyModel.ZeroAddress.selector);
        vm.prank(owner);
        royaltyModel.setRoyaltyRecipient(address(0));
    }

    function test_configureCollectionStoresMintPriceAndEmits() public {
        address collection = makeAddr("collection");

        vm.expectEmit(true, true, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.CollectionConfigured(collection, 2_000e8);

        vm.prank(owner);
        royaltyModel.configureCollection(collection, 2_000e8);

        (bool configured, uint192 mintPriceUsd) = royaltyModel.collections(collection);
        assertTrue(configured);
        assertEq(mintPriceUsd, 2_000e8);
    }

    function test_onlyOwnerCanConfigureCollection() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.configureCollection(address(nft), 2_000e8);
    }

    function test_overrideTokenTakesPrecedenceAndEmits() public {
        // $16,000 mint price = 8 ETH at $2,000/ETH
        uint192 overrideUsd = 16_000e8;

        vm.expectEmit(true, true, true, true, address(royaltyModel));
        emit LuciRoyaltyModel.TokenOverriden(address(nft), TOKEN_ID, overrideUsd);

        vm.prank(owner);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, overrideUsd);

        (bool enabled, uint192 mintPriceUsd) = royaltyModel.tokenOverrides(address(nft), TOKEN_ID);
        assertTrue(enabled);
        assertEq(mintPriceUsd, overrideUsd);

        // 12 ETH sale = $24,000 -> 50% profit over $16,000 -> 5% of 12 ETH
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, 12 ether, NATIVE);
        assertEq(royalty, 0.6 ether);
    }

    function test_onlyOwnerCanOverrideToken() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, 1_000e8);
    }

    /////////////////////////////////////////////////////////////////////
    // ROYALTY CALCULATION
    /////////////////////////////////////////////////////////////////////

    function test_calculateRoyaltyUsesExpectedThresholds() public view {
        (, uint256 belowMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE - 1, NATIVE);
        (, uint256 atMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, NATIVE);
        (, uint256 atDoubleMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 2, NATIVE);
        (, uint256 aboveDoubleMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 3, NATIVE);

        assertEq(belowMint, 0);
        assertEq(atMint, 0);
        assertEq(atDoubleMint, 1 ether); // 10% of 10 ETH = 1 ETH
        assertEq(aboveDoubleMint, 1.5 ether); // 10% of 15 ETH = 1.5 ETH
    }

    function test_calculateRoyaltySlidingScale() public view {
        uint256 salePrice = 7.5 ether; // $15,000 against a $10,000 mint -> 50% profit -> 500 bps
        uint256 expectedBps = Math.mulDiv(_toUsd(salePrice) - MINT_PRICE_USD, 1_000, MINT_PRICE_USD);
        uint256 expected = Math.mulDiv(salePrice, expectedBps, 10_000);

        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);

        assertEq(expectedBps, 500);
        assertEq(royalty, expected);
        assertEq(royalty, 0.375 ether); // 5% of 7.5 ETH = 0.375 ETH
    }

    function test_calculateRoyaltyTracksEthPriceMoves() public {
        uint256 salePrice = 7.5 ether;

        (, uint256 atBasePrice) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(atBasePrice, 0.375 ether); // 5%

        // ETH doubles -> the same 7.5 ETH sale is $30,000, >= 2x the $10,000 mint -> full 10%
        _setEthUsdPrice(ETH_USD_PRICE * 2);
        (, uint256 atDoublePrice) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(atDoublePrice, 0.75 ether);

        // ETH halves -> the same sale is $7,500, below the $10,000 mint -> 0%
        _setEthUsdPrice(ETH_USD_PRICE / 2);
        (, uint256 atHalfPrice) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(atHalfPrice, 0);
    }

    function test_calculateRoyaltyForUnconfiguredCollectionDefaultsToMaxRoyalty() public {
        address unconfigured = makeAddr("unconfigured");

        (address recipient, uint256 zeroSaleRoyalty) = royaltyModel.calculateRoyalty(unconfigured, TOKEN_ID, 0, NATIVE);
        (, uint256 royalty) = royaltyModel.calculateRoyalty(unconfigured, TOKEN_ID, 1 ether, NATIVE);

        assertEq(recipient, royaltyRecipient);
        assertEq(zeroSaleRoyalty, 0);
        assertEq(royalty, 0.1 ether);
    }

    /////////////////////////////////////////////////////////////////////
    // CURRENCY REGISTRY
    /////////////////////////////////////////////////////////////////////

    function test_configureCurrencyStoresConfigAndEmits() public {
        address currency = makeAddr("currency");
        MockAggregatorV3 feed = new MockAggregatorV3(18, 1e18);

        vm.expectEmit(true, true, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.CurrencyConfigured(currency, address(feed), 6, 2 hours);

        vm.prank(owner);
        royaltyModel.configureCurrency(currency, address(feed), 6, 2 hours);

        (bool allowed, uint8 currencyDecimals, uint32 maxAge, address oracle) = royaltyModel.currencies(currency);
        assertTrue(allowed);
        assertEq(currencyDecimals, 6);
        assertEq(maxAge, 2 hours);
        assertEq(oracle, address(feed));
    }

    function test_onlyOwnerCanConfigureOrRemoveCurrency() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 18, 1 hours);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.removeCurrency(NATIVE);
    }

    function test_configureCurrencyRevertsForInvalidInputs() public {
        vm.expectRevert(LuciRoyaltyModel.ZeroAddress.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(0), 18, 1 hours);

        vm.expectRevert(LuciRoyaltyModel.InvalidMaxAge.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 18, 0);

        vm.expectRevert(LuciRoyaltyModel.InvalidCurrencyDecimals.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 19, 1 hours);

        MockAggregatorV3 wideFeed = new MockAggregatorV3(19, 1e8);
        vm.expectRevert(LuciRoyaltyModel.InvalidCurrencyDecimals.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(wideFeed), 18, 1 hours);
    }

    function test_removeCurrencyClearsConfigAndEmits() public {
        vm.expectEmit(true, false, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.CurrencyRemoved(NATIVE);

        vm.prank(owner);
        royaltyModel.removeCurrency(NATIVE);

        (bool allowed,,, address oracle) = royaltyModel.currencies(NATIVE);
        assertFalse(allowed);
        assertEq(oracle, address(0));
    }

    function test_calculateRoyaltyHandlesNonStandardDecimals() public {
        // a 6-decimal currency with an 18-decimal feed priced at $1
        address currency = makeAddr("sixDecimalCurrency");
        MockAggregatorV3 feed = new MockAggregatorV3(18, 1e18);

        vm.prank(owner);
        royaltyModel.configureCurrency(currency, address(feed), 6, 1 hours);

        address collection = makeAddr("decimalsCollection");
        vm.prank(owner);
        royaltyModel.configureCollection(collection, 100e8); // $100 mint

        // 200 units = $200 = 2x mint -> full 10%
        (, uint256 royalty) = royaltyModel.calculateRoyalty(collection, TOKEN_ID, 200e6, currency);
        assertEq(royalty, 20e6);

        // 150 units = $150 -> 50% profit -> 5%
        (, uint256 slidingRoyalty) = royaltyModel.calculateRoyalty(collection, TOKEN_ID, 150e6, currency);
        assertEq(slidingRoyalty, 7.5e6);
    }

    /////////////////////////////////////////////////////////////////////
    // ORACLE FALLBACK
    /////////////////////////////////////////////////////////////////////

    function _assertMaxRoyaltyFallback() internal view {
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, NATIVE);
        // without the fallback this sale sits exactly at the mint price and would pay 0
        assertEq(royalty, Math.mulDiv(MINT_PRICE, 1_000, 10_000));
    }

    function test_fallsBackToMaxRoyaltyForUnregisteredCurrency() public {
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, makeAddr("unknown"));
        assertEq(royalty, Math.mulDiv(MINT_PRICE, 1_000, 10_000));
    }

    function test_fallsBackToMaxRoyaltyForRemovedCurrency() public {
        vm.prank(owner);
        royaltyModel.removeCurrency(NATIVE);

        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyForNonPositiveAnswer() public {
        ethUsdFeed.setAnswer(0);
        _assertMaxRoyaltyFallback();

        ethUsdFeed.setAnswer(-1);
        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyForStaleAnswer() public {
        vm.warp(block.timestamp + FEED_MAX_AGE + 1);
        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyForZeroOrFutureUpdatedAt() public {
        ethUsdFeed.setUpdatedAt(0);
        _assertMaxRoyaltyFallback();

        ethUsdFeed.setUpdatedAt(block.timestamp + 1);
        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyWhenOracleReverts() public {
        ethUsdFeed.setShouldRevert(true);
        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyWhenAnswerWouldOverflow() public {
        ethUsdFeed.setAnswer(type(int256).max);
        _assertMaxRoyaltyFallback();
    }

    function test_revertsWhenDecimalsRevert() public {
        ethUsdFeed.setShouldRevertDecimals(true);
        vm.expectRevert(MockAggregatorV3.MockAggregatorRevert.selector);
        royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, NATIVE);
    }

    function test_fallsBackToMaxRoyaltyWhenLiveDecimalsExceedMax() public {
        ethUsdFeed.setDecimals(19);
        _assertMaxRoyaltyFallback();
    }

    function test_calculateRoyaltyUsesLiveOracleDecimals() public {
        uint256 salePrice = MINT_PRICE * 2; // $20,000 at 8-dec $2,000/ETH -> 10%
        (, uint256 atEightDecimals) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(atEightDecimals, 1 ether);

        // same answer, 18-dec scale: conversion understates USD and the sale looks below mint
        ethUsdFeed.setDecimals(18);
        (, uint256 atEighteenDecimals) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(atEighteenDecimals, 0);
    }

    /////////////////////////////////////////////////////////////////////
    // FUZZ
    /////////////////////////////////////////////////////////////////////

    function testFuzz_calculateRoyaltyInvariants(uint192 mintPriceUsd, uint256 salePrice, int256 ethUsdPrice) public {
        mintPriceUsd = uint192(bound(mintPriceUsd, 1, uint192(type(uint96).max)));
        salePrice = bound(salePrice, 0, 1_000_000 ether);
        ethUsdPrice = int256(bound(ethUsdPrice, 1e8, 1_000_000e8));

        ethUsdFeed.setAnswer(ethUsdPrice);

        address collection = makeAddr("fuzzCollection");
        vm.prank(owner);
        royaltyModel.configureCollection(collection, mintPriceUsd);

        uint256 saleUsd = _toUsd(salePrice);
        (, uint256 royalty) = royaltyModel.calculateRoyalty(collection, TOKEN_ID, salePrice, NATIVE);

        assertLe(royalty, Math.mulDiv(salePrice, 1_000, 10_000)); // always less than or equal to 10% of sale price
        if (saleUsd <= mintPriceUsd) {
            assertEq(royalty, 0);
        }
        if (saleUsd >= uint256(mintPriceUsd) * 2) {
            assertEq(royalty, Math.mulDiv(salePrice, 1_000, 10_000));
        }
    }
}
