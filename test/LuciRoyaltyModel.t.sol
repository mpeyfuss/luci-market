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

    function test_maxRoyaltyBpsMirrorMatchesModel() public view {
        assertEq(MAX_ROYALTY_BPS, royaltyModel.MAX_ROYALTY_BPS());
    }

    function test_configureCollectionStoresMintPriceAndCapAndEmits() public {
        address collection = makeAddr("collection");

        vm.expectEmit(true, true, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.CollectionConfigured(collection, 2_000e8, 500);

        vm.prank(owner);
        royaltyModel.configureCollection(collection, 2_000e8, 500);

        (bool configured, uint16 maxRoyaltyBps, uint192 mintPriceUsd) = royaltyModel.collections(collection);
        assertTrue(configured);
        assertEq(maxRoyaltyBps, 500);
        assertEq(mintPriceUsd, 2_000e8);
    }

    function test_onlyOwnerCanConfigureCollection() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.configureCollection(address(nft), 2_000e8, MAX_ROYALTY_BPS);
    }

    function testFuzz_configureCollectionRevertsForCapAboveMax(uint16 maxRoyaltyBps) public {
        maxRoyaltyBps = uint16(bound(maxRoyaltyBps, MAX_ROYALTY_BPS + 1, type(uint16).max));

        vm.expectRevert(LuciRoyaltyModel.InvalidRoyaltyBps.selector);
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), 2_000e8, maxRoyaltyBps);
    }

    function test_overrideTokenTakesPrecedenceAndEmits() public {
        // $16,000 mint price = 8 ETH at $2,000/ETH
        uint192 overrideUsd = 16_000e8;

        vm.expectEmit(true, true, true, true, address(royaltyModel));
        emit LuciRoyaltyModel.TokenOverriden(address(nft), TOKEN_ID, overrideUsd, MAX_ROYALTY_BPS);

        vm.prank(owner);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, overrideUsd, MAX_ROYALTY_BPS);

        (bool enabled, uint16 maxRoyaltyBps, uint192 mintPriceUsd) = royaltyModel.tokenOverrides(address(nft), TOKEN_ID);
        assertTrue(enabled);
        assertEq(maxRoyaltyBps, MAX_ROYALTY_BPS);
        assertEq(mintPriceUsd, overrideUsd);

        // 12 ETH sale = $24,000 -> 50% profit over $16,000 -> 5% of 12 ETH
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, 12 ether, NATIVE);
        assertEq(royalty, 0.6 ether);
    }

    function test_onlyOwnerCanOverrideToken() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, 1_000e8, MAX_ROYALTY_BPS);
    }

    function testFuzz_overrideTokenRevertsForCapAboveMax(uint16 maxRoyaltyBps) public {
        maxRoyaltyBps = uint16(bound(maxRoyaltyBps, MAX_ROYALTY_BPS + 1, type(uint16).max));

        vm.expectRevert(LuciRoyaltyModel.InvalidRoyaltyBps.selector);
        vm.prank(owner);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, 1_000e8, maxRoyaltyBps);
    }

    function test_clearTokenOverrideRestoresCollectionMintAndEmits() public {
        uint192 overrideUsd = 16_000e8;
        vm.prank(owner);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, overrideUsd, 500);

        vm.expectEmit(true, true, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.TokenOverrideCleared(address(nft), TOKEN_ID);

        vm.prank(owner);
        royaltyModel.clearTokenOverride(address(nft), TOKEN_ID);

        (bool enabled, uint16 maxRoyaltyBps, uint192 mintPriceUsd) = royaltyModel.tokenOverrides(address(nft), TOKEN_ID);
        assertFalse(enabled);
        assertEq(maxRoyaltyBps, 0);
        assertEq(mintPriceUsd, 0);

        // 12 ETH = $24,000 vs the collection $10,000 mint -> >= 2x -> 10%
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, 12 ether, NATIVE);
        assertEq(royalty, 1.2 ether);
    }

    function test_onlyOwnerCanClearTokenOverride() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.clearTokenOverride(address(nft), TOKEN_ID);
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
        uint256 salePrice = 7.5 ether; // $15,000 against a $10,000 mint -> 50% profit
        uint256 expected =
            Math.mulDiv(salePrice, (_toUsd(salePrice) - MINT_PRICE_USD) * 1_000, uint256(MINT_PRICE_USD) * 10_000);

        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);

        assertEq(royalty, expected);
        assertEq(royalty, 0.375 ether); // 5% of 7.5 ETH = 0.375 ETH
    }

    function test_calculateRoyaltySlidingScaleHasNoBpsDeadZone() public view {
        // 5 ETH + 5e6 wei is $10,000.00000001 against a $10,000 mint: two-step bps truncated to 0
        uint256 salePrice = MINT_PRICE + 5e6;
        uint256 saleUsd = _toUsd(salePrice);
        assertEq(saleUsd, uint256(MINT_PRICE_USD) + 1);

        uint256 expected = Math.mulDiv(salePrice, 1 * 1_000, uint256(MINT_PRICE_USD) * 10_000);
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);

        assertGt(expected, 0);
        assertEq(royalty, expected);
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
    // ROYALTY CAP
    /////////////////////////////////////////////////////////////////////

    function test_cappedCollectionSlidesUpToItsCap() public {
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, 500); // 5% cap

        (, uint256 atMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, NATIVE);
        (, uint256 halfway) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, 7.5 ether, NATIVE);
        (, uint256 atDoubleMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 2, NATIVE);
        (, uint256 aboveDoubleMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 3, NATIVE);

        assertEq(atMint, 0);
        assertEq(halfway, 0.1875 ether); // 50% profit -> half of the 5% cap -> 2.5% of 7.5 ETH
        assertEq(atDoubleMint, 0.5 ether); // 5% of 10 ETH
        assertEq(aboveDoubleMint, 0.75 ether); // 5% of 15 ETH
    }

    function test_cappedCollectionWithZeroMintPricePaysCap() public {
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), 0, 500);

        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, 1 ether, NATIVE);
        assertEq(royalty, 0.05 ether);
    }

    function test_cappedCollectionFallsBackToCapWhenConversionFails() public {
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, 500);

        vm.warp(block.timestamp + FEED_MAX_AGE + 1);
        (, uint256 staleRoyalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, NATIVE);
        assertEq(staleRoyalty, Math.mulDiv(MINT_PRICE, 500, 10_000));

        (, uint256 unknownRoyalty) =
            royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE, makeAddr("unknown"));
        assertEq(unknownRoyalty, Math.mulDiv(MINT_PRICE, 500, 10_000));
    }

    function test_zeroCapIsRoyaltyFreeWithoutConsultingFeed() public {
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, 0);

        // a reverting feed would otherwise fall back to the cap; a zero cap never reaches the feed
        ethUsdFeed.setShouldRevert(true);
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 3, NATIVE);
        assertEq(royalty, 0);

        (, uint256 unknownRoyalty) =
            royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 3, makeAddr("unknown"));
        assertEq(unknownRoyalty, 0);
    }

    function test_tokenOverrideCapTakesPrecedenceOverCollectionCap() public {
        // lower override cap on a full-cap collection
        vm.prank(owner);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, MINT_PRICE_USD, 250);
        (, uint256 lowered) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 2, NATIVE);
        assertEq(lowered, 0.25 ether); // 2.5% of 10 ETH

        // higher override cap on a lower-cap collection
        vm.startPrank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, 250);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, MINT_PRICE_USD, MAX_ROYALTY_BPS);
        vm.stopPrank();
        (, uint256 raised) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 2, NATIVE);
        assertEq(raised, 1 ether); // 10% of 10 ETH

        // other tokens keep the collection cap
        (, uint256 otherToken) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID_TWO, MINT_PRICE * 2, NATIVE);
        assertEq(otherToken, 0.25 ether);
    }

    function test_tokenOverrideCapAppliesToUnconfiguredCollection() public {
        address shared = makeAddr("shared");
        vm.prank(owner);
        royaltyModel.overrideToken(shared, TOKEN_ID, MINT_PRICE_USD, 500);

        (, uint256 overridden) = royaltyModel.calculateRoyalty(shared, TOKEN_ID, MINT_PRICE * 2, NATIVE);
        assertEq(overridden, 0.5 ether); // 5% of 10 ETH

        // other tokens in the unconfigured contract pay the max royalty
        (, uint256 otherToken) = royaltyModel.calculateRoyalty(shared, TOKEN_ID_TWO, MINT_PRICE * 2, NATIVE);
        assertEq(otherToken, 1 ether);
    }

    function test_clearTokenOverrideRestoresCollectionCap() public {
        vm.startPrank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, 500);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, MINT_PRICE_USD, 0);
        royaltyModel.clearTokenOverride(address(nft), TOKEN_ID);
        vm.stopPrank();

        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 2, NATIVE);
        assertEq(royalty, 0.5 ether);
    }

    /////////////////////////////////////////////////////////////////////
    // CURRENCY REGISTRY
    /////////////////////////////////////////////////////////////////////

    function test_configureCurrencyStoresConfigAndEmits() public {
        address currency = makeAddr("currency");
        MockAggregatorV3 feed = new MockAggregatorV3(18, 1e18);

        vm.expectEmit(true, true, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.CurrencyConfigured(currency, address(feed), 6, 18, 2 hours);

        vm.prank(owner);
        royaltyModel.configureCurrency(currency, address(feed), 6, 18, 2 hours);

        (bool allowed, uint8 currencyDecimals, uint8 oracleDecimals, uint32 maxAge, address oracle) =
            royaltyModel.currencies(currency);
        assertTrue(allowed);
        assertEq(currencyDecimals, 6);
        assertEq(oracleDecimals, 18);
        assertEq(maxAge, 2 hours);
        assertEq(oracle, address(feed));
    }

    function test_onlyOwnerCanConfigureOrRemoveCurrency() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 18, FEED_DECIMALS, 1 hours);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.removeCurrency(NATIVE);
    }

    function test_configureCurrencyRevertsForInvalidInputs() public {
        vm.expectRevert(LuciRoyaltyModel.ZeroAddress.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(0), 18, FEED_DECIMALS, 1 hours);

        vm.expectRevert(LuciRoyaltyModel.InvalidMaxAge.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 18, FEED_DECIMALS, 0);

        vm.expectRevert(LuciRoyaltyModel.InvalidCurrencyDecimals.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 19, FEED_DECIMALS, 1 hours);

        vm.expectRevert(LuciRoyaltyModel.InvalidCurrencyDecimals.selector);
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 18, 19, 1 hours);
    }

    function test_removeCurrencyClearsConfigAndEmits() public {
        vm.expectEmit(true, false, false, true, address(royaltyModel));
        emit LuciRoyaltyModel.CurrencyRemoved(NATIVE);

        vm.prank(owner);
        royaltyModel.removeCurrency(NATIVE);

        (bool allowed,,,, address oracle) = royaltyModel.currencies(NATIVE);
        assertFalse(allowed);
        assertEq(oracle, address(0));
    }

    function test_calculateRoyaltyHandlesNonStandardDecimals() public {
        // a 6-decimal currency with an 18-decimal feed priced at $1
        address currency = makeAddr("sixDecimalCurrency");
        MockAggregatorV3 feed = new MockAggregatorV3(18, 1e18);

        vm.prank(owner);
        royaltyModel.configureCurrency(currency, address(feed), 6, 18, 1 hours);

        address collection = makeAddr("decimalsCollection");
        vm.prank(owner);
        royaltyModel.configureCollection(collection, 100e8, MAX_ROYALTY_BPS); // $100 mint

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

    function test_fallsBackToMaxRoyaltyWhenConversionWouldOverflow() public {
        // the largest answer that still passes the `_isUsableRound` bound
        ethUsdFeed.setAnswer(int256(type(uint256).max / 1e8));

        // converting a ~whole-supply sale at that answer would overflow uint256 without the guard
        uint256 salePrice = 120_000_000 ether;
        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(royalty, Math.mulDiv(salePrice, 1_000, 10_000));
    }

    function test_fallsBackToMaxRoyaltyWhenDecimalsRevert() public {
        ethUsdFeed.setShouldRevertDecimals(true);
        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyWhenLiveDecimalsExceedMax() public {
        ethUsdFeed.setDecimals(19);
        _assertMaxRoyaltyFallback();
    }

    function test_fallsBackToMaxRoyaltyWhenLiveOracleDecimalsDiffer() public {
        uint256 salePrice = MINT_PRICE * 2; // $20,000 at 8-dec $2,000/ETH -> 10%
        (, uint256 atEightDecimals) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(atEightDecimals, 1 ether);

        // same answer, live scale changed: fail closed to max royalty instead of under-charging
        ethUsdFeed.setDecimals(18);
        (, uint256 afterScaleChange) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice, NATIVE);
        assertEq(afterScaleChange, Math.mulDiv(salePrice, 1_000, 10_000));
    }

    function test_fallsBackToMaxRoyaltyWhenConfiguredDecimalsAreWrong() public {
        // nothing validates the declared decimals at configure time, but a wrong value fails closed at
        // conversion: the live decimals (8) differ from the stored value (9)
        vm.prank(owner);
        royaltyModel.configureCurrency(NATIVE, address(ethUsdFeed), 18, 9, FEED_MAX_AGE);
        _assertMaxRoyaltyFallback();
    }

    /////////////////////////////////////////////////////////////////////
    // FUZZ
    /////////////////////////////////////////////////////////////////////

    function testFuzz_calculateRoyaltyInvariants(
        uint192 mintPriceUsd,
        uint16 maxRoyaltyBps,
        uint256 salePrice,
        int256 ethUsdPrice
    ) public {
        mintPriceUsd = uint192(bound(mintPriceUsd, 1, uint192(type(uint96).max)));
        maxRoyaltyBps = uint16(bound(maxRoyaltyBps, 0, MAX_ROYALTY_BPS));
        salePrice = bound(salePrice, 0, 1_000_000 ether);
        ethUsdPrice = int256(bound(ethUsdPrice, 1e8, 1_000_000e8));

        ethUsdFeed.setAnswer(ethUsdPrice);

        address collection = makeAddr("fuzzCollection");
        vm.prank(owner);
        royaltyModel.configureCollection(collection, mintPriceUsd, maxRoyaltyBps);

        uint256 saleUsd = _toUsd(salePrice);
        (, uint256 royalty) = royaltyModel.calculateRoyalty(collection, TOKEN_ID, salePrice, NATIVE);

        assertLe(royalty, Math.mulDiv(salePrice, maxRoyaltyBps, 10_000)); // never above the cap
        if (saleUsd <= mintPriceUsd) {
            assertEq(royalty, 0);
        } else if (saleUsd >= uint256(mintPriceUsd) * 2) {
            assertEq(royalty, Math.mulDiv(salePrice, maxRoyaltyBps, 10_000));
        } else {
            assertEq(
                royalty,
                Math.mulDiv(salePrice, (saleUsd - mintPriceUsd) * maxRoyaltyBps, uint256(mintPriceUsd) * 10_000)
            );
        }
    }

    function testFuzz_cappedRoyaltyIsNonDecreasingInSalePrice(
        uint16 maxRoyaltyBps,
        uint256 lowerSalePrice,
        uint256 higherSalePrice
    ) public {
        maxRoyaltyBps = uint16(bound(maxRoyaltyBps, 0, MAX_ROYALTY_BPS));
        lowerSalePrice = bound(lowerSalePrice, 0, 1_000_000 ether);
        higherSalePrice = bound(higherSalePrice, lowerSalePrice, 1_000_000 ether);

        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, maxRoyaltyBps);

        (, uint256 lowerRoyalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, lowerSalePrice, NATIVE);
        (, uint256 higherRoyalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, higherSalePrice, NATIVE);

        assertLe(lowerRoyalty, higherRoyalty);
    }
}
