# Run 3 — solidity-auditor

<!--RUN pass=3 of=3 stamp=20261025-002500 sha=0615a10 agents=12/12-->

Pass 3 of 3 · 2026-10-24 · `0615a10` · 12/12 agents returned.

## Findings

<!--F key=lucimarket|buy|stale-listing-reactivation conf=90 kind=FINDING agents=11-->

[90] **A returned NFT revives an old listing**

`LuciMarket.buy` · Confidence: 90

**Description**
Any buyer can buy a returned NFT at its old price because the marketplace keeps the listing through intermediate ownership changes.

**Fix**

```diff
-        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();
+        if (nft.getApproved(tokenId) != address(this)) revert NotApproved();
```

<!--/F-->

## Leads

