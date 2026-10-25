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
gross sale price in its *original currency*. Appreciation above mint sets the percentage; the model does not
charge a percentage of profit.

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
- The `latestRoundData()` and `decimals()` calls are each wrapped in their own `try/catch`, so a revert
  from either falls back to max royalty. `catch` covers a revert from the call itself, not a failure
  decoding its return data, so an oracle that returns malformed data still reverts settlement until the
  currency is reconfigured or removed. `configureCurrency` makes no external calls; the feed's decimals
  are owner-declared at configuration time. Conversion re-reads `decimals()` live and falls back to max
  royalty if they differ from the declared value, so a wrong declaration or a scale change without a
  matching `answer` rescaling cannot under-charge. An `answer` that would overflow
  `answer * 10**USD_DECIMALS`, or a converted USD value that would overflow `uint256`, is treated as a
  failed conversion (max royalty) rather than reverting settlement.
- `MAX_CURRENCY_DECIMALS` (18) matches real currencies and Chainlink feeds. The bound is enforced at
  configuration time for the currency and the feed.

### Reversal of an audited design decision

Listings no longer snapshot `royaltyAmount`. This reverses `52c02a1`, which introduced the snapshot so the
amount could not change after listing. The USD denomination requires the reversal: a snapshot taken at listing
time drifts against the ETH/USD rate and settles at the wrong percentage. Both the recipient and the
amount are resolved live in `buy()`, matching what `acceptBid()` already did.

Seller proceeds on an open listing move with the ETH/USD rate. That is a seller-visible behavior change, not
an internal refactor. The design intentionally does not add an order-specific proceeds floor: over the intended
order horizons such a bound would become stale, while the marketplace's independent 10% ceiling guarantees that
every successful settlement pays the seller at least 90% of the gross sale price.

### Public interface changes

- `calculateRoyalty` gained a fourth `currency` argument.
- `configureCurrency` gained an `oracleDecimals` argument; the feed is no longer probed (`decimals()`,
  `latestRoundData()`) at configuration time.
- `Listing` dropped `uint256 royaltyAmount`; `buyer` moved from slot 3 to slot 2.
- `Listed` dropped its trailing `royaltyAmount` argument.
- Mint price fields renamed to `mintPriceUsd`, carrying the USD denomination described above.
- `src/interfaces/ISanctionsList.sol` pragma pinned from `^0.8.30` to `0.8.30`, matching the rest of `src/`.

Nothing is deployed and the contracts are not upgradeable, so the storage layout change carries no migration risk.

### New admin surface

`configureCurrency` and `removeCurrency` on `LuciRoyaltyModel`, with the `currencies` registry (allowed flag,
currency decimals, owner-declared oracle decimals, staleness window, oracle address), plus `clearTokenOverride`.
This widens what a compromised royalty-model owner key can do: previously an arbitrary mint price or recipient,
now also an arbitrary price source. The intended production deployment transfers both ownership domains to
timelock controllers governed by a multisig. Those controls are operational and are not enforced by the source
contracts themselves.

### New safety bound

`LuciMarket` enforces `royaltyAmount <= 10%` of the sale price in `_settleSale`, replacing the audited
`royaltyAmount > salePrice` check. It also rejects a zero royalty recipient when the royalty amount is
positive. Both checks cover `buy()` and `acceptBid()` and hold regardless of which royalty model the owner
configures, bounding both the widened owner surface above and any future `setRoyaltyModel` swap.

`list()` performs no royalty check, because it no longer calls the royalty model.

### Listing extension requires current ownership

`extendListings` now checks, for each token, that the caller still owns it and that the marketplace is
still approved, matching the checks in `list`. Previously only the stored seller was checked, so a seller
could extend a stale listing for a token they had transferred away, keeping it alive in case they later
reacquired the token. A stale listing can still become fillable if the seller reacquires the token before
the listing's existing expiry, but it can no longer be extended past that.

### Trait bids replaced by selection bids

Trait bids are removed entirely. In their place, **selection bids** are escrowed ETH bids on an explicit set
of tokens committed to by a Merkle root. Any holder of a token in the set can accept one, and a set can span
multiple collections. The contract no longer stores traits or selection contents: the site resolves traits
offchain, builds the tree, stores it, and serves proofs to sellers.

How it works:

