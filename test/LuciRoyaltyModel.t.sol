// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";
import {LuciRoyaltyModel} from "../src/LuciRoyaltyModel.sol";
import {LuciTestBase} from "./LuciTestBase.sol";

contract LuciRoyaltyModelTest is LuciTestBase {
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
        emit LuciRoyaltyModel.CollectionConfigured(collection, 2 ether);

        vm.prank(owner);
        royaltyModel.configureCollection(collection, 2 ether);

        (bool configured, uint192 mintPrice) = royaltyModel.collections(collection);
        assertTrue(configured);
        assertEq(mintPrice, 2 ether);
    }

    function test_onlyOwnerCanConfigureCollection() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.configureCollection(address(nft), 2 ether);
    }

    function test_overrideTokenTakesPrecedenceAndEmits() public {
        vm.expectEmit(true, true, true, true, address(royaltyModel));
        emit LuciRoyaltyModel.TokenOverriden(address(nft), TOKEN_ID, 8 ether);

        vm.prank(owner);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, 8 ether);

        (bool enabled, uint192 mintPrice) = royaltyModel.tokenOverrides(address(nft), TOKEN_ID);
        assertTrue(enabled);
        assertEq(mintPrice, 8 ether);

        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, 12 ether);
        assertEq(royalty, 0.6 ether);
    }

    function test_onlyOwnerCanOverrideToken() public {
        _expectOwnableUnauthorized(other);
        vm.prank(other);
        royaltyModel.overrideToken(address(nft), TOKEN_ID, 1 ether);
    }

    function test_calculateRoyaltyUsesExpectedThresholds() public view {
        (, uint256 belowMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE - 1);
        (, uint256 atMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE);
        (, uint256 atDoubleMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 2);
        (, uint256 aboveDoubleMint) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, MINT_PRICE * 3);

        assertEq(belowMint, 0);
        assertEq(atMint, 0);
        assertEq(atDoubleMint, 1 ether); // 10% of 10 ETH = 1 ETH
        assertEq(aboveDoubleMint, 1.5 ether); // 10% of 15 ETH = 1.5 ETH
    }

    function test_calculateRoyaltySlidingScale() public view {
        uint256 salePrice = 7.5 ether;
        uint256 expected = Math.mulDiv(salePrice, (salePrice - MINT_PRICE) * 1_000, MINT_PRICE * 10_000);

        (, uint256 royalty) = royaltyModel.calculateRoyalty(address(nft), TOKEN_ID, salePrice);

        assertEq(royalty, expected);
        assertEq(royalty, 0.375 ether); // 5% of 7.5 ETH = 0.375 ETH
    }

    function test_calculateRoyaltyForUnconfiguredCollectionDefaultsToMaxRoyalty() public {
        address unconfigured = makeAddr("unconfigured");

        (address recipient, uint256 zeroSaleRoyalty) = royaltyModel.calculateRoyalty(unconfigured, TOKEN_ID, 0);
        (, uint256 royalty) = royaltyModel.calculateRoyalty(unconfigured, TOKEN_ID, 1 ether);

        assertEq(recipient, royaltyRecipient);
        assertEq(zeroSaleRoyalty, 0);
        assertEq(royalty, 0.1 ether);
    }

    function testFuzz_calculateRoyaltyInvariants(uint192 mintPrice, uint256 salePrice) public {
        mintPrice = uint192(bound(mintPrice, 1, type(uint128).max));
        salePrice = bound(salePrice, 0, uint256(mintPrice) * 3);

        address collection = makeAddr("fuzzCollection");
        vm.prank(owner);
        royaltyModel.configureCollection(collection, mintPrice);

        (, uint256 royalty) = royaltyModel.calculateRoyalty(collection, TOKEN_ID, salePrice);

        assertLe(royalty, Math.mulDiv(salePrice, 1_000, 10_000)); // always less then or equal to 10% of sale price
        if (salePrice <= mintPrice) {
            assertEq(royalty, 0);
        }
        if (salePrice >= uint256(mintPrice) * 2) {
            assertEq(royalty, Math.mulDiv(salePrice, 1_000, 10_000));
        }
    }
}
