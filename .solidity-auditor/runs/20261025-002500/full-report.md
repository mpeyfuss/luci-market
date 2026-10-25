# 🔐 Security Review — luci-market

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./src/LuciMarket.sol` · `./src/LuciRoyaltyModel.sol` · `./script/Deploy.s.sol`<br>`./script/SlidingRoyaltyCalc.s.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 0 records before this scan · 1 after · `0615a10` |

---

## Findings

[90] **1. A returned NFT revives an old listing**

`LuciMarket.buy` · Confidence: 90 · seen in 3/3 runs · NEW

**Description**
Any buyer can buy a returned NFT at its old price because the marketplace keeps the listing through intermediate ownership changes.

**Fix**

```diff
-        if (!_isApproved(nft, msg.sender, tokenId)) revert NotApproved();
+        if (nft.getApproved(tokenId) != address(this)) revert NotApproved();
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

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