- `selectionRoot` is the selection's Merkle root. Leaves follow the OpenZeppelin standard Merkle tree format,
  `keccak256(bytes.concat(keccak256(abi.encode(collection, tokenId))))`, with sorted-pair hashing, verified
  with OpenZeppelin's `MerkleProof`. A zero root is rejected with `InvalidSelection`.
- `placeBid` with `BidType.SELECTION` stores the bid keyed by bidder and root. There is no creation step.
- `acceptBid` gained a trailing `bytes32[] proof` argument. For a selection bid it verifies that the sold
  token is in the selection, right after the allowlist check and before the bid lookup, so an invalid proof
  reverts with `TokenNotInSelection` ahead of `NoBidExists`, `BidExpired`, and `BidTooLow`. Token and
  collection bids ignore the proof and pass an empty array. All checks still run before any effects or
  interactions, which are unchanged in order.
- `isInSelection(selectionRoot, collection, tokenId, proof)` exposes the proof check as a view.

Eligibility semantics:

- The allowlist rule is per token, the same as listings and token bids: a token's collection must be allowed,
  or the token must be individually allowed. It is checked for the sold token when a bid is accepted.
- Placing, increasing, and extending a selection bid do **not** check the allowlist, because the contract
  does not know a selection's contents. This differs from token and collection bids, where those operations
  do check. Fulfillment is still gated per token.
- Individually allowed tokens are now eligible for selection bids. They were not eligible for trait bids,
  and they remain ineligible for collection bids.

Public interface changes:

- `BidType.TRAIT` is replaced by `BidType.SELECTION` (same ordinal, 2).
- `BidSelector.traitKey` (`uint256`) is replaced by `BidSelector.selectionRoot` (`bytes32`). The same change
  applies to the `traitKey` field of `BidPlaced`, `BidIncreased`, `BidExtended`, `BidCanceled`, and
  `BidAccepted`. Selection bid events emit `address(0)` as `collection`, except `BidAccepted`, which emits
  the sold token's collection.
- `acceptBid(bidSelector, bidder, minAmount)` becomes `acceptBid(bidSelector, bidder, minAmount, proof)`.
- Added: `isInSelection`, `selectionBids`, and the `InvalidSelection` and
  `TokenNotInSelection` errors.
- Removed: `setCollectionTraitsConfig`, `setTraits`, `tokenTraits`, `collectionTraitConfigs`, `traitBids`,
  the `CollectionTraitConfigSet` and `TraitsSet` events, and the `InvalidTraitKey`, `TraitMismatch`,
  `TraitNotSet`, and `ArrayLengthMismatch` errors. `script/pack_traits.py` and its tests and Makefile
  targets are removed.
- The Solady `LibMap` import is replaced by OpenZeppelin's `MerkleProof`.

Change in trust assumptions:

- **Owner surface shrinks.** The owner no longer writes trait data that bids settle against, so a
  compromised owner key can no longer redirect trait bids by rewriting traits.
- **Bidders trust the site's tree.** A bidder signs a bare root. The contract cannot show or check what it
  contains, so the bidder relies on the site to build the tree they intended.
- **Offchain data availability.** If the tree behind a root is lost, the bid cannot be filled. Escrow is not
  at risk, because the bidder can always cancel.
- **Offchain correctness.** Whether a selection matches a trait is the site's responsibility. Because a
  selection is a snapshot of token IDs, the site must not offer trait-based selections for collections whose
  metadata can still change.

Listings, token bids, collection bids, royalties, settlement, and sanctions are unchanged by this work.

### Per-collection and per-token royalty caps

The sliding scale's ceiling is no longer fixed at 10% for every collection. `CollectionConfig` and
`TokenOverride` each gained a `uint16 maxRoyaltyBps` (packed into the existing slot), and the scale runs from
0% at the mint price to that cap at 2x mint. The curve's shape and thresholds are unchanged.

- `configureCollection(collection, mintPriceUsd)` becomes `configureCollection(collection, mintPriceUsd, maxRoyaltyBps)`.
- `overrideToken(collection, tokenId, mintPriceUsd)` becomes `overrideToken(collection, tokenId, mintPriceUsd, maxRoyaltyBps)`.
  An enabled override's cap takes precedence over the collection's.
- `CollectionConfigured` and `TokenOverriden` gained a trailing, non-indexed `maxRoyaltyBps`.
- The `collections` and `tokenOverrides` getters now return `(bool, uint16, uint192)`.
- Added the `InvalidRoyaltyBps` error. Both setters revert when the cap exceeds `MAX_ROYALTY_BPS`.

