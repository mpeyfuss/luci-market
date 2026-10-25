# Architecture Invariant Reference

## 1. Enforced Guards

#### G-1
**Check:** `royaltyAmount > Math.mulDiv(salePrice, MAX_ROYALTY_BPS, BASIS)` reverts.
**Location:** src/LuciMarket.sol:749.
**Purpose:** bound the royalty selected by an owner-replaceable model at both settlement entry points.

#### G-2
**Check:** `!_isInSelection(selector.selectionRoot, selector.collection, selector.tokenId, proof)` reverts.
**Location:** src/LuciMarket.sol:426.
**Purpose:** restrict a selection fill to the bidder's committed token set; allowlist validation remains independent.

## 2. Single-Contract Properties

#### I-1
**Property:** a successful sale splits exactly salePrice into royaltyAmount and sellerProceeds, with royaltyAmount <= floor(salePrice / 10).
**Category:** Conservation / Bound. **On-chain:** Yes, for successful settlement and ordinary ETH accounting.
**Derivation:** src/LuciMarket.sol:749-765 checks the ceiling, computes `sellerProceeds = salePrice - royaltyAmount`, and sends those two amounts. Failed sends revert. This is per-sale conservation, not a claim that the contract balance equals total bids; forced ETH can create surplus.

#### I-2
**Property:** stored royalty caps never exceed 1,000 basis points; royaltyRecipient is nonzero.
**Category:** Bound. **On-chain:** Yes.
**Derivation:** all cap writes are configureCollection (177-180), overrideToken (193-196), or deletion (204); both setters reject larger caps. Recipient writes occur only at 257 behind the check at 255, including constructor initialization at 97-98.

#### I-3
**Property:** listing expiration is no later than 180 days after its most recent creation/extension; purchase cannot succeed after that stored expiration.
**Category:** Temporal. **On-chain:** Yes.
**Derivation:** all expiration writes are list (244, guards 236-237) and extendListings (274, guards 260-261); buy calls the expiry check at 303, with `block.timestamp > expiresAt` at 653. Equality is fillable. This does not assert continuous ownership since listing.

## 3. Cross-Contract Properties

#### X-1
**Property:** an open listing does not preserve the royalty percentage or recipient from listing time.
**Category:** Temporal / configuration dependency. **On-chain preservation:** No, deliberately.
**Caller side:** LuciMarket.list stores seller, expiry, gross price and buyer (244); buy resolves current royalty at 312; acceptBid at 444-445.
**Callee side:** LuciRoyaltyModel configuration writes at 179-180, 195-196, 204, 231-237, 245 and 257 can change the result returned at 110-159; live feed reads can also change it.
**Meaning:** current-policy settlement is intentional. G-1 supplies a durable bound even after model replacement (LuciMarket:570-575).

## 4. Economic Consequences

#### E-1
**Property:** successful sale proceeds to the seller are at least 90% of gross sale price, before gas, despite live royalty policy changes.
**On-chain:** Yes, assuming the ETH transfer semantics and the scoped settlement paths.
**Derivation:** I-1 supplies conservation and the 10% ceiling; X-1 identifies policy variability, which does not bypass that ceiling. A reverting model or recipient can prevent a sale; this property promises no liveness.
