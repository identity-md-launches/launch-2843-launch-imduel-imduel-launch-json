# IMDuel

IMDuel is chess played by swaps through `IMDuelHook`. The committed `launch.json`
launches the fixed-supply IMDuel token (`IMDUEL`) and its IMD pool on Ethereum.

The hook constructor is
`(IPoolManager manager, IChessEngine engine, Currency imd, uint256 turnBlocks)`.
The factory supplies the PoolManager; the other committed arguments are
`0xc21788f704a8b9456f7391a01d8a3d95be215a27` (ChessEngineV5),
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD), and `3`.
The engine is already deployed and is not deployed by this launch. Construction
does not call it. There are no owners, administrators, signers, pause controls or
upgrade paths in the hook or token.

The token has a nonpayable constructor with no arguments, 18 decimals, and
exactly `10^27` minor units minted once to its deployer, the factory. The factory
handles the launch allocations. The token has ordinary transfers and allowances,
with no transfer tax or later minting. The manifest's `token.constructorArgs`
and `token.totalSupply` are informational extra fields: supply is enforced by
the token constructor and launch policy, not those fields.

The pool uses fee `12500` and tick spacing `60`. The factory derives its opening
price from the launch policy and the deployed token's address. The first pool
initialized in the factory's atomic launch becomes the main duel; its currency
other than IMD is learned as IMDUEL. The hook enables `afterInitialize`,
`beforeSwap`, `afterSwap`, and both swap return-delta permissions. All callbacks
accept only the PoolManager. No liquidity callbacks restrict factory LP fee
collection.

## Fees and play

The hook fee is 0.75%, on top of the pool's 1.25% LP fee, with no opening surcharge
and no price reads. Each side of a trade contributes 0.325% of that side's amount
to its token's pot. The remaining 0.1% is taken in IMDUEL when present, owed to
`0x000000000000000000000000000000000000dEaD`; anyone can call
`withdraw(dead, imduel)` to send it there. This moves tokens to the burn address;
the ERC-20's fixed `totalSupply` does not decrease. In a duel without IMDUEL,
the slice is taken in IMD and added to the main duel's IMD pot. Fees are ERC-6909
claims in the PoolManager, so collecting them during a swap needs no upfront ETH
balance or token transfer to the hook. Each fee-bearing swap emits URC-2
`HookSwap`. An order that only partially fills reverts.

Every swap bids for the team of the token received. A new top bid must exceed
the current bid by more than 10%. Strength depends on the received amount as a
share of that team's pot: 0% at a 0.1% share, approximately 30% at 1%, 60% at
10%, and at most 90% from a whole pot. A later swap resolves the closed window
through the engine. The launch's window is three blocks; a silent side times
out after 600 seconds. A closing-block builder can influence that block's hash;
this remains an accepted design risk.

Only a checkmate pays the mating move's owner, in the loser's token: the minimum
of one quarter of the losing pot, twice the mating bid's payment, and that game's
trade contributions to the losing pot. Captures, checks, draws and timeout moves
pay nothing. Rewards are recorded in `owed`, with no recipient transfer inside
a swap. Anyone can call `withdraw(who, currency)`, which pays only `who`;
`withdrawTo(currency, recipient)` redirects only the caller's own claim. A claim
retains one wei. Per-address stats and the player list count main-duel play for
display only.

## Wallet and router integration

**Relayed smart wallets must pass their intended bid owner in `hookData`.** Use
exactly `abi.encode(walletAddress)` (32 bytes) or
`abi.encodePacked(walletAddress)` (20 bytes), forwarded unchanged to the pool's
swap. That address owns the bid, the move, its stats and any mate payout.

Empty or malformed data, dirty ABI padding, and the zero, hook, PoolManager or
burn address fall back to `tx.origin`. For a Safe or ERC-4337 account behind a
router, this can be the relayer or bundler, which then receives the reward.
The hook cannot recover the wallet from the callback's `sender`, which is the
router. A router that cannot forward `hookData` cannot provide wallet attribution
for relayed trades. This fallback is retained as specified in `launch.json`.
The address is an explicit beneficiary, not a signature or authentication claim;
integrators must construct it from the wallet's intended recipient.

Gas estimates are state dependent. An estimate made while bidding is open does
not include a move if the transaction lands after the window closes. Budget for
resolution even when an estimate observes the open window: the primary engine
cap is 3,000,000 gas, with another 2,000,000 for fallback, plus hook, router and
settlement overhead. The local single-hop regression uses a 6,000,000 router
call budget; it is not a universal bound for aggregators or multi-hop routes.
Before each engine call the hook requires its complete gas cap, the EIP-150
forwarding margin, and a 300,000-gas reserve for recording the result and
continuing the swap. Underfunded calls revert early with `NotEnoughGas`, wrapped
by the PoolManager. Consequently, a resolution estimate reserves over three
million gas even when the actual move consumes much less; unused gas is returned.
Re-estimate against the inclusion state and account for each hook resolution
along the route. A failed transaction is atomic and may be retried with sufficient
gas; it does not cancel the queued bid or change the pots.

## Local checks

Use the committed Foundry configuration and vendored dependencies:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe8816041d7a517ef79966162f0fea0f911d4436d59d99935d60bf1744dd02edf forge test
```

`test/FactoryLaunch.t.sol` deploys the real token and hook through a local factory
in both token orders, opens and seeds the pool in the same call, trades exact
input and exact output in both directions, checks burn claims and accounting,
and collects fees with a zero liquidity change. It uses the committed static
constructor arguments and a local PoolManager. This is an offline rehearsal,
not a fork or a deployment. `test/AuditRegression.t.sol` covers the imported
wallet attribution and gas findings. See `ADAPTATION.md` for their disposition.
