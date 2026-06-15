# Sam Spratt Marketplace

A bespoke ETH marketplace for trading ERC-721 tokens from Sam Spratt collections. The system supports fixed-price listings, token bids, collection bids, trait-based bids, escrowed ETH offers, sanctions checks, token-level allowlisting for shared contracts, and enforced on-chain royalties through an external royalty model.

![Contract architecture](./public/contract-architecture.png)

## Contracts

- `LuciMarket` in `src/LuciMarket.sol` handles listings, bid escrow, settlement, collection/token allowlists, trait data, pausing, and sanctions checks.
- `LuciRoyaltyModel` in `src/LuciRoyaltyModel.sol` calculates royalties from configured mint prices and holds the royalty recipient.
- `ISanctionsList` in `src/interfaces/ISanctionsList.sol` is the Chainalysis-compatible sanctions interface used by the marketplace.

Both main contracts use `Ownable2Step`. The marketplace owner and royalty model owner may be the same address, but they are separate ownership domains.

## Listings

Token owners can list NFTs for a fixed ETH price. Listings are time-gated with a maximum duration of 180 days and do not escrow the NFT. The token remains in the seller's wallet until purchased.

Listings can be public or private. A public listing sets `buyer` to `address(0)` and can be purchased by anyone. A private listing sets `buyer` to a specific address, and only that address can call `buy`.

Listings can be extended in batch while the marketplace is unpaused and the collection or token remains allowed. Listings can be delisted while the marketplace is paused, but delisting is still subject to the sanctions check.

If a listed token is transferred outside the marketplace, the listing becomes stale. The `buy` function verifies that the stored seller still owns the token at execution time. A stale listing can become executable again if the original seller reacquires the token before expiry and still has marketplace approval, so frontends and indexers should filter stale listings.

## Offers

There are three bid types. Each bid escrows ETH when placed:

- **Token bid**: a bid on a specific token.
- **Collection bid**: a standing bid for any token in an allowed collection.
- **Trait bid**: a standing bid for any token in an allowed collection that matches a trait key.

A bidder can hold one active bid per type per collection, token, or trait key as applicable. Bids can be increased or extended while the marketplace is unpaused and the relevant collection or token is allowed. Bid acceptance includes a `minAmount` parameter to protect the seller from a bidder reducing or canceling a bid before the seller's transaction executes.

Bid cancellation is available while the marketplace is paused and does not require the collection to remain allowed. Cancellation is blocked while the bidder is sanctioned; once the bidder is no longer sanctioned, the bidder can cancel and withdraw escrowed ETH.

## Collection And Token Allowlisting

The marketplace supports two allowlist modes:

- **Allowed collections**: full collection support. Tokens in an allowed collection can be listed, bought, bid on with token bids, bid on with collection bids, and bid on with trait bids.
- **Allowed tokens**: token-level support for shared contracts. An individually allowed token can be listed, bought, and bid on with token bids, but it is not eligible for collection bids or trait bids.

Removing a collection or token blocks new orders, extensions, and fulfillment for that collection or token, but it does not delete existing listings or escrowed bids. Users can still delist or cancel, subject to sanctions checks. If a collection or token is later allowed again, unexpired orders can become executable again unless users have removed them.

## Royalty Model

Royalties are calculated by `LuciRoyaltyModel` from a configured mint price. The marketplace calls:

```solidity
calculateRoyalty(collection, tokenId, salePrice)
```

The royalty model returns the royalty recipient and the royalty amount. The marketplace pays royalties before paying seller proceeds.

### Configuration

The royalty model owner can:

- Set the royalty recipient.
- Configure a collection mint price.
- Override the mint price for a specific token.

Token overrides take precedence over collection configuration. A zero address royalty recipient is rejected in both the constructor and setter.

### Formula

Constants:

```solidity
BASIS = 10_000
MAX_ROYALTY_BPS = 1_000 // 10%
```

The effective mint price is:

1. `tokenOverrides[collection][tokenId].mintPrice` when the token override is enabled.
2. Otherwise `collections[collection].mintPrice`.
3. Otherwise `0`.

Royalty behavior:

| Scenario | Royalty |
| --- | --- |
| `salePrice <= mintPrice` | 0 |
| `salePrice >= mintPrice * 2` | 10% of sale price |
| `mintPrice < salePrice < mintPrice * 2` | Sliding scale from 0% to 10% |
| Unconfigured collection/token and positive sale price | 10% of sale price |

For the sliding-scale range:

```solidity
profit = salePrice - mintPrice;
royalty = Math.mulDiv(salePrice, profit * MAX_ROYALTY_BPS, mintPrice * BASIS);
```

Unconfigured collections intentionally default to `mintPrice == 0`, which charges full royalties for any positive sale price. The marketplace owner controls which collections and tokens can trade, so royalty readiness is an operational allowlist decision.

## Trait Bidding System

The trait bidding system allows bidders to place offers on tokens matching specific trait combinations. It uses a compact `uint32` for token traits and a `uint256` for trait bid keys.

### Token Trait Encoding (`uint32`)

Each token's traits are stored as four 8-bit slots:

```text
[ Trait 3 ][ Trait 2 ][ Trait 1 ][ Trait 0 ]
```

Each 8-bit slot is:

```text
bit 7      initialized flag
bit 6      reserved
bits 5-0   value index, 0-63
```

