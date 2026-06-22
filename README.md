# HookSafetyGate

A standalone, default-closed admission gate for routing through Uniswap v4 pools.

`HookSafetyGate` lets any v4 integrator (a router, aggregator, periphery contract,
or off-chain solver) decide whether a pool's hook is safe to route through —
**before any token moves** — using two independent checks:

- **Layer 1 — delta-permission screen (immutable).** A hook is only ever routable
  if its address carries neither of the two return-delta permission flags
  (`BEFORE_SWAP_RETURNS_DELTA`, `AFTER_SWAP_RETURNS_DELTA`). These are the only two
  of v4's 14 hook flags that let a hook modify swap accounting. The check is pure:
  it reads only the hook's own address and never calls the hook. By the
  PoolManager's own enforcement, a hook lacking those bits cannot alter what a
  swapper pays or receives.

- **Layer 2 — default-closed allow-list (governed).** A hook is routable only if it
  has been explicitly admitted by the owner. Anything not admitted is denied. This
  covers griefing, gas exhaustion, and behaviour the flags do not describe.

The contract **holds no funds, makes no external calls, and cannot move tokens.**
It is purely a predicate (`isRoutableHook`) plus an owner-managed allow-list.

## Why this exists

v4 hooks are arbitrary third-party code in the swap path. Existing protections — the
PoolManager's flag enforcement, end-state slippage bounds, and off-chain interface
allow-lists — are each necessary but leave the routing layer without a deterministic,
on-chain, default-closed gate. Real losses have already occurred at the hook/router
layer (Cork Protocol, $11M, May 2025; z0r0z V4 Router, $42K, March 2026). This gate
is the missing enforcement piece, and the on-chain complement to the Uniswap
Foundation's prior routing-research grant to Gauntlet.

## Design principles

1. **Zero external dependencies.** Flag values are redeclared verbatim from
   `Uniswap/v4-core` `Hooks.sol` and pinned by a test (`test_constants_matchV4Core`),
   so the contract audits and deploys in isolation.
2. **Auditable in minutes.** ~90 lines of logic, no assembly, no proxies, no
   delegatecall, no token handling. Every branch maps to a stated invariant.
3. **Fail closed.** Unknown hooks are denied. A delta-flagged hook can never be
   admitted — Layer 1 is enforced at both read time and write time.

## Integration

```solidity
// Before routing a v4 leg:
if (!hookSafetyGate.isRoutableHook(address(key.hooks))) {
    // skip this pool (off-chain), or revert (on-chain execution)
}
```

Three integration paths (direct periphery patch, canonical satellite deployment,
off-chain scoring) are documented in the technical specification.

## Build & test

```bash
forge install foundry-rs/forge-std
forge build
forge test -vvv
```

## Invariants (all covered by the test suite)

- `isRoutableHook(h) == true` ⇒ `h` carries no delta flags.
- A delta-flagged hook is never routable and never allow-listable.
- Unknown hooks return `false` (default-closed).
- `address(0)` (hookless pools) is always routable.
- Only the owner can modify the allow-list.
- The contract cannot hold or move funds.

## License

MIT. The technique is published as a public good; no exclusivity is claimed.

## Author

Blaze Phoenix
