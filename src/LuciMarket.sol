// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts-5.6.1/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin-contracts-5.6.1/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin-contracts-5.6.1/utils/Strings.sol";
import {LuciRoyaltyModel} from "./LuciRoyaltyModel.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";

/// @title Luci Market
/// @notice A simple, onchain marketplace for buying and selling allowlisted ERC721 tokens
/// @dev Supports listings, collection bids, token bids, and selection bids
/// @author mpeyfuss
/// @author Sam Spratt
contract LuciMarket is Ownable2Step, ReentrancyGuardTransient {
    /////////////////////////////////////////////////////////////////////
    // TYPES
    /////////////////////////////////////////////////////////////////////

    struct Listing {
        address seller; // slot 0 (20 bytes)
        uint64 expiresAt; // slot 0 (8 bytes)
        uint256 price; // slot 1 (32 bytes)
        address buyer; // slot 2 (20 bytes) - address(0) means anyone can buy
    }

    struct Bid {
        uint192 amount; // more than enough for any ETH amount
        uint64 expiresAt; // 0 = no expiry
    }

    struct Token {
        address collection;
        uint256 tokenId;
    }

    enum BidType {
        TOKEN,
        COLLECTION,
        SELECTION
    }

    struct BidSelector {
        BidType bidType;
        address collection;
        uint256 tokenId;
        bytes32 selectionRoot;
    }

    /////////////////////////////////////////////////////////////////////
    // STORAGE
    /////////////////////////////////////////////////////////////////////

    /// @notice Maximum listing duration to help avoid the stale listing attack vector
    uint256 public constant MAX_LISTING_DURATION = 180 days;

    /// @notice Basis points denominator
    uint256 public constant BASIS = 10_000;

    /// @notice Hard ceiling on royalties, enforced on every settlement regardless of the configured royalty model
    uint256 public constant MAX_ROYALTY_BPS = 1_000; // 10%

    /// @notice Sale currency passed to the royalty model - this marketplace settles in native ETH only
    address public constant NATIVE_CURRENCY = address(0);

    /// @notice Whether the marketplace is paused
    bool public paused;

    /// @notice Royalty model
    address public royaltyModel;

    /// @notice Chainalysis Sanctions List
    address public sanctionsList;

    /// @notice Base URI where selection Merkle trees are published, keyed by root (see `selectionUri`)
    string public selectionBaseUri;

    /// @notice Collections that can be traded
    mapping(address collection => bool) public allowedCollections;

    /// @notice Token override for shared contracts - these tokens are not eligible for collection bids
    mapping(address collection => mapping(uint256 tokenId => bool)) public allowedTokens;

    /// @notice Listings: collection => tokenId => Listing
    mapping(address collection => mapping(uint256 tokenId => Listing)) public listings;

    /// @notice Collection bids: bidder => collection => Bid
    mapping(address bidder => mapping(address collection => Bid)) public collectionBids;

    /// @notice Token bids: bidder => collection => tokenId => Bid
    mapping(address bidder => mapping(address collection => mapping(uint256 tokenId => Bid))) public tokenBids;

    /// @notice Selection bids: bidder => selectionRoot (Merkle root of the selected tokens) => Bid
    mapping(address bidder => mapping(bytes32 selectionRoot => Bid)) public selectionBids;

    /////////////////////////////////////////////////////////////////////
    // EVENTS
    /////////////////////////////////////////////////////////////////////

    event Listed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        uint64 expiresAt,
        address buyer
    );
    event Delisted(address indexed collection, uint256 indexed tokenId, address indexed seller);
    event Sold(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        uint256 price,
        uint256 royaltyAmount
    );

    event BidPlaced(
        BidType indexed bidType,
        address indexed collection,
        address indexed bidder,
        uint256 tokenId,
        bytes32 selectionRoot,
        uint256 amount,
        uint64 expiresAt
    );
    event BidIncreased(
        BidType indexed bidType,
        address indexed collection,
        address indexed bidder,
        uint256 tokenId,
        bytes32 selectionRoot,
        uint256 newAmount
    );
    event BidExtended(
        BidType indexed bidType,
        address indexed collection,
        address indexed bidder,
        uint256 tokenId,
        bytes32 selectionRoot,
        uint64 newExpiresAt
    );
    event BidCanceled(
        BidType indexed bidType,
        address indexed collection,
        address indexed bidder,
        uint256 tokenId,
        bytes32 selectionRoot
    );
    event BidAccepted(
        BidType indexed bidType,
        address indexed collection,
        address indexed bidder,
        uint256 tokenId,
        bytes32 selectionRoot,
        address seller,
        uint256 price,
        uint256 royaltyAmount
    );

    event CollectionAdded(address indexed collection);
    event CollectionRemoved(address indexed collection);
    event PauseToggled(bool paused);
    event RoyaltyModelUpdated(address indexed oldRoyaltyModel, address indexed newRoyaltyModel);
    event SanctionsListUpdated(address indexed oldSanctionsList, address indexed newSanctionsList);
    event SelectionBaseUriUpdated(string oldSelectionBaseUri, string newSelectionBaseUri);
    event TokenAdded(address indexed collection, uint256 indexed tokenId);
    event TokenRemoved(address indexed collection, uint256 indexed tokenId);

    /////////////////////////////////////////////////////////////////////
    // ERRORS
    /////////////////////////////////////////////////////////////////////

    error BidAlreadyExists();
    error BidExpired();
    error BidTooLow();
    error CollectionNotAllowed();
    error CollectionOrTokenNotAllowed();
    error EthTransferFailed();
    error IncorrectPayment();
    error InvalidListingExpiration();
    error InvalidPrice();
    error InvalidRoyaltyAmount();
    error InvalidSelection();
    error IsPaused();
    error ListingExpired();
    error NotApproved();
    error NoBidExists();
    error NotListed();
    error NotListingOwner();
    error NotPrivateBuyer();
    error NotTokenOwner();
    error Sanctioned();
    error TokenNotInSelection();
    error ZeroAddress();
    error ZeroLengthArray();

    /////////////////////////////////////////////////////////////////////
    // MODIFIERS
    /////////////////////////////////////////////////////////////////////

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    /////////////////////////////////////////////////////////////////////
    // CONSTRUCTOR
    /////////////////////////////////////////////////////////////////////

    constructor(address initOwner, address initRoyaltyModel, address initSanctionsList) Ownable(initOwner) {
        if (initRoyaltyModel == address(0)) revert ZeroAddress();
        royaltyModel = initRoyaltyModel;
        sanctionsList = initSanctionsList;
    }

    /////////////////////////////////////////////////////////////////////
    // LISTING FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice List an NFT for sale
    /// @dev Listings should be one at a time - cleaner UX.
    /// @dev This can be used to update a listing or override an existing listing that may have been created by a previous owner.
    function list(address collection, uint256 tokenId, uint256 price, uint64 expiresAt, address buyer)
        external
        nonReentrant
        whenNotPaused
    {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionOrTokenAllowed(collection, tokenId);
        if (price == 0) revert InvalidPrice();
        if (expiresAt < block.timestamp) revert InvalidListingExpiration();
        if (expiresAt - uint64(block.timestamp) > MAX_LISTING_DURATION) revert InvalidListingExpiration();

        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();

        // effects
        listings[collection][tokenId] = Listing({seller: msg.sender, expiresAt: expiresAt, price: price, buyer: buyer});

        emit Listed(collection, tokenId, msg.sender, price, expiresAt, buyer);
    }

    /// @notice Extend listing(s)
    /// @dev Compatible with batch operations for UX benefits and allows extended expired listings
    /// @dev Extends all token listings to `expiresAt` for simplicity
    /// @dev Requires the seller to still own and have approved each token, matching `list`, so a stale listing left
    ///      behind after a transfer cannot be kept alive
    function extendListings(Token[] calldata tokens, uint64 expiresAt) external nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        uint256 num = tokens.length;
        if (num == 0) revert ZeroLengthArray();

        if (expiresAt < block.timestamp) revert InvalidListingExpiration();
        if (expiresAt - uint64(block.timestamp) > MAX_LISTING_DURATION) revert InvalidListingExpiration();

        // effects
        for (uint256 i = 0; i < num; ++i) {
            Token memory token = tokens[i];
            _checkCollectionOrTokenAllowed(token.collection, token.tokenId);
            Listing storage listing = listings[token.collection][token.tokenId];
            if (listing.seller != msg.sender) revert NotListingOwner(); // this is triggered if the token isn't listed

            IERC721 nft = IERC721(token.collection);
            if (nft.ownerOf(token.tokenId) != msg.sender) revert NotTokenOwner();
            if (!_isApproved(nft, msg.sender, token.tokenId)) revert NotApproved();

            listing.expiresAt = expiresAt;

            emit Listed(token.collection, token.tokenId, msg.sender, listing.price, expiresAt, listing.buyer);
        }
    }

    /// @notice Remove listing(s)
    /// @dev Compatible with batch operations for UX benefits. Always allowed, even when paused.
    /// @dev Does not check sanctions as listing does not escrow assets so sanctioned addresses should be able to delist.
    function delist(Token[] calldata tokens) external nonReentrant {
        // checks
        uint256 num = tokens.length;
        if (num == 0) revert ZeroLengthArray();

        // effects
        for (uint256 i = 0; i < num; ++i) {
            _delist(msg.sender, tokens[i].collection, tokens[i].tokenId);
        }
    }

    /// @notice Buy a listed NFT
    function buy(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionOrTokenAllowed(collection, tokenId);
        Listing memory listing = listings[collection][tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (listing.buyer != address(0) && msg.sender != listing.buyer) revert NotPrivateBuyer();
        _checkSanctionsList(listing.seller);
        _checkListingNotExpired(listing.expiresAt);
        if (msg.value != listing.price) revert IncorrectPayment();

        IERC721 nft = IERC721(collection);

        // effects
        delete listings[collection][tokenId];

        // interactions
        (address royaltyRecipient, uint256 royaltyAmount) = _getRoyaltyInfo(collection, tokenId, listing.price);
        _settleSale(nft, tokenId, listing.seller, msg.sender, listing.price, royaltyRecipient, royaltyAmount);

        emit Sold(collection, tokenId, msg.sender, listing.seller, listing.price, royaltyAmount);
    }

    /////////////////////////////////////////////////////////////////////
    // BID FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Place a token, collection, or selection bid
    /// @dev A selection bid's `selectionRoot` is the Merkle root of the selected tokens (see `isInSelection` for the
    ///      leaf format). The contract does not know a selection's contents, so eligibility is checked per token
    ///      when the bid is accepted.
    /// @param bidSelector The bid type and its identifying fields
    /// @param expiresAt Expiry timestamp (0 = no expiry)
    function placeBid(BidSelector calldata bidSelector, uint64 expiresAt) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        if (msg.value == 0) revert InvalidPrice();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        if (bidSelector.bidType == BidType.TOKEN) {
            _checkCollectionOrTokenAllowed(bidSelector.collection, bidSelector.tokenId);
            if (tokenBids[msg.sender][bidSelector.collection][bidSelector.tokenId].amount > 0) {
                revert BidAlreadyExists();
            }
            tokenBids[msg.sender][bidSelector.collection][bidSelector.tokenId] =
                Bid({amount: uint192(msg.value), expiresAt: expiresAt});
            emit BidPlaced(
                BidType.TOKEN, bidSelector.collection, msg.sender, bidSelector.tokenId, 0, msg.value, expiresAt
            );
        } else if (bidSelector.bidType == BidType.COLLECTION) {
            _checkCollectionAllowed(bidSelector.collection);
            if (collectionBids[msg.sender][bidSelector.collection].amount > 0) revert BidAlreadyExists();
            collectionBids[msg.sender][bidSelector.collection] = Bid({amount: uint192(msg.value), expiresAt: expiresAt});
            emit BidPlaced(BidType.COLLECTION, bidSelector.collection, msg.sender, 0, 0, msg.value, expiresAt);
        } else {
            if (bidSelector.selectionRoot == bytes32(0)) revert InvalidSelection();
            if (selectionBids[msg.sender][bidSelector.selectionRoot].amount > 0) revert BidAlreadyExists();
            selectionBids[msg.sender][bidSelector.selectionRoot] =
                Bid({amount: uint192(msg.value), expiresAt: expiresAt});
            emit BidPlaced(
                BidType.SELECTION, address(0), msg.sender, 0, bidSelector.selectionRoot, msg.value, expiresAt
            );
        }
    }

    /// @notice Increase an existing token, collection, or selection bid
    /// @dev Prevents increasing an expired bid
    /// @param bidSelector The bid type and its identifying fields
    function increaseBid(BidSelector calldata bidSelector) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        if (msg.value == 0) revert InvalidPrice();

        // effects
        if (bidSelector.bidType == BidType.TOKEN) {
            _checkCollectionOrTokenAllowed(bidSelector.collection, bidSelector.tokenId);
            Bid storage tokenBid = tokenBids[msg.sender][bidSelector.collection][bidSelector.tokenId];
            if (tokenBid.amount == 0) revert NoBidExists();
            _checkBidNotExpired(tokenBid.expiresAt);
            tokenBid.amount += uint192(msg.value);
            emit BidIncreased(
                BidType.TOKEN, bidSelector.collection, msg.sender, bidSelector.tokenId, 0, tokenBid.amount
            );
        } else if (bidSelector.bidType == BidType.COLLECTION) {
            _checkCollectionAllowed(bidSelector.collection);
            Bid storage collectionBid = collectionBids[msg.sender][bidSelector.collection];
            if (collectionBid.amount == 0) revert NoBidExists();
            _checkBidNotExpired(collectionBid.expiresAt);
            collectionBid.amount += uint192(msg.value);
            emit BidIncreased(BidType.COLLECTION, bidSelector.collection, msg.sender, 0, 0, collectionBid.amount);
        } else {
            Bid storage selectionBid = selectionBids[msg.sender][bidSelector.selectionRoot];
            if (selectionBid.amount == 0) revert NoBidExists();
            _checkBidNotExpired(selectionBid.expiresAt);
            selectionBid.amount += uint192(msg.value);
            emit BidIncreased(
                BidType.SELECTION, address(0), msg.sender, 0, bidSelector.selectionRoot, selectionBid.amount
            );
        }
    }

    /// @notice Accept a token, collection, or selection bid by selling an NFT to the bidder
    /// @dev Frontrunning is prevented with `minAmount`
    /// @dev For selection bids, `proof` must show that `(collection, tokenId)` is in the selection. A single-token
    ///      selection takes an empty proof. Token and collection bids ignore `proof`; pass an empty array.
    /// @param bidSelector The bid type, collection, fulfillment token id, and optional selection root
    /// @param bidder The address that placed the bid
    /// @param minAmount The minimum acceptable bid amount
    /// @param proof Merkle proof of selection membership (selection bids only)
    function acceptBid(BidSelector calldata bidSelector, address bidder, uint256 minAmount, bytes32[] calldata proof)
        external
        nonReentrant
        whenNotPaused
    {
        BidSelector memory selector = bidSelector; // one calldata decode instead of one per field read
        // checks
        _checkSanctionsList(msg.sender);
        _checkSanctionsList(bidder);
        Bid memory bid;
        if (selector.bidType == BidType.TOKEN) {
            _checkCollectionOrTokenAllowed(selector.collection, selector.tokenId);
            bid = tokenBids[bidder][selector.collection][selector.tokenId];
        } else if (selector.bidType == BidType.COLLECTION) {
            _checkCollectionAllowed(selector.collection);
            bid = collectionBids[bidder][selector.collection];
        } else {
            _checkCollectionOrTokenAllowed(selector.collection, selector.tokenId);
            if (!_isInSelection(selector.selectionRoot, selector.collection, selector.tokenId, proof)) {
                revert TokenNotInSelection();
            }
            bid = selectionBids[bidder][selector.selectionRoot];
        }
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);
        if (bid.amount < minAmount) revert BidTooLow();

        IERC721 nft = IERC721(selector.collection);

        // effects
        if (selector.bidType == BidType.TOKEN) {
            delete tokenBids[bidder][selector.collection][selector.tokenId];
        } else if (selector.bidType == BidType.COLLECTION) {
            delete collectionBids[bidder][selector.collection];
        } else {
            delete selectionBids[bidder][selector.selectionRoot];
        }
        _clearListing(selector.collection, selector.tokenId); // avoids stale listing attack

        // interactions
        (address royaltyRecipient, uint256 royaltyAmount) =
            _getRoyaltyInfo(selector.collection, selector.tokenId, bid.amount);
        _settleSale(nft, selector.tokenId, msg.sender, bidder, bid.amount, royaltyRecipient, royaltyAmount);

        bytes32 selectionRoot = selector.bidType == BidType.SELECTION ? selector.selectionRoot : bytes32(0);
        emit BidAccepted(
            selector.bidType,
            selector.collection,
            bidder,
            selector.tokenId,
            selectionRoot,
            msg.sender,
            bid.amount,
            royaltyAmount
        );
    }

    /////////////////////////////////////////////////////////////////////
    // BATCH BID FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Extend bid(s)
    /// @dev Allows extending expired bids rather than canceling and re-bidding
    /// @dev All bids share the same `expiresAt` for simplicity
    /// @dev Selection bids are not re-checked against the allowlist here; eligibility is enforced per token on acceptance
    function extendBids(BidSelector[] calldata bidSelectors, uint64 expiresAt) external nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        uint256 num = bidSelectors.length;
        if (num == 0) revert ZeroLengthArray();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        for (uint256 i = 0; i < num; ++i) {
            BidSelector memory bs = bidSelectors[i];
            if (bs.bidType == BidType.TOKEN) {
                // token bid
                _checkCollectionOrTokenAllowed(bs.collection, bs.tokenId);
                Bid storage tokenBid = tokenBids[msg.sender][bs.collection][bs.tokenId];
                if (tokenBid.amount == 0) revert NoBidExists();
                tokenBid.expiresAt = expiresAt;
                emit BidExtended(BidType.TOKEN, bs.collection, msg.sender, bs.tokenId, 0, expiresAt);
            } else if (bs.bidType == BidType.COLLECTION) {
                // collection bid
                _checkCollectionAllowed(bs.collection);
                Bid storage collectionBid = collectionBids[msg.sender][bs.collection];
                if (collectionBid.amount == 0) revert NoBidExists();
                collectionBid.expiresAt = expiresAt;
                emit BidExtended(BidType.COLLECTION, bs.collection, msg.sender, 0, 0, expiresAt);
            } else {
                // selection bid
                Bid storage selectionBid = selectionBids[msg.sender][bs.selectionRoot];
                if (selectionBid.amount == 0) revert NoBidExists();
                selectionBid.expiresAt = expiresAt;
                emit BidExtended(BidType.SELECTION, address(0), msg.sender, 0, bs.selectionRoot, expiresAt);
            }
        }
    }

    /// @notice Cancels bid(s)
    /// @dev Compatible with batch cancellation for UX ease. Always possible to cancel, even when paused (except if sanctioned).
    function cancelBids(BidSelector[] calldata bidSelectors) external nonReentrant {
        // checks
        _checkSanctionsList(msg.sender);
        uint256 num = bidSelectors.length;
        if (num == 0) revert ZeroLengthArray();

        // effects
        uint192 totalBidAmount = 0;
        for (uint256 i = 0; i < num; ++i) {
            BidSelector memory bs = bidSelectors[i];

            if (bs.bidType == BidType.TOKEN) {
                // token bid
                totalBidAmount += _cancelTokenBid(msg.sender, bs.collection, bs.tokenId);
            } else if (bs.bidType == BidType.COLLECTION) {
                // collection bid
                totalBidAmount += _cancelCollectionBid(msg.sender, bs.collection);
            } else {
                // selection bid
                totalBidAmount += _cancelSelectionBid(msg.sender, bs.selectionRoot);
            }
        }

        // interactions
        _safeTransferEth(msg.sender, totalBidAmount);
    }

    /////////////////////////////////////////////////////////////////////
    // ADMIN FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Toggle marketplace pause state (only delist and cancel functions work when paused)
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseToggled(paused_);
    }

    /// @notice Add a collection to the allowlist
    function addCollection(address collection) external onlyOwner {
        allowedCollections[collection] = true;
        emit CollectionAdded(collection);
    }

    /// @notice Remove a collection from the allowlist
    function removeCollection(address collection) external onlyOwner {
        allowedCollections[collection] = false;
        emit CollectionRemoved(collection);
    }

    /// @notice Add a shared collection token to the token allowlist
    /// @dev Only needed for tokens whose collection is not allowed
    function addToken(address collection, uint256 tokenId) external onlyOwner {
        allowedTokens[collection][tokenId] = true;
        emit TokenAdded(collection, tokenId);
    }

    /// @notice Remove a shared collection token from the token allowlist
    /// @dev Not a blocklist - a token in an allowed collection stays tradable after removal
    function removeToken(address collection, uint256 tokenId) external onlyOwner {
        allowedTokens[collection][tokenId] = false;
        emit TokenRemoved(collection, tokenId);
    }

    /// @notice Update royalty model
    function setRoyaltyModel(address newRoyaltyModel) external onlyOwner {
        if (newRoyaltyModel == address(0)) revert ZeroAddress();
        address oldRoyaltyModel = royaltyModel;
        royaltyModel = newRoyaltyModel;
        emit RoyaltyModelUpdated(oldRoyaltyModel, newRoyaltyModel);
    }

    /// @notice Update sanctions list address
    function setSanctionsList(address newSanctionsList) external onlyOwner {
        address oldSanctionsList = sanctionsList;
        sanctionsList = newSanctionsList;

        emit SanctionsListUpdated(oldSanctionsList, newSanctionsList);
    }

    /// @notice Update the base URI where selection Merkle trees are published
    /// @dev Informational only - settlement never reads it. Include the trailing separator (e.g. `.../merkle/`).
    function setSelectionBaseUri(string calldata newSelectionBaseUri) external onlyOwner {
        string memory oldSelectionBaseUri = selectionBaseUri;
        selectionBaseUri = newSelectionBaseUri;

        emit SelectionBaseUriUpdated(oldSelectionBaseUri, newSelectionBaseUri);
    }

    /////////////////////////////////////////////////////////////////////
    // VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Whether a Merkle proof shows a token is in a selection
    /// @dev Membership only - does not check the allowlist. Leaves follow the OpenZeppelin standard Merkle tree
    ///      format: `keccak256(bytes.concat(keccak256(abi.encode(collection, tokenId))))`, with sorted-pair hashing.
    function isInSelection(bytes32 selectionRoot, address collection, uint256 tokenId, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        return _isInSelection(selectionRoot, collection, tokenId, proof);
    }

    /// @notice Where to fetch the Merkle tree behind a selection root
    /// @dev Returns `selectionBaseUri` followed by the root as `0x`-prefixed lowercase hex (66 characters), or an
    ///      empty string when no base URI is set. Does not check that the tree exists or that any bid uses the root.
    ///      A fetched tree is self-verifying: integrators should recompute its root and compare.
    function selectionUri(bytes32 selectionRoot) external view returns (string memory) {
        string memory baseUri = selectionBaseUri;
        if (bytes(baseUri).length == 0) return "";
        return string.concat(baseUri, Strings.toHexString(uint256(selectionRoot), 32));
    }

    /////////////////////////////////////////////////////////////////////
    // INTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @dev Helper for the modifier to reduce code size
    function _whenNotPaused() internal view {
        if (paused) revert IsPaused();
    }

    function _checkSanctionsList(address user) internal view {
        if (sanctionsList != address(0)) {
            if (ISanctionsList(sanctionsList).isSanctioned(user)) revert Sanctioned();
        }
    }

    /// @dev Helper for checking if a collection is allowed
    function _checkCollectionAllowed(address collection) internal view {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
    }

    /// @dev Helper for checking if a collection or token is allowed
    function _checkCollectionOrTokenAllowed(address collection, uint256 tokenId) internal view {
        if (!allowedCollections[collection] && !allowedTokens[collection][tokenId]) {
            revert CollectionOrTokenNotAllowed();
        }
    }

    /// @dev Check if marketplace is approved to transfer the token
    function _isApproved(IERC721 nft, address owner, uint256 tokenId) internal view returns (bool) {
        return nft.isApprovedForAll(owner, address(this)) || nft.getApproved(tokenId) == address(this);
    }

    /// @dev Revert if a listing has expired
    function _checkListingNotExpired(uint64 expiresAt) internal view {
        if (block.timestamp > expiresAt) revert ListingExpired();
    }

    /// @dev Revert if a bid has expired
    function _checkBidNotExpired(uint64 expiresAt) internal view {
        if (expiresAt != 0 && block.timestamp > expiresAt) revert BidExpired();
    }

    /// @dev Merkle membership check for a selection
    function _isInSelection(bytes32 selectionRoot, address collection, uint256 tokenId, bytes32[] calldata proof)
        internal
        pure
        returns (bool)
    {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(collection, tokenId))));
        return MerkleProof.verifyCalldata(proof, selectionRoot, leaf);
    }

    /// @dev Clears a listing
    function _clearListing(address collection, uint256 tokenId) internal {
        address seller = listings[collection][tokenId].seller;
        if (seller != address(0)) {
            delete listings[collection][tokenId];
            emit Delisted(collection, tokenId, seller);
        }
    }

    /// @dev Sends ETH, capping gas at 100_000 gas, reverting upon failure
    function _safeTransferEth(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount, gas: 1e5}("");
        if (!success) revert EthTransferFailed();
    }

    /// @dev Delist an NFT
    function _delist(address sender, address collection, uint256 tokenId) internal {
        // checks
        Listing storage listing = listings[collection][tokenId];
        if (listing.seller != sender) revert NotListingOwner();

        // effects
        delete listings[collection][tokenId];

        emit Delisted(collection, tokenId, sender);
    }

    /// @dev Cancel a token bid and withdraw funds
    function _cancelTokenBid(address sender, address collection, uint256 tokenId) internal returns (uint192 bidAmount) {
        bidAmount = tokenBids[sender][collection][tokenId].amount;
        if (bidAmount == 0) revert NoBidExists();

        delete tokenBids[sender][collection][tokenId];

        emit BidCanceled(BidType.TOKEN, collection, sender, tokenId, 0);
    }

    /// @dev Cancel a collection bid and withdraw funds
    function _cancelCollectionBid(address sender, address collection) internal returns (uint192 bidAmount) {
        bidAmount = collectionBids[sender][collection].amount;
        if (bidAmount == 0) revert NoBidExists();

        delete collectionBids[sender][collection];

        emit BidCanceled(BidType.COLLECTION, collection, sender, 0, 0);
    }

    /// @dev Cancel a selection bid and withdraw funds
    function _cancelSelectionBid(address sender, bytes32 selectionRoot) internal returns (uint192 bidAmount) {
        bidAmount = selectionBids[sender][selectionRoot].amount;
        if (bidAmount == 0) revert NoBidExists();

        delete selectionBids[sender][selectionRoot];

        emit BidCanceled(BidType.SELECTION, address(0), sender, 0, selectionRoot);
    }

    /// @dev Get the current royalty recipient and royalty amount for a sale
    function _getRoyaltyInfo(address collection, uint256 tokenId, uint256 salePrice)
        internal
        view
        returns (address recipient, uint256 royaltyAmount)
    {
        return LuciRoyaltyModel(royaltyModel).calculateRoyalty(collection, tokenId, salePrice, NATIVE_CURRENCY);
    }

    /// @dev Settle a sale using royalty information resolved by the caller.
    ///      Caps royalty at 10% and rejects a zero recipient when the royalty amount is positive.
    ///      Uses `transferFrom` as a contract purchasing should be able to receive ERC-721 tokens and the liability falls on the buyer.
    function _settleSale(
        IERC721 nft,
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 salePrice,
        address royaltyRecipient,
        uint256 royaltyAmount
    ) internal {
        if (royaltyAmount > Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS)) {
            revert InvalidRoyaltyAmount();
        }
        if (royaltyAmount > 0 && royaltyRecipient == address(0)) revert ZeroAddress();
        uint256 sellerProceeds = salePrice - royaltyAmount;

        if (royaltyAmount > 0) {
            _checkSanctionsList(royaltyRecipient);
        }

        // Transfer NFT
        nft.transferFrom(seller, buyer, tokenId);

        // Transfer payments
        if (royaltyAmount > 0) {
            _safeTransferEth(royaltyRecipient, royaltyAmount);
        }
        _safeTransferEth(seller, sellerProceeds);
    }
}
