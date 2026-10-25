# 🔐 Security Review — luci-market

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./src/LuciMarket.sol` · `./src/LuciRoyaltyModel.sol` · `./script/Deploy.s.sol`<br>`./script/SlidingRoyaltyCalc.s.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 1 records before this scan · 1 after · `cf6a0c2` |

---

## Findings

[90] **1. A returned NFT revives an old listing**

`LuciMarket.buy` · Confidence: 90 · seen in 3/3 runs · KNOWN (2 scans)

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

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | A returned NFT revives an old listing |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

_None._

---

## Known from earlier scans

_Recorded by earlier scans of this repo, not raised again by this one. Not re-checked — a record here may be fixed, or may still be live and missed. `.solidity-auditor/memory.tsv`._

_None — every record in the ledger was raised again by this scan._

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
