# Run 2 — solidity-auditor

<!--RUN pass=2 of=3 stamp=20261025-231202 sha=cf6a0c2 agents=12/12-->

Pass 2 of 3 · 2026-10-25 · `cf6a0c2` · 12/12 agents returned (scheduled in batches of three).

## Findings

<!--F key=lucimarket|buy|stale-listing-reactivation conf=90 kind=FINDING agents=11-->

[90] **A returned NFT revives an old listing**

`LuciMarket.buy` · Confidence: 90

**Description**
An attacker buys a returned NFT at its old price because external transfers leave its listing active; the README explicitly accepts this risk.

**Fix**

Both options require the collection to expose `transferNonce(tokenId)` and increment it on every transfer, burn, and remint without resetting it.
Standard ERC-721 lacks this API; these changes require collection integration and do not provide a standalone fix for existing incompatible collections.
Escrow is an alternative that requires a broader custody redesign.

**Fix (Option A — reject extension after a transfer)**:

```diff
+interface IERC721TransferNonce {
+    function transferNonce(uint256 tokenId) external view returns (uint256);
+}

 contract LuciMarket is Ownable2Step, ReentrancyGuardTransient {
+    error ListingOwnershipChanged();
+    mapping(address => mapping(uint256 => uint256)) private listingTransferNonces;

@@ function list
         if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();

+        listingTransferNonces[collection][tokenId] =
+            IERC721TransferNonce(collection).transferNonce(tokenId);
         // effects
         listings[collection][tokenId] = Listing({seller: msg.sender, expiresAt: expiresAt, price: price, buyer: buyer});

@@ function extendListings
             if (!_isApproved(nft, msg.sender, token.tokenId)) revert NotApproved();

+            if (
+                IERC721TransferNonce(token.collection).transferNonce(token.tokenId)
+                    != listingTransferNonces[token.collection][token.tokenId]
+            ) revert ListingOwnershipChanged();
             listing.expiresAt = expiresAt;

@@ function buy
         if (msg.value != listing.price) revert IncorrectPayment();
+        if (
+            IERC721TransferNonce(collection).transferNonce(tokenId)
+                != listingTransferNonces[collection][tokenId]
+        ) revert ListingOwnershipChanged();
```

**Fix (Option B — renew authorization on extension)**:

```diff
+interface ITransferNonce {
+    function transferNonce(uint256 tokenId) external view returns (uint256);
+}

 contract LuciMarket is Ownable2Step, ReentrancyGuardTransient {
+    mapping(address collection => mapping(uint256 tokenId => uint256)) public listingTransferNonces;
+    error ListingInvalidated();

     // In list(), after ownership and approval checks:
+    listingTransferNonces[collection][tokenId] = ITransferNonce(collection).transferNonce(tokenId);

     // In extendListings(), after ownership and approval checks:
+    listingTransferNonces[token.collection][token.tokenId] =
+        ITransferNonce(token.collection).transferNonce(token.tokenId);

     // In buy(), before deleting the listing:
+    if (listingTransferNonces[collection][tokenId] != ITransferNonce(collection).transferNonce(tokenId)) {
+        revert ListingInvalidated();
+    }
```

<!--/F-->

## Leads

_None._
