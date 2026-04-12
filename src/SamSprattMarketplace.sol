// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts-5.6.1/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721.sol";

/// @title SamSprattMarketplace
/// @notice A marketplace for buying and selling ERC721 tokens from the artist
/// @dev Supports listings, collection bids, token bids, and trait bids
/// @author rhynotic, mpeyfuss
contract SamSprattMarketplace is Ownable2Step, ReentrancyGuardTransient {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Listing {
        address seller;    // slot 0 (20 bytes)
        uint64 expiresAt;  // slot 0 (8 bytes)
        uint256 price;     // slot 1 (32 bytes)
    }

    struct Bid {
        uint192 amount;    // more than enough for any ETH amount
        uint64 expiresAt;  // 0 = no expiry
    }

    struct LastSale {
        address buyer;
        uint256 price;
    }

    struct Token {
        address collection;
        uint256 tokenId;
    }

    enum BidType { TOKEN, COLLECTION, TRAIT }

    struct BidSelector {
        BidType bidType;
        address collection;
        uint256 tokenId;
        uint256 traitKey;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis
    uint256 public constant BASIS = 10_000;

    /// @notice Maximum royalty percentage (10%)
    uint256 public constant MAX_ROYALTY_BPS = 1000;

    /// @notice Minimum royalty charged on any profitable resale (0.5%)
    uint256 public constant MIN_ROYALTY_BPS = 50; 

    /// @notice Maximum listing duration to avoid stale listings
    uint256 public constant MAX_LISTING_DURATION = 180 days;

    /// @notice Whether the marketplace is paused
    bool public paused;

    /// @notice Royalty recipient
    address public royaltyRecipient;

    /// @notice Whitelisted collections that can be traded
    mapping(address collection => bool) public allowedCollections;

    /// @notice Whitelisted collections that can be traded
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

    /// @notice Last sale info: collection => tokenId => LastSale
    mapping(address collection => mapping(uint256 tokenId => LastSale)) public lastSales;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Listed(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 price, uint64 expiresAt);
    event Delisted(address indexed collection, uint256 indexed tokenId, address indexed seller);
    event Sold(address indexed collection, uint256 indexed tokenId, address indexed buyer, address seller, uint256 price, uint256 royaltyAmount);

    event CollectionBidPlaced(address indexed collection, address indexed bidder, uint256 amount, uint64 expiresAt);
    event CollectionBidIncreased(address indexed collection, address indexed bidder, uint256 newAmount);
    event CollectionBidExtended(address indexed collection, address indexed bidder, uint64 newExpiresAt);
    event CollectionBidCanceled(address indexed collection, address indexed bidder);
    event CollectionBidAccepted(address indexed collection, uint256 indexed tokenId, address seller, address indexed bidder, uint256 price, uint256 royaltyAmount);

    event TokenBidPlaced(address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 amount, uint64 expiresAt);
    event TokenBidIncreased(address indexed collection, uint256 indexed tokenId, address indexed bidder, uint256 newAmount);
    event TokenBidExtended(address indexed collection, uint256 indexed tokenId, address indexed bidder, uint64 newExpiresAt);
    event TokenBidCanceled(address indexed collection, uint256 indexed tokenId, address indexed bidder);
    event TokenBidAccepted(address indexed collection, uint256 indexed tokenId, address seller, address indexed bidder, uint256 price, uint256 royaltyAmount);

    event TraitBidPlaced(address indexed collection, uint256 indexed traitKey, address indexed bidder, uint256 amount, uint64 expiresAt);
    event TraitBidIncreased(address indexed collection, uint256 indexed traitKey, address indexed bidder, uint256 newAmount);
    event TraitBidExtended(address indexed collection, uint256 indexed traitKey, address indexed bidder, uint64 newExpiresAt);
    event TraitBidCanceled(address indexed collection, uint256 indexed traitKey, address indexed bidder);
    event TraitBidAccepted(address indexed collection, uint256 indexed tokenId, address seller, address indexed bidder, uint256 traitKey, uint256 price, uint256 royaltyAmount);

    event CollectionAdded(address indexed collection);
    event CollectionRemoved(address indexed collection);
    event CollectionTraitConfigSet(address indexed collection, uint32 config);
    event TraitsSet(address indexed collection, uint256[] tokenIds, uint32[] traits);
    event RoyaltyRecipientUpdated(address newRecipient);
    event PauseToggled(bool paused);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ArrayLengthMismatch();
    error BidAlreadyExists();
    error BidExpired();
    error BidTooLow();
    error CollectionNotAllowed();
    error EthTransferFailed();
    error IncorrectPayment();
    error InvalidListingExpiration();
    error InvalidPrice();
    error InvalidTraitKey();
    error IsPaused();
    error ListingExpired();
    error ListingOwnerNotTokenOwner();
    error NotApproved();
    error NoBidExists();
    error NotListed();
    error NotListingOwner();
    error NotTokenOwner();
    error TraitMismatch();
    error TraitNotSet();
    error ZeroAddress();
    error ZeroLengthArray();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address initOwner, address initRoyaltyRecipient) Ownable(initOwner) {
        if (initRoyaltyRecipient == address(0)) revert ZeroAddress();
        royaltyRecipient = initRoyaltyRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                           OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Toggle marketplace pause state (only delist and cancel functions work when paused)
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseToggled(paused_);
    }

    /// @notice Add a collection to the whitelist
    function addCollection(address collection) external onlyOwner {
        allowedCollections[collection] = true;
        emit CollectionAdded(collection);
    }

    /// @notice Remove a collection from the whitelist
    function removeCollection(address collection) external onlyOwner {
        allowedCollections[collection] = false;
        emit CollectionRemoved(collection);
    }

    /// @notice Update royalty recipient
    function setRoyaltyRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        royaltyRecipient = newRecipient;
        emit RoyaltyRecipientUpdated(newRecipient);
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
    function setTraits(address collection, uint256[] calldata tokenIds, uint32[] calldata traitsArray) external onlyOwner {
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (tokenIds.length != traitsArray.length) revert ArrayLengthMismatch();

        uint256 num = tokenIds.length;
        for (uint256 i = 0; i < num; ++i) {
            tokenTraits[collection][tokenIds[i]] = traitsArray[i];
        }

        emit TraitsSet(collection, tokenIds, traitsArray);
    }

    /*//////////////////////////////////////////////////////////////
                          LISTING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice List an NFT for sale
    /// @dev Listings should be one at a time - cleaner UX.
    /// @dev This can be used to update a listing or override an existing listing that may have been created by a previous owner.
    function list(address collection, uint256 tokenId, uint256 price, uint64 expiresAt) external nonReentrant whenNotPaused {
        // checks
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (price == 0) revert InvalidPrice();
        if (expiresAt < block.timestamp) revert InvalidListingExpiration();
        if (expiresAt - uint64(block.timestamp) > MAX_LISTING_DURATION) revert InvalidListingExpiration();

        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();

        // effects
        listings[collection][tokenId] = Listing({
            seller: msg.sender,
            expiresAt: expiresAt,
            price: price
        });

        emit Listed(collection, tokenId, msg.sender, price, expiresAt);
    }

    /// @notice Extend listing(s)
    /// @dev Compatible with batch operations for UX benefits and allows extended expired listings
    function extendListings(Token[] calldata tokens, uint64 expiresAt) external nonReentrant whenNotPaused {
        // checks
        uint256 num = tokens.length;
        if (num == 0) revert ZeroLengthArray();

        if (expiresAt < block.timestamp) revert InvalidListingExpiration();
        if (expiresAt - uint64(block.timestamp) > MAX_LISTING_DURATION) revert InvalidListingExpiration();

        // effects
        for (uint256 i = 0; i < num; ++i) {
            Token memory token = tokens[i];
            Listing storage listing = listings[token.collection][token.tokenId];
            if (listing.seller != msg.sender) revert NotListingOwner();

            listing.expiresAt = expiresAt;

            emit Listed(token.collection, token.tokenId, msg.sender, listing.price, expiresAt);
        }
    }

    /// @notice Remove listing(s)
    /// @dev Compatible with batch operations for UX benefits. Always allowed, even when paused.
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
        Listing memory listing = listings[collection][tokenId];
        if (listing.seller == address(0)) revert NotListed();
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

    /*//////////////////////////////////////////////////////////////
                        TOKEN BID FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a bid on a specific token
    function placeTokenBid(address collection, uint256 tokenId, uint64 expiresAt) external payable nonReentrant whenNotPaused {
        // checks
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (msg.value == 0) revert InvalidPrice();
        if (tokenBids[msg.sender][collection][tokenId].amount > 0) revert BidAlreadyExists();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        tokenBids[msg.sender][collection][tokenId] = Bid({
            amount: uint192(msg.value),
            expiresAt: expiresAt
        });

        emit TokenBidPlaced(collection, tokenId, msg.sender, msg.value, expiresAt);
    }

    /// @notice Increase an existing token bid
    /// @dev Prevents increasing an expired bid
    function increaseTokenBid(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused {
        // checks
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
    function acceptTokenBid(address collection, uint256 tokenId, address bidder, uint256 minAmount) external nonReentrant whenNotPaused {
        // checks
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

    /*//////////////////////////////////////////////////////////////
                       COLLECTION BID FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a standing bid for any NFT in a collection
    function placeCollectionBid(address collection, uint64 expiresAt) external payable nonReentrant whenNotPaused {
        // checks
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (msg.value == 0) revert InvalidPrice();
        if (collectionBids[msg.sender][collection].amount > 0) revert BidAlreadyExists();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        collectionBids[msg.sender][collection] = Bid({
            amount: uint192(msg.value),
            expiresAt: expiresAt
        });

        emit CollectionBidPlaced(collection, msg.sender, msg.value, expiresAt);
    }

    /// @notice Increase an existing collection bid
    /// @dev Prevents increasing an expired bid
    function increaseCollectionBid(address collection) external payable nonReentrant whenNotPaused {
        // checks
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
    function acceptCollectionBid(address collection, uint256 tokenId, address bidder, uint256 minAmount) external nonReentrant whenNotPaused {
        // checks
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

    /*//////////////////////////////////////////////////////////////
                        TRAIT BID FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a bid matching tokens by trait
    /// @param collection The collection address
    /// @param traitKey Encoded traits filter
    /// @param expiresAt Expiry timestamp (0 = no expiry)
    function placeTraitBid(address collection, uint256 traitKey, uint64 expiresAt) external payable nonReentrant whenNotPaused {
        // checks
        if (!allowedCollections[collection]) revert CollectionNotAllowed();
        if (msg.value == 0) revert InvalidPrice();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();
        if (!_validateTraitKey(traitKey, collectionTraitConfigs[collection])) revert InvalidTraitKey();
        if (traitBids[msg.sender][collection][traitKey].amount > 0) revert BidAlreadyExists();

        // effects
        traitBids[msg.sender][collection][traitKey] = Bid({
            amount: uint192(msg.value),
            expiresAt: expiresAt
        });

        emit TraitBidPlaced(collection, traitKey, msg.sender, msg.value, expiresAt);
    }

    /// @notice Increase an existing trait bid
    /// @dev Prevents increasing an expired bid
    function increaseTraitBid(address collection, uint256 traitKey) external payable nonReentrant whenNotPaused {
        // checks
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
    function acceptTraitBid(
        address collection,
        uint256 tokenId,
        address bidder,
        uint256 traitKey,
        uint256 minAmount
    ) external nonReentrant whenNotPaused {
        // checks
        Bid memory bid = traitBids[bidder][collection][traitKey];
        if (bid.amount == 0) revert NoBidExists();
        _checkBidNotExpired(bid.expiresAt);
        if (bid.amount < minAmount) revert BidTooLow();

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

    /*//////////////////////////////////////////////////////////////
                        BATCH BID FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Extend bid(s)
    /// @dev Allows extending expired bids rather than canceling and re-bidding
    function extendBids(BidSelector[] calldata bidSelectors, uint64 expiresAt) external nonReentrant whenNotPaused {
        // checks
        uint256 num = bidSelectors.length;
        if (num == 0) revert ZeroLengthArray();
        if (expiresAt != 0 && expiresAt < block.timestamp) revert BidExpired();

        // effects
        for (uint256 i = 0; i < num; ++i) {
            BidSelector memory bs = bidSelectors[i];
            if (bs.bidType == BidType.TOKEN) {
                // token bid
                Bid storage tokenBid = tokenBids[msg.sender][bs.collection][bs.tokenId];
                if (tokenBid.amount == 0) revert NoBidExists();
                tokenBid.expiresAt = expiresAt;
                emit TokenBidExtended(bs.collection, bs.tokenId, msg.sender, expiresAt);
                
            } else if (bs.bidType == BidType.COLLECTION) {

                // collection bid
                Bid storage collectionBid = collectionBids[msg.sender][bs.collection];
                if (collectionBid.amount == 0) revert NoBidExists();
                collectionBid.expiresAt = expiresAt;
                emit CollectionBidExtended(bs.collection, msg.sender, expiresAt);

            } else {

                // trait bid
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

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @dev Helper for the modifier to reduce code size
    function _whenNotPaused() internal view {
        if (paused) revert IsPaused();
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
        (bool success,) = to.call{value: amount}("");
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
    function _cancelTraitBid(address sender, address collection, uint256 traitKey) internal returns (uint192 bidAmount) {
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
    ) internal returns (uint256 royalty) {
        // Calculate royalties
        royalty = _calculateRoyalty(collection, tokenId, seller, salePrice);
        uint256 sellerProceeds = salePrice - royalty;

        // Record this sale for dynamic royalties
        lastSales[collection][tokenId] = LastSale({
            buyer: buyer,
            price: salePrice
        });

        // Transfer NFT
        nft.safeTransferFrom(seller, buyer, tokenId);

        // Transfer payments
        if (royalty > 0) {
            _safeTransferEth(royaltyRecipient, royalty);
        }
        _safeTransferEth(seller, sellerProceeds);
    }

    /// @dev Calculate dynamic royalty based on profit since last marketplace sale.
    /// @dev If there was no last sale recorded, or the seller does not equal the last recorded buyer, then default to full royalties.
    function _calculateRoyalty(
        address collection,
        uint256 tokenId,
        address seller,
        uint256 salePrice
    ) internal view returns (uint256 royalty) {
        LastSale memory lastSale = lastSales[collection][tokenId];

        // No cost basis: charge full royalty
        if (lastSale.buyer == address(0) || lastSale.buyer != seller) {
            return (salePrice * MAX_ROYALTY_BPS) / BASIS;
        }

        uint256 lastPrice = lastSale.price;

        // Breakeven or loss: 0% royalty
        if (salePrice <= lastPrice) {
            return 0;
        }

        // 2x or more profit: full MAX_ROYALTY_BPS
        if (salePrice >= lastPrice * 2) {
            return (salePrice * MAX_ROYALTY_BPS) / BASIS;
        }

        // Linear scale between 1x and 2x last sale price
        uint256 profit = salePrice - lastPrice;
        uint256 royaltyBps = (profit * (MAX_ROYALTY_BPS - MIN_ROYALTY_BPS)) / lastPrice + MIN_ROYALTY_BPS;

        return (salePrice * royaltyBps) / BASIS;
    }
}
