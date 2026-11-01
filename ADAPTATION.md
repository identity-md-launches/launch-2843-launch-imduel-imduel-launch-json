# IMDuel launch adaptation

The committed launch already has callable nonpayable constructors: four static
arguments for `IMDuelHook` and no arguments for `IMDuelToken`. The token mints the
policy's entire fixed supply to its deployer. No constructor, manifest,
permissions, compiler setting or dependency needed adaptation.

## Changes

| File | Change and reason |
| --- | --- |
| `src/IMDuelHook.sol` | Check the complete engine cap, EIP-150 forwarding margin and a 300,000-gas reserve before each engine call. This is the only production source change, required by the reproduced gas audit finding below. It preserves the engine caps, deferred swap-driven play, payout rules, constructors and permissions. |
| `test/AuditRegression.t.sol` | Reproduce the closed-window failure and assert its exact wrapped `NotEnoughGas` signal, unchanged state on failure, and successful retry through the real engine. Also exercise gas exhaustion in the fallback, and actual relayed-wallet bids, move ownership, stats, mate rewards and withdrawals with empty, packed and ABI-encoded `hookData`. |
| `test/FactoryLaunch.t.sol` | Add an atomic CREATE2 factory rehearsal using the production token and hook, the committed arguments, a real local PoolManager, and both token orders. Cover construction without engine code, single-sided seeding, exact-input and exact-output buys and sells, engine play, URC-2 events, claim solvency, burn withdrawals and the factory's zero-liquidity fee collection. Existing launch tests use mock tokens or the hook harness; this exercises the contracts the launch actually deploys. |
| `test/Hostile.t.sol` | Extend the existing engine-starvation gas sweep through 4,000,000 gas to cover the new up-front admission threshold while continuing to require both refusals and successful engine moves without fallback. |
| `README.md` | Document the committed launch, economics and the integration mitigation for wallet attribution. Explain resolution gas budgets and retries, claim withdrawals, and the informational manifest fields. |
| `ADAPTATION.md` | Record scope, audit reproduction, changes and verification as required by the assignment. |

`launch.json`, all other `src/` files, `foundry.toml`, and dependencies are
unchanged. No installation, signer, backend, owner setting, deployment or
initialization transaction is required from the requester. The deployer still
resolves `$poolManager`, mines the hook address for the existing permissions,
and deploys the token and hook before opening the first pool atomically.

## Imported audit findings

**110c2538d76f2eab119a417a466a80ffa8ea6c97d8310a158ea3b9d20c0744e9 —
relayed-wallet attribution: reproduced; documented integration mitigation.**
`test_emptyHookDataReproducesAcceptedRelayerAttribution` sends an actual wallet's
trade through a router with a different `tx.origin`. The relayer owns the bid,
move, stats and mate payout and receives the withdrawal. The packed and
ABI-encoded tests repeat that path with the wallet in `hookData`; the wallet
receives all attribution and the payout, while the relayer is owed nothing.

The audit explicitly offers documentation as a mitigation, and the committed
manifest expressly accepts this fallback. The new README requires relayed
wallet integrations to forward the beneficiary and identifies the consequence
of omitting it. Replacing `tx.origin` with the callback's `sender` would credit
the router in this reproduction, not the wallet. Adding a router registry,
administrator or signer would change the requested design. The on-chain
fallback therefore remains, with its residual risk explicit; it is not claimed
to have been eliminated for integrations that omit `hookData`.

**65340217845b4492448be8aab3d40731dbd4d3c8528716caeae9bd6b384af233 —
opaque engine starvation: reproduced and fixed.**
On the original source, the new regression measured an open-window swap, sent
it successfully with 30% headroom, then advanced past the three-block close and
retried with that same budget. The PoolManager wrapped an empty hook error
instead of `NotEnoughGas` (`0xdd629f86`). Six of the seven added tests passed;
this assertion failed, establishing the defect before the source edit.

The local trace also exposed an adjacent path: the engine can successfully
return but leave too little gas to record its move, producing the same empty
error. Reserving only enough gas for a failed engine call would not fix that.
The repair checks the complete engine cap and its EIP-150 margin before making
the call, with another 300,000 gas for recording the result and continuing the
swap. Insufficient gas is rejected before the engine can consume it. Both the
primary and fallback calls use this guard, so starvation cannot select a weaker
move or force a draw. The original 3,000,000 and 2,000,000 caps still apply.
Estimates for closed-window resolution now reserve the full cap even when
actual execution uses less; unused gas is returned. The source change is limited
to this reproduced finding under the assignment's audit-fix exception; it
does not move resolution out of swaps or lower engine strength.

The timing-dependent cost itself remains: a move takes more gas than an open
bid, so integrations must budget for resolution. The README states this and
does not promise that every out-of-gas failure anywhere in a router will carry
the hook's custom error.

**cf9570372670f5cb587b42a6a9bdb0c86389bc942b4aa03bf9b8f83413fc9def —
extra manifest keys: confirmed as informational; no manifest edit.**
`token.constructorArgs` and `token.totalSupply` exist outside the supplied
manifest field list. They are not deployment authority. The real token's
zero-argument constructor and policy supply are exercised by the factory
rehearsal. This does not prevent launching, so the instruction to preserve
`launch.json` applies. The README explains the fields. The engine address is
the supplied address; the previous audit's mainnet bytecode identity check was
not independently repeated here.

**cce8f2709e5ded07c52f51f33090b015c58b42896c6b14ac0a47d9afc1d3cee5 —
coverage report: not a defect.**
This entry reports the previous audit's work and closed leads, so it supplies
no change to reproduce or fix. The existing economics, hostile-token, gas,
token and invariant tests are retained. The pinned floor tests and security
references were read; their verifier-only harness imports and environment are
not installed into this project. The new local factory tests exercise the
relevant deployment, initialization and LP fee collection flows without them.

## Verification

All checks use the project's existing Solidity 0.8.26 / Cancun / via-IR /
200-run configuration and vendored dependencies. Test commands use
`FOUNDRY_FUZZ_SEED=0xe8816041d7a517ef79966162f0fea0f911d4436d59d99935d60bf1744dd02edf`.

- Original `forge build`: passed with existing compiler/lint warnings.
- New tests before the repair: six passed; the gas error regression failed with
  the empty wrapped reason described above. Both factory token orders passed.
- Final `forge build`: passed with compiler/lint warnings; no configuration
  changes or dependency installation.
- Final `forge test` with the seed above: **184 passed, 0 failed, 0 skipped**
  across 26 suites, including the existing fuzz and invariant tests.
- `forge test --isolate --match-contract 'AuditRegressionTest|FactoryLaunchTest'`
  with the same seed: **7 passed, 0 failed, 0 skipped**, also checking the new
  gas regressions and both factory token orders with transaction isolation.
- Artifact inspection: hook runtime 16,900 bytes, token runtime 1,088 bytes,
  both below EIP-170; creation code has no unresolved library links and each
  constructor is nonpayable with the committed argument types. The unchanged
  local engine build is 23,339 bytes.
- Original-file SHA-256 comparison: `launch.json`, `foundry.toml` and every
  production source except the documented hook fix are unchanged.

This work performs local tests, not a mainnet fork, an on-chain engine-code
check, formal verification, or a new Slither run. No test depends on a network
connection or the temporary `.imd/reads` inputs.
