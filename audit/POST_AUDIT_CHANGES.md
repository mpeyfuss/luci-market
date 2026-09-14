# Audit Provenance And Post-Audit Changes

This file records what the external review covered and what has changed in `src/` since, so that anyone
reading the audit report knows which parts of the current code it speaks to.

The report itself (`audit/Luci Market Contract Review.pdf`) is the authority on scope, methodology, and
findings.

## Audit Summary

| | |
| --- | --- |
| Report | `audit/Luci Market Contract Review.pdf` |
| Source state reviewed | `28960f2` (2026-07-12) |

At that point the design was:

- Mint prices denominated in **ETH wei**, compared directly against the sale price.
- `list()` resolved the royalty and **snapshotted `royaltyAmount` into the `Listing` struct**, introduced in
  `52c02a1` so the amount could not change after listing.
- `buy()` paid the snapshotted amount; only `acceptBid()` resolved the royalty live.
- The only royalty sanity check was `royaltyAmount > salePrice` in `_settleSale`.
- `LuciRoyaltyModel` made **no external calls**.

## What Has Changed Since

The changes below are post-audit and were not part of the external review.

### The headline change: mint prices are denominated in USD

The mint price a royalty is measured against is a USD concept. The audited model treated it as ETH wei, which
meant the royalty curve moved with the ETH price: the same piece crossed its 0% and 10% thresholds at
different dollar amounts depending on when it sold. Mint prices are now stored in **USD with 8 decimals**, and
the sliding scale is driven by the sale price's deviation from that USD mint price.

Everything else in this document follows from that decision.

The royalty is still transacted in ETH. Only the percentage is determined in USD: the sale price is converted
to USD, the basis points are derived from the USD comparison, and those basis points are then applied to the
sale price in its *original currency*.

### Consequence: on-chain oracles in the royalty path

Comparing a sale price against a USD mint price requires a live ETH/USD rate on-chain, so `LuciRoyaltyModel`
calls an owner-configured Chainlink aggregator (`src/interfaces/IAggregatorV3.sol`) during royalty
calculation. The audited model had no external dependencies in the royalty path, making this the largest
change to the contract's trust assumptions.

- Royalty amounts depend on a third-party feed's liveness and correctness.
- The royalty model owner can point a currency at any contract returning any price.
- A feed outage, stale answer, or reverting feed falls back to the **maximum royalty (10%)** rather than
  reverting. Trading stays available and sellers pay the ceiling while the feed is degraded. This is the
  intended behavior: availability is preferred over precision, and the fallback never under-charges.
- The oracle call is wrapped in `try/catch`. `catch` covers a revert from the call itself, not a failure
  decoding its return data. A non-contract oracle is rejected at configuration time, where
  `configureCurrency` calls `decimals()` on it.
- `MAX_CURRENCY_DECIMALS` (36) bounds the conversion denominator below the `uint256` overflow limit. The
  bound is enforced at configuration time because the multiplication sits inside the `try` block's success
  body, which `catch` does not cover.

### Reversal of an audited design decision

Listings no longer snapshot `royaltyAmount`. This reverses `52c02a1`, which introduced the snapshot so the
amount could not change after listing. The USD denomination requires the reversal: a snapshot taken at listing
time drifts against the ETH/USD rate and settles at the wrong percentage. Both the recipient and the
amount are resolved live in `buy()`, matching what `acceptBid()` already did.

Seller proceeds on an open listing move with the ETH/USD rate. That is a seller-visible behavior change, not
an internal refactor.

### Public interface changes

- `calculateRoyalty` gained a fourth `currency` argument.
- `Listing` dropped `uint256 royaltyAmount`; `buyer` moved from slot 3 to slot 2.
- `Listed` dropped its trailing `royaltyAmount` argument.
- Mint price fields renamed to `mintPriceUsd`, carrying the USD denomination described above.
- `src/interfaces/ISanctionsList.sol` pragma pinned from `^0.8.30` to `0.8.30`, matching the rest of `src/`.

Nothing is deployed and the contracts are not upgradeable, so the storage layout change carries no migration risk.

### New admin surface

`configureCurrency` and `removeCurrency` on `LuciRoyaltyModel`, with the `currencies` registry (allowed flag,
currency decimals, cached oracle decimals, staleness window, oracle address). This widens what a compromised
royalty-model owner key can do: previously an arbitrary mint price or recipient, now also an arbitrary price
source.

### New safety bound

`LuciMarket` enforces `royaltyAmount <= 10%` of the sale price in `_settleSale`, replacing the audited
`royaltyAmount > salePrice` check. It covers both `buy()` and `acceptBid()` and holds regardless of which
royalty model the owner configures, bounding both the widened owner surface above and any future
`setRoyaltyModel` swap.

`list()` performs no royalty check, because it no longer calls the royalty model.

## Review Status

The core trading, escrow, bid, allowlist, and sanctions logic covered by the report is unchanged. The
post-audit changes above were reviewed internally with automated analysis rather than sent for external
re-review, which is sufficient for a change of this scope against an audited core.

Verification performed on the post-audit state:

- Full Foundry suite passing, including fuzz and invariant runs.
- 100% line, statement, branch, and function coverage on both `src/` contracts.
- Slither clean. The two reported findings (`arbitrary-send-eth`, `unused-return`) are reviewed false
  positives; see the Security Considerations section of the README.
