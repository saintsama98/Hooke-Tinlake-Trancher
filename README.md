# Hooke-Tinlake-Trancher

A two tranche lending pool rebuilt from Centrifuge's Tinlake, with the waterfall rules written down and tested.

> This project was developed privately and published once it had been tested against its original design. Its full development history is published on a single `main` branch so reviewers can follow it in one place.

Hooke is an open tranching model for general DeFi use, built around [Centrifuge's Tinlake](https://github.com/centrifuge/tinlake), the legacy codebase from Centrifuge v2. Tinlake is deprecated, but it ran with complete live onchain activity until 2023 and a few of its pools are still active on mainnet. Hooke keeps the architecture that motivated it and adds its own research and development on the systematic waterfall, so the codebase can evolve into a product or serve as an extension of the open research.

The purpose of Hooke is to deepen the ongoing research on DeFi native tranching and to lower the build complexity for developers and the community. It provides the contract side context for the research and data in [Awesome-Tranching](https://github.com/saintsama98/Awesome-Tranching), which is the official source for Hooke.

## What this build establishes

1. **The four actor split.** Orders, cash, valuation and orchestration live in four separate contracts. Valuation cannot move money, and orchestration cannot value anything, so each piece can be replaced on its own and a bug here is a mispricing rather than a theft.
2. **The waterfall as invariants.** `ICascade` states distribution order, loss order, conservation and diversion (I1 to I4). The arithmetic is fuzzed against them on its own, and a pool is driven through complete epochs, including a senior first fill, a junior first loss and a junior wipe out.
3. **A cleaner Tinlake.** The deviations listed below remove duplicated seams and duplicated senior maths, fix an error code collision and an epoch keying edge case, and compile under solc 0.8.

## Architecture

A complete pool with two tranches is nine contracts. [`script/deployer.sol`](script/deployer.sol) deploys and wires them, and [`src/lender/interfaces.sol`](src/lender/interfaces.sol) declares every call one contract makes into another, so the whole architecture can be read on one page.

| Layer | Contracts | Role |
|---|---|---|
| Tranches | `Tranche` (one per seniority class) | Owns user orders and escrow. Knows nothing about seniority, the other tranches or risk. |
| Cash | `idle` | The reserve: currency at rest between epochs. Knows nothing else. |
| Valuation | `assessor`, with `sacred.sol` | Owns the net asset value, the ratios, the token prices and the waterfall itself. Holds no cash. |
| Orchestration | `EpochCoordinator` | Opens and closes epochs, checks a proposed allocation and executes it. Holds no cash and computes no valuation. |
| Access | `Operator` (one per tranche) | The only caller allowed to place orders on its tranche. Checks an optional memberlist. |
| Seams | `interfaces.sol`, `ICascade.sol` | Every cross contract call, and the waterfall interface this work is trying to generalise. |

### An epoch, in order

```
users place supply and redeem orders on a tranche through its operator
-> closeEpoch: the coordinator takes the order totals and the current valuation
-> submitSolution: a proposed fill is checked against the pool constraints and scored
-> executeEpoch: the best valid fill is applied and the senior split is settled
-> users collect currency or tokens with deservedRelease
```

Redemptions are filled before subscriptions and senior before junior by default. An epoch with no orders still advances.

## Bootstrapping on this

This is a structural reference, not a product. It compiles, it is tested, and the seams are real. The intent is that you fork it, keep the parts that are load-bearing, and replace the parts that are policy.

### Reading order

1. `src/lender/interfaces.sol` - the whole architecture on one page. Four actors and
the calls between them.
2. `test/lender/sacred.t.sol` - the invariants, fuzzed against the arithmetic alone.
If you keep nothing else, keep these.
3. `test/lender/system.t.sol` - a pool being driven through complete epochs.
4. `script/deployer.sol` - nine contracts, who knows whom, and who may mutate whom.
5. `src/lender/ICascade.sol` - the interface this work is trying to generalise.

## What is load-bearing and what is yours to change

The **four-actor split** is the point. `tranche` owns orders and knows nothing about
seniority. `idle` owns cash and knows nothing at all. `assessor` owns valuation and
allocation and holds no money. `coordinator` orchestrates and neither values nor
holds. Valuation that cannot move money is why a bug here is a mispricing rather
than a theft.

The **invariants** in `ICascade` (I1 distribution order, I2 loss order, I3
conservation, I4 diversion) are what make this a waterfall rather than a pro-rata
pool. Breaking one changes the instrument, not the implementation.

Everything else is calibration and is meant to be replaced:

| Extension point | Where | Default |
|---|---|---|
| Valuation | `NavLike` | `test/mock/navfeed.sol`, a number somebody sets |
| Fill policy | `EpochCoordinator.scoreSolution`, `virtual` | redemptions before subscriptions, senior before junior |
| Risk band | `assessor.file` | set at deploy |
| Permissioning | `MemberlistLike` on the operator | none, permissionless |
| Tranche count | `assessor.trancher` | two |

## Two things this deliberately does not do

**It does not value anything.** `NavLike` is a seam with a one-line mock behind it.
Every tranched pool that has failed, on-chain or off, failed at valuation rather than
at distribution. The guarantees here are conditional on a correct NAV and the code
has no way to tell you the NAV is wrong.

**It does not divert cash flow on a coverage test.** I4 is written into `ICascade`
and upheld vacuously, because the surface does not yet expose loss allocation or a
coverage trigger. Tinlake enforces its ratio band by refusing to execute an epoch; a
CLO enforces it by re-routing the waterfall. Those are different mechanisms and only
the first is implemented. The second is not implemented.

## Deviations from Tinlake, and why

- **`Fixed27` is a file-level struct.** Tinlake reaches the type by inheriting
`FixedPoint`, which works only because its seams are `contract`s with unimplemented
functions, illegal under solc 0.8.
- **Seams live in one file.** Tinlake declares `*Like` inline per file, so `IdleLike`
existed three times with three different member sets and nothing forced them to agree.
- **Senior state and ratio maths live in `sacred.sol`.** Tinlake carries a copy of
`calcSeniorAssetValue` in both `assessor` and `coordinator`, kept in step by hand.
- **The off-chain solver is `virtual`, not transcribed.** The state machine and the
constraint checks are exact. The weights that rank a submission are a policy choice,
so they are an override rather than a prerequisite.
- **Error codes renumbered to Tinlake's.** The previous `ERR_MAX_RESERVE = -2`
collided with Tinlake's `ERR_MAX_ORDER`.
- **Empty epochs key by `lastEpochExecuted + 1`.** Tinlake keys them by `currentEpoch`,
which agrees with the execution path only while no epoch is ever skipped.

## Roles

| Role | Can do |
|---|---|
| Suppliers and redeemers | Place supply and redeem orders through their tranche's operator, collect with `deservedRelease` |
| Operator | The only caller allowed to place orders on its tranche, gated by the memberlist when one is set |
| Coordinator | Drives both tranches through the epoch handshake, settles the senior split in the assessor once per executed epoch, opens and closes the reserve's draw window |
| Tranches | Move currency in and out of the reserve during `epochUpdate` |
| Keeper (anyone) | Close an epoch once its minimum time has passed, submit solutions during the submission period, execute the epoch |
| Deployer | Admin on every contract until `denyDeployer` is called, which it should be |

Every privileged edge in the pool is one of the eight `rely` calls in [`script/deployer.sol`](script/deployer.sol), written out one by one rather than granted in a loop.

## Build and test

Foundry, solc 0.8.28.

```
forge build
forge test
```

| Suite | Covers |
|---|---|
| `test/lender/sacred.t.sol` | The `ICascade` invariants fuzzed against the arithmetic alone: ratios conserve, junior absorbs first, senior never exceeds assets |
| `test/lender/submission.t.sol` | The submission period: the best submission wins, base constraints are absolute, no submission outside the period |
| `test/lender/system.t.sol` | Complete epochs: full lifecycle, redeem round trip, senior first fills, junior first losses, pool closure when junior is wiped out, empty epochs, auth gating |

## Status

Written for study, and under development. It is not audited and it has never held money.

## License

MIT. See [`LICENSE`](LICENSE).
