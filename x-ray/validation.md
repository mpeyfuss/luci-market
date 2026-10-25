# Validation — 2026-10-25

- `make test-cov`: successful build; 140 tests passed, 0 failed, 0 skipped. This includes the grouped invariant run (two invariant functions, 1,024 runs / 512,000 handler calls).
- Both core contracts: 100% lines, statements, branches and functions reported by Forge coverage (320 lines, 385 statements, 107 branches, 48 functions total).
- Runtime sizes: LuciMarket 17,634 bytes; LuciRoyaltyModel 6,073 bytes.
- `slither . --filter-paths 'dependencies|test|script'`: analyzed 19 contracts with 102 detectors, emitted 15 results across arbitrary-send-eth, unused-return, missing-zero-check, calls-loop, return-bomb, timestamp and low-level-calls. These are analyzer results, not verified vulnerabilities. Full output is preserved in slither.txt. The current run should not be described as clean based on older documentation.
- No deployment, external-service availability check, or full vulnerability validation was performed. No source or test edits were made by this review.
- Broad enumeration includes dependency tests; project-only counts are 139 test functions plus 2 invariant functions across 7 Solidity test/helper/mock files.
