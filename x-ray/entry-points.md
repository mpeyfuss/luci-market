# Entry Point Map

23 source-declared state-changing external functions; inherited ownership functions listed separately. Inputs are caller-controlled; stored bid keys bind bid management to msg.sender. All 9 market trading entry points use nonReentrant; admin setters do not. No initializer, receive or fallback entry point.

## Protocol Flow Paths

```text
Deploy model → deploy market → configure policy and eligibility
Seller approve NFT → list → buyer buy → NFT transfer + ETH split
Bidder placeBid → optional increaseBid / extendBids → seller acceptBid
Site build tree → bidder place selection bid → seller supply proof → acceptBid
Bidder placeBid → cancelBids → ETH refund (also during pause)
Seller list → extendListings / delist (delist also during pause)
Owner nominate owner → pending owner acceptOwnership
```

## User Entry Points

| Function | Access | State | External calls / value |
|---|---|---|---|
| list | Current NFT owner, unsanctioned | listings overwrite | Sanctions; ownerOf and approvals; no value |
| extendListings | Stored seller and current NFT owner | listing expiries | Sanctions; ownerOf and approvals; no value |
| delist | Stored seller | delete own listings | No external calls or value |
| buy | Public, or listing's designated buyer | delete listing | Sanctions, model → feed, NFT transfer, ETH in and payouts |
| placeBid | Public, unsanctioned | create caller's bid | Sanctions; ETH in |
| increaseBid | Public, caller's existing bid | add msg.value to caller's amount | Sanctions; ETH in |
| acceptBid | NFT seller, enforced by ERC-721 transferFrom | delete bid and listing | Sanctions, model → feed, NFT transfer; escrow out |
| extendBids | Public, caller's existing bids | bid expiries | Sanctions; no value |
| cancelBids | Public, caller's existing bids | delete bids | Sanctions; aggregate ETH refund |

All except delist/cancelBids require unpaused state. Membership proofs and minAmount are seller-provided; selection root is bidder-selected. Private buy, listing ownership and NFT seller restrictions are conditional/address-based authorization, not protocol admin roles. Permissionless caller-scoped bid APIs cannot modify another bidder's keys.

## Admin Entry Points

Market owner: setPaused → paused; addCollection/removeCollection → allowedCollections; addToken/removeToken → allowedTokens; setRoyaltyModel → royaltyModel; setSanctionsList → sanctionsList; setSelectionBaseUri → selectionBaseUri.

Royalty owner: setRoyaltyRecipient → royaltyRecipient; configureCollection → collections; overrideToken/clearTokenOverride → tokenOverrides; configureCurrency/removeCurrency → currencies.

These setters are onlyOwner, accept owner-provided inputs, transfer no value and make no external calls. Market and model ownership are separate.

## Inherited Ownership Entry Points (each contract)

- transferOwnership: current owner nominates pendingOwner (including cancellation with zero); no value or external call.
- acceptOwnership: pending owner only; updates owner and clears pendingOwner.
- renounceOwnership: current owner only; clears owner and pendingOwner; no restoration mechanism.

## Source Scan

```text
src/LuciMarket.sol:227: LuciMarket.list(address collection, uint256 tokenId, uint256 price, uint64 expiresAt, address buyer) external nonReentrant whenNotPaused
src/LuciMarket.sol:254: LuciMarket.extendListings(Token[] calldata tokens, uint64 expiresAt) external nonReentrant whenNotPaused
src/LuciMarket.sol:283: LuciMarket.delist(Token[] calldata tokens) external nonReentrant
src/LuciMarket.sol:295: LuciMarket.buy(address collection, uint256 tokenId) external payable nonReentrant whenNotPaused
src/LuciMarket.sol:328: LuciMarket.placeBid(BidSelector calldata bidSelector, uint64 expiresAt) external payable nonReentrant whenNotPaused
src/LuciMarket.sol:364: LuciMarket.increaseBid(BidSelector calldata bidSelector) external payable nonReentrant whenNotPaused
src/LuciMarket.sol:405: LuciMarket.acceptBid(BidSelector calldata bidSelector, address bidder, uint256 minAmount, bytes32[] calldata proof) external nonReentrant whenNotPaused
src/LuciMarket.sol:470: LuciMarket.extendBids(BidSelector[] calldata bidSelectors, uint64 expiresAt) external nonReentrant whenNotPaused
src/LuciMarket.sol:506: LuciMarket.cancelBids(BidSelector[] calldata bidSelectors) external nonReentrant
src/LuciMarket.sol:538: LuciMarket.setPaused(bool paused_) external onlyOwner
src/LuciMarket.sol:544: LuciMarket.addCollection(address collection) external onlyOwner
src/LuciMarket.sol:550: LuciMarket.removeCollection(address collection) external onlyOwner
src/LuciMarket.sol:557: LuciMarket.addToken(address collection, uint256 tokenId) external onlyOwner
src/LuciMarket.sol:564: LuciMarket.removeToken(address collection, uint256 tokenId) external onlyOwner
src/LuciMarket.sol:570: LuciMarket.setRoyaltyModel(address newRoyaltyModel) external onlyOwner
src/LuciMarket.sol:578: LuciMarket.setSanctionsList(address newSanctionsList) external onlyOwner
src/LuciMarket.sol:587: LuciMarket.setSelectionBaseUri(string calldata newSelectionBaseUri) external onlyOwner
src/LuciRoyaltyModel.sol:168: LuciRoyaltyModel.setRoyaltyRecipient(address newRoyaltyRecipient) external onlyOwner
src/LuciRoyaltyModel.sol:176: LuciRoyaltyModel.configureCollection(address collection, uint192 mintPriceUsd, uint16 maxRoyaltyBps) external onlyOwner
src/LuciRoyaltyModel.sol:189: LuciRoyaltyModel.overrideToken(address collection, uint256 tokenId, uint192 mintPriceUsd, uint16 maxRoyaltyBps) external onlyOwner
src/LuciRoyaltyModel.sol:203: LuciRoyaltyModel.clearTokenOverride(address collection, uint256 tokenId) external onlyOwner
src/LuciRoyaltyModel.sol:219: LuciRoyaltyModel.configureCurrency(address currency, address oracle, uint8 currencyDecimals, uint8 oracleDecimals, uint32 maxAge) external onlyOwner
src/LuciRoyaltyModel.sol:244: LuciRoyaltyModel.removeCurrency(address currency) external onlyOwner
# 23 entry point(s) in 2 of 2 .sol file(s)
```