A trait slot with bit 7 unset cannot satisfy a trait bid. This prevents tokens with partially configured traits from matching bids that reference unconfigured slots.

Example:

- Trait 0 = value `5`, initialized: `0x85`
- Trait 1 = value `12`, initialized: `0x8C`
- Trait 2 = unused: `0x00`
- Trait 3 = unused: `0x00`

Encoded token traits: `0x00008C85`

### Trait Key Encoding (`uint256`)

A trait key is four packed 64-bit bitmaps:

```text
[ Trait 3 bitmap ][ Trait 2 bitmap ][ Trait 1 bitmap ][ Trait 0 bitmap ]
```

Each bitmap represents acceptable values for that trait slot. Bit `N` means value `N` is acceptable.

Matching semantics:

- Within a bitmap, values are ORed.
- Across non-zero bitmaps, slots are ANDed.
- A zero bitmap is a wildcard for that slot.

A trait key of `0` is rejected because it is equivalent to a collection bid.

### Collection Trait Configuration

Each collection has a `uint32` trait configuration that mirrors the token trait layout. Only bit 7 of each 8-bit segment matters. If bit 7 is set, that trait slot is enabled for the collection.

When placing, increasing, or accepting a trait bid, the marketplace validates that the trait key does not specify non-zero bitmaps for disabled trait slots. Updating a collection's trait configuration can therefore make existing trait bids unfillable until the bidder cancels or the configuration changes again.

## Sanctions Checks

The marketplace can be configured with a Chainalysis-compatible sanctions list. If `sanctionsList` is `address(0)`, sanctions checks are disabled.

When a sanctions list is configured:

- Sanctioned users cannot list, extend listings, delist, buy, place bids, increase bids, extend bids, cancel bids, or accept bids.
- Buyers are checked in `buy`.
- Listing sellers are checked in `buy`.
- Sellers and bidders are checked when bids are accepted.
- Bid escrow remains in the contract while a bidder is sanctioned. The bidder can cancel and withdraw only after removal from the sanctions list.

The marketplace owner can update the sanctions list address.

## Pause Behavior

When paused:

- New listings, listing extensions, purchases, bid placements, bid increases, bid extensions, and bid acceptances are blocked.
- Delisting remains available, subject to sanctions checks.
- Bid cancellation remains available, subject to sanctions checks.

Pausing does not delete orders or refund escrow automatically.

## Access Control

The marketplace owner manages:

- Collection allowlist.
- Token allowlist for shared contracts.
- Trait configuration.
- Token trait data.
- Pause state.
- Royalty model address.
- Sanctions list address.

The royalty model owner manages:

- Royalty recipient.
- Collection mint price configuration.
- Token mint price overrides.

Owner-managed trait data is trusted. The marketplace does not derive traits from token metadata or validate trait values beyond the compact encoding rules used for matching.

## Known Limitations

- **Non-escrowed listings**: listed NFTs remain in seller wallets.
- **Stale listings**: listings are not automatically invalidated when NFTs transfer outside the marketplace.
- **ETH only**: ERC-20 payments are not supported.
- **No partial fills**: each accepted bid is consumed in full.
- **One active bid per key**: bidders can hold one collection bid per collection, one token bid per token, and one trait bid per trait key.
- **Four trait slots**: trait matching supports four slots with 64 possible values each.
- **Indexed reads required**: active offers are spread across bidder-keyed mappings and are not enumerable on-chain.

## Known Tradeoffs

- **Full royalty fallback**: unconfigured royalty entries default to full royalties for positive sale prices instead of reverting.
- **User-managed stale orders**: users, frontends, and indexers are expected to manage stale listings and stale bids. Fulfillment paths re-check ownership, approval, allowlist status, trait validity, expiration, sanctions status, and payment amount.
- **Re-approved orders can reactivate**: removing a collection or token blocks fulfillment while removed, but existing unexpired orders can become executable again if allowlisted later.
- **Fixed-gas ETH transfers**: ETH payouts use `call` with `100_000` gas. This supports normal EOAs and many smart wallets while bounding recipient execution, but recipients requiring more gas can cause their own payout path to revert.
- **Allowed collection trust**: settlement uses `safeTransferFrom` and assumes allowed ERC-721 collections behave correctly.

## Security Considerations

- **Reentrancy**: external state-changing functions use `ReentrancyGuardTransient`. State changes happen before external calls.
- **ERC-721 receiver callbacks**: NFT transfers use `safeTransferFrom`, which may call `onERC721Received` on contract buyers. The reentrancy guard protects marketplace entry points during that callback.
- **ETH payouts**: failed ETH sends revert settlement or cancellation. Contract sellers, bidders, or royalty recipients should be able to receive ETH within the gas cap.
- **Sanctioned escrow**: sanctioned bidders cannot withdraw bid escrow until no longer sanctioned.
- **Owner trust**: owners can pause trading, change allowlists, set traits, change the royalty model, change sanctions enforcement, and configure royalties.

## Indexing Considerations

The indexing layer should enrich on-chain events into a queryable model. Key responsibilities:

- Track listing state and current token ownership.
- Hide listings where the stored seller no longer owns the token.
- Optionally mark stale listings as active again if the original seller reacquires the token before expiry.
- Aggregate token, collection, and trait bids for token and collection pages.
- Resolve compact trait indices into human-readable trait names and values.
- Track sanctions and allowlist changes that affect order executability.

On-chain bid data is keyed by bidder address, so event indexing is required for practical offer discovery.
