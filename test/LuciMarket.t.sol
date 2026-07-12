// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LuciMarket} from "../src/LuciMarket.sol";
import {LuciRoyaltyModel} from "../src/LuciRoyaltyModel.sol";
import {LuciTestBase} from "./LuciTestBase.sol";
import {MockERC721, MockRoyaltyModel} from "./mocks/MarketplaceMocks.sol";
import {IERC721Errors} from "@openzeppelin-contracts-5.6.1/interfaces/draft-IERC6093.sol";

contract LuciMarketTest is LuciTestBase {
    function test_constructorSetsOwnerRoyaltyModelAndSanctionsList() public view {
        assertEq(market.owner(), owner);
        assertEq(market.royaltyModel(), address(royaltyModel));
        assertEq(market.sanctionsList(), address(0));
    }

    function test_constructorRevertsForZeroRoyaltyModel() public {
        vm.expectRevert(LuciMarket.ZeroAddress.selector);
        new LuciMarket(owner, address(0), address(0));
    }

    function test_adminCanManageAllowlistsAndEmitEvents() public {
        address collection = makeAddr("collection");

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.addCollection(collection);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.removeCollection(collection);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.addToken(collection, 1);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.removeToken(collection, 1);

        vm.expectEmit(true, false, false, true, address(market));
        emit LuciMarket.CollectionAdded(collection);
        vm.prank(owner);
        market.addCollection(collection);
        assertTrue(market.allowedCollections(collection));

        vm.expectEmit(true, false, false, true, address(market));
        emit LuciMarket.CollectionRemoved(collection);
        vm.prank(owner);
        market.removeCollection(collection);
        assertFalse(market.allowedCollections(collection));

        vm.expectEmit(true, true, false, true, address(market));
        emit LuciMarket.TokenAdded(collection, TOKEN_ID);
        vm.prank(owner);
        market.addToken(collection, TOKEN_ID);
        assertTrue(market.allowedTokens(collection, TOKEN_ID));

        vm.expectEmit(true, true, false, true, address(market));
        emit LuciMarket.TokenRemoved(collection, TOKEN_ID);
        vm.prank(owner);
        market.removeToken(collection, TOKEN_ID);
        assertFalse(market.allowedTokens(collection, TOKEN_ID));
    }

    function test_adminCanPauseAndUpdateExternalContracts() public {
        LuciRoyaltyModel newRoyaltyModel = new LuciRoyaltyModel(owner, royaltyRecipient);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.setPaused(true);

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.setRoyaltyModel(address(newRoyaltyModel));

        _expectOwnableUnauthorized(other);
        vm.prank(other);
        market.setSanctionsList(address(sanctions));

        vm.expectEmit(false, false, false, true, address(market));
        emit LuciMarket.PauseToggled(true);
        vm.prank(owner);
        market.setPaused(true);
        assertTrue(market.paused());

        vm.expectEmit(true, true, false, true, address(market));
        emit LuciMarket.RoyaltyModelUpdated(address(royaltyModel), address(newRoyaltyModel));
        vm.prank(owner);
        market.setRoyaltyModel(address(newRoyaltyModel));
        assertEq(market.royaltyModel(), address(newRoyaltyModel));

        vm.expectEmit(true, true, false, true, address(market));
        emit LuciMarket.SanctionsListUpdated(address(0), address(sanctions));
        vm.prank(owner);
        market.setSanctionsList(address(sanctions));
        assertEq(market.sanctionsList(), address(sanctions));
    }

    function test_setRoyaltyModelRevertsForZeroAddress() public {
        vm.expectRevert(LuciMarket.ZeroAddress.selector);
        vm.prank(owner);
        market.setRoyaltyModel(address(0));
    }

    function test_listStoresListingAndEmits() public {
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Listed(address(nft), TOKEN_ID, seller, PRICE, expiresAt, address(0), 1 ether);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, expiresAt, address(0));

        (
            address listingSeller,
            uint64 listingExpiresAt,
            uint256 listingPrice,
            uint256 royaltyAmount,
            address listingBuyer
        ) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, seller);
        assertEq(listingExpiresAt, expiresAt);
        assertEq(listingPrice, PRICE);
        assertEq(listingBuyer, address(0));
        assertEq(royaltyAmount, 1 ether);
    }

    function test_listPrivateBuyerStoresListingAndEmits() public {
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Listed(address(nft), TOKEN_ID, seller, PRICE, expiresAt, owner, 1 ether);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, expiresAt, owner);

        (
            address listingSeller,
            uint64 listingExpiresAt,
            uint256 listingPrice,
            uint256 royaltyAmount,
            address listingBuyer
        ) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, seller);
        assertEq(listingExpiresAt, expiresAt);
        assertEq(listingPrice, PRICE);
        assertEq(listingBuyer, owner);
        assertEq(royaltyAmount, 1 ether);
    }

    function test_relistingRefreshesRoyaltyAmount() public {
        _list(TOKEN_ID, PRICE, address(0));

        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), uint192(PRICE));

        _list(TOKEN_ID, PRICE, address(0));

        (,,, uint256 royaltyAmount,) = market.listings(address(nft), TOKEN_ID);
        assertEq(royaltyAmount, 0);
    }

    function test_listRevertsWhenRoyaltyExceedsPrice() public {
        MockRoyaltyModel excessiveRoyaltyModel = new MockRoyaltyModel(royaltyRecipient, PRICE + 1);
        vm.prank(owner);
        market.setRoyaltyModel(address(excessiveRoyaltyModel));

        vm.expectRevert(LuciMarket.InvalidRoyaltyAmount.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, _expires(1 days), address(0));
    }

    function test_listRevertsForInvalidInputs() public {
        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, 0, _expires(1 days), address(0));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.InvalidListingExpiration.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, expiredAt, address(0));

        uint256 maxListingDuration = market.MAX_LISTING_DURATION();
        vm.expectRevert(LuciMarket.InvalidListingExpiration.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, _expires(maxListingDuration + 1), address(0));
    }

    function test_listRevertsWhenNotOwnerOrApprovedOrAllowed() public {
        vm.expectRevert(LuciMarket.NotTokenOwner.selector);
        vm.prank(other);
        market.list(address(nft), TOKEN_ID, PRICE, _expires(1 days), address(0));

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(LuciMarket.NotApproved.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, _expires(1 days), address(0));

        address disallowedCollection = makeAddr("disallowedCollection");
        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.list(disallowedCollection, TOKEN_ID, PRICE, _expires(1 days), address(0));
    }

    function test_extendListingsUpdatesMultipleListingsAndAllowsExpiredListings() public {
        _list(TOKEN_ID, PRICE, address(0));
        _list(TOKEN_ID_TWO, PRICE + 1 ether, buyer);
        vm.warp(block.timestamp + 2 days);

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](2);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        tokens[1] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID_TWO});
        uint64 newExpiry = _expires(1 days);

        vm.prank(owner);
        royaltyModel.configureCollection(address(nft), uint192(PRICE));

        vm.prank(seller);
        market.extendListings(tokens, newExpiry);

        (, uint64 firstExpiry,, uint256 firstRoyalty,) = market.listings(address(nft), TOKEN_ID);
        (, uint64 secondExpiry,, uint256 secondRoyalty,) = market.listings(address(nft), TOKEN_ID_TWO);
        assertEq(firstExpiry, newExpiry);
        assertEq(secondExpiry, newExpiry);
        assertEq(firstRoyalty, 1 ether);
        assertEq(secondRoyalty, 1.1 ether);
    }

    function test_extendListingsRevertsForEmptyArrayOrNonSeller() public {
        LuciMarket.Token[] memory empty = new LuciMarket.Token[](0);
        vm.expectRevert(LuciMarket.ZeroLengthArray.selector);
        vm.prank(seller);
        market.extendListings(empty, _expires(1 days));

        _list(TOKEN_ID, PRICE, address(0));
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});

        vm.expectRevert(LuciMarket.NotListingOwner.selector);
        vm.prank(other);
        market.extendListings(tokens, _expires(1 days));
    }

    function test_extendListingsRevertsForInvalidExpirations() public {
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.InvalidListingExpiration.selector);
        vm.prank(seller);
        market.extendListings(tokens, expiredAt);

        uint256 maxListingDuration = market.MAX_LISTING_DURATION();
        vm.expectRevert(LuciMarket.InvalidListingExpiration.selector);
        vm.prank(seller);
        market.extendListings(tokens, _expires(maxListingDuration + 1));
    }

    function test_delistDeletesListingWhilePaused() public {
        _list(TOKEN_ID, PRICE, address(0));
        vm.prank(owner);
        market.setPaused(true);

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Delisted(address(nft), TOKEN_ID, seller);
        vm.prank(seller);
        market.delist(tokens);

        (address listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, address(0));
    }

    function test_delistRevertsForEmptyArrayOrNonSeller() public {
        LuciMarket.Token[] memory empty = new LuciMarket.Token[](0);
        vm.expectRevert(LuciMarket.ZeroLengthArray.selector);
        vm.prank(seller);
        market.delist(empty);

        _list(TOKEN_ID, PRICE, address(0));
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});

        vm.expectRevert(LuciMarket.NotListingOwner.selector);
        vm.prank(other);
        market.delist(tokens);
    }

    function test_buyRevertsForPrivateBuyerExpiredStaleAndIncorrectPayment() public {
        vm.expectRevert(LuciMarket.NotListed.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        _list(TOKEN_ID, PRICE, buyer);

        vm.expectRevert(LuciMarket.NotPrivateBuyer.selector);
        vm.prank(other);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.expectRevert(LuciMarket.IncorrectPayment.selector);
        vm.prank(buyer);
        market.buy{value: PRICE - 1}(address(nft), TOKEN_ID);

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(LuciMarket.ListingExpired.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        _list(TOKEN_ID_TWO, PRICE, address(0));
        vm.prank(seller);
        nft.transferFrom(seller, other, TOKEN_ID_TWO);

        uint256 buyerBalanceBefore = buyer.balance;
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN_ID_TWO)
        );
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID_TWO);

        (address listingSeller,,,,) = market.listings(address(nft), TOKEN_ID_TWO);
        assertEq(listingSeller, seller);
        assertEq(buyer.balance, buyerBalanceBefore);
    }

    function test_pausedBlocksActiveOrderPathsButAllowsCancelAndDelist() public {
        _list(TOKEN_ID, PRICE, address(0));
        _placeTokenBid(TOKEN_ID, 1 ether);

        vm.prank(owner);
        market.setPaused(true);

        vm.expectRevert(LuciMarket.IsPaused.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID_TWO, PRICE, _expires(1 days), address(0));

        vm.expectRevert(LuciMarket.IsPaused.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });
        vm.prank(bidder);
        market.cancelBids(selectors);

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        vm.prank(seller);
        market.delist(tokens);
    }

    function test_tokenBidLifecycle() public {
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidPlaced(LuciMarket.BidType.TOKEN, address(nft), bidder, TOKEN_ID, 0, 1 ether, expiresAt);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), expiresAt);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), expiresAt);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidIncreased(LuciMarket.BidType.TOKEN, address(nft), bidder, TOKEN_ID, 0, 1.5 ether);
        vm.prank(bidder);
        market.increaseBid{value: 0.5 ether}(_tokenBid(TOKEN_ID));

        (uint192 amount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        assertEq(amount, uint192(1.5 ether));

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });
        uint64 newExpiry = _expires(2 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidExtended(LuciMarket.BidType.TOKEN, address(nft), bidder, TOKEN_ID, 0, newExpiry);
        vm.prank(bidder);
        market.extendBids(selectors, newExpiry);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidCanceled(LuciMarket.BidType.TOKEN, address(nft), bidder, TOKEN_ID, 0);
        vm.prank(bidder);
        market.cancelBids(selectors);

        (amount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        assertEq(amount, 0);
    }

    function test_bidEventsCanonicalizeIgnoredSelectorFields() public {
        LuciMarket.BidSelector memory selector = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION,
            collection: address(nft),
            tokenId: type(uint256).max,
            traitKey: type(uint256).max
        });
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidPlaced(LuciMarket.BidType.COLLECTION, address(nft), bidder, 0, 0, 1 ether, expiresAt);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(selector, expiresAt);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidIncreased(LuciMarket.BidType.COLLECTION, address(nft), bidder, 0, 0, 2 ether);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(selector);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = selector;
        uint64 newExpiry = _expires(2 days);
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidExtended(LuciMarket.BidType.COLLECTION, address(nft), bidder, 0, 0, newExpiry);
        vm.prank(bidder);
        market.extendBids(selectors, newExpiry);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidCanceled(LuciMarket.BidType.COLLECTION, address(nft), bidder, 0, 0);
        vm.prank(bidder);
        market.cancelBids(selectors);

        _placeTokenBid(TOKEN_ID, 1 ether);
        selector = _tokenBid(TOKEN_ID);
        selector.traitKey = type(uint256).max;
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(LuciMarket.BidType.TOKEN, address(nft), bidder, TOKEN_ID, 0, seller, 1 ether, 0);
        vm.prank(seller);
        market.acceptBid(selector, bidder, 0);
    }

    function test_placeTokenBidErrors() public {
        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.placeBid{value: 0}(_tokenBid(TOKEN_ID), _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), expiredAt);

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0}(_tokenBid(TOKEN_ID));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(_tokenBid(TOKEN_ID));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 0);
    }

    function test_acceptTokenBidErrors() public {
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), _expires(1 days));
        _list(TOKEN_ID, PRICE, address(0));

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, other, TOKEN_ID, seller));
        vm.prank(other);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 0);

        (uint192 tokenBidAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (address listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(tokenBidAmount, 1 ether);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, 1 ether);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN_ID)
        );
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 0);

        (tokenBidAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(tokenBidAmount, 1 ether);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, 1 ether);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 0);
    }

    function test_acceptBidRevertsWhenRoyaltyExceedsPriceAndPreservesState() public {
        uint256 bidAmount = 1 ether;
        _placeTokenBid(TOKEN_ID, bidAmount);

        MockRoyaltyModel excessiveRoyaltyModel = new MockRoyaltyModel(royaltyRecipient, bidAmount + 1);
        vm.prank(owner);
        market.setRoyaltyModel(address(excessiveRoyaltyModel));

        vm.expectRevert(LuciMarket.InvalidRoyaltyAmount.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, bidAmount);

        (uint192 storedAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        assertEq(storedAmount, bidAmount);
        assertEq(address(market).balance, bidAmount);
        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_collectionBidLifecycle() public {
        _placeCollectionBid(2 ether);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_collectionBid(0), _expires(1 days));

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidIncreased(LuciMarket.BidType.COLLECTION, address(nft), bidder, 0, 0, 3 ether);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(_collectionBid(0));

        (uint192 amount,) = market.collectionBids(bidder, address(nft));
        assertEq(amount, uint192(3 ether));

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidExtended(LuciMarket.BidType.COLLECTION, address(nft), bidder, 0, 0, _expires(2 days));
        vm.prank(bidder);
        market.extendBids(selectors, _expires(2 days));

        vm.prank(bidder);
        market.cancelBids(selectors);
        (amount,) = market.collectionBids(bidder, address(nft));
        assertEq(amount, 0);
    }

    function test_collectionBidErrors() public {
        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.placeBid{value: 0}(_collectionBid(0), _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_collectionBid(0), expiredAt);

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0}(_collectionBid(0));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(_collectionBid(0));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID), bidder, 0);

        _placeCollectionBid(1 ether);
        _list(TOKEN_ID, PRICE, address(0));

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID), bidder, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, other, TOKEN_ID, seller));
        vm.prank(other);
        market.acceptBid(_collectionBid(TOKEN_ID), bidder, 0);

        (uint192 collectionBidAmount,) = market.collectionBids(bidder, address(nft));
        (address listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(collectionBidAmount, 1 ether);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, 1 ether);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN_ID)
        );
        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID), bidder, 0);

        (collectionBidAmount,) = market.collectionBids(bidder, address(nft));
        (listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(collectionBidAmount, 1 ether);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, 1 ether);
    }

    function test_traitBidValidationLifecycleAndMatchingFailures() public {
        uint32 config = _traitConfig(0);
        uint256 traitKey = _traitKey(0, 5);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), config);

        // 0 trait key
        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_traitBid(0, 0), _expires(1 days));

        // trait bid on disabled slot
        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_traitBid(0, _traitKey(1, 5)), _expires(1 days));

        _placeTraitBid(traitKey, 2 ether);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidIncreased(LuciMarket.BidType.TRAIT, address(nft), bidder, 0, traitKey, 3 ether);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(_traitBid(0, traitKey));

        (uint192 amount,) = market.traitBids(bidder, address(nft), traitKey);
        assertEq(amount, uint192(3 ether));

        vm.expectRevert(LuciMarket.TraitNotSet.selector);
        vm.prank(seller);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 0);

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = TOKEN_ID;
        traitsArray[0] = _trait(0, 4);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        vm.expectRevert(LuciMarket.TraitMismatch.selector);
        vm.prank(seller);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 0);
    }

    function test_placeTraitBidErrors() public {
        uint256 traitKey = _traitKey(0, 5);
        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.placeBid{value: 0}(_traitBid(0, traitKey), _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_traitBid(0, traitKey), expiredAt);

        _placeTraitBid(traitKey, 1 ether);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_traitBid(0, traitKey), _expires(1 days));

        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(_traitBid(0, _traitKey(1, 5))); // slot 1 disabled

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0}(_traitBid(0, traitKey));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(other);
        market.increaseBid{value: 1 ether}(_traitBid(0, traitKey));
    }

    function test_acceptTraitBidErrors() public {
        uint256 traitKey = _traitKey(0, 5);
        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 0);

        _placeTraitBid(traitKey, 1 ether);

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 2 ether);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), 0);

        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(seller);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 0);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = TOKEN_ID;
        traitsArray[0] = _trait(0, 5);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);
        _list(TOKEN_ID, PRICE, address(0));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, other, TOKEN_ID, seller));
        vm.prank(other);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 0);

        (uint192 traitBidAmount,) = market.traitBids(bidder, address(nft), traitKey);
        (address listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(traitBidAmount, 1 ether);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, 1 ether);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN_ID)
        );
        vm.prank(seller);
        market.acceptBid(_traitBid(TOKEN_ID, traitKey), bidder, 0);

        (traitBidAmount,) = market.traitBids(bidder, address(nft), traitKey);
        (listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(traitBidAmount, 1 ether);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, 1 ether);
    }

    function test_extendBidsRevertsForMissingBidAndExpiredTimestamp() public {
        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.extendBids(selectors, expiredAt);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.extendBids(selectors, _expires(1 days));
    }

    function test_extendBidsCoversEmptyTokenMissingAndTraitBranches() public {
        LuciMarket.BidSelector[] memory empty = new LuciMarket.BidSelector[](0);

        vm.expectRevert(LuciMarket.ZeroLengthArray.selector);
        vm.prank(bidder);
        market.extendBids(empty, _expires(1 days));

        LuciMarket.BidSelector[] memory tokenSelectors = new LuciMarket.BidSelector[](1);
        tokenSelectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.extendBids(tokenSelectors, _expires(1 days));

        uint256 traitKey = _traitKey(0, 5);
        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        LuciMarket.BidSelector[] memory traitSelectors = new LuciMarket.BidSelector[](1);
        traitSelectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TRAIT, collection: address(nft), tokenId: 0, traitKey: traitKey
        });

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.extendBids(traitSelectors, _expires(1 days));

        _placeTraitBid(traitKey, 1 ether);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidExtended(LuciMarket.BidType.TRAIT, address(nft), bidder, 0, traitKey, _expires(2 days));
        vm.prank(bidder);
        market.extendBids(traitSelectors, _expires(2 days));
    }

    function test_expiredBidsCanBeExtendedAndBecomeFillableAgain() public {
        uint256 traitTokenId = 3;
        uint256 traitKey = _traitKey(0, 5);
        uint64 initialExpiry = _expires(1);

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
        market.placeBid{value: 1 ether}(_tokenBid(TOKEN_ID), initialExpiry);
        market.placeBid{value: 2 ether}(_collectionBid(0), initialExpiry);
        market.placeBid{value: 3 ether}(_traitBid(0, traitKey), initialExpiry);
        vm.stopPrank();

        vm.warp(initialExpiry + 1);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0.1 ether}(_tokenBid(TOKEN_ID));

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 0);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0.1 ether}(_collectionBid(0));

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID_TWO), bidder, 0);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0.1 ether}(_traitBid(0, traitKey));

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptBid(_traitBid(traitTokenId, traitKey), bidder, 0);

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

        uint64 newExpiry = _expires(1 days);
        vm.prank(bidder);
        market.extendBids(selectors, newExpiry);

        vm.startPrank(bidder);
        market.increaseBid{value: 0.1 ether}(_tokenBid(TOKEN_ID));
        market.increaseBid{value: 0.1 ether}(_collectionBid(0));
        market.increaseBid{value: 0.1 ether}(_traitBid(0, traitKey));
        vm.stopPrank();

        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 1.1 ether);

        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID_TWO), bidder, 2.1 ether);

        vm.prank(seller);
        market.acceptBid(_traitBid(traitTokenId, traitKey), bidder, 3.1 ether);

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
        assertEq(nft.ownerOf(traitTokenId), bidder);
    }

    function test_cancelBidsRevertsForMissingBidAndEmptyArray() public {
        LuciMarket.BidSelector[] memory empty = new LuciMarket.BidSelector[](0);
        vm.expectRevert(LuciMarket.ZeroLengthArray.selector);
        vm.prank(bidder);
        market.cancelBids(empty);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.cancelBids(selectors);
    }

    function test_cancelBidsRevertsForMissingTokenAndTraitBids() public {
        LuciMarket.BidSelector[] memory tokenSelectors = new LuciMarket.BidSelector[](1);
        tokenSelectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.cancelBids(tokenSelectors);

        LuciMarket.BidSelector[] memory traitSelectors = new LuciMarket.BidSelector[](1);
        traitSelectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TRAIT, collection: address(nft), tokenId: 0, traitKey: _traitKey(0, 5)
        });

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.cancelBids(traitSelectors);
    }

    function test_tokenOverrideCollectionTraitBidsNotAllowed() public {
        MockERC721 shared = new MockERC721();
        shared.mint(seller, TOKEN_ID);
        vm.prank(seller);
        shared.setApprovalForAll(address(market), true);
        vm.prank(owner);
        market.addToken(address(shared), TOKEN_ID);

        vm.prank(seller);
        market.list(address(shared), TOKEN_ID, PRICE, _expires(1 days), address(0));

        vm.prank(bidder);
        market.placeBid{value: 1 ether}(
            LuciMarket.BidSelector({
                bidType: LuciMarket.BidType.TOKEN, collection: address(shared), tokenId: TOKEN_ID, traitKey: 0
            }),
            _expires(1 days)
        );

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(
            LuciMarket.BidSelector({
                bidType: LuciMarket.BidType.COLLECTION, collection: address(shared), tokenId: 0, traitKey: 0
            }),
            _expires(1 days)
        );

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(
            LuciMarket.BidSelector({
                bidType: LuciMarket.BidType.TRAIT, collection: address(shared), tokenId: 0, traitKey: _traitKey(0, 1)
            }),
            _expires(1 days)
        );
    }

    function test_sanctionsBlockTradingAndEscrowWithdrawalButAllowDelisting() public {
        _setSanctionsList();

        _list(TOKEN_ID, PRICE, address(0));
        sanctions.setSanctioned(seller, true);
        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID_TWO, PRICE, _expires(1 days), address(0));

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        vm.prank(seller);
        market.delist(tokens);

        (address listingSeller,,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, address(0));

        sanctions.setSanctioned(seller, false);

        _placeTokenBid(TOKEN_ID, 1 ether);
        sanctions.setSanctioned(bidder, true);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });

        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(bidder);
        market.cancelBids(selectors);

        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 0);

        sanctions.setSanctioned(bidder, false);
        vm.prank(bidder);
        market.cancelBids(selectors);
    }

    function test_removedCollectionBlocksFulfillmentButStillAllowsDelistAndCancel() public {
        _list(TOKEN_ID, PRICE, address(0));
        _placeCollectionBid(1 ether);

        vm.prank(owner);
        market.removeCollection(address(nft));

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID);

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(_collectionBid(TOKEN_ID), bidder, 0);

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](1);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        vm.prank(seller);
        market.delist(tokens);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });
        vm.prank(bidder);
        market.cancelBids(selectors);
    }

    function test_setTraitsRequiresAllowedCollectionAndMatchingArrayLengths() public {
        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](2);

        vm.expectRevert(LuciMarket.ArrayLengthMismatch.selector);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(owner);
        market.setCollectionTraitsConfig(makeAddr("collection"), _traitConfig(0));

        uint32[] memory oneTrait = new uint32[](1);
        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(owner);
        market.setTraits(makeAddr("collection"), tokenIds, oneTrait);
    }
}
