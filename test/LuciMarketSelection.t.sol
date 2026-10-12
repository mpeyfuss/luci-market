// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std-1.14.0/Vm.sol";
import {IERC721Errors} from "@openzeppelin-contracts-5.6.1/interfaces/draft-IERC6093.sol";
import {Hashes} from "@openzeppelin-contracts-5.6.1/utils/cryptography/Hashes.sol";
import {LuciMarket} from "../src/LuciMarket.sol";
import {LuciTestBase} from "./LuciTestBase.sol";
import {MockERC721} from "./mocks/MarketplaceMocks.sol";

contract LuciMarketSelectionTest is LuciTestBase {
    MockERC721 internal nftTwo; // second allowed collection
    MockERC721 internal shared; // not allowed - only TOKEN_ID is individually allowed

    function setUp() public override {
        super.setUp();
        nftTwo = new MockERC721();
        shared = new MockERC721();

        vm.startPrank(owner);
        market.addCollection(address(nftTwo));
        royaltyModel.configureCollection(address(nftTwo), MINT_PRICE_USD);
        market.addToken(address(shared), TOKEN_ID);
        vm.stopPrank();

        nftTwo.mint(seller, TOKEN_ID);
        shared.mint(seller, TOKEN_ID);
        shared.mint(seller, TOKEN_ID_TWO);

        vm.startPrank(seller);
        nftTwo.setApprovalForAll(address(market), true);
        shared.setApprovalForAll(address(market), true);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////////////////
    // PLACEMENT AND LIFECYCLE
    /////////////////////////////////////////////////////////////////////

    function test_placeSelectionBidStoresBidAndEmits() public {
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO));
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidPlaced(
            LuciMarket.BidType.SELECTION, address(0), bidder, 0, selectionRoot, 1 ether, expiresAt
        );
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_selectionBid(selectionRoot, address(0), 0), expiresAt);

        (uint192 amount, uint64 storedExpiry) = market.selectionBids(bidder, selectionRoot);
        assertEq(amount, 1 ether);
        assertEq(storedExpiry, expiresAt);
        assertEq(address(market).balance, 1 ether);
    }

    function test_selectionBidLifecycle() public {
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO));
        _placeSelectionBid(selectionRoot, 1 ether);
        LuciMarket.BidSelector memory selector = _selectionBid(selectionRoot, address(0), 0);

        vm.expectRevert(LuciMarket.BidAlreadyExists.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(selector, _expires(1 days));

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidIncreased(LuciMarket.BidType.SELECTION, address(0), bidder, 0, selectionRoot, 1.5 ether);
        vm.prank(bidder);
        market.increaseBid{value: 0.5 ether}(selector);

        (uint192 amount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(amount, 1.5 ether);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = selector;
        uint64 newExpiry = _expires(2 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidExtended(LuciMarket.BidType.SELECTION, address(0), bidder, 0, selectionRoot, newExpiry);
        vm.prank(bidder);
        market.extendBids(selectors, newExpiry);

        (, uint64 storedExpiry) = market.selectionBids(bidder, selectionRoot);
        assertEq(storedExpiry, newExpiry);

        uint256 bidderBefore = bidder.balance;
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidCanceled(LuciMarket.BidType.SELECTION, address(0), bidder, 0, selectionRoot);
        vm.prank(bidder);
        market.cancelBids(selectors);

        (amount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(amount, 0);
        assertEq(bidder.balance, bidderBefore + 1.5 ether);
        assertEq(address(market).balance, 0);
    }

    function test_selectionIsSharedAcrossBidders() public {
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, 1 ether);
        vm.prank(other);
        market.placeBid{value: 2 ether}(_selectionBid(selectionRoot, address(0), 0), _expires(1 days));

        // filling one bid leaves the other intact
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), other, 2 ether, _merkleProof(tokens, 0));

        (uint192 bidderAmount,) = market.selectionBids(bidder, selectionRoot);
        (uint192 otherAmount,) = market.selectionBids(other, selectionRoot);
        assertEq(bidderAmount, 1 ether);
        assertEq(otherAmount, 0);
        assertEq(nft.ownerOf(TOKEN_ID), other);

        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(nft), TOKEN_ID_TWO), bidder, 1 ether, _merkleProof(tokens, 1)
        );
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
        assertEq(address(market).balance, 0);
    }

    function test_selectionBidInputErrors() public {
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID));
        LuciMarket.BidSelector memory selector = _selectionBid(selectionRoot, address(0), 0);

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.placeBid{value: 0}(selector, _expires(1 days));

        uint64 expiredAt = _expiredAt();
        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(selector, expiredAt);

        // a zero root is rejected so selection events never carry the placeholder id of other bid types
        vm.expectRevert(LuciMarket.InvalidSelection.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_selectionBid(bytes32(0), address(0), 0), 0);

        vm.expectRevert(LuciMarket.InvalidPrice.selector);
        vm.prank(bidder);
        market.increaseBid{value: 0}(selector);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(selector);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _noProof());

        assertEq(address(market).balance, 0);
    }

    /////////////////////////////////////////////////////////////////////
    // ELIGIBILITY
    /////////////////////////////////////////////////////////////////////

    /// @dev The contract cannot see a selection's contents, so placement accepts any root and acceptance checks the token
    function test_eligibilityIsCheckedPerTokenOnAcceptance() public {
        MockERC721 unknown = new MockERC721();
        unknown.mint(seller, TOKEN_ID);
        vm.prank(seller);
        unknown.setApprovalForAll(address(market), true);

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](4);
        tokens[0] = LuciMarket.Token({collection: address(unknown), tokenId: TOKEN_ID}); // not allowed at all
        tokens[1] = LuciMarket.Token({collection: address(shared), tokenId: TOKEN_ID_TWO}); // shared, not allowed
        tokens[2] = LuciMarket.Token({collection: address(shared), tokenId: TOKEN_ID}); // individually allowed
        tokens[3] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID}); // allowed collection
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, 1 ether);
        vm.prank(other);
        market.placeBid{value: 1 ether}(_selectionBid(selectionRoot, address(0), 0), _expires(1 days));

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(unknown), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(shared), TOKEN_ID_TWO), bidder, 0, _merkleProof(tokens, 1)
        );

        // unconfigured royalty entry falls back to the 10% maximum
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(
            LuciMarket.BidType.SELECTION, address(shared), bidder, TOKEN_ID, selectionRoot, seller, 1 ether, 0.1 ether
        );
        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(shared), TOKEN_ID), bidder, 1 ether, _merkleProof(tokens, 2)
        );

        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), other, 1 ether, _merkleProof(tokens, 3));

        assertEq(shared.ownerOf(TOKEN_ID), bidder);
        assertEq(nft.ownerOf(TOKEN_ID), other);
        assertEq(unknown.ownerOf(TOKEN_ID), seller);
        assertEq(shared.ownerOf(TOKEN_ID_TWO), seller);
    }

    function test_crossCollectionSelectionFillsFromEachCollection() public {
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](3);
        tokens[0] = LuciMarket.Token({collection: address(nftTwo), tokenId: TOKEN_ID});
        tokens[1] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        tokens[2] = LuciMarket.Token({collection: address(shared), tokenId: TOKEN_ID});
        bytes32 selectionRoot = _merkleRoot(tokens);

        _placeSelectionBid(selectionRoot, PRICE);
        vm.prank(buyer);
        market.placeBid{value: PRICE}(_selectionBid(selectionRoot, address(0), 0), _expires(1 days));

        // the same token id in each collection is a separate member
        assertTrue(market.isInSelection(selectionRoot, address(nft), TOKEN_ID, _merkleProof(tokens, 1)));
        assertTrue(market.isInSelection(selectionRoot, address(nftTwo), TOKEN_ID, _merkleProof(tokens, 0)));
        assertTrue(market.isInSelection(selectionRoot, address(shared), TOKEN_ID, _merkleProof(tokens, 2)));
        assertFalse(market.isInSelection(selectionRoot, address(nftTwo), TOKEN_ID, _merkleProof(tokens, 1)));

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(
            LuciMarket.BidType.SELECTION, address(nftTwo), bidder, TOKEN_ID, selectionRoot, seller, PRICE, 1 ether
        );
        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(nftTwo), TOKEN_ID), bidder, PRICE, _merkleProof(tokens, 0)
        );

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(
            LuciMarket.BidType.SELECTION, address(nft), buyer, TOKEN_ID, selectionRoot, seller, PRICE, 1 ether
        );
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), buyer, PRICE, _merkleProof(tokens, 1));

        assertEq(nftTwo.ownerOf(TOKEN_ID), bidder);
        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(shared.ownerOf(TOKEN_ID), seller);
        assertEq(address(market).balance, 0);
    }

    function test_tokenThatLosesAllowedStatusCannotFillWhileOthersCan() public {
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](2);
        tokens[0] = LuciMarket.Token({collection: address(shared), tokenId: TOKEN_ID});
        tokens[1] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, 1 ether);
        vm.prank(buyer);
        market.placeBid{value: 1 ether}(_selectionBid(selectionRoot, address(0), 0), _expires(1 days));

        vm.prank(owner);
        market.removeToken(address(shared), TOKEN_ID);

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(shared), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        (uint192 amount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(amount, 1 ether);
        assertEq(shared.ownerOf(TOKEN_ID), seller);

        // another member of the same selection still fills
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 1 ether, _merkleProof(tokens, 1));
        assertEq(nft.ownerOf(TOKEN_ID), bidder);

        // re-allowing the token makes it fillable again
        vm.prank(owner);
        market.addToken(address(shared), TOKEN_ID);
        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(shared), TOKEN_ID), buyer, 1 ether, _merkleProof(tokens, 0)
        );
        assertEq(shared.ownerOf(TOKEN_ID), buyer);
    }

    function test_removedCollectionBlocksItsMembersButNotOtherCollections() public {
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](2);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: TOKEN_ID});
        tokens[1] = LuciMarket.Token({collection: address(nftTwo), tokenId: TOKEN_ID});
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, 1 ether);

        vm.prank(owner);
        market.removeCollection(address(nft));

        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        // placement does not depend on the allowlist
        vm.prank(other);
        market.placeBid{value: 1 ether}(_selectionBid(selectionRoot, address(0), 0), _expires(1 days));

        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(nftTwo), TOKEN_ID), bidder, 1 ether, _merkleProof(tokens, 1)
        );
        assertEq(nftTwo.ownerOf(TOKEN_ID), bidder);

        vm.prank(owner);
        market.addCollection(address(nft));
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), other, 1 ether, _merkleProof(tokens, 0));
        assertEq(nft.ownerOf(TOKEN_ID), other);
    }

    /////////////////////////////////////////////////////////////////////
    // PROOFS AND MEMBERSHIP
    /////////////////////////////////////////////////////////////////////

    /// @dev A single-token selection's root is its leaf, so the empty proof is valid for it and no other selection
    function test_emptyProofFillsSingleTokenSelectionsOnly() public {
        bytes32 single = _merkleRoot(_tokens(address(nft), TOKEN_ID));
        assertEq(single, _leaf(address(nft), TOKEN_ID));
        bytes32 multi = _merkleRoot(_tokens(address(nftTwo), TOKEN_ID, TOKEN_ID_TWO));
        _placeSelectionBid(single, 1 ether);
        _placeSelectionBid(multi, 1 ether);

        vm.expectRevert(LuciMarket.TokenNotInSelection.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(multi, address(nftTwo), TOKEN_ID), bidder, 0, _noProof());

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidAccepted(
            LuciMarket.BidType.SELECTION, address(nft), bidder, TOKEN_ID, single, seller, 1 ether, 0
        );
        vm.prank(seller);
        market.acceptBid(_selectionBid(single, address(nft), TOKEN_ID), bidder, 1 ether, _noProof());
        assertEq(nft.ownerOf(TOKEN_ID), bidder);
    }

    function test_tokenAndCollectionBidsIgnoreProof() public {
        bytes32[] memory junk = new bytes32[](2);
        junk[0] = keccak256("junk");
        junk[1] = keccak256("more junk");
        _placeTokenBid(TOKEN_ID, 1 ether);
        _placeCollectionBid(1 ether);

        vm.startPrank(seller);
        market.acceptBid(_tokenBid(TOKEN_ID), bidder, 1 ether, junk);
        market.acceptBid(_collectionBid(TOKEN_ID_TWO), bidder, 1 ether, junk);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), bidder);
        assertEq(nft.ownerOf(TOKEN_ID_TWO), bidder);
        (uint192 tokenBidAmount,) = market.tokenBids(bidder, address(nft), TOKEN_ID);
        (uint192 collectionBidAmount,) = market.collectionBids(bidder, address(nft));
        assertEq(tokenBidAmount, 0);
        assertEq(collectionBidAmount, 0);
    }

    function test_membershipEdgeCases() public view {
        uint256 maxId = type(uint256).max;
        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](5);
        tokens[0] = LuciMarket.Token({collection: address(nft), tokenId: maxId});
        tokens[1] = LuciMarket.Token({collection: address(nft), tokenId: 256});
        tokens[2] = LuciMarket.Token({collection: address(nftTwo), tokenId: 255});
        tokens[3] = LuciMarket.Token({collection: address(nft), tokenId: 0});
        tokens[4] = LuciMarket.Token({collection: address(nft), tokenId: 255}); // odd node, carried up unhashed
        bytes32 root = _merkleRoot(tokens);

        for (uint256 i = 0; i < tokens.length; ++i) {
            assertTrue(market.isInSelection(root, tokens[i].collection, tokens[i].tokenId, _merkleProof(tokens, i)));
        }

        bytes32[] memory proof = _merkleProof(tokens, 0);
        // a valid proof only proves its own token
        assertFalse(market.isInSelection(root, address(nft), maxId - 1, proof));
        assertFalse(market.isInSelection(root, address(nftTwo), maxId, proof));
        assertFalse(market.isInSelection(root, address(nft), 256, proof));
        // wrong root, empty proof, truncated, extended, and tampered proofs
        assertFalse(market.isInSelection(bytes32(0), address(nft), maxId, proof));
        assertFalse(market.isInSelection(keccak256("unknown"), address(nft), maxId, proof));
        assertFalse(market.isInSelection(root, address(nft), maxId, new bytes32[](0)));
        bytes32[] memory truncated = new bytes32[](proof.length - 1);
        bytes32[] memory extended = new bytes32[](proof.length + 1);
        for (uint256 i = 0; i < proof.length; ++i) {
            if (i < truncated.length) truncated[i] = proof[i];
            extended[i] = proof[i];
        }
        extended[proof.length] = keccak256("extra");
        assertFalse(market.isInSelection(root, address(nft), maxId, truncated));
        assertFalse(market.isInSelection(root, address(nft), maxId, extended));
        proof[0] ^= bytes32(uint256(1));
        assertFalse(market.isInSelection(root, address(nft), maxId, proof));
    }

    /// @dev Leaves must be double-hashed; a tree of single-hashed leaves does not verify
    function test_singleHashedLeavesAreRejected() public view {
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 leafA = keccak256(abi.encode(address(nft), TOKEN_ID));
        bytes32 leafB = keccak256(abi.encode(address(nft), TOKEN_ID_TWO));
        bytes32 root = Hashes.commutativeKeccak256(leafA, leafB);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        assertFalse(market.isInSelection(root, address(nft), TOKEN_ID, proof));
        assertTrue(market.isInSelection(_merkleRoot(tokens), address(nft), TOKEN_ID, _merkleProof(tokens, 0)));
    }

    /// @dev Root and proofs generated by `@openzeppelin/merkle-tree` 1.0.8:
    ///      `StandardMerkleTree.of(values, ["address", "uint256"])`
    function test_openZeppelinStandardMerkleTreeVector() public view {
        bytes32 root = 0xd87defa40b5a2f95c22ca8a187f8168d7d27daddf587c48ec0eb620b04fee722;
        address a = 0x1111111111111111111111111111111111111111;
        address b = 0x2222222222222222222222222222222222222222;
        address c = 0x3333333333333333333333333333333333333333;

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0xdd05ddd79adc5569806124d3c5d8151b75bc81032a0ea21d4cd74fd964947bf5;
        proof[1] = 0x286379eda94f0a3478e31b56e86658fda9990545bfabec3321081c247a0bd88b;
        assertTrue(market.isInSelection(root, a, 1, proof));
        assertFalse(market.isInSelection(root, a, 2, proof));

        proof = new bytes32[](3);
        proof[0] = 0x038637e8a0f418d4415404d100e746362bff09198cf345795cce423ccd6d4c1f;
        proof[1] = 0xebf09d18ef212432cfa2e714503e8710a4032aa6d15b222f8880dd796ec2e957;
        proof[2] = 0x5c426183fd49d5a493a87b59d6d5f030b2d7789c948b35552a8c25f966007df4;
        assertTrue(market.isInSelection(root, a, 2, proof));

        proof = new bytes32[](2);
        proof[0] = 0x5e9a59a7a2365a9c7750f53d7ab721999c97de0d59a286037a48bdd16a71b59a;
        proof[1] = 0x5c426183fd49d5a493a87b59d6d5f030b2d7789c948b35552a8c25f966007df4;
        assertTrue(market.isInSelection(root, b, 1, proof));

        proof = new bytes32[](3);
        proof[0] = 0x2810e82be134d73d36c6d30b0ca86228c1dd8f68b0fa8649ac2e7b6f43a20371;
        proof[1] = 0xebf09d18ef212432cfa2e714503e8710a4032aa6d15b222f8880dd796ec2e957;
        proof[2] = 0x5c426183fd49d5a493a87b59d6d5f030b2d7789c948b35552a8c25f966007df4;
        assertTrue(market.isInSelection(root, b, type(uint256).max, proof));

        proof = new bytes32[](2);
        proof[0] = 0x60648906e1a3f55dd188e992dc24db68c6b6d455fe925705f5e110ed7889ad90;
        proof[1] = 0x286379eda94f0a3478e31b56e86658fda9990545bfabec3321081c247a0bd88b;
        assertTrue(market.isInSelection(root, c, 0, proof));
    }

    function test_acceptRevertsForTokenNotInSelectionAndPreservesState() public {
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID_TWO, 3);
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, 1 ether);
        _list(TOKEN_ID, PRICE, address(0));

        // a member's proof does not prove another token
        vm.expectRevert(LuciMarket.TokenNotInSelection.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        // same token id, different (allowed) collection
        vm.expectRevert(LuciMarket.TokenNotInSelection.selector);
        vm.prank(seller);
        market.acceptBid(
            _selectionBid(selectionRoot, address(nftTwo), TOKEN_ID_TWO), bidder, 0, _merkleProof(tokens, 0)
        );

        _assertSelectionBidAndListingIntact(selectionRoot, 1 ether);
        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_acceptSelectionBidErrors() public {
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 selectionRoot = _merkleRoot(tokens);
        bytes32[] memory proof = _merkleProof(tokens, 0);
        _placeSelectionBid(selectionRoot, 1 ether);
        _list(TOKEN_ID, PRICE, address(0));

        vm.expectRevert(LuciMarket.BidTooLow.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 2 ether, proof);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, other, TOKEN_ID, seller));
        vm.prank(other);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, proof);

        _assertSelectionBidAndListingIntact(selectionRoot, 1 ether);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), false);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(market), TOKEN_ID)
        );
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, proof);

        _assertSelectionBidAndListingIntact(selectionRoot, 1 ether);

        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, proof);
    }

    /// @dev Selection acceptance checks the allowlist, then the proof, then the bid
    function test_acceptSelectionBidCheckOrder() public {
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 selectionRoot = _merkleRoot(tokens);
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("not a sibling");

        // no bid yet: a non-allowed token fails the allowlist before the proof
        vm.expectRevert(LuciMarket.CollectionOrTokenNotAllowed.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(shared), TOKEN_ID_TWO), bidder, 0, badProof);

        // no bid yet: a bad proof fails before NoBidExists
        vm.expectRevert(LuciMarket.TokenNotInSelection.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, badProof);

        vm.expectRevert(LuciMarket.NoBidExists.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        // bid too low: a bad proof fails before BidTooLow
        _placeSelectionBid(selectionRoot, 1 ether);
        vm.expectRevert(LuciMarket.TokenNotInSelection.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 2 ether, badProof);

        // bid expired: a bad proof fails before BidExpired
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(LuciMarket.TokenNotInSelection.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, badProof);

        vm.expectRevert(LuciMarket.BidExpired.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        (uint192 amount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(amount, 1 ether);
        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    /// @dev The `else` branches treat any bid type other than TOKEN and COLLECTION as SELECTION. That holds
    ///      because ABI decoding rejects enum values out of range, so no other value reaches the branch.
    function test_outOfRangeBidTypeIsRejectedByAbiDecoding() public {
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO));
        _placeSelectionBid(selectionRoot, 1 ether);

        bytes memory acceptData = abi.encodeCall(
            LuciMarket.acceptBid, (_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _noProof())
        );
        bytes memory placeData =
            abi.encodeCall(LuciMarket.placeBid, (_selectionBid(selectionRoot, address(0), 0), _expires(1 days)));
        // bidType is the first argument word; set its low byte to 3
        acceptData[35] = bytes1(uint8(3));
        placeData[35] = bytes1(uint8(3));

        vm.prank(seller);
        (bool acceptSuccess, bytes memory acceptRevert) = address(market).call(acceptData);
        vm.prank(other);
        (bool placeSuccess, bytes memory placeRevert) = address(market).call{value: 1 ether}(placeData);

        assertFalse(acceptSuccess);
        assertFalse(placeSuccess);
        assertEq(acceptRevert.length, 0);
        assertEq(placeRevert.length, 0);
        (uint192 amount,) = market.selectionBids(bidder, selectionRoot);
        assertEq(amount, 1 ether);
        (amount,) = market.selectionBids(other, selectionRoot);
        assertEq(amount, 0);
        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    /////////////////////////////////////////////////////////////////////
    // PAUSE, SANCTIONS, EVENTS
    /////////////////////////////////////////////////////////////////////

    function test_pausedBlocksSelectionBidsButAllowsCancel() public {
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 selectionRoot = _merkleRoot(tokens);
        _placeSelectionBid(selectionRoot, 1 ether);
        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = _selectionBid(selectionRoot, address(0), 0);

        vm.prank(owner);
        market.setPaused(true);

        vm.expectRevert(LuciMarket.IsPaused.selector);
        vm.prank(other);
        market.placeBid{value: 1 ether}(selectors[0], 0);

        vm.expectRevert(LuciMarket.IsPaused.selector);
        vm.prank(bidder);
        market.increaseBid{value: 1 ether}(selectors[0]);

        vm.expectRevert(LuciMarket.IsPaused.selector);
        vm.prank(bidder);
        market.extendBids(selectors, _expires(2 days));

        vm.expectRevert(LuciMarket.IsPaused.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, _merkleProof(tokens, 0));

        vm.prank(bidder);
        market.cancelBids(selectors);
        assertEq(address(market).balance, 0);
    }

    function test_sanctionsBlockSelectionBids() public {
        _setSanctionsList();
        LuciMarket.Token[] memory tokens = _tokens(address(nft), TOKEN_ID, TOKEN_ID_TWO);
        bytes32 selectionRoot = _merkleRoot(tokens);
        bytes32[] memory proof = _merkleProof(tokens, 0);

        sanctions.setSanctioned(bidder, true);
        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(bidder);
        market.placeBid{value: 1 ether}(_selectionBid(selectionRoot, address(0), 0), 0);

        sanctions.setSanctioned(bidder, false);
        _placeSelectionBid(selectionRoot, 1 ether);
        sanctions.setSanctioned(bidder, true);

        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, proof);

        sanctions.setSanctioned(bidder, false);
        sanctions.setSanctioned(seller, true);
        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(seller);
        market.acceptBid(_selectionBid(selectionRoot, address(nft), TOKEN_ID), bidder, 0, proof);
        sanctions.setSanctioned(seller, false);

        sanctions.setSanctioned(bidder, true);
        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = _selectionBid(selectionRoot, address(0), 0);
        vm.expectRevert(LuciMarket.Sanctioned.selector);
        vm.prank(bidder);
        market.cancelBids(selectors);

        sanctions.setSanctioned(bidder, false);
        vm.prank(bidder);
        market.cancelBids(selectors);
        assertEq(address(market).balance, 0);
    }

    function test_selectionBidEventsCanonicalizeIgnoredSelectorFields() public {
        bytes32 selectionRoot = _merkleRoot(_tokens(address(nft), TOKEN_ID));
        LuciMarket.BidSelector memory junk = _selectionBid(selectionRoot, address(nftTwo), type(uint256).max);
        uint64 expiresAt = _expires(1 days);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidPlaced(LuciMarket.BidType.SELECTION, address(0), other, 0, selectionRoot, 1 ether, expiresAt);
        vm.prank(other);
        market.placeBid{value: 1 ether}(junk, expiresAt);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidIncreased(LuciMarket.BidType.SELECTION, address(0), other, 0, selectionRoot, 2 ether);
        vm.prank(other);
        market.increaseBid{value: 1 ether}(junk);

        LuciMarket.BidSelector[] memory selectors = new LuciMarket.BidSelector[](1);
        selectors[0] = junk;
        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidExtended(LuciMarket.BidType.SELECTION, address(0), other, 0, selectionRoot, expiresAt);
        vm.prank(other);
        market.extendBids(selectors, expiresAt);

        vm.expectEmit(true, true, true, true, address(market));
        emit LuciMarket.BidCanceled(LuciMarket.BidType.SELECTION, address(0), other, 0, selectionRoot);
        vm.prank(other);
        market.cancelBids(selectors);
    }

    /////////////////////////////////////////////////////////////////////
    // FUZZ
    /////////////////////////////////////////////////////////////////////

    /// @dev Builds a random cross-collection tree and checks every proof against a reference: a member's proof
    ///      verifies exactly the tokens equal to that member
    function testFuzz_selectionMembershipMatchesReference(uint256[33] memory seeds, uint256 count, uint256 probeSeed)
        public
        view
    {
        count = bound(count, 1, seeds.length);
        address[3] memory collections = [address(nft), address(nftTwo), address(shared)];

        LuciMarket.Token[] memory tokens = new LuciMarket.Token[](count);
        for (uint256 i = 0; i < count; ++i) {
            uint256 seed = seeds[i];
            // half small ids (so collisions across collections are common), half anywhere in uint256
            uint256 tokenId = seed >> 255 == 0 ? seed % 8 : uint256(keccak256(abi.encode(seed)));
            tokens[i] = LuciMarket.Token({collection: collections[seed % 3], tokenId: tokenId});
        }
        bytes32 root = _merkleRoot(tokens);

        LuciMarket.Token memory probe = LuciMarket.Token({
            collection: collections[probeSeed % 3], tokenId: probeSeed >> 255 == 0 ? probeSeed % 8 : probeSeed
        });
        for (uint256 i = 0; i < count; ++i) {
            bytes32[] memory proof = _merkleProof(tokens, i);
            assertTrue(market.isInSelection(root, tokens[i].collection, tokens[i].tokenId, proof));

            bool expected = probe.collection == tokens[i].collection && probe.tokenId == tokens[i].tokenId;
            assertEq(market.isInSelection(root, probe.collection, probe.tokenId, proof), expected);
            for (uint256 c = 0; c < collections.length; ++c) {
                expected = collections[c] == tokens[i].collection;
                assertEq(market.isInSelection(root, collections[c], tokens[i].tokenId, proof), expected);
            }
        }
    }

    /////////////////////////////////////////////////////////////////////
    // GAS
    /////////////////////////////////////////////////////////////////////

    /// @dev Placing a selection bid costs the same as any other bid; accepting grows with proof depth only.
    ///      A tree of `n` tokens has depth `ceil(log2(n))`: 1M tokens is depth 20. Run with `-vv` to print.
    function test_gasSelectionBidsByProofDepth() public {
        uint256 start = vm.snapshotState();
        uint64 expiresAt = _expires(1 days);
        uint256 tokenBidGas =
            _measure(bidder, 1 ether, abi.encodeCall(LuciMarket.placeBid, (_tokenBid(TOKEN_ID), expiresAt)));
        uint256 selectionBidGas = _measure(
            bidder,
            1 ether,
            abi.encodeCall(LuciMarket.placeBid, (_selectionBid(keccak256("root"), address(0), 0), expiresAt))
        );
        emit log_named_uint("place token bid", tokenBidGas);
        emit log_named_uint("place selection bid", selectionBidGas);
        // no allowlist read at placement
        assertLe(selectionBidGas, tokenBidGas);

        uint256 tokenAcceptGas =
            _measure(seller, 0, abi.encodeCall(LuciMarket.acceptBid, (_tokenBid(TOKEN_ID), bidder, 0, _noProof())));
        emit log_named_uint("accept token bid", tokenAcceptGas);
        vm.revertToState(start);

        uint256[6] memory depths = [uint256(0), 7, 10, 14, 17, 20];
        uint256 previous = 0;
        for (uint256 i = 0; i < depths.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            bytes32[] memory proof = new bytes32[](depths[i]);
            bytes32 root = _leaf(address(nft), TOKEN_ID);
            for (uint256 d = 0; d < depths[i]; ++d) {
                proof[d] = keccak256(abi.encode(i, d));
                root = Hashes.commutativeKeccak256(root, proof[d]);
            }
            _placeSelectionBid(root, 1 ether);
            uint256 acceptGas = _measure(
                seller,
                0,
                abi.encodeCall(LuciMarket.acceptBid, (_selectionBid(root, address(nft), TOKEN_ID), bidder, 0, proof))
            );
            vm.revertToState(snapshot);

            emit log_named_uint(string.concat("accept selection bid, proof depth ", vm.toString(depths[i])), acceptGas);
            assertGt(acceptGas, previous);
            previous = acceptGas;
        }
        // about 1.3k gas per proof level: a 1M-token selection costs under 30k more to fill than a token bid
        assertLt(previous, tokenAcceptGas + 30_000);
    }

    /////////////////////////////////////////////////////////////////////
    // HELPERS
    /////////////////////////////////////////////////////////////////////

    function _assertSelectionBidAndListingIntact(bytes32 selectionRoot, uint256 amount) internal view {
        (uint192 storedAmount,) = market.selectionBids(bidder, selectionRoot);
        (address listingSeller,,,) = market.listings(address(nft), TOKEN_ID);
        assertEq(storedAmount, amount);
        assertEq(listingSeller, seller);
        assertEq(address(market).balance, amount);
    }

    /// @dev Cost of sending `data` to the market as a standalone transaction: 21k base, calldata (EIP-7623 floor
    ///      aware), execution against cold storage, and refunds capped at one fifth
    function _measure(address sender, uint256 value, bytes memory data) internal returns (uint256) {
        vm.cool(address(market));
        vm.cool(address(nft));
        vm.cool(address(royaltyModel));
        vm.cool(address(ethUsdFeed));
        vm.cool(royaltyRecipient);

        vm.prank(sender);
        (bool success,) = address(market).call{value: value}(data);
        assertTrue(success);
        Vm.Gas memory gas = vm.lastCallGas();

        uint256 zeroBytes = 0;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++zeroBytes;
        }
        uint256 tokens = zeroBytes + (data.length - zeroBytes) * 4;
        uint256 used = 21_000 + tokens * 4 + gas.gasTotalUsed;
        uint256 refund = gas.gasRefunded > 0 ? uint256(int256(gas.gasRefunded)) : 0;
        if (refund > used / 5) refund = used / 5;
        uint256 standardGas = used - refund;
        uint256 floorGas = 21_000 + tokens * 10;
        return standardGas > floorGas ? standardGas : floorGas;
    }
}
