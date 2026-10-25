// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LuciMarket} from "../src/LuciMarket.sol";
import {LuciRoyaltyModel} from "../src/LuciRoyaltyModel.sol";
import {LuciTestBase} from "./LuciTestBase.sol";
import {MockERC721, RejectEthActor, ReenteringBuyer} from "./mocks/MarketplaceMocks.sol";

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

    function test_buyCappedCollectionPaysCappedRoyalty() public {
        // 10 ETH = $20,000 vs a $10,000 mint -> top of the scale, capped at 5%
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), MINT_PRICE_USD, 500);
        _list(TOKEN_ID, PRICE, address(0));
        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Sold(address(nft), TOKEN_ID, buyer, seller, PRICE, 0.5 ether);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(seller.balance, sellerBefore + 9.5 ether);
        assertEq(royaltyRecipient.balance, recipientBefore + 0.5 ether);
        assertEq(address(market).balance, 0);
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

    function test_buyUsesLiveRoyaltyAmountAfterConfigurationChanges() public {
        _list(TOKEN_ID, PRICE, address(0));
        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        // raising the mint price to the sale price after listing drops the royalty to zero at settlement
        uint192 newMintPriceUsd = uint192(_toUsd(PRICE));
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), newMintPriceUsd, MAX_ROYALTY_BPS);

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(seller.balance, sellerBefore + PRICE);
        assertEq(royaltyRecipient.balance, recipientBefore);
    }

    function test_buyUsesCurrentRoyaltyRecipientWithLiveAmount() public {
        _list(TOKEN_ID, PRICE, address(0));
        address newRecipient = makeAddr("newRecipient");

        vm.prank(owner);
        royaltyModel.setRoyaltyRecipient(newRecipient);

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(newRecipient.balance, 1 ether);
        assertEq(royaltyRecipient.balance, 0);
    }

    /// @dev The replacement model has no collection or currency configured, so it falls back to the max royalty
    function test_buyUsesReplacementModelRecipientWithLiveAmount() public {
        _list(TOKEN_ID, PRICE, address(0));
        address newRecipient = makeAddr("replacementRecipient");
        LuciRoyaltyModel replacementModel = new LuciRoyaltyModel(owner, newRecipient);

        vm.prank(owner);
        market.setRoyaltyModel(address(replacementModel));

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(newRecipient.balance, 1 ether);
    }

    function test_buyRevertsWhenPositiveRoyaltyRecipientIsSanctioned() public {
        _list(TOKEN_ID, PRICE, address(0));
        _setSanctionsList();
        sanctions.setSanctioned(royaltyRecipient, true);

        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        assertEq(seller.balance, sellerBefore);
        assertEq(royaltyRecipient.balance, recipientBefore);
        assertEq(address(market).balance, 0);

        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, seller);
    }

    function test_buyAllowsSanctionedRoyaltyRecipientWhenRoyaltyIsZero() public {
        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), uint192(PRICE), MAX_ROYALTY_BPS);
        _list(TOKEN_ID, PRICE, address(0));
        _setSanctionsList();
        sanctions.setSanctioned(royaltyRecipient, true);

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(royaltyRecipient.balance, 0);
    }

    function test_acceptBidCalculatesRoyaltyAtAcceptance() public {
        _placeTokenBid(TOKEN_ID, PRICE);
        uint256 sellerBefore = seller.balance;

        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), uint192(PRICE), MAX_ROYALTY_BPS);

        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, PRICE, _noProof());

        assertEq(seller.balance, sellerBefore + PRICE);
        assertEq(royaltyRecipient.balance, 0);
    }

    function test_acceptTokenBidTransfersNftClearsBidAndClearsListing() public {
        _list(TOKEN_ID, PRICE + 1 ether, address(0));
        _placeTokenBid(TOKEN_ID, PRICE);
        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Delisted(address(nft), TOKEN_ID, seller);
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(LuciMarket.BidType.TOKEN, address(nft), bidder, TOKEN_ID, 0, seller, PRICE, 1 ether);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, PRICE, _noProof());

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(seller.balance, sellerBefore + 9 ether);
        assertEq(royaltyRecipient.balance, recipientBefore + 1 ether);
        assertEq(address(market).balance, 0);

        (uint192 bidAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(bidAmount, 0);
        assertEq(listingSeller, address(0));
    }

    function test_acceptBidRevertsWhenPositiveRoyaltyRecipientIsSanctioned() public {
        _placeTokenBid(TOKEN_ID, PRICE);
        _setSanctionsList();
        sanctions.setSanctioned(royaltyRecipient, true);

        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, PRICE, _noProof());

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        assertEq(seller.balance, sellerBefore);
        assertEq(royaltyRecipient.balance, recipientBefore);
        assertEq(address(market).balance, PRICE);

        (uint192 bidAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        assertEq(bidAmount, PRICE);
    }

    function test_acceptCollectionBidTransfersNftAndDeletesBid() public {
        _placeCollectionBid(PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(
            LuciMarket.BidType.COLLECTION, address(nft), bidder, TOKEN_ID, 0, seller, PRICE, 1 ether
        );
        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID), bidder, PRICE, _noProof());

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        (uint192 bidAmount,) = market.collectionBids(bidder, address(nft));
        assertEq(bidAmount, 0);
        assertEq(address(market).balance, 0);
    }

    function test_acceptSelectionBidTransfersNftClearsBidAndClearsListing() public {
        _list(TOKEN_ID, PRICE + 1 ether, address(0));
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, PRICE);
        uint256 sellerBefore = seller.balance;
        uint256 recipientBefore = royaltyRecipient.balance;

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Delisted(address(nft), TOKEN_ID, seller);
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(
            LuciMarket.BidType.SELECTION, address(nft), bidder, TOKEN_ID, selectionRoot, seller, PRICE, 1 ether
        );
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, PRICE, _merkleProof(tokens, 0));

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(seller.balance, sellerBefore + 9 ether);
        assertEq(royaltyRecipient.balance, recipientBefore + 1 ether);
        assertEq(address(market).balance, 0);

        (uint192 bidAmount,) = market.selectionBids(bidder, selectionRoot);
        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(bidAmount, 0);
        assertEq(listingSeller, address(0));
    }

    function test_cancelBidsRefundsMultipleEscrowsInOneCall() public {
        uint256 bidderBefore = bidder.balance;

        _placeTokenBid(TOKEN_ID, 1 ether);
        _placeCollectionBid(2 ether);
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID));
        _placeSelectionBid(selectionRoot, 3 ether);
        assertEq(address(market).balance, 6 ether);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](3);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, selectionRoot: bytes32(0)
        });
        selectors[1] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, selectionRoot: bytes32(0)
        });
        selectors[2] = _selectionBid(selectionRoot, address(0), 0);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidCanceled(LuciMarket.BidType.SELECTION, address(0), bidder, 0, selectionRoot);
        vm.prank(bidder);
        market.cancelBids(selectors);

        assertEq(bidder.balance, bidderBefore);
        assertEq(address(market).balance, 0);
    }

    function test_cancelExpiredBidsRefundsEscrow() public {
        uint256 bidderBefore = bidder.balance;
        uint64 initialExpiry = _expires(1);
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID));

        vm.startPrank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), initialExpiry);
        market.placeBid{value: 2 ether}(_collectionBid(0), initialExpiry);
        market.placeBid{value: 3 ether}(_selectionBid(selectionRoot, address(0), 0), initialExpiry);
        vm.stopPrank();

        assertEq(bidder.balance, bidderBefore - 6 ether);
        assertEq(address(market).balance, 6 ether);

        vm.warp(initialExpiry + 1);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](3);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, selectionRoot: bytes32(0)
        });
        selectors[1] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, selectionRoot: bytes32(0)
        });
        selectors[2] = _selectionBid(selectionRoot, address(0), 0);

        vm.prank(bidder);
        market.cancelBids(selectors);

        assertEq(bidder.balance, bidderBefore);
        assertEq(address(market).balance, 0);

        (uint192 tokenAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (uint192 collectionAmount,) = market.collectionBids(bidder, address(nft));
        (uint192 selectionAmount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(tokenAmount, 0);
        assertEq(collectionAmount, 0);
        assertEq(selectionAmount, 0);
    }

    function test_staleListingBecomesFillableAgainWhenSellerReacquiresToken() public {
        _list(TOKEN_ID, PRICE, address(0));

        vm.prank(seller);
        nft.transferFrom(seller, other, TOKEN_ID);

        vm.expectRevert();
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
        market.acceptBid(_collectionBid(TOKEN_ID_TWO), bidder, PRICE, _noProof());

        vm.prank(owner);
        market.addCollection(address(nft));

        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID_TWO), bidder, PRICE, _noProof());

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
    }

    function test_zeroExpiryBidsRemainFillableAfterLongTime() public {
        uint256 selectionTokenId = 3;
        nft.mint(seller, selectionTokenId);
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), selectionTokenId));

        vm.startPrank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), 0);
        market.placeBid{value: 2 ether}(_collectionBid(0), 0);
        market.placeBid{value: 3 ether}(_selectionBid(selectionRoot, address(0), 0), 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(bidder);
        market.increaseBid{value: 0.1 ether}(_tokenBid(TOKEN_ID));
        market.increaseBid{value: 0.1 ether}(_collectionBid(0));
        market.increaseBid{value: 0.1 ether}(_selectionBid(selectionRoot, address(0), 0));
        vm.stopPrank();

        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 1.1 ether, _noProof());

        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID_TWO), bidder, 2.1 ether, _noProof());

        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), selectionTokenId), bidder, 3.1 ether, _noProof());

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
        assertEq(nft.ownerOf(selectionTokenId), bidder);
    }

    function test_bidderCanCancelAndRebidSameKeysWithDifferentAmounts() public {
        uint256 bidderBefore = bidder.balance;
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID));

        vm.startPrank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), _expires(1 days));
        market.placeBid{value: 2 ether}(_collectionBid(0), _expires(1 days));
        market.placeBid{value: 3 ether}(_selectionBid(selectionRoot, address(0), 0), _expires(1 days));
        vm.stopPrank();

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](3);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, selectionRoot: bytes32(0)
        });
        selectors[1] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, selectionRoot: bytes32(0)
        });
        selectors[2] = _selectionBid(selectionRoot, address(0), 0);

        vm.prank(bidder);
        market.cancelBids(selectors);

        assertEq(bidder.balance, bidderBefore);
        assertEq(address(market).balance, 0);

        vm.startPrank(bidder);
        market.placeBid{value: 1.5 ether}(_tokenBid(TOKEN_ID), _expires(2 days));
        market.placeBid{value: 2.5 ether}(_collectionBid(0), _expires(2 days));
        market.placeBid{value: 3.5 ether}(_selectionBid(selectionRoot, address(0), 0), _expires(2 days));
        vm.stopPrank();

        (uint192 tokenAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (uint192 collectionAmount,) = market.collectionBids(bidder, address(nft));
        (uint192 selectionAmount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(tokenAmount, 1.5 ether);
        assertEq(collectionAmount, 2.5 ether);
        assertEq(selectionAmount, 3.5 ether);
        assertEq(address(market).balance, 7.5 ether);
    }

    function test_selectionBidBecomesFillableAgainAfterTokenIsReallowed() public {
        MockERC721 shared = new MockERC721();
        shared.mint(seller, TOKEN_ID);
        vm.prank(seller);
        shared.setApprovalForAll(address(market), true);
        vm.prank(owner);
        market.addToken(address(shared), TOKEN_ID);

        bytes32 selectionRoot = _merkleRoot(_tokens(address(shared), TOKEN_ID));
        _placeSelectionBid(selectionRoot, PRICE);

        vm.prank(owner);
        market.removeToken(address(shared), TOKEN_ID);

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(shared), TOKEN_ID), bidder, PRICE, _noProof());

        // extension is not gated by the allowlist for selection bids; fulfillment is
        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = _selectionBid(selectionRoot, address(0), 0);
        vm.prank(bidder);
        market.extendBids(selectors, _expires(2 days));

        vm.prank(owner);
        market.addToken(address(shared), TOKEN_ID);

        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(shared), TOKEN_ID), bidder, PRICE, _noProof());

        assertEq(shared.ownerOf(TOKEN_ID), bidder);
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

    function test_transferFromDoesNotCallReceiverCallback() public {
        ReenteringBuyer reenteringBuyer = new ReenteringBuyer();
        vm.deal(address(reenteringBuyer), PRICE);
        _list(TOKEN_ID, PRICE, address(reenteringBuyer));
        reenteringBuyer.setReentry(market, address(nft), TOKEN_ID);

        reenteringBuyer.buy{value: PRICE}(address(nft), TOKEN_ID);

        assertFalse(reenteringBuyer.attempted());
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

        market.placeBid{value: amount}(
            LuciMarket.BidSelector({
                bidType: LuciMarket.BidType.TOKEN, collection: collection, tokenId: tokenId, selectionRoot: bytes32(0)
            }),
            expiresAt
        );
        activeAmount = uint192(amount);
    }

    function increase(uint96 amount) external {
        if (activeAmount == 0) return;
        amount = uint96(_bound(amount, 1, 100 ether));
        if (amount > address(this).balance) return;

        (, uint64 expiresAt) = market.tokenBids(address(this), collection, tokenId);
        if (expiresAt != 0 && block.timestamp > expiresAt) return;

        market.increaseBid{value: amount}(
            LuciMarket.BidSelector({
                bidType: LuciMarket.BidType.TOKEN, collection: collection, tokenId: tokenId, selectionRoot: bytes32(0)
            })
        );
        activeAmount += uint192(amount);
    }

    function extend(uint64 expiresAt) external {
        if (activeAmount == 0) return;
        expiresAt = expiresAt == 0 ? 0 : uint64(_bound(expiresAt, block.timestamp, block.timestamp + 180 days));

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: collection, tokenId: tokenId, selectionRoot: bytes32(0)
        });
        market.extendBids(selectors, expiresAt);
    }

    function cancel() external {
        if (activeAmount == 0) return;

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: collection, tokenId: tokenId, selectionRoot: bytes32(0)
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
