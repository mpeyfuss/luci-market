# AGENTS.md

## Scope
These instructions apply to the entire repository.

## Repository Overview
This is a Foundry-based Solidity repository. Core contracts live in `src/`, tests live in `test/`, and deployment or operational scripts live in `script/`. Dependencies are managed through Soldeer in `dependencies/` and resolved via `remappings.txt`. Check `foundry.toml`, the `Makefile`, and the `README` for project-specific layout and tooling before making changes.

## Development Standards
- Prefer well-audited libraries (such as OpenZeppelin or Solady) over custom implementations when they fit the use case.
- Keep contract logic explicit, readable, and easy to audit.
- Avoid inline assembly unless it is already established in nearby code or explicitly required.
- Preserve public interfaces, storage layout, events, and custom errors unless the task explicitly requires a breaking change.
- Be especially careful with ownership, admin roles, access control, upgradeability, and any value- or permission-bearing logic.
- Match the repository's existing Solidity style: follow the pinned compiler version in `foundry.toml`, include SPDX headers, write NatSpec for public-facing behavior, use custom errors, and assert events explicitly in tests.

## Dependencies
- Use Soldeer-managed imports from `dependencies/` and the mappings in `remappings.txt`; do not introduce another dependency mechanism.
- Do not vendor new dependencies manually.
- Match the dependency versions already pinned in the project rather than upgrading them as a side effect.
- Use `make install` (or the project's documented Soldeer install command) to add or refresh dependencies, and only refresh when a dependency change is actually intended.

## Build, Test, and Analysis Commands
Prefer the repository's `Makefile` targets when they exist; otherwise fall back to the underlying `forge` commands.
- Format with `make fmt` or `forge fmt`.
- Build with `make build` or `forge build`.
- Run the test suite with the project's test target(s) or `forge test`.
- Use narrower or faster test targets for quick feedback, and broader fuzz/invariant targets for deeper coverage when available.
- Measure gas with the project's gas target or `forge test --gas-report`.
- Measure coverage with the project's coverage target or `forge coverage`.
- Run any configured static analysis (e.g., Slither) before completing security-relevant work.

## Testing Standards
- Add or update Foundry tests for every behavioral contract change.
- Prefer focused unit tests for isolated behavior and integration-style tests for cross-contract flows.
- Assert emitted events for state-changing paths where events are part of the contract interface.
- Prefer contract constants, selectors, custom errors, and event declarations over hard-coded literals.
- Use fuzz tests for access control, input validation, arithmetic, and state transitions.
- Keep fuzz tests deterministic and constrain inputs with `vm.assume(...)` where needed.
- Maintain realistic tests for clone/proxy initialization and disabled-initializer behavior when touching deployable implementations.

## Security and Review Priorities
- Treat changes to authorization, value transfers, accounting, state mutation, external calls, and upgrade paths as high risk.
- Confirm zero-address and boundary handling, and preserve any permanent or irreversible state semantics before changing related logic.
- Preserve ERC-165 and other interface support declarations and compatibility as needed.
- Avoid broad refactors in security-sensitive code unless required by the task.

## Deployment and Environment
- Use the repository's documented deployment workflow (e.g., `forge script` or `forge create`).
- Never commit private keys, RPC secrets, ledger configuration, or populated `.env` files.
- Do not run broadcast or live-deployment targets unless explicitly requested.

## Generated and Local Artifacts
- Do not edit `out/`, `cache/`, `broadcast/`, or generated coverage artifacts by hand.
- Keep changes scoped to source, tests, scripts, docs, and configuration relevant to the task.