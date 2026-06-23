// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LuciMarket} from "../src/LuciMarket.sol";
import {LuciTestBase} from "./LuciTestBase.sol";
import {RejectEthActor, ReenteringBuyer} from "./mocks/MarketplaceMocks.sol";

contract LuciMarketIntegrationTest is LuciTestBase {
    function test_buyPublicListingTransfersNftClearsListingAndSplitsEth() public {
        _list(TOKEN_ID, PRICE, address(0));
        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Sold(address(nft), TOKEN_ID, buyer, seller, PRICE, 1 ether);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(seller.balance, sellerBefore + 9 ether);
        assertEq(royaltyRecipient.balance, recipientBefore + 1 ether);
        assertEq(address(market).balance, 0);

        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, address(0));
    }

    function test_buyPrivateListingOnlyDesignatedBuyerCanSettle() public {
        _list(TOKEN_ID, PRICE, buyer);

        vm.expectRevert(LuciMarket.NotPrivateBuyer.selector);
        vm.prank(other);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }

    function test_acceptTokenBidTransfersNftClearsBidAndClearsListing() public {
        _list(TOKEN_ID, PRICE + 1 ether, address(0));
        _placeTokenBid(TOKEN_ID, PRICE);
        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Delisted(address(nft), TOKEN_ID, seller);
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.TokenBidAccepted(address(nft), TOKEN_ID, seller, bidder, PRICE, 1 ether);
        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(seller.balance, sellerBefore + 9 ether);
        assertEq(royaltyRecipient.balance, recipientBefore + 1 ether);
        assertEq(address(market).balance, 0);

        (uint192 bidAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(bidAmount, 0);
        assertEq(listingSeller, address(0));
    }

    function test_acceptCollectionBidTransfersNftAndDeletesBid() public {
        _placeCollectionBid(PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.CollectionBidAccepted(address(nft), TOKEN_ID, seller, bidder, PRICE, 1 ether);
        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID, bidder, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        (uint192 bidAmount,) = market.collectionBids(bidder, address(nft));
        assertEq(bidAmount, 0);
        assertEq(address(market).balance, 0);
    }

    function test_acceptTraitBidTransfersNftAndDeletesBid() public {
        uint32 config = _traitConfig(0) | _traitConfig(1);
        uint32 tokenTraits = _trait(0, 5) | _trait(1, 7);
        uint256 traitKey = _traitKey(0, 5) | _traitKey(1, 7);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), config);

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = TOKEN_ID;
        traitsArray[0] = tokenTraits;
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        _placeTraitBid(traitKey, PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.TraitBidAccepted(address(nft), TOKEN_ID, seller, bidder, traitKey, PRICE, 1 ether);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        (uint192 bidAmount,) = market.traitBids(bidder, address(nft), traitKey);
        assertEq(bidAmount, 0);
        assertEq(address(market).balance, 0);
    }

    function test_cancelBidsRefundsMultipleEscrowsInOneCall() public {
        uint256 bidderBefore = bidder.balance;
        uint256 traitKey = _traitKey(0, 5);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        _placeTokenBid(TOKEN_ID, 1 ether);
        _placeCollectionBid(2 ether);
        _placeTraitBid(traitKey, 3 ether);
        assertEq(address(market).balance, 6 ether);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](3);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });
        selectors[1] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });
        selectors[2] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TRAIT, collection: address(nft), tokenId: 0, traitKey: traitKey
        });

        vm.prank(bidder);
        market.cancelBids(selectors);

        assertEq(bidder.balance, bidderBefore);
        assertEq(address(market).balance, 0);
    }

    function test_cancelExpiredBidsRefundsEscrow() public {
        uint256 bidderBefore = bidder.balance;
        uint256 traitKey = _traitKey(0, 5);
        uint64 initialExpiry = _expires(1);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.startPrank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, initialExpiry);
        market.placeCollectionBid{value: 2 ether}(address(nft), initialExpiry);
        market.placeTraitBid{value: 3 ether}(address(nft), traitKey, initialExpiry);
        vm.stopPrank();

        assertEq(bidder.balance, bidderBefore - 6 ether);
        assertEq(address(market).balance, 6 ether);

        vm.warp(initialExpiry + 1);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](3);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });
        selectors[1] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });
        selectors[2] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TRAIT, collection: address(nft), tokenId: 0, traitKey: traitKey
        });

        vm.prank(bidder);
        market.cancelBids(selectors);

        assertEq(bidder.balance, bidderBefore);
        assertEq(address(market).balance, 0);

        (uint192 tokenAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (uint192 collectionAmount,) = market.collectionBids(bidder, address(nft));
        (uint192 traitAmount,) = market.traitBids(bidder, address(nft), traitKey);
        assertEq(tokenAmount, 0);
        assertEq(collectionAmount, 0);
        assertEq(traitAmount, 0);
    }

    function test_staleListingBecomesFillableAgainWhenSellerReacquiresToken() public {
        _list(TOKEN_ID, PRICE, address(0));

        vm.prank(seller);
        nft.transferFrom(seller, other, TOKEN_ID);

        vm.expectRevert(LuciMarket.ListingOwnerNotTokenOwner.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.prank(other);
        nft.transferFrom(other, seller, TOKEN_ID);

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, address(0));
    }

    function test_listingCanBeUpdatedAfterBuyerOrPriceChanges() public {
        _list(TOKEN_ID, PRICE, other);

        vm.expectRevert(LuciMarket.NotPrivateBuyer.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        uint256 updatedPrice = PRICE - 1 ether;
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, updatedPrice, _expires(2 days), buyer);

        vm.expectRevert(LuciMarket.NotPrivateBuyer.selector);
        vm.prank(other);
        market.buy{value: updatedPrice}(address(nft), TOKEN_ID);

        vm.prank(buyer);
        market.buy{value: updatedPrice}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }

    function test_listingBlockedByRevokedApprovalCanBeFilledAfterReapproval() public {
        _list(TOKEN_ID, PRICE, address(0));

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert();
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }

    function test_ordersBecomeFillableAgainAfterCollectionIsReallowed() public {
        _list(TOKEN_ID, PRICE, address(0));
        _placeCollectionBid(PRICE);

        vm.prank(owner);
        market.removeCollection(address(nft));

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID_TWO, bidder, PRICE);

        vm.prank(owner);
        market.addCollection(address(nft));

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID_TWO, bidder, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
    }

    function test_zeroExpiryBidsRemainFillableAfterLongTime() public {
        uint256 traitTokenId = 3;
        uint256 traitKey = _traitKey(0, 5);

        nft.mint(seller, traitTokenId);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = traitTokenId;
        traitsArray[0] = _trait(0, 5);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        vm.startPrank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, 0);
        market.placeCollectionBid{value: 2 ether}(address(nft), 0);
        market.placeTraitBid{value: 3 ether}(address(nft), traitKey, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(bidder);
        market.increaseTokenBid{value: 0.1 ether}(address(nft), TOKEN_ID);
        market.increaseCollectionBid{value: 0.1 ether}(address(nft));
        market.increaseTraitBid{value: 0.1 ether}(address(nft), traitKey);
        vm.stopPrank();

        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 1.1 ether);

        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID_TWO, bidder, 2.1 ether);

        vm.prank(seller);
        market.acceptTraitBid(address(nft), traitTokenId, bidder, traitKey, 3.1 ether);

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
        assertEq(nft.ownerOf(traitTokenId), bidder);
    }

    function test_bidderCanCancelAndRebidSameKeysWithDifferentAmounts() public {
        uint256 traitKey = _traitKey(0, 5);
        uint256 bidderBefore = bidder.balance;

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.startPrank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, _expires(1 days));
        market.placeCollectionBid{value: 2 ether}(address(nft), _expires(1 days));
        market.placeTraitBid{value: 3 ether}(address(nft), traitKey, _expires(1 days));
        vm.stopPrank();

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](3);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });
        selectors[1] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });
        selectors[2] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TRAIT, collection: address(nft), tokenId: 0, traitKey: traitKey
        });

        vm.prank(bidder);
        market.cancelBids(selectors);

        assertEq(bidder.balance, bidderBefore);
        assertEq(address(market).balance, 0);

        vm.startPrank(bidder);
        market.placeTokenBid{value: 1.5 ether}(address(nft), TOKEN_ID, _expires(2 days));
        market.placeCollectionBid{value: 2.5 ether}(address(nft), _expires(2 days));
        market.placeTraitBid{value: 3.5 ether}(address(nft), traitKey, _expires(2 days));
        vm.stopPrank();

        (uint192 tokenAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (uint192 collectionAmount,) = market.collectionBids(bidder, address(nft));
        (uint192 traitAmount,) = market.traitBids(bidder, address(nft), traitKey);
        assertEq(tokenAmount, 1.5 ether);
        assertEq(collectionAmount, 2.5 ether);
        assertEq(traitAmount, 3.5 ether);
        assertEq(address(market).balance, 7.5 ether);
    }

    function test_traitBidBecomesFillableAgainAfterTraitConfigIsRestored() public {
        uint256 traitKey = _traitKey(0, 5);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = TOKEN_ID;
        traitsArray[0] = _trait(0, 5);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        _placeTraitBid(traitKey, PRICE);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), 0);

        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, PRICE);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
    }

    function test_buyRevertsAndRestoresStateWhenSellerCannotReceiveEth() public {
        RejectEthActor rejectingSeller = new RejectEthActor();
        nft.mint(address(rejectingSeller), 99);

        rejectingSeller.approveAll(address(nft), address(market));
        rejectingSeller.list(market, address(nft), 99, PRICE, _expires(1 days), address(0));

        vm.expectRevert(LuciMarket.EthTransferFailed.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), 99);

        assertEq(nft.ownerOf(99), address(rejectingSeller));
        (address listingSeller,,,) = market.listings(address(nft), 99);
        assertEq(listingSeller, address(rejectingSeller));
    }

    function test_buyRevertsAndRestoresStateWhenRoyaltyRecipientCannotReceiveEth() public {
        RejectEthActor rejectingRecipient = new RejectEthActor();
        vm.prank(owner);
        royaltyModel.setRoyaltyRecipient(address(rejectingRecipient));
        _list(TOKEN_ID, PRICE, address(0));

        vm.expectRevert(LuciMarket.EthTransferFailed.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, seller);
    }

    function test_reentrancyDuringSafeTransferCallbackIsBlocked() public {
        ReenteringBuyer reenteringBuyer = new ReenteringBuyer();
        vm.deal(address(reenteringBuyer), PRICE);
        _list(TOKEN_ID, PRICE, address(reenteringBuyer));
        reenteringBuyer.setReentry(market, address(nft), TOKEN_ID);

        reenteringBuyer.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertTrue(reenteringBuyer.attempted());
        assertFalse(reenteringBuyer.reentered());
        assertEq(nft.ownerOf(TOKEN_ID), address(reenteringBuyer));
        assertEq(address(market).balance, 0);
    }
}

