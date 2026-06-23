// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LuciMarket} from "../src/LuciMarket.sol";
import {LuciRoyaltyModel} from "../src/LuciRoyaltyModel.sol";
import {LuciTestBase} from "./LuciTestBase.sol";
import {MockERC721} from "./mocks/MarketplaceMocks.sol";

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
        emit LuciMarket.Listed(address(nft), TOKEN_ID, seller, PRICE, expiresAt, address(0));
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, expiresAt, address(0));

        (address listingSeller, uint64 listingExpiresAt, uint256 listingPrice, address listingBuyer) =
            market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, seller);
        assertEq(listingExpiresAt, expiresAt);
        assertEq(listingPrice, PRICE);
        assertEq(listingBuyer, address(0));
    }

    function test_listPrivateBuyerStoresListingAndEmits() public {
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.Listed(address(nft), TOKEN_ID, seller, PRICE, expiresAt, owner);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, expiresAt, owner);

        (address listingSeller, uint64 listingExpiresAt, uint256 listingPrice, address listingBuyer) =
            market.listings(address(nft), TOKEN_ID);
        assertEq(listingSeller, seller);
        assertEq(listingExpiresAt, expiresAt);
        assertEq(listingPrice, PRICE);
        assertEq(listingBuyer, owner);
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

        vm.prank(seller);
        market.extendListings(tokens, newExpiry);

        (, uint64 firstExpiry,,) = market.listings(address(nft), TOKEN_ID);
        (, uint64 secondExpiry,,) = market.listings(address(nft), TOKEN_ID_TWO);
        assertEq(firstExpiry, newExpiry);
        assertEq(secondExpiry, newExpiry);
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

        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
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

        vm.expectRevert(LuciMarket.ListingOwnerNotTokenOwner.selector);
        vm.prank(buyer);
        market.buy{value: PRICE}(address(nft), TOKEN_ID_TWO);
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
        emit LuciMarket.TokenBidPlaced(address(nft), TOKEN_ID, bidder, 1 ether, expiresAt);
        vm.prank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, expiresAt);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, expiresAt);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.TokenBidIncreased(address(nft), TOKEN_ID, bidder, 1.5 ether);
        vm.prank(bidder);
        market.increaseTokenBid{value: 0.5 ether}(address(nft), TOKEN_ID);

        (uint192 amount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        assertEq(amount, uint192(1.5 ether));

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.TOKEN, collection: address(nft), tokenId: TOKEN_ID, traitKey: 0
        });
        uint64 newExpiry = _expires(2 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.TokenBidExtended(address(nft), TOKEN_ID, bidder, newExpiry);
        vm.prank(bidder);
        market.extendBids(selectors, newExpiry);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.TokenBidCanceled(address(nft), TOKEN_ID, bidder);
        vm.prank(bidder);
        market.cancelBids(selectors);

        (amount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        assertEq(amount, 0);
    }

    function test_placeTokenBidErrors() public {
        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.placeTokenBid{value: 0}(address(nft), TOKEN_ID, _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, expiredAt);

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseTokenBid{value: 0}(address(nft), TOKEN_ID);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.increaseTokenBid{value: 1 ether}(address(nft), TOKEN_ID);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 0);
    }

    function test_acceptTokenBidErrors() public {
        vm.prank(bidder);
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, _expires(1 days));

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 2 ether);

        vm.expectRevert(LuciMarket.NotTokenOwner.selector);
        vm.prank(other);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 0);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(LuciMarket.NotApproved.selector);
        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 0);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 0);
    }

    function test_collectionBidLifecycle() public {
        _placeCollectionBid(2 ether);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeCollectionBid{value: 1 ether}(address(nft), _expires(1 days));

        vm.expectEmit(true, true, false, true, address(market));
        emit LuciMarket.CollectionBidIncreased(address(nft), bidder, 3 ether);
        vm.prank(bidder);
        market.increaseCollectionBid{value: 1 ether}(address(nft));

        (uint192 amount,) = market.collectionBids(bidder, address(nft));
        assertEq(amount, uint192(3 ether));

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = LuciMarket.BidSelector({
            bidType: LuciMarket.BidType.COLLECTION, collection: address(nft), tokenId: 0, traitKey: 0
        });

        vm.expectEmit(true, true, false, true, address(market));
        emit LuciMarket.CollectionBidExtended(address(nft), bidder, _expires(2 days));
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
        market.placeCollectionBid{value: 0}(address(nft), _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeCollectionBid{value: 1 ether}(address(nft), expiredAt);

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseCollectionBid{value: 0}(address(nft));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.increaseCollectionBid{value: 1 ether}(address(nft));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID, bidder, 0);

        _placeCollectionBid(1 ether);

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID, bidder, 2 ether);

        vm.expectRevert(LuciMarket.NotTokenOwner.selector);
        vm.prank(other);
        market.acceptCollectionBid(address(nft), TOKEN_ID, bidder, 0);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(LuciMarket.NotApproved.selector);
        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID, bidder, 0);
    }

    function test_traitBidValidationLifecycleAndMatchingFailures() public {
        uint32 config = _traitConfig(0);
        uint256 traitKey = _traitKey(0, 5);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), config);

        // 0 trait key
        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(bidder);
        market.placeTraitBid{value: 1 ether}(address(nft), 0, _expires(1 days));

        // trait bid on disabled slot
        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(bidder);
        market.placeTraitBid{value: 1 ether}(address(nft), _traitKey(1, 5), _expires(1 days));

        _placeTraitBid(traitKey, 2 ether);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.TraitBidIncreased(address(nft), traitKey, bidder, 3 ether);
        vm.prank(bidder);
        market.increaseTraitBid{value: 1 ether}(address(nft), traitKey);

        (uint192 amount,) = market.traitBids(bidder, address(nft), traitKey);
        assertEq(amount, uint192(3 ether));

        vm.expectRevert(LuciMarket.TraitNotSet.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 0);

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = TOKEN_ID;
        traitsArray[0] = _trait(0, 4);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        vm.expectRevert(LuciMarket.TraitMismatch.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 0);
    }

    function test_placeTraitBidErrors() public {
        uint256 traitKey = _traitKey(0, 5);
        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.placeTraitBid{value: 0}(address(nft), traitKey, _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeTraitBid{value: 1 ether}(address(nft), traitKey, expiredAt);

        _placeTraitBid(traitKey, 1 ether);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeTraitBid{value: 1 ether}(address(nft), traitKey, _expires(1 days));

        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(bidder);
        market.increaseTraitBid{value: 1 ether}(address(nft), _traitKey(1, 5)); // slot 1 disabled

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseTraitBid{value: 0}(address(nft), traitKey);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(other);
        market.increaseTraitBid{value: 1 ether}(address(nft), traitKey);
    }

    function test_acceptTraitBidErrors() public {
        uint256 traitKey = _traitKey(0, 5);
        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 0);

        _placeTraitBid(traitKey, 1 ether);

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 2 ether);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), 0);

        vm.expectRevert(LuciMarket.InvalidTraitKey.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 0);

        vm.prank(owner);
        market.setCollectionTraitsConfig(address(nft), _traitConfig(0));

        uint256[] memory tokenIds = new uint256[](1);
        uint32[] memory traitsArray = new uint32[](1);
        tokenIds[0] = TOKEN_ID;
        traitsArray[0] = _trait(0, 5);
        vm.prank(owner);
        market.setTraits(address(nft), tokenIds, traitsArray);

        vm.expectRevert(LuciMarket.NotTokenOwner.selector);
        vm.prank(other);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 0);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(LuciMarket.NotApproved.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), TOKEN_ID, bidder, traitKey, 0);
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
        emit LuciMarket.TraitBidExtended(address(nft), traitKey, bidder, _expires(2 days));
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
        market.placeTokenBid{value: 1 ether}(address(nft), TOKEN_ID, initialExpiry);
        market.placeCollectionBid{value: 2 ether}(address(nft), initialExpiry);
        market.placeTraitBid{value: 3 ether}(address(nft), traitKey, initialExpiry);
        vm.stopPrank();

        vm.warp(initialExpiry + 1);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.increaseTokenBid{value: 0.1 ether}(address(nft), TOKEN_ID);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 0);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.increaseCollectionBid{value: 0.1 ether}(address(nft));

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptCollectionBid(address(nft), TOKEN_ID_TWO, bidder, 0);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.increaseTraitBid{value: 0.1 ether}(address(nft), traitKey);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptTraitBid(address(nft), traitTokenId, bidder, traitKey, 0);

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
        market.placeTokenBid{value: 1 ether}(address(shared), TOKEN_ID, _expires(1 days));

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(bidder);
        market.placeCollectionBid{value: 1 ether}(address(shared), _expires(1 days));

        vm.expectRevert(LuciMarket.CollectionNotAllowed.selector);
        vm.prank(bidder);
        market.placeTraitBid{value: 1 ether}(address(shared), _traitKey(0, 1), _expires(1 days));
    }

    function test_sanctionsBlockAllUserPathsAndEscrowWithdrawalUntilCleared() public {
        _setSanctionsList();

        sanctions.setSanctioned(seller, true);
        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(seller);
        market.list(address(nft), TOKEN_ID, PRICE, _expires(1 days), address(0));
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
        market.acceptTokenBid(address(nft), TOKEN_ID, bidder, 0);

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
        market.acceptCollectionBid(address(nft), TOKEN_ID, bidder, 0);

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
