# X-Ray Report

> Luci Market | 683 source nSLOC including 12 interface nSLOC | main at 0615a10 plus existing working-tree changes | Foundry | 2026-10-25

Architecture review of the current local source, not a vulnerability audit or verification of deployed contracts. Existing user edits were preserved.

## 1. Protocol Overview

- **Purpose:** a curated native-ETH secondary marketplace for Sam Spratt ERC-721 artwork.
- **Users:** collectors list, buy, and fund offers; NFT holders accept eligible offers.
- **Core mechanism:** non-custodial NFT listings plus fully funded ETH bids; atomic NFT transfer and royalty/seller payout.
- **Token model:** existing allowlisted ERC-721 collections and individual tokens from shared contracts; no protocol token.
- **Admin model:** two independent Ownable2Step owners; no proxy or implementation upgrade entry point.

[Architecture diagram](architecture.svg). The site and governance nodes describe responsibilities, not implemented services in this repository. Royalty recipients receive ETH directly from the market; the model only calculates amounts.

| Subsystem | Contracts | nSLOC | Role |
|---|---|---:|---|
| Trading | LuciMarket | 502 | Listings, three bid types, escrow, settlement, eligibility, sanctions |
| Royalty policy | LuciRoyaltyModel | 169 | Mint-price configuration, token overrides, oracle conversion |

### How It Fits Together

The core mechanism is a single settlement path shared by purchases and accepted bids.

```text
Seller approves NFT → list → stored price, seller, optional buyer, expiry
Buyer pays exact ETH → buy → delete listing → calculate current royalty
  → NFT.transferFrom(seller, buyer) → royalty ETH → seller ETH → Sold

Bidder pays ETH → placeBid → token / collection / selection bid mapping
Seller calls acceptBid → eligibility + expiry + minimum gross price
  → selection proof if applicable → delete bid + clear listing
  → same royalty/NFT/payment settlement → BidAccepted

Bidder → cancelBids → delete own bid entries → refund total ETH
  → allowed during pause and after delisting a collection; sanctions still apply

Site resolves a token set → publishes standard Merkle tree → bidder commits root
  → seller obtains proof → market verifies (collection, tokenId) membership
```

Listings expire within 180 days of creation/extension; bids can have no expiry. A collection or selection bid purchases one NFT and is consumed fully. No order matching engine, partial fills, platform fee, ERC-20 payment path, or royalty collection vault appears in the core source.

## 2. Threat & Trust Model

**Profile:** curated NFT exchange with ETH custody and an oracle-dependent royalty policy.

| Actor | Trust boundary | Capabilities |
|---|---|---|
| Seller | Own NFT / own listing | List, extend, delist; sell into a funded bid |
| Buyer / bidder | Own ETH / own bids | Buy; place, increase, extend, cancel offers |
| Marketplace owner | Trusted, immediate | Pause; set eligibility, royalty model, sanctions list, tree URI |
| Royalty model owner | Trusted, immediate | Set recipient, USD mint prices, caps, currencies and feeds |
| Site operator | Trusted for intended selection and data availability | Resolve criteria, preserve trees, serve proofs, index executable orders |

The README's multisig-governed timelocks are intended production infrastructure (per spec), not enforced by constructors or deployed by the included script. Two-step ownership protects acceptance of a new owner; it adds no time delay. A timelock for every owner action also delays emergency pausing, so its emergency-response policy needs an explicit operational decision.

### Trust Boundaries

- **NFT custody:** NFTs remain in seller wallets; ERC-721 ownership and approvals are enforced by the external token during settlement (`LuciMarket.sol:759`). Allowlisting therefore trusts collection behavior.
- **ETH custody:** offers stay in LuciMarket until accepted or canceled; there is no owner escrow sweep in the source.
- **Policy replacement:** the owner can replace the royalty model immediately, but LuciMarket independently rejects royalties above 10% (`LuciMarket.sol:749`).
- **Sanctions dependency:** a zero address disables screening; a configured list is called without fallback, including on cancellation (`LuciMarket.sol:633`).
- **Selection data:** proofs bind to a root and cannot substitute another set; availability and the relationship between the set and displayed criteria remain offchain.

### Key Attack Surfaces

