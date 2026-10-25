# Audit validation notes

Scope: src/LuciMarket.sol, src/LuciRoyaltyModel.sol, script/Deploy.s.sol, script/SlidingRoyaltyCalc.s.sol at cf6a0c2. Soldeer dependencies are reference material, not primary audit targets.

Runtime limit: three specialist agents run concurrently; twelve specialties are scheduled in batches per pass.

## Tool checks

- `make test-std`: 140 tests passed, 0 failed, 0 skipped across six suites. See tests.log.
- Slither: 19 contracts, 102 detectors, 15 results. An initial attempt against existing build metadata failed; a fresh build under the temporary audit directory completed. See slither.log.
- Detector triage: ETH destinations come from callers, stored sellers or the trusted royalty model; cancellation is caller-keyed. Sanctions address zero intentionally disables checks. Timestamp comparisons implement expiry/freshness. Batch external reads are user-sized and atomic. Ignored oracle fields do not defeat positive-answer, timestamp, decimal or overflow checks. A rejecting payout recipient can block its own sale/cancellation; this does not drain other escrow. No new material exploit established by these detectors.

## Known stale-listing finding: sequential gate decision

1. Attack execution — ALLOWS. buy checks seller != zero, private buyer, sanctions, allowlist, expiry and exact payment. transferFrom checks current owner and approval, but no transfer epoch.
2. Reachability — ALLOWS. External transfer and reacquisition before expiry are normal ERC-721 operations; operator approval persists. Existing integration test test_staleListingBecomesFillableAgainWhenSellerReacquiresToken passes this trace.
3. Trigger — ALLOWS. Any unprivileged buyer can pay the old public listing price. No admin action is needed.
4. Impact — ALLOWS. A seller who reacquires an appreciated NFT can lose it for the previous lower price. Requires a specific reachable lifecycle; confidence 90.

The README explicitly accepts this risk. It is retained as a known accepted risk, not presented as a new discovery. Generic ERC-721 exposes no transfer nonce, so another ownerOf check cannot fix it. A complete mitigation requires collection support or an escrow redesign. Proposed fixes in the report are not applied.

## Pass coverage

Pass 1: all twelve specialties returned; nine raised the known listing finding. Pass 2: all twelve returned; eleven raised the same finding. Neither pass raised a new group or lead. Completeness per pass: one unique (Contract, function) in raw findings, one covered in the run file. The original gate trace remains applicable; no different mechanism or new fix was introduced in pass 2.

Pass 3: all twelve specialties returned; eleven raised the same known finding. No new group, lead, mechanism or fix. Completeness: one unique (Contract, function) in raw findings, one covered in the run file. All three runs use the same four-gate decision and retain both distinct conditional fixes from pass 1.

Tool versions: Foundry 1.8.6; Slither 0.11.6. No source, test, script, dependency or configuration changes were made. The findings ledger is updated once per scan, independently of the three passes.
