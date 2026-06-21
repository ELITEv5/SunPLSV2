# SunPLS

**Autonomous · Ownerless · Immutable · PulseChain**

SunPLS is a decentralized CDP (Collateralized Debt Position) protocol on PulseChain. Users lock PLS as collateral and mint SunPLS — an experimental native floating-peg asset whose value is governed by an autonomous on-chain monetary policy engine. There are no admin keys, no upgradeability, no owner functions. Once deployed, the contracts run forever without human intervention.

SunPLS is inspired by RAI (Reflexer Finance) and improves upon its shortcomings: 10× stickier redemption value, no negative rates, and a Stability Pool that earns WPLS yield from liquidations. RAI is used only as a familiar reference point — SunPLS has its own architecture, its own float, and its own on-chain equilibrium.

> *"If stablecoins truly become infrastructure then the systems that matter most will be the ones that no one controls."*
> — ProjectUSD specification author

---

## Table of Contents

1. [Intellectual Lineage](#intellectual-lineage)
2. [ProjectUSD Specification](#projectusd-specification)
3. [What is SunPLS?](#what-is-sunpls)
4. [System Architecture](#system-architecture)
5. [The Floating Peg — R vs P](#the-floating-peg--r-vs-p)
6. [Three Stability Layers](#three-stability-layers)
7. [The Rate Engine (Controller)](#the-rate-engine-controller)
8. [The Oracle](#the-oracle)
9. [How to Use the Protocol](#how-to-use-the-protocol)
10. [Vault Health Zones](#vault-health-zones)
11. [Liquidations](#liquidations)
12. [Redemptions](#redemptions)
13. [Stability Pool](#stability-pool)
14. [RAI Architecture Improvements](#rai-architecture-improvements)
15. [Emergency Unlock](#emergency-unlock)
16. [System Invariants](#system-invariants)
17. [Design Goals](#design-goals)
18. [Deployed Contracts](#deployed-contracts)
19. [Compiling the Contracts](#compiling-the-contracts)
20. [Security Model](#security-model)
21. [Frontend Files](#frontend-files)
22. [Acknowledgements](#acknowledgements)

---

## Intellectual Lineage

SunPLS sits at the intersection of two independent lines of thinking that arrived at the same conclusion 50 years apart.

In 1976, economist Friedrich Hayek published *Denationalisation of Money*, arguing that government monopoly on currency issuance was the root cause of monetary instability. His proposed solution: competing private currencies that earn trust through demonstrated stability — not legal mandate, not institutional backing, not governance decisions. Every central bank ignored him. He lacked the trustless infrastructure to make it real.

The ProjectUSD specification translated Hayek's vision into a concrete architectural framework for autonomous stable assets — defining the P/R/r feedback loop, the redemption mechanism, and the closed-loop stability guarantee that requires no external reference, no oracle dependency on USD, and no human discretion at any point in the system.

SunPLS is an implementation of that specification on PulseChain.

The architecture is not pegged to the dollar. It is not pegged to any external asset. It defines its own internal equilibrium price R and defends it through mathematics. The "bank" is immutable Solidity. The "monetary policy" is a proportional controller that executes identically whether it processes $100 or $100 million. No board meeting required.

The intellectual lineage traces from Hayek's 1976 work through the ProjectUSD specification to this implementation. The spec author and the SunPLS development team arrived at compatible conclusions independently — the spec from first-principles reasoning about trustless monetary architecture, the implementation from practical CDP building experience on PulseChain. Notably, the spec author was aware of Hayek but did not realize until later how precisely the specification reproduced his conclusions. This is corroboration, not citation — three independent lines of reasoning converging on the same architecture across 50 years.

---

## ProjectUSD Specification

SunPLS follows the **ProjectUSD architecture specification**.

ProjectUSD defines a framework for building fully autonomous stable assets that operate without discretionary governance. The specification emphasizes:

- Deterministic monetary policy
- Immutable contracts
- Oracle resilience
- Closed-loop stability control
- Economic safety invariants
- System liveness under degraded conditions

ProjectUSD specification: https://github.com/Aqua75/ProjectUSD

---

## What is SunPLS?

SunPLS is a **closed-loop autonomous monetary system**. Users lock PLS as collateral and borrow SunPLS against it. SunPLS is not pegged to USD or any external asset — it tracks an internal redemption value R that floats autonomously based on market pressure. R started at 1.227 WPLS at launch and drifts slowly over time. The market chases R; R does not chase the market.

The protocol continuously observes market price and adjusts economic incentives through the Controller:

```
Market Price (P)
       ↓
Controller Policy
       ↓
Stability Rate (r)
       ↓
Vault Incentives
       ↓
Supply Changes
       ↓
Market Price
       ↺
```

This feedback loop allows the system to dynamically adjust borrowing incentives and supply conditions in response to market deviation — with no human in the loop at any step.

The token supply expands when users open vaults and mint, and contracts when users repay, redeem, or get liquidated. The protocol has no treasury, no admin fee receiver, and no governance token. It is a self-contained economic machine.

**Key properties:**
- Stability rate is always ≥ 0% — borrowing is free at worst, never subsidized
- R moves at most 1% per epoch (10× stickier than prior architecture)
- Stability Pool earns WPLS from liquidations and stability fees
- Pool-first liquidation makes instant liquidation available when pool is funded

---

## System Architecture

The SunPLS protocol is composed of five core contracts:

```
        SunPLS Token
              │
              ▼
          Price Oracle
              │
              ▼
      Monetary Controller
              │
              ▼
          Vault System ←──→ Stability Pool
```

Each component performs a dedicated role. The token is minted and burned by the vault. The oracle feeds the market price to the controller. The controller outputs the stability rate and R value used by the vault. The stability pool sits alongside the vault as a liquidation backstop and yield source — pool depositors earn WPLS from liquidations and stability fees.

**Contract files:**
```
SunPLS_Token_RAI.sol         — ERC20Permit, vault-controlled mint/burn
SunPLS_Oracle_RAI.sol        — SunPLS/WPLS TWAP oracle (PulseX pair)
SunPLS_Controller_RAI.sol    — Sticky proportional controller (no negative rates)
SunPLS_StabilityPool_RAI.sol — Depositors earn WPLS from liquidations + fees
SunPLS_Vault_RAI.sol         — PLS CDP vault with pool-first liquidation
```

---

## The Floating Peg — R vs P

Two prices govern your vault at all times:

| Symbol | Name | What it is |
|--------|------|-----------|
| **P** | Oracle Price | The live AMM market price of SunPLS in WPLS, from the PulseX pair via time-weighted average |
| **R** | Redemption Value | The protocol's internal equilibrium price — the guaranteed WPLS you receive per SunPLS when redeeming |

**The relationship:**

- When **P > R** (SunPLS trading above target): the Controller raises the stability rate. Borrowing becomes more expensive, discouraging new minting, pushing supply down and price toward R.
- When **P < R** (SunPLS trading below target): the Controller lowers the rate toward 0% (never negative). Simultaneously, redemption arbitrage — buy cheap SunPLS on the open market, redeem at R for profit — pulls market price back up.

**R started at 1.227 WPLS** at deployment. The Controller moves R by at most `MAX_R_MOVE = 1%` per epoch (100 bps). This 10× sticky R means SunPLS stability comes from the market chasing R, not R chasing the market — a fundamentally different philosophy to RAI that makes R a reliable long-term reference.

`MIN_RATE = 0` is enforced as a permanent floor — SunPLS never pays borrowers to borrow. The rate is always ≥ 0%.

The Controller formula:
```
ε = P − R            (spread)
Δr = K × ε           (rate adjustment)
new R = prev R + alpha × Δr  (damped redemption value update)
```

Where K = 1e15 (0.1% proportional gain) and alpha = 5e14 (0.05% damping) are set at deploy and immutable.

---

## Three Stability Layers

SunPLS stability is enforced by three independent mechanisms that reinforce each other:

```
Layer 1 — Over-Collateralized Vaults
Layer 2 — Redemption Arbitrage
Layer 3 — Autonomous Controller
```

**Layer 1 — Vaults** ensure every SunPLS in circulation is backed by at least 150% collateral value. The collateral buffer absorbs price volatility before the system becomes undercollateralized.

**Layer 2 — Redemption** creates a hard economic floor. If SunPLS ever trades below R on the open market, anyone can buy it cheaply and redeem it at the full R rate — pocketing the spread. This arbitrage loop closes automatically, no coordination required.

**Layer 3 — Controller** adjusts borrowing costs to influence supply. When price is above R, rates rise and reduce demand for new SunPLS. When price is below R, rates fall toward 0 to reduce holding cost. This layer operates continuously in the background regardless of whether anyone is actively trading.

All three layers are permissionless, trustless, and run without any human intervention.

---

## The Rate Engine (Controller)

The Controller is an autonomous monetary policy engine that runs in epochs (30 minutes each). Any wallet can trigger a new epoch — it is fully permissionless.

**Each epoch the Controller:**
1. Reads the current oracle price (P) and the current R value
2. Calculates the spread: `ε = (P - R) / R`
3. Adjusts R by at most `MAX_R_MOVE_BPS = 100 bps` (1%) per epoch
4. Calculates a new stability rate `r` applied to all outstanding debt

**Stability Rate:**
- Always ≥ 0% (`MIN_RATE = 0`)
- A **positive rate** means your debt grows over time — you owe more SunPLS than you minted
- A **zero rate** means your debt stays constant — free borrowing
- Maximum rate: 30% APR

**Controller parameters (immutable after deploy):**

| Parameter | Value | Meaning |
|-----------|-------|---------|
| K | 1e15 | 0.1% proportional gain |
| ALPHA | 5e14 | 0.05% damping — 10× stickier than RAI default |
| MAX_R_MOVE | 100 bps | Max 1% R shift per epoch |
| MIN_RATE | 0 | No negative rates, ever |
| MAX_RATE | 30e16 | 30% APR ceiling |
| EPOCH_DURATION | 1800s | 30-minute epochs |

**Controller features:**
- Proportional feedback control with alpha damping
- Deadband to ignore trivial deviations
- Per-epoch R change limiter
- Four oracle degradation modes — system stays live even with stale oracle

---

## The Oracle

The oracle reads the PulseX SunPLS/WPLS AMM pair and produces a stored price snapshot. It is a standalone contract that anyone can update.

**Key functions:**
- `oracle.update()` — stores a snapshot of AMM reserves with a timestamp
- `oracle.peek()` — returns the stored price and its timestamp
- `oracle.isHealthy()` — returns true if the stored price is within the valid age window

**Oracle degradation modes:**

| Mode | Description |
|------|-------------|
| A | Fresh oracle update — normal operation |
| B | Peek fallback price — uses stored snapshot |
| C | Stored price buffer — uses last-known price with reduced K |
| D | Frozen epoch — controller pauses rate adjustments |

These modes ensure the system remains live even during oracle disruption. Deposits, repayments, and withdrawals are never blocked by a stale oracle.

---

## How to Use the Protocol

### Auto Mode (Recommended)

1. Connect MetaMask on PulseChain (chain ID 369)
2. Switch to the **Auto** tab
3. Enter the amount of PLS you want to deposit
4. Click **1-Click Auto Mint**

Two transactions: first deposits PLS via `depositPLS()`, second mints SunPLS at 155% CR — 5% buffer above the 150% minimum.

### Manual Flow

**Deposit:** Lock PLS as collateral via `depositPLS()` (payable).

**Mint:** Borrow SunPLS against collateral. Minimum 150% CR enforced on-chain.
```
CR (bps) = (Collateral × Oracle Price P) ÷ (SunPLS Debt × R) × 10000
```
Example: 1,845 PLS collateral, P = R = 1.227 WPLS/SunPLS, 1,000 SunPLS debt → CR ≈ 150%.

**Repay:** Burn SunPLS to reduce debt via `repay(amount)`. Instant, no cooldown, no fee.

**Repay All & Close:** `repayAndClose()` burns your full accrued debt and closes the vault in one transaction.

**Withdraw:** Pull PLS back to wallet via `withdraw(amount)`. CR must stay ≥ 150% after withdrawal. No withdrawal cooldown.

### Vault State

A single `getVault(address)` call returns everything about a vault:

| Field | What it means |
|-------|--------------|
| **collateral** | PLS locked in the vault (in wei) |
| **debt** | SunPLS currently owed (grows with positive rate) |
| **crBps** | Collateralization ratio in basis points (15000 = 150%) |
| **liquidatable** | True if CR < 110% |
| **redeemable** | True if CR < 150% |
| **lastAccrual** | Timestamp of last debt accrual |

System-wide metrics come from a single `globalStats()` call: TVL, total minted, surplus, bad debt, current rate, redemption price, system CR, debt ceiling, and utilization.

---

## Vault Health Zones

| CR Range | Status | What can happen |
|----------|--------|----------------|
| **Above 150%** | Safe | Normal operation. Immune to redemption and liquidation. Can mint and withdraw. |
| **110–150%** | Redeemable | SunPLS holders can redeem against your vault at R rate. Your debt and collateral decrease proportionally. A 0.5% fee stays with you. |
| **Below 110%** | Liquidatable | Pool can liquidate instantly, or Dutch auction liquidation for anyone with SunPLS. |

**Recommended target:** 170%+ CR to absorb price swings without entering the redeemable zone.

---

## Liquidations

When a vault's CR falls below 110%, it becomes liquidatable. SunPLS has two liquidation paths.

### Path 1 — Pool Liquidate (Instant, Preferred)

```solidity
vault.poolLiquidate(vaultOwner)
```

- No SunPLS required from the caller
- The Stability Pool absorbs the vault's debt (burns its deposited SunPLS)
- The pool receives the PLS collateral, distributed as WPLS to pool depositors
- Reverts cleanly if pool has insufficient SunPLS — fallback to auction

### Path 2 — Auction Liquidate (Dutch Auction, Fallback)

```solidity
vault.auctionLiquidate(vaultOwner, sunplsInput)
```

- Caller provides SunPLS and receives PLS collateral
- Dutch auction: the longer the vault sits under 110%, the better the PLS/SunPLS rate
- Works even when the pool is empty

### Using the Vault Dashboard

1. Open **Vault Dashboard → Liquidate tab**
2. Click **Scan All Vaults** — finds all vaults below 110% CR
3. Click **Liquidate** on any eligible vault
4. Choose **Pool Liquidate** (instant, no SunPLS needed) or **Auction Liquidate** (provide SunPLS)
5. Confirm

---

## Redemptions

Redemptions keep the market price gravitating toward R. When SunPLS trades below R, anyone can buy it cheaply on the market and redeem it at the full R rate — extracting the spread as profit.

**Eligibility:** Vaults below 150% CR can be redeemed against.

```solidity
vault.redeem(sunplsIn, targetVault)
```

**What happens:**
1. You burn `sunplsIn` SunPLS
2. You receive `sunplsIn × R` worth of PLS, minus 0.5% fee
3. The 0.5% fee stays with the vault owner
4. The vault's debt and collateral decrease proportionally

Redemptions always execute at R, not the market price. No slippage. Guaranteed rate regardless of AMM conditions.

**Why this creates stability:** If SunPLS trades at 1.10 WPLS on the market but R = 1.227 WPLS, buying SunPLS and redeeming earns the spread risk-free. This arbitrage continues until the market price approaches R.

---

## Stability Pool

The Stability Pool is deployed and live. It is the primary liquidation backstop and the main source of yield for SunPLS holders.

### What it does

Depositors lock SunPLS into the pool and earn WPLS. Two yield sources:

1. **Liquidation yield:** When a vault is pool-liquidated, the pool burns SunPLS and receives PLS collateral (distributed as WPLS to depositors)
2. **Stability fee yield:** Borrower interest accrues as a `surplusBuffer`; keepers periodically flush fees to the pool as WPLS via `vault.flushFeesToPool()`

### Participating

```solidity
pool.deposit(sunplsAmount)          // deposit SunPLS, start earning WPLS
pool.withdraw(sunplsAmount)         // withdraw SunPLS + claim WPLS
pool.claimWPLS()                    // claim accrued WPLS without withdrawing
pool.withdrawAllAndClaim()          // single-tx full exit
```

### Checking your position

```solidity
pool.depositorInfo(address) returns (
    sunplsRedeemable,  // your current SunPLS balance
    wplsClaimable,     // pending WPLS rewards
    userShares_,       // your virtual shares
    sharePercent       // your % of pool (in basis points)
)
```

### Pool Stats

```solidity
pool.poolStats() returns (
    totalSunPLSDeposited,
    totalSharesOutstanding,
    sunplsPerShare_1e18,
    totalWPLSHeld,
    lifetimeSunPLSAbsorbed,
    lifetimeWPLSFromLiquidations,
    lifetimeWPLSFromFees,
    totalLiquidations,
    currentAccWplsPerShare
)
```

### Share accounting

Virtual shares represent each depositor's proportional claim. The accumulator pattern tracks WPLS rewards:

```
accRewardPerShare += (wplsReceived × PRECISION) / totalShares
pending WPLS = shares × accRewardPerShare − rewardDebt
```

When a liquidation burns pool SunPLS, each share is worth less SunPLS but more WPLS. Depositors who joined before a liquidation earn from it; depositors who join after start fresh.

### Fee routing (keeper workflow)

Stability fees accrue as virtual SunPLS debt (`surplusBuffer`). Converting to WPLS for pool distribution:

1. Monitor `vault.globalStats().surplus` — grows as borrowers pay interest
2. Sell equivalent SunPLS from protocol treasury on PulseX for WPLS
3. Approve WPLS to vault, call `vault.depositFeeWPLS(amount)`
4. Call `vault.flushFeesToPool(amount)` — distributes to depositors

`flushFeesToPool()` only ever draws from `feeReserveWPLS`, never from user collateral.

---

## RAI Architecture Improvements

SunPLS is based on RAI's architecture and addresses its three core shortcomings:

| RAI Problem | SunPLS Fix |
|-------------|-----------|
| R drifted toward market too fast — confidence collapsed | ALPHA 10× smaller (5e14 vs 5e15) — R is sticky, market chases R |
| Negative rates confused users, attracted mercenary capital | MIN_RATE = 0 — borrowing free at worst, never paid to borrow |
| Holding RAI earned nothing — no native yield | Stability Pool: deposit SunPLS, earn WPLS from liquidations + fees |
| FLX governance token added complexity | No governance token. WPLS + SunPLS only. |

**Key architectural comparison:**

| Dimension | RAI (default) | SunPLS |
|-----------|--------------|--------|
| Controller ALPHA | Higher (faster R drift) | 5e14 — 10× stickier |
| Minimum rate | Allows negative | 0 — never paid to borrow |
| Maximum rate | ~50% | 30% |
| Max R move/epoch | Up to 10% | 100 bps (1%) |
| Epoch duration | Varies | 1800s (30 min) |
| Stability pool | None in base | Deployed — SunPLS → WPLS yield |
| Pool-first liquidation | No | Yes — instant when pool funded |
| Fee routing to holders | No | Via flushFeesToPool() |
| Governance token | FLX | None |
| Philosophy | R approximates market | Market approximates R |

### Vault API

| Action | Function |
|--------|---------|
| Read vault state | `getVault(owner)` → (collateral, debt, crBps, liquidatable, redeemable, lastAccrual) |
| Read system state | `globalStats()` → single call for all protocol metrics |
| Deposit PLS | `depositPLS()` (payable) |
| Withdraw PLS | `withdraw(amount)` |
| Mint SunPLS | `mint(amount)` |
| Repay SunPLS | `repay(amount)` |
| Repay all & close | `repayAndClose()` |
| Pool liquidate | `poolLiquidate(owner)` — no SunPLS from caller |
| Auction liquidate | `auctionLiquidate(owner, sunplsInput)` |
| Redeem | `redeem(sunplsIn, target)` |
| Vault count | `vaultCount()` |
| Vault owner by index | `vaultOwners(index)` |

No withdrawal cooldown. No `reconcile()`. No `liquidationInfo()`. No `repayToHealth()` or `maxMint()` view functions — these are calculated client-side from `getVault()` + current price.

---

## Emergency Unlock

If you have zero debt, collateral locked, and the oracle is in a degraded state, call `emergencyUnlock()` to recover collateral. This is a safety valve — in normal operation it is never needed.

---

## System Invariants

```
I1  — Vault solvency:       CR ≥ 150% required to mint or withdraw
I2  — Liquidation:          Vaults below 110% CR can be liquidated
I3  — Redemption:           Vaults below 150% CR can be redeemed against
I4  — Rate floor:           Stability rate ≥ 0% at all times (MIN_RATE = 0)
I5  — R stickiness:         R moves at most MAX_R_MOVE_BPS (100 bps) per epoch
I6  — Oracle resilience:    Stale oracle never blocks deposit, repay, or withdraw
I7  — Immutability:         No admin, no pause, no upgrade after deploy
I8  — Liveness:             Dead oracle never blocks core vault operations
I9  — Trust-minimized burn: Vault can only burn SunPLS it holds in its own balance
I10 — Pool isolation:       Pool's receive() restricted to vault address only
I11 — Fee routing:          flushFeesToPool() only draws from feeReserveWPLS
I12 — Pool-first liq:       poolLiquidate() reverts cleanly if pool has no funds
```

---

## Design Goals

- **Fully autonomous monetary policy** — no human required to run the rate engine
- **No governance control** — no DAO, no multisig, no timelock, no admin
- **No negative rates** — borrowing is always free at worst, never a subsidy
- **Sticky R** — the market chases R; R does not chase the market
- **Deterministic economic rules** — identical behavior at any TVL scale
- **Strong arbitrage stabilization** — redemption creates a self-enforcing floor
- **Oracle failure resilience** — four degradation modes keep the system live
- **Permissionless operation** — any wallet or contract can interact with any function
- **Native yield** — pool depositors earn WPLS from liquidations and stability fees
- **Keeper-friendly** — pool-first liquidation, two-path liquidation design

---

## Deployed Contracts

All contracts on **PulseChain (Chain ID: 369)**. No owner keys. No upgradeability. Immutable after deploy.

| Contract | Address |
|----------|---------|
| **SunPLS Token** | `0xfbfe269C256A62425feD4b57Aabf44b3536f4AD4` |
| **SunPLS Vault** | `0x7414121FBe16e18c03991F2980461f071a88Ce8f` |
| **Oracle** | `0x228436E79B91103d1F3fff8a80F33485186DEfdB` |
| **Controller** | `0x45dbaa6E65075391002c05f4EaDB3D6e8605218A` |
| **Stability Pool** | `0x1f55942646BB2edBC1B7ACE9EeD0D71560A6AF3D` |
| **PulseX SunPLS/WPLS Pair** | `0x44C152d91df1C2aD5a2F964cb982963a98e5885D` |
| **WPLS** | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |

**Deployment details:**
- Deployed: 2026-06-21 (PulseChain Mainnet)
- Initial R: 1.227303007594859405 WPLS per SunPLS
- All 5 latches confirmed (token→vault, token→pool, controller→vault, vault→pool, pool→vault)

**Token:** ERC20Permit (EIP-2612) · 18 decimals · 1B initial supply minted to deployer at deploy

**Vault parameters:**
- Min collateral ratio: **150%** · Liquidation threshold: **< 110% CR**
- Redemption threshold: **< 150% CR**
- Stability rate: **0%–30% APR** (never negative)
- No withdrawal cooldown
- Debt ceiling: 100,000 SunPLS at launch (increases as TVL grows)

**Starting R:** 1.227 WPLS — matched the live PulseX pair price at deploy time, so P ≈ R at launch with near-zero controller spread.

---

## Compiling the Contracts

**⚠️ PulseChain EVM Constraint:** PulseChain supports Shanghai EVM but **not Cancun** (`mcopy` / EIP-5656). OpenZeppelin v5 transitively imports `Bytes.sol` which uses `mcopy` — this will fail on PulseChain. Use OZ v4.9.6 via versioned GitHub URLs.

**Required:**
- Compiler: `pragma ^0.8.20`
- OZ: **v4.9.6 via GitHub URLs** (not npm — npm resolves to OZ v5)
- EVM target: **paris** or **shanghai** (not cancun)
- Optimizer: 200 runs recommended

```solidity
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/utils/SafeERC20.sol";
```

**Deploy order:**
```
1. Deploy SunPLS_Token_RAI.sol          — 1B seed SunPLS minted to deployer
2. Create PulseX SunPLS/WPLS pair      — seed with desired initial price ratio
3. Deploy SunPLS_Oracle_RAI.sol         — bootstraps lastPrice from live reserves
4. Deploy SunPLS_Controller_RAI.sol     — initialR = oracle.peek() at deploy time
5. Deploy SunPLS_StabilityPool_RAI.sol
6. Deploy SunPLS_Vault_RAI.sol          — pass debtCeiling (start conservative: 100_000e18)
7. token.setVault(vault)                — one-time latch, immutable
8. token.setPool(pool)                  — one-time latch (pool burn permission)
9. controller.setVault(vault)           — one-time latch, immutable
10. vault.setStabilityPool(pool)        — one-time latch, immutable
11. pool.setVault(vault)                — one-time latch, immutable
─── system is now fully autonomous ───
```

See `DEPLOY.md` for the full deployment guide and recommended parameters.

---

## Security Model

**No admin keys.** All `set*()` latch functions are one-time-call and become permanently inaccessible after being called once.

**No upgradeability.** No proxies, no beacons, no delegate calls.

**No oracle manipulation.** TWAP-based stored snapshot — single-block sandwich cannot influence vault operations.

**Immutable rate engine.** Controller parameters (K, ALPHA, MAX_R_MOVE, MIN_RATE, MAX_RATE, EPOCH_DURATION) are set at deploy and cannot change.

**No negative rates.** `MIN_RATE = 0` is a hard constant. The controller can never set a negative stability rate regardless of market conditions.

**Trust-minimized token.** Vault can only burn SunPLS it holds. Users must approve first. Vault cannot drain wallets.

**Pool isolation.** Pool's `receive()` is restricted to the vault address only. Random PLS sent directly to the pool is rejected.

**What the contracts cannot do:**
- Mint SunPLS to arbitrary addresses
- Pause or freeze any function
- Change liquidation parameters, collateral requirements, or rate bounds
- Redirect or withdraw collateral outside of vault operations
- Set a negative stability rate

---

## Frontend Files

Self-contained — no build step required. All ABIs are inlined in the HTML. Serve statically or open directly in a browser.

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, stability pool, rate engine, oracle |
| `liquidations.html` | Dashboard — scan all vaults, liquidate (pool + auction), redeem, inspect any vault |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `sunplslogo.png` | Protocol logo |

ABIs are inlined directly in `index.html` and `liquidations.html` — no separate ABI JSON files needed in the GitHub folder.

**GitHub Pages:** Push this folder to a GitHub repo, enable Pages on root branch. `index.html` is served automatically.

---

## Acknowledgements

SunPLS is inspired by the RAI architecture (Reflexer Finance) and improves upon its shortcomings. RAI proved that a non-pegged floating stable with autonomous monetary policy is viable on-chain. SunPLS takes that foundation and adds: sticky R, no negative rates, and a native yield layer for holders.

SunPLS was also developed following the **ProjectUSD autonomous stable asset specification**, which provided the architectural framework, safety invariants, and P/R/r feedback model.

ProjectUSD specification: https://github.com/Aqua75/ProjectUSD

The intellectual lineage traces from Hayek's *Denationalisation of Money* (1976) through the ProjectUSD specification to this implementation. Three independent lines of reasoning converging on the same architecture across 50 years.

---

*SunPLS is experimental software. No audits have been performed. Use at your own risk. Not financial advice.*

**License: CC-BY-NC-SA-4.0**
