# Hooke-Tinlake-Trancher

A two tranche lending pool rebuilt from Centrifuge's Tinlake, with the waterfall rules written down and tested.

> This project was developed privately and published once it had been tested against its original design. Its full development history is published on a single `main` branch so reviewers can follow it in one place.

Hooke is an open tranching model for general DeFi use, adapted from [Centrifuge's Tinlake](https://github.com/centrifuge/tinlake), the legacy codebase from Centrifuge v2. Tinlake is deprecated, but it ran with live on-chain activity until 2023 and a few of its pools are still active on mainnet. Hooke keeps Tinlake's architecture and adds its own work on the waterfall, stated as invariants and tested, so the codebase can grow into a product or serve as a reference for the research.

The aim is to make DeFi native tranching easier to study and cheaper to build on. Hooke is the contract side companion to the research in [Awesome-Tranching](https://github.com/saintsama98/Awesome-Tranching).

## What this build establishes

1. **The four actor split.** Orders, cash, valuation and orchestration live in four separate contracts. Valuation cannot move money, and orchestration cannot value anything, so each piece can be replaced on its own and a bug here is a mispricing rather than a theft.
2. **The waterfall as invariants.** `ICascade` states distribution order, loss order, conservation and diversion (I1 to I4). The arithmetic is fuzzed against them on its own, and a pool is driven through complete epochs, including a senior first fill, a junior first loss and a junior wipe out. A stateful suite then drives random orders, epochs, NAV moves and losses and checks I1 to I3 together with cash and token conservation after every step.
3. **A cleaner Tinlake.** The deviations listed below remove duplicated seams and duplicated senior math, fix an error code collision and an epoch keying edge case, and compile under solc 0.8.

## Architecture

A complete pool with two tranches is nine contracts. [`script/LenderDeployer.s.sol`](script/LenderDeployer.s.sol) deploys and wires them, and [`src/lender/Interfaces.sol`](src/lender/Interfaces.sol) declares every call one contract makes into another, so the whole architecture can be read on one page.

| Layer | Contracts | Role |
|---|---|---|
| Tranches | `Tranche` (one per seniority class) | Owns user orders and escrow. Knows nothing about seniority, the other tranches or risk. |
| Cash | `Idle` | The reserve: currency at rest between epochs. Knows nothing else. |
| Valuation | `Assessor`, with `Sacred.sol` | Owns the net asset value, the ratios, the token prices and the waterfall itself. Holds no cash. |
| Orchestration | `EpochCoordinator` | Opens and closes epochs, checks a proposed allocation and executes it. Holds no cash and computes no valuation. |
| Access | `Operator` (one per tranche) | The only caller allowed to place orders on its tranche. Checks an optional memberlist. |
| Seams | `Interfaces.sol`, `ICascade.sol` | Every cross contract call, and the waterfall interface this work is trying to generalize. |

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

1. `src/lender/Interfaces.sol`: the whole architecture on one page. Four actors and the calls between them.
2. `test/unit/Sacred.t.sol`: the invariants, fuzzed against the arithmetic alone. If you keep nothing else, keep these.
3. `test/scenario/System.t.sol`: a pool being driven through complete epochs.
4. `test/invariant/PoolInvariants.t.sol`: the same invariants held across random sequences of orders, epochs and losses.
5. `script/LenderDeployer.s.sol`: nine contracts, who knows whom, and who may mutate whom.
6. `src/lender/ICascade.sol`: the interface this work is trying to generalize.

## What is load-bearing and what is yours to change

The **four-actor split** is the point. `Tranche` owns orders and knows nothing about seniority. `Idle` owns cash and knows nothing at all. `Assessor` owns valuation and allocation and holds no money. `EpochCoordinator` orchestrates and neither values nor holds. Valuation that cannot move money is why a bug here is a mispricing rather than a theft.

The **invariants** in `ICascade` (I1 distribution order, I2 loss order, I3 conservation, I4 diversion) are what make this a waterfall rather than a pro-rata pool. Breaking one changes the instrument, not the implementation.

Everything else is calibration and is meant to be replaced:

| Extension point | Where | Default |
|---|---|---|
| Valuation | `INavLike` | `test/mocks/SimpleNAVFeed.sol`, a number somebody sets |
| Fill policy | `EpochCoordinator.scoreSolution`, `virtual` | redemptions before subscriptions, senior before junior |
| Risk band | `Assessor.file` | set at deploy |
| Permissioning | `IMemberlistLike` on the operator | none, permissionless |
| Tranche count | `Assessor.trancher` | two |

## Two things this deliberately does not do

**It does not value anything.** `INavLike` is a seam with a one-line mock behind it. Every tranched pool that has failed, on-chain or off, failed at valuation rather than at distribution. The guarantees here are conditional on a correct NAV and the code has no way to tell you the NAV is wrong.

**It does not divert cash flow on a coverage test.** I4 is written into `ICascade` and upheld vacuously, because the surface does not yet expose loss allocation or a coverage trigger. Tinlake enforces its ratio band by refusing to execute an epoch; a CLO enforces it by re-routing the waterfall. Those are different mechanisms and only the first is implemented. The second is not implemented.

## Deviations from Tinlake, and why

- **`Fixed27` is a file-level struct.** Tinlake reaches the type by inheriting `FixedPoint`, which works only because its seams are `contract`s with unimplemented functions, illegal under solc 0.8.
- **Seams live in one file.** Tinlake declares `*Like` inline per file, so `IdleLike` existed three times with three different member sets and nothing forced them to agree.
- **Senior state and ratio math live in `Sacred.sol`.** Tinlake carries a copy of `calcSeniorAssetValue` in both `assessor` and `coordinator`, kept in step by hand.
- **The off-chain solver is `virtual`, not transcribed.** The state machine and the constraint checks are exact. The weights that rank a submission are a policy choice, so they are an override rather than a prerequisite.
- **Error codes renumbered to Tinlake's.** The previous `ERR_MAX_RESERVE = -2` collided with Tinlake's `ERR_MAX_ORDER`.
- **Empty epochs key by `lastEpochExecuted + 1`.** Tinlake keys them by `currentEpoch`, which agrees with the execution path only while no epoch is ever skipped.

## Roles

| Role | Can do |
|---|---|
| Suppliers and redeemers | Place supply and redeem orders through their tranche's operator, collect with `deservedRelease` |
| Operator | The only caller allowed to place orders on its tranche, gated by the memberlist when one is set |
| Coordinator | Drives both tranches through the epoch handshake, settles the senior split in the assessor once per executed epoch, opens and closes the reserve's draw window |
| Tranches | Move currency in and out of the reserve during `epochUpdate` |
| Keeper (anyone) | Close an epoch once its minimum time has passed, submit solutions during the submission period, execute the epoch |
| Deployer | Admin on every contract until `denyDeployer` is called, which it should be |

Every privileged edge in the pool is one of the eight `rely` calls in [`script/LenderDeployer.s.sol`](script/LenderDeployer.s.sol), written out one by one rather than granted in a loop.

## Build and test

Foundry, solc 0.8.28.

```
forge build
forge test
```

| Suite | Covers |
|---|---|
| `test/unit/Sacred.t.sol` | The `ICascade` invariants fuzzed against the arithmetic alone: ratios conserve, junior absorbs first, senior never exceeds assets |
| `test/scenario/SubmissionPeriod.t.sol` | The submission period: the best submission wins, base constraints are absolute, no submission outside the period |
| `test/scenario/System.t.sol` | Complete epochs: full lifecycle, redeem round trip, senior first fills, junior first losses, pool closure when junior is wiped out, empty epochs, auth gating |
| `test/unit/Interest.t.sol` | The compounding guards: future timestamps and a zero rate revert with custom errors, a unit rate charges nothing |
| `test/invariant/PoolInvariants.t.sol` | Seven stateful invariants over a handler (`test/invariant/handlers/PoolHandler.sol`) that drives orders, epochs, NAV moves and losses: I1 to I3, cash conservation, the reserve ledger matching its balance, and tokens held only by lenders or escrow |

Fuzz and invariant runs are set per profile in `foundry.toml`: the default profile for local runs, `pr` for pull requests and `ci` for pushes to `main`. `FOUNDRY_PROFILE=ci forge test` reproduces the deepest run.

## Third-party code and licenses

| Component | Use | License |
|---|---|---|
| [Centrifuge Tinlake](https://github.com/centrifuge/tinlake) | Source of the lender contracts, `src/FixedPoint.sol` and part of `src/math/Math.sol`, adapted file by file | AGPL-3.0-only |
| [tinlake-math](https://github.com/centrifuge/tinlake-math) | Source of `src/math/Math.sol` and `src/math/Interest.sol` | AGPL-3.0-only |
| [tinlake-auth](https://github.com/centrifuge/tinlake-auth) | Source of `src/auth/Auth.sol` | AGPL-3.0-only |
| [forge-std](https://github.com/foundry-rs/forge-std) | Test library, git submodule under `lib/` | MIT OR Apache-2.0 |

[`NOTICE`](NOTICE) maps every adapted file to the upstream file it comes from and keeps the upstream copyright lines.

## Status

Research build. Not audited. Not deployed.

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE). Hooke is a modified version of the three Centrifuge projects listed above, all AGPL-3.0-only.
