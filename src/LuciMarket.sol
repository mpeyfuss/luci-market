// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts-5.6.1/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721.sol";
import {LuciRoyaltyModel} from "./LuciRoyaltyModel.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";

/// @title Luci Market
/// @notice A marketplace for buying and selling allowlisted ERC721 tokens
/// @dev Supports listings, collection bids, token bids, and trait bids
/// @author mpeyfuss
/// @author rhynotic
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
        TRAIT
    }

    struct BidSelector {
        BidType bidType;
        address collection;
        uint256 tokenId;
        uint256 traitKey;
    }

    /////////////////////////////////////////////////////////////////////
    // STORAGE
    /////////////////////////////////////////////////////////////////////

    /// @notice Maximum listing duration to avoid stale listings
    uint256 public constant MAX_LISTING_DURATION = 180 days;

    /// @notice Whether the marketplace is paused
    bool public paused;

    /// @notice Royalty model
    address public royaltyModel;

    /// @notice Chainalysis Sanctions List
    address public sanctionsList;

    /// @notice Collections that can be traded
    mapping(address collection => bool) public allowedCollections;

    /// @notice Token override for shared contracts - these tokens are not eligible for collection/trait bids
    mapping(address collection => mapping(uint256 tokenId => bool)) public allowedTokens;

    /// @notice Collections trait config
    mapping(address collection => uint32) public collectionTraitConfigs;

    /// @notice Listings: collection => tokenId => Listing
    mapping(address collection => mapping(uint256 tokenId => Listing)) public listings;

    /// @notice Collection bids: bidder => collection => Bid
    mapping(address bidder => mapping(address collection => Bid)) public collectionBids;

    /// @notice Token bids: bidder => collection => tokenId => Bid
    mapping(address bidder => mapping(address collection => mapping(uint256 tokenId => Bid))) public tokenBids;

    /// @notice Trait bids: bidder => collection => traitKey => Bid
    mapping(address bidder => mapping(address collection => mapping(uint256 traitKey => Bid))) public traitBids;

    /// @notice Token traits: collection => tokenId => encoded traits
    mapping(address collection => mapping(uint256 tokenId => uint32)) public tokenTraits;

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

    event CollectionBidPlaced(address indexed collection, address indexed bidder, uint256 amount, uint64 expiresAt);
    event CollectionBidIncreased(address indexed collection, address indexed bidder, uint256 newAmount);
    event CollectionBidExtended(address indexed collection, address indexed bidder, uint64 newExpiresAt);
    event CollectionBidCanceled(address indexed collection, address indexed bidder);
    event CollectionBidAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address indexed bidder,
        uint256 price,
        uint256 royaltyAmount
    );

    event TokenBidPlaced(
        address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 amount, uint64 expiresAt
    );
    event TokenBidIncreased(
        address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 newAmount
    );
    event TokenBidExtended(
        address indexed collection, uint256 indexed tokenId, address indexed bidder, uint64 newExpiresAt
    );
    event TokenBidCanceled(address indexed collection, uint256 indexed tokenId, address indexed bidder);
    event TokenBidAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address indexed bidder,
        uint256 price,
        uint256 royaltyAmount
    );

    event TraitBidPlaced(
        address indexed collection, uint256 indexed traitKey, address indexed bidder, uint256 amount, uint64 expiresAt
    );
    event TraitBidIncreased(
        address indexed collection, uint256 indexed traitKey, address indexed bidder, uint256 newAmount
    );
    event TraitBidExtended(
        address indexed collection, uint256 indexed traitKey, address indexed bidder, uint64 newExpiresAt
    );
    event TraitBidCanceled(address indexed collection, uint256 indexed traitKey, address indexed bidder);
    event TraitBidAccepted(
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address indexed bidder,
        uint256 traitKey,
        uint256 price,
        uint256 royaltyAmount
    );

    event CollectionAdded(address indexed collection);
    event CollectionRemoved(address indexed collection);
    event CollectionTraitConfigSet(address indexed collection, uint32 config);
    event CollectionMinHoldTimeSet(address indexed collection, uint64 minHoldTime);
    event TraitsSet(address indexed collection, uint256[] tokenIds, uint32[] traits);
    event PauseToggled(bool paused);
    event RoyaltyModelUpdated(address indexed oldRoyaltyModel, address indexed newRoyaltyModel);
    event SanctionsListUpdated(address indexed oldSanctionsList, address indexed newSanctionsList);
    event TokenAdded(address indexed collection, uint256 indexed tokenId);
    event TokenRemoved(address indexed collection, uint256 indexed tokenId);

    /////////////////////////////////////////////////////////////////////
    // ERRORS
    /////////////////////////////////////////////////////////////////////

    error ArrayLengthMismatch();
    error BidAlreadyExists();
    error BidExpired();
    error BidTooLow();
    error CollectionNotAllowed();
    error CollectionOrTokenNotAllowed();
    error EthTransferFailed();
    error IncorrectPayment();
    error InvalidListingExpiration();
    error InvalidPrice();
    error InvalidTraitKey();
    error IsPaused();
    error ListingExpired();
    error ListingOwnerNotTokenOwner();
    error MinHoldTimeTooLong();
    error NotApproved();
    error NoBidExists();
    error NotListed();
    error NotListingOwner();
    error NotPrivateBuyer();
    error NotTokenOwner();
    error Sanctioned();
    error TraitMismatch();
    error TraitNotSet();
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
            if (listing.seller != msg.sender) revert NotListingOwner();

            listing.expiresAt = expiresAt;

            emit Listed(token.collection, token.tokenId, msg.sender, listing.price, expiresAt, listing.buyer);
        }
    }

    /// @notice Remove listing(s)
    /// @dev Compatible with batch operations for UX benefits. Always allowed, even when paused.
    function delist(Token[] calldata tokens) external nonReentrant {
        // checks
        _checkSanctionsList(msg.sender);
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
        if (nft.ownerOf(tokenId) != listing.seller) revert ListingOwnerNotTokenOwner(); // verify seller still owns the NFT

        // effects
        delete listings[collection][tokenId];

        // interactions
        uint256 royalty = _settleSale(nft, collection, tokenId, listing.seller, msg.sender, listing.price);

        emit Sold(collection, tokenId, msg.sender, listing.seller, listing.price, royalty);
    }

    /////////////////////////////////////////////////////////////////////
    // TOKEN BID FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Place a bid on a specific token
    function placeTokenBid(address collection, uint256 tokenId, uint64 expiresAt)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionOrTokenAllowed(collection, tokenId);
        if (msg.value == 0) revert InvalidPrice();
        if (tokenBids[msg.sender][collection][tokenId].amount > 0) revert BidAlreadyExists();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        tokenBids[msg.sender][collection][tokenId] = Bid({amount: uint192(msg.value), expiresAt: expiresAt});

        emit TokenBidPlaced(collection, tokenId, msg.sender, msg.value, expiresAt);
    }

    /// @notice Increase an existing token bid
    /// @dev Prevents increasing an expired bid
    function increaseTokenBid(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionOrTokenAllowed(collection, tokenId);
        if (msg.value == 0) revert InvalidPrice();

        Bid storage bid = tokenBids[msg.sender][collection][tokenId];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);

        // effects
        uint192 newAmount = bid.amount + uint192(msg.value);
        bid.amount = newAmount;

        emit TokenBidIncreased(collection, tokenId, msg.sender, newAmount);
    }

    /// @notice Accept a token bid by selling your NFT to the bidder
    /// @dev Frontrunning is prevented with `minAmount`
    function acceptTokenBid(address collection, uint256 tokenId, address bidder, uint256 minAmount)
        external
        nonReentrant
        whenNotPaused
    {
        // checks
        _checkSanctionsList(msg.sender);
        _checkSanctionsList(bidder);
        _checkCollectionOrTokenAllowed(collection, tokenId);
        Bid memory bid = tokenBids[bidder][collection][tokenId];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);
        if (bid.amount < minAmount) revert BidTooLow();

        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();

        // effects
        delete tokenBids[bidder][collection][tokenId];
        _clearListing(collection, tokenId);

        // interactions
        uint256 royalty = _settleSale(nft, collection, tokenId, msg.sender, bidder, bid.amount);

        emit TokenBidAccepted(collection, tokenId, msg.sender, bidder, bid.amount, royalty);
    }

    /////////////////////////////////////////////////////////////////////
    // COLLECTION BID FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Place a standing bid for any NFT in a collection
    function placeCollectionBid(address collection, uint64 expiresAt) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionAllowed(collection);
        if (msg.value == 0) revert InvalidPrice();
        if (collectionBids[msg.sender][collection].amount > 0) revert BidAlreadyExists();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        collectionBids[msg.sender][collection] = Bid({amount: uint192(msg.value), expiresAt: expiresAt});

        emit CollectionBidPlaced(collection, msg.sender, msg.value, expiresAt);
    }

    /// @notice Increase an existing collection bid
    /// @dev Prevents increasing an expired bid
    function increaseCollectionBid(address collection) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionAllowed(collection);
        if (msg.value == 0) revert InvalidPrice();

        Bid storage bid = collectionBids[msg.sender][collection];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);

        // effects
        uint192 newAmount = bid.amount + uint192(msg.value);
        bid.amount = newAmount;

        emit CollectionBidIncreased(collection, msg.sender, newAmount);
    }

    /// @notice Accept a collection bid by selling your NFT to the bidder
    /// @dev Frontrunning is prevented with `minAmount`
    function acceptCollectionBid(address collection, uint256 tokenId, address bidder, uint256 minAmount)
        external
        nonReentrant
        whenNotPaused
    {
        // checks
        _checkSanctionsList(msg.sender);
        _checkSanctionsList(bidder);
        _checkCollectionAllowed(collection);
        Bid memory bid = collectionBids[bidder][collection];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);
        if (bid.amount < minAmount) revert BidTooLow();

        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();

        // effects
        delete collectionBids[bidder][collection];
        _clearListing(collection, tokenId);

        // interactions
        uint256 royalty = _settleSale(nft, collection, tokenId, msg.sender, bidder, bid.amount);

        emit CollectionBidAccepted(collection, tokenId, msg.sender, bidder, bid.amount, royalty);
    }

    /////////////////////////////////////////////////////////////////////
    // TRAIT BID FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Place a bid matching tokens by trait
    /// @param collection The collection address
    /// @param traitKey Encoded traits filter
    /// @param expiresAt Expiry timestamp (0 = no expiry)
    function placeTraitBid(address collection, uint256 traitKey, uint64 expiresAt)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionAllowed(collection);
        if (msg.value == 0) revert InvalidPrice();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();
        if (!_validateTraitKey(traitKey, collectionTraitConfigs[collection])) revert InvalidTraitKey();
        if (traitBids[msg.sender][collection][traitKey].amount > 0) revert BidAlreadyExists();

        // effects
        traitBids[msg.sender][collection][traitKey] = Bid({amount: uint192(msg.value), expiresAt: expiresAt});

        emit TraitBidPlaced(collection, traitKey, msg.sender, msg.value, expiresAt);
    }

    /// @notice Increase an existing trait bid
    /// @dev Prevents increasing an expired bid
    function increaseTraitBid(address collection, uint256 traitKey) external payable nonReentrant whenNotPaused {
        // checks
        _checkSanctionsList(msg.sender);
        _checkCollectionAllowed(collection);
        if (!_validateTraitKey(traitKey, collectionTraitConfigs[collection])) revert InvalidTraitKey();
        if (msg.value == 0) revert InvalidPrice();

        Bid storage bid = traitBids[msg.sender][collection][traitKey];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);

        // effects
        uint192 newAmount = bid.amount + uint192(msg.value);
        bid.amount = newAmount;

        emit TraitBidIncreased(collection, traitKey, msg.sender, newAmount);
    }

    /// @notice Accept a trait bid by selling your NFT to the bidder
    /// @dev Frontrunning is prevented with `minAmount`
    function acceptTraitBid(address collection, uint256 tokenId, address bidder, uint256 traitKey, uint256 minAmount)
        external
        nonReentrant
        whenNotPaused
    {
        // checks
        _checkSanctionsList(msg.sender);
        _checkSanctionsList(bidder);
        _checkCollectionAllowed(collection);
        Bid memory bid = traitBids[bidder][collection][traitKey];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);
        if (bid.amount < minAmount) revert BidTooLow();
        if (!_validateTraitKey(traitKey, collectionTraitConfigs[collection])) revert InvalidTraitKey();
        uint32 traits = tokenTraits[collection][tokenId];
        if (!_matchesTraitBid(traits, traitKey)) revert TraitMismatch();

        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();

        // effects
        delete traitBids[bidder][collection][traitKey];
        _clearListing(collection, tokenId);

        // interactions
        uint256 royalty = _settleSale(nft, collection, tokenId, msg.sender, bidder, bid.amount);

        emit TraitBidAccepted(collection, tokenId, msg.sender, bidder, traitKey, bid.amount, royalty);
    }

    /////////////////////////////////////////////////////////////////////
    // BATCH BID FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /// @notice Extend bid(s)
    /// @dev Allows extending expired bids rather than canceling and re-bidding
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
                emit TokenBidExtended(bs.collection, bs.tokenId, msg.sender, expiresAt);
            } else if (bs.bidType == BidType.COLLECTION) {
                // collection bid
                _checkCollectionAllowed(bs.collection);
                Bid storage collectionBid = collectionBids[msg.sender][bs.collection];
                if (collectionBid.amount == 0) revert NoBidExists();
                collectionBid.expiresAt = expiresAt;
                emit CollectionBidExtended(bs.collection, msg.sender, expiresAt);
            } else {
                // trait bid
                _checkCollectionAllowed(bs.collection);
                Bid storage traitBid = traitBids[msg.sender][bs.collection][bs.traitKey];
                if (traitBid.amount == 0) revert NoBidExists();
                traitBid.expiresAt = expiresAt;
                emit TraitBidExtended(bs.collection, bs.traitKey, msg.sender, expiresAt);
            }
        }
    }

    /// @notice Cancels bid(s)
    /// @dev Compatible with batch cancellation for UX ease. Always possible to cancel, even when paused.
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
                // trait bid
                totalBidAmount += _cancelTraitBid(msg.sender, bs.collection, bs.traitKey);
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

    /// @notice Add a shared collection token to the allowlist
    function addToken(address collection, uint256 tokenId) external onlyOwner {
        allowedTokens[collection][tokenId] = true;
        emit TokenAdded(collection, tokenId);
    }

    /// @notice Remove a shared collection token to the allowlist
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

    /// @notice Set a collection trait config (which traits are allowed)
    function setCollectionTraitsConfig(address collection, uint32 config) external onlyOwner {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        collectionTraitConfigs[collection] = config;

        emit CollectionTraitConfigSet(collection, config);
    }

    /// @notice Batch set traits for tokens in a collection
    /// @dev Since this is a priveledged function, it's expected that the traits include the properly
    ///      configured bit 7 for each trait in the encoded traits
    function setTraits(address collection, uint256[] calldata tokenIds, uint32[] calldata traitsArray)
        external
        onlyOwner
    {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (tokenIds.length != traitsArray.length) revert ArrayLengthMismatch();

        uint256 num = tokenIds.length;
        for (uint256 i = 0; i < num; ++i) {
            tokenTraits[collection][tokenIds[i]] = traitsArray[i];
        }

        emit TraitsSet(collection, tokenIds, traitsArray);
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
        if (!allowedCollections[collection] && !allowedTokens[collection][tokenId]) revert CollectionOrTokenNotAllowed();
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

    /// @dev Validates that a trait key only specifies enabled traits
    function _validateTraitKey(uint256 traitKey, uint32 collectionTraitConfig) internal pure returns (bool) {
        if (traitKey == 0) return false;
        for (uint256 i = 0; i < 4; ++i) {
            uint64 bitmap = uint64(traitKey >> (i * 64));
            bool slotEnabled = uint8(collectionTraitConfig >> (i * 8)) & 0x80 != 0;
            if (bitmap != 0 && !slotEnabled) return false; // bidding on disabled slot
        }
        return true;
    }

    /// @dev Check if a token's trait matches a trait bid key
    function _matchesTraitBid(uint32 traits, uint256 traitKey) internal pure returns (bool) {
        for (uint256 i = 0; i < 4; ++i) {
            uint64 bitmap = uint64(traitKey >> (i * 64));
            if (bitmap == 0) continue; // wildcard
            uint8 trait = uint8(traits >> (i * 8));
            if (trait & 0x80 == 0) revert TraitNotSet();
            uint8 index = trait & 0x3F; // bitwise and with b00111111 to get the bottom 6 bits only
            if (bitmap >> index & 1 == 0) return false; // shift bitmap down the steps to see if that slot is set to 1, which matches the token trait
        }
        // if gets here, the token has a desired trait from each trait.
        return true;
    }

    /// @dev Clears a listing
    function _clearListing(address collection, uint256 tokenId) internal {
        address seller = listings[collection][tokenId].seller;
        if (seller != address(0)) {
            delete listings[collection][tokenId];
            emit Delisted(collection, tokenId, seller);
        }
    }

    /// @dev Sends ETH, forwarding all gas, reverting upon failure
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

        emit TokenBidCanceled(collection, tokenId, sender);
    }

    /// @dev Cancel a collection bid and withdraw funds
    function _cancelCollectionBid(address sender, address collection) internal returns (uint192 bidAmount) {
        bidAmount = collectionBids[sender][collection].amount;
        if (bidAmount == 0) revert NoBidExists();

        delete collectionBids[sender][collection];

        emit CollectionBidCanceled(collection, sender);
    }

    /// @dev Cancel a trait bid and withdraw funds
    function _cancelTraitBid(address sender, address collection, uint256 traitKey)
        internal
        returns (uint192 bidAmount)
    {
        bidAmount = traitBids[sender][collection][traitKey].amount;
        if (bidAmount == 0) revert NoBidExists();

        delete traitBids[sender][collection][traitKey];

        emit TraitBidCanceled(collection, traitKey, sender);
    }

    /// @dev Settle a sale: calculate royalties, record sale, clear inquiries, transfer NFT and payments
    function _settleSale(
        IERC721 nft,
        address collection,
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 salePrice
    ) internal returns (uint256) {
        // Calculate royalties
        (address royaltyRecipient, uint256 royalty) = LuciRoyaltyModel(royaltyModel).calculateRoyalty(collection, tokenId, salePrice);
        uint256 sellerProceeds = salePrice - royalty;

        // Transfer NFT
        nft.safeTransferFrom(seller, buyer, tokenId);

        // Transfer payments
        if (royalty > 0) {
            _safeTransferEth(royaltyRecipient, royalty);
        }
        _safeTransferEth(seller, sellerProceeds);

        return royalty;
    }
}