Behavior changes:

- Fallbacks charge the applicable cap rather than a flat 10%: a zero mint price and every failed USD conversion.
- A cap of `0` returns zero without calling the price feed.
- `calculateRoyalty` now reads the previously unused `configured` flag. A collection with no configuration and
  no token override still charges `MAX_ROYALTY_BPS`, as before. Without that check its zero cap would read as
  royalty free.

`LuciMarket` is unchanged. Its 10% settlement ceiling still bounds every cap.

### Selection tree location

Integrators had no on-chain way to find the tree behind a selection root. `LuciMarket` now exposes one.

- Added `selectionBaseUri` (owner-set string) and `setSelectionBaseUri(string)`, emitting
  `SelectionBaseUriUpdated(oldSelectionBaseUri, newSelectionBaseUri)`.
- Added `selectionUri(bytes32 selectionRoot)`, returning the base URI followed by the root as `0x`-prefixed
  lowercase hex (66 characters), or an empty string when no base URI is set. It uses OpenZeppelin's `Strings`.

The change is additive: no existing function, event, error, or struct changes. Settlement never reads the URI,
so it adds no trust to fills. The owner can point integrators at a different location, but any tree fetched
there must still hash to the root the bid was placed on.

## Acknowledged Findings

Findings from the post-audit internal review that are accepted by design and not fixed in code.

### A returned NFT revives an old listing

Source: `.solidity-auditor/runs/20261025-002500/full-report.md`, finding 1.

**Finding.** Listings are not invalidated when a token leaves the seller's wallet. If the token comes back
to the seller before the listing expires, and the marketplace is still approved, `buy()` fills the old
listing at its original price. Settlement only checks the current state: `transferFrom(listing.seller, ...)`
requires the stored seller to own the token and the marketplace to be approved at that moment.

**Status: acknowledged, by design.** Listings are non-custodial. Without escrow, the contract cannot see
transfers that happen outside it, because ERC-721 has no transfer hook for third parties. The only ways to
detect a round trip are escrowing the NFT, which the design rules out, or a trusted party that invalidates
listings offchain, which adds centralization. Neither is acceptable.

**Proposed fix rejected.** The report suggests requiring `getApproved(tokenId) == address(this)` instead of
`_isApproved`. Per-token approvals are cleared on transfer, but this does not fix the issue:

- Sellers who approved the marketplace with `setApprovalForAll` still have that approval after the token
  returns, so the listing can still be filled. These sellers would also be locked out of listing at all,
  which breaks the standard approval flow `_isApproved` supports on purpose.
- A seller who approves the token again after getting it back makes the old listing fillable anyway.
- The diff is placed in `buy()`, but the `_isApproved` check it replaces is in `list()` and
  `extendListings()`.

**Existing mitigations.**

- The affected party is the seller who set the listing price, and `delist` is always available to them,
  including while the marketplace is paused.
- `extendListings` requires current ownership and approval, so a stale listing cannot be kept alive. It
  lapses at its original expiry, at most `MAX_LISTING_DURATION` (180 days) after it was set.
- Calling `list` again for the token overwrites the stored listing, and accepting any bid on the token
  clears it.
- The README documents the behavior and requires frontends and indexers to filter stale listings.

## Review Status

Token bid, collection bid, settlement, allowlist, and sanctions logic covered by the report is
unchanged. Listing logic is unchanged except for the ownership and approval checks added to
`extendListings`. The audited trait bid path has been removed and replaced by selection bids, which reuse the
audited bid lifecycle (escrow, expiry, `minAmount`, listing clearing, settlement) and add only a Merkle
proof check. The post-audit changes above were reviewed internally with automated
analysis rather than sent for external re-review.

Verification performed on the post-audit state:

- Full Foundry suite passing (123 tests), including fuzz (10,000 runs, with Merkle proofs over random
  cross-collection token sets checked against a reference) and invariant runs. Roots and proofs are also
  checked against a vector generated by `@openzeppelin/merkle-tree`.
- 100% line, statement, branch, and function coverage on both `src/` contracts.
- Slither clean. The two reported findings (`arbitrary-send-eth`, `unused-return`) are reviewed false
  positives; see the Security Considerations section of the README. Selection bids add no new detector
  categories and no findings in the new code.