contract LuciMarketEscrowInvariantTest is LuciTestBase {
    TokenBidEscrowHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new TokenBidEscrowHandler(market, address(nft), TOKEN_ID);
        vm.deal(address(handler), 1_000 ether);
        targetContract(address(handler));
    }

    function invariant_marketBalanceEqualsHandlerActiveEscrow() public view {
        assertEq(address(market).balance, handler.activeAmount());
    }

    function invariant_tokenBidStorageMatchesHandlerAccounting() public view {
        (uint192 amount,) = market.tokenBids(address(handler), address(nft), TOKEN_ID);
        assertEq(amount, handler.activeAmount());
    }
}

contract TokenBidEscrowHandler {
    LuciMarket internal immutable market;
    address internal immutable collection;
    uint256 internal immutable tokenId;

    uint192 public activeAmount;

    constructor(LuciMarket market_, address collection_, uint256 tokenId_) {
        market = market_;
        collection = collection_;
        tokenId = tokenId_;
    }

    function place(uint96 amount, uint64 expiresAt) external {
        if (activeAmount != 0) return;
        amount = uint96(_bound(amount, 1, 100 ether));
        expiresAt = expiresAt == 0 ? 0 : uint64(_bound(expiresAt, block.timestamp, block.timestamp + 180 days));

        market.placeTokenBid{value: amount}(collection, tokenId, expiresAt);
        activeAmount = uint192(amount);
    }

    function increase(uint96 amount) external {
        if (activeAmount == 0) return;
        amount = uint96(_bound(amount, 1, 100 ether));

        market.increaseTokenBid{value: amount}(collection, tokenId);
        activeAmount += uint192(amount);
    }

    function extend(uint64 expiresAt) external {
        if (activeAmount == 0) return;
        expiresAt = expiresAt == 0 ? 0 : uint64(_bound(expiresAt, block.timestamp, block.timestamp + 180 days));

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: collection, tokenId: tokenId, traitKey: 0
        });
        market.extendBids(selectors, expiresAt);
    }

    function cancel() external {
        if (activeAmount == 0) return;

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: collection, tokenId: tokenId, traitKey: 0
        });
        market.cancelBids(selectors);
        activeAmount = 0;
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

    receive() external payable {}
}
