// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std-1.14.0/Test.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";
import {LuciMarket} from "../src/LuciMarket.sol";
import {LuciRoyaltyModel} from "../src/LuciRoyaltyModel.sol";
import {MockAggregatorV3, MockERC721, MockSanctionsList} from "./mocks/MarketplaceMocks.sol";

abstract contract LuciTestBase is Test {
    address internal owner = makeAddr("owner");
    address internal royaltyRecipient = makeAddr("royaltyRecipient");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal bidder = makeAddr("bidder");
    address internal other = makeAddr("other");

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant TOKEN_ID_TWO = 2;
    uint256 internal constant PRICE = 10 ether;

    /// @dev ETH/USD feed setup: $2,000 per ETH at 8 decimals
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant ETH_USD_PRICE = 2_000e8;
    uint32 internal constant FEED_MAX_AGE = 1 hours;

    /// @dev 5 ETH at $2,000/ETH = $10,000, stored with 8 decimals
    uint256 internal constant MINT_PRICE = 5 ether;
    uint192 internal constant MINT_PRICE_USD = 10_000e8;

    LuciRoyaltyModel internal royaltyModel;
    LuciMarket internal market;
    MockERC721 internal nft;
    MockSanctionsList internal sanctions;
    MockAggregatorV3 internal ethUsdFeed;

    function setUp() public virtual {
        ethUsdFeed = new MockAggregatorV3(FEED_DECIMALS, ETH_USD_PRICE);
        royaltyModel = new LuciRoyaltyModel(owner, royaltyRecipient);
        market = new LuciMarket(owner, address(royaltyModel), address(0));
        nft = new MockERC721();
        sanctions = new MockSanctionsList();

        vm.prank(owner);
        market.addCollection(address(nft));

        vm.prank(owner);
        royaltyModel.configureCurrency(address(0), address(ethUsdFeed), 18, FEED_MAX_AGE);

        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD);

        nft.mint(seller, TOKEN_ID);
        nft.mint(seller, TOKEN_ID_TWO);

        vm.deal(buyer, 100 ether);
        vm.deal(bidder, 100 ether);
        vm.deal(other, 100 ether);

        vm.startPrank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.stopPrank();
    }

    function _expires(uint256 secondsFromNow) internal view returns (uint64) {
        return uint64(block.timestamp + secondsFromNow);
    }

    function _expiredAt() internal returns (uint64) {
        if (block.timestamp <= 1) vm.warp(2);
        return uint64(block.timestamp - 1);
    }

    function _list(uint256 tokenId, uint256 price, address privateBuyer) internal {
        vm.prank(seller);
        market.list(address(nft), tokenId, price, _expires(1 days), privateBuyer);
    }

    function _placeTokenBid(uint256 tokenId, uint256 amount) internal {
        vm.prank(bidder);
        market.placeBid{value: amount}(_tokenBid(tokenId), _expires(1 days));
    }

    function _placeCollectionBid(uint256 amount) internal {
        vm.prank(bidder);
        market.placeBid{value: amount}(_collectionBid(0), _expires(1 days));
    }

    function _placeTraitBid(uint256 traitKey, uint256 amount) internal {
        vm.prank(bidder);
        market.placeBid{value: amount}(_traitBid(0, traitKey), _expires(1 days));
    }

    function _tokenBid(uint256 tokenId) internal view returns (LuciMarket.BidSelector memory) {
        return LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: tokenId, traitKey: 0
        });
    }

    function _collectionBid(uint256 tokenId) internal view returns (LuciMarket.BidSelector memory) {
        return LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: tokenId, traitKey: 0
        });
    }

    function _traitBid(uint256 tokenId, uint256 traitKey) internal view returns (LuciMarket.BidSelector memory) {
        return LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TRAIT, collection: address(nft), tokenId: tokenId, traitKey: traitKey
        });
    }

    function _setSanctionsList() internal {
        vm.prank(owner);
        market.setSanctionsList(address(sanctions));
    }

    function _traitConfig(uint8 slot) internal pure returns (uint32) {
        return uint32(uint32(0x80) << (slot * 8));
    }

    function _trait(uint8 slot, uint8 value) internal pure returns (uint32) {
        return uint32(uint32(0x80 | value) << (slot * 8));
    }

    function _traitKey(uint8 slot, uint8 value) internal pure returns (uint256) {
        return uint256(1) << (uint256(slot) * 64 + value);
    }

    function _expectOwnableUnauthorized(address account) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
    }

    function _expectRevert(bytes4 selector) internal {
        vm.expectRevert(selector);
    }

    /// @dev Reprices the ETH/USD feed and refreshes its `updatedAt`
    function _setEthUsdPrice(int256 price) internal {
        ethUsdFeed.setAnswer(price);
    }

    /// @dev Converts an ETH amount into USD with 8 decimals at the feed's current answer
    function _toUsd(uint256 ethAmount) internal view returns (uint256) {
        return Math.mulDiv(ethAmount, uint256(ethUsdFeed.answer()) * 1e8, 1e18 * 10 ** FEED_DECIMALS);
    }
}