- **Settlement and callbacks** [G-1](invariants.md#g-1), [I-1](invariants.md#i-1) — trace both value paths through `_settleSale`, including bounded-gas recipient calls and failed transfer rollback.

- **Royalty configuration and feed conversion** [I-2](invariants.md#i-2), [X-1](invariants.md#x-1) — check current-policy resolution, override precedence, decimal scaling, fallback and rounding across `calculateRoyalty` and `_toUsd`.

- **Order lifetime** [I-3](invariants.md#i-3) — examine expiry boundaries and order reactivation after ownership, approval, or allowlist changes.

- **Selection construction** [G-2](invariants.md#g-2) — validate site-generated trees against the double-hashed address/token-ID leaf used by `_isInSelection`.

- **Owner and sanctions availability** — assess policy replacement, failed external reads, and emergency response separately from the royalty ceiling.

### Architectural Tradeoffs

1. **Live economics:** the price is fixed but the royalty is live. At successful settlement sellers receive at least 90% of gross price before transaction gas; `minAmount` on bid acceptance constrains gross proceeds, not a separately quoted net amount.
2. **Oracle degradation:** stale, nonpositive, future-dated, reverting, or decimal-mismatched feeds normally select the configured cap. Unconfigured entries use 10%. Malformed return data can still revert; fallback is not a universal availability guarantee.
3. **Push payments:** royalty and seller transfers each get 100,000 gas. Failure reverts the whole trade. Cancellation likewise requires the bidder to receive ETH; no alternate withdrawal recipient is exposed.
4. **Stale orders:** transfer or approval revocation does not delete a listing. An old listing can revive if ownership/approval returns before expiry; allowlist re-addition can revive stored orders too.
5. **Snapshot selections:** roots encode token IDs, not ongoing predicates. Trait-based selections require frozen metadata (per spec). Preserve downloadable trees and verify roots client-side before funding.
6. **Royalty scope:** enforcement covers trades through LuciMarket. These contracts do not establish royalty enforcement on transfers or sales elsewhere.

### Temporal & Deployment Concerns

`script/Deploy.s.sol` uses CreateX CREATE3 with sender-bound salts and expected-chain checks. Deploy the royalty model first, then the market, configure native ETH feed and collection/token economics, establish governance, and only then enable trading eligibility. Constructors create no proxy initialization window. ReentrancyGuardTransient requires a chain supporting transient storage; deterministic addresses do not establish equivalent configuration across chains.

### Dependency Map

| Dependency | Assumption / checks | Failure behavior |
|---|---|---|
| Allowed ERC-721 | Correct ownership and transfer semantics; approval checked at listing | Token revert aborts trade; no receiver callback via transferFrom |
| Royalty model | Owner-selected; market checks 10% ceiling and positive-payment recipient | Reverting model blocks settlement |
| Price feed | Owner-declared decimals, bounded age, positive answer, valid timestamp, overflow checks | Ordinary invalid reads use cap; malformed ABI may revert |
| Sanctions list | Owner-selected address; zero disables | Revert blocks screened actions, including refunds |
| ETH receivers | Can accept value within 100,000 gas | Revert rolls back trade/refund |
| Site/tree storage | Correct criteria and durable tree availability | Missing proof prevents selection fill; cancellation remains subject to normal rules |

## 3. Invariants

> See [invariants.md](invariants.md): 2 focal guards, 3 single-contract properties, 1 cross-contract property, and 1 economic consequence. This is an architecture-focused reference, not an exhaustive formal specification.

## 4. Documentation Quality

README documents flows, ownership, oracle fallback, selection format, indexing and acknowledged tradeoffs. Source NatSpec is present. No independent formal specification was identified. `audit/POST_AUDIT_CHANGES.md` identifies the externally reviewed state as 28960f2; USD royalties, selection bids and subsequent local changes must not inherit that review's assurance automatically.

## 5. Test Analysis

Project-only scan: 7 Solidity files under test/ (including helpers/mocks), 139 test functions including 7 fuzz tests, plus 2 invariant functions. The broad skill enumeration reported 26 files / 335 test functions / 33 fuzz functions because it also sees dependencies; those are not project coverage counts.

Validation: see validation.md for this run. Coverage measures executed branches, not correctness of the architecture. No Certora, Halmos, Echidna or Medusa configuration was detected by enumeration. CI runs the quick Foundry suite; deployed governance and production site availability were not validated.

## 6. Developer & Git History

Analyzed branch: main at 0615a10; local source/doc/test edits are additional and are not represented by committed-history statistics. Normal development: 20 commits over 182 days, 13 touching source. One named contributor accounts for source additions. Source hotspots: LuciMarket (10 commits), LuciRoyaltyModel (8). Git analysis flags no TODO debt or forked libraries; that is not evidence of security.

Test files changed alongside 76.9% of source commits; this is file co-modification, not a coverage measure. Four source commits in the last 30 days relative to HEAD's date also changed tests. Current code contains USD oracle-based royalties (3322b95), overflow/feed handling (ea76a44, 8c559b7), and selection bids (0615a10). These areas deserve review against the older external audit scope. No merge commits were detected; review outside git cannot be inferred.

## X-Ray Verdict

**ADEQUATE — structural readiness only.** Roles and boundaries are explicit, documentation and unit/fuzz/invariant tests exist; deployed governance and post-audit changes require separate validation.

**Structural facts:**
1. Two core contracts contain 671 nSLOC; interfaces add 12.
2. There are two independent Ownable2Step ownership domains and no proxy upgrade path.
3. The project contains 139 test functions and 2 invariant functions.
4. Current source includes changes after the externally reviewed commit.
