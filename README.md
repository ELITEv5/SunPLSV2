# SunPLS V2

**Autonomous · Ownerless · Immutable · PulseChain**

SunPLS is a decentralized CDP (Collateralized Debt Position) protocol on PulseChain. Users lock WPLS as collateral and mint SunPLS — a synthetic token whose value is governed by an autonomous on-chain monetary policy engine. There are no admin keys, no upgradeability, no owner functions. Once deployed, the contracts run forever without human intervention.

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
13. [V2 Protocol Improvements](#v2-protocol-improvements)
14. [Stability Pool](#stability-pool)
15. [Emergency Unlock](#emergency-unlock)
16. [Protocol Tools](#protocol-tools)
17. [System Invariants](#system-invariants)
18. [Design Goals](#design-goals)
19. [Deployed Contracts](#deployed-contracts)
20. [Version History](#version-history)
21. [Compiling the Contracts](#compiling-the-contracts)
22. [Security Model](#security-model)
23. [Frontend Files](#frontend-files)
24. [Acknowledgements](#acknowledgements)

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

SunPLS V2 represents a hardened implementation of these design principles, incorporating lessons learned from V1 deployments into a more robust safety architecture.

ProjectUSD specification: https://github.com/Aqua75/ProjectUSD

---

## What is SunPLS?

SunPLS is a **closed-loop autonomous monetary system**. Users lock WPLS as collateral and borrow SunPLS against it. SunPLS is pegged to PLS itself — not to USD, not to any external asset. 1 SunPLS targets 1 WPLS at launch, with the equilibrium value R allowed to drift autonomously based on market conditions.

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

---

## System Architecture

The SunPLS protocol is composed of four core contracts plus an optional stability pool:

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
          Vault System
              │
              ▼
      Stability Pool (optional)
```

Each component performs a dedicated role. The token is minted and burned by the vault. The oracle feeds the market price to the controller. The controller outputs the stability rate and R value used by the vault. The stability pool sits alongside the vault as a permissionless liquidation backstop — it calls the vault just like any other liquidator.

---

## The Floating Peg — R vs P

Two prices govern your vault at all times:

| Symbol | Name | What it is |
|--------|------|-----------|
| **P** | Oracle Price | The live AMM market price of SunPLS in WPLS, from the PulseX pair via time-weighted average |
| **R** | Redemption Value | The protocol's internal equilibrium price — the guaranteed PLS you receive per SunPLS when redeeming |

**The relationship:**

- When **P > R** (SunPLS trading above target): the Controller raises the stability rate. Borrowing becomes more expensive, discouraging new minting, pushing supply down and price toward R.
- When **P < R** (SunPLS trading below target): the Controller lowers the rate (potentially negative — a borrowing subsidy). Cheap borrowing encourages new minting; simultaneously, redemption arbitrage (buy cheap SunPLS → redeem at R for profit) pulls market price back up.

**R starts at 1.0 WPLS** (1:1 with PLS at launch). The Controller can drift R upward or downward by a maximum of `DELTA_R_MAX = 0.0005 WPLS` per epoch. Over time, R represents the protocol's best estimate of the equilibrium exchange rate. `R_FLOOR = 1e18` (1 WPLS) is enforced as a permanent minimum — R will never fall below 1 PLS per SunPLS.

The Controller formula:
```
ε = P − R          (spread)
Δr = K × ε         (rate adjustment)
```

Where K and alpha are parameters set at deploy time and immutable thereafter.

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

**Layer 3 — Controller** adjusts borrowing costs to influence supply. When price is too high, rates rise and reduce demand for new SunPLS. When price is too low, rates fall (or go negative) to stimulate minting and attract arbitrageurs. This layer operates continuously in the background regardless of whether anyone is actively trading.

All three layers are permissionless, trustless, and run without any human intervention.

---

## The Rate Engine (Controller)

The Controller is an autonomous monetary policy engine that runs in epochs (default: 1 hour each). Any wallet can trigger a new epoch — it is fully permissionless.

**Each epoch the Controller:**
1. Reads the current oracle price (P) and the current R value
2. Calculates the spread: `spread = (P - R) / R`
3. Adjusts R by up to `DELTA_R_MAX` in the direction that closes the spread
4. Calculates a new stability rate applied to all outstanding debt

**Stability Rate:**
- A **positive rate** means your debt grows over time — you owe more SunPLS than you minted
- A **negative rate** means your debt shrinks — the protocol is subsidizing borrowers to stimulate minting
- The rate is displayed on your vault as `+X.XX% APR` or `−X.XX% APR`

**Controller features:**
- Proportional feedback control
- Deadband to ignore trivial deviations
- Per-epoch rate change limiter (`DELTA_R_MAX`)
- Redemption value damping
- Oracle degradation handling

**Epoch triggering:**
Anyone can click "Trigger Epoch" in the Rate Engine panel. Bots and keeper contracts can also trigger epochs — V2 uses `.call{value}()` throughout, so smart contract callers work without the 2300-gas restriction of V1.

---

## The Oracle

The oracle reads the PulseX SunPLS/WPLS AMM pair and produces a stored price snapshot. It is a standalone contract that anyone can update.

**Key functions:**
- `oracle.update()` — stores a snapshot of AMM reserves with a timestamp
- `oracle.peek()` — returns the stored price and its timestamp
- `oracle.isHealthy()` — returns true if the stored price is less than 24 hours old

**Oracle degradation modes:**

To prevent system failure during oracle outages, the controller supports four degradation modes:

| Mode | Description |
|------|-------------|
| A | Fresh oracle update — normal operation |
| B | Peek fallback price — uses stored snapshot |
| C | Stored price buffer — uses last-known price |
| D | Frozen epoch — controller pauses rate adjustments |

These modes ensure the system remains live even during oracle disruption. Deposits, repayments, and withdrawals are never blocked by a stale oracle.

If you see "Oracle stale" in the Oracle Status panel, click **Update Oracle Price** to refresh it. This costs only gas — no economic cost.

---

## How to Use the Protocol

### Auto Mode (Recommended)

1. Connect MetaMask on PulseChain (chain ID 369)
2. Switch to the **Auto** tab
3. Enter the amount of PLS you want to deposit
4. Click **1-Click Auto Mint**

One transaction deposits PLS and mints SunPLS at 155% CR — 5% buffer above the 150% minimum.

### Manual Flow

**Deposit:** Lock PLS as collateral. 5-minute withdrawal cooldown begins.

**Mint:** Borrow SunPLS against collateral. Minimum 150% CR enforced on-chain.
```
CR = (Collateral in WPLS × Oracle Price P) ÷ SunPLS Debt × 100%
```
Example: 1,500 PLS collateral, P = 1.0 WPLS/SunPLS, 1,000 SunPLS debt → CR = 150%.

**Repay:** Burn SunPLS to reduce debt. Instant, no cooldown, no fee. **Repay to Safe** auto-calculates exact amount to return to 150% CR.

**Withdraw:** Pull PLS back to wallet. CR must stay ≥ 150% after withdrawal. **Withdraw Max Safe** calculates and extracts maximum while holding the 150% line.

**Full exit:** Auto tab → **Repay All & Withdraw Everything** — single transaction, requires SunPLS equal to current total debt.

### Vault Health Monitoring

| Field | What it means |
|-------|--------------|
| **Collateral** | WPLS locked in the vault |
| **Debt** | SunPLS currently owed (grows with positive rate) |
| **CR Ratio** | Your collateralization ratio — keep above 150% |
| **Rate (APR)** | Current stability rate — positive means debt grows |
| **Coll Value** | Collateral worth in SunPLS at current oracle price |
| **Mintable** | Additional SunPLS you can borrow and stay at 150% |

The CR gauge arc animates green → amber → red as your ratio drops. A warning banner appears at the top when your CR falls into the redeemable zone. A pulsing red border appears below 110% — act immediately.

---

## Vault Health Zones

| CR Range | Status | What can happen |
|----------|--------|----------------|
| **Above 150%** | Safe | Normal operation. Immune to redemption and liquidation. Can mint and withdraw. |
| **131–150%** | At risk | Cannot mint more. Not yet redeemable. Add collateral before price falls further. |
| **110–130%** | Redeemable | SunPLS holders can redeem against your vault at R rate. Your debt and collateral decrease proportionally. A 0.5% fee stays with you. |
| **Below 110%** | Liquidatable | Also redeemable. Liquidators can repay 5%+ of your debt and claim collateral plus bonus (up to 7%). First mover wins — inverted Dutch auction decays the bonus over 3 hours. |

**Recommended target:** 170%+ CR to absorb price swings without entering the redeemable zone.

---

## Liquidations

When a vault's CR falls below 110%, it becomes liquidatable.

**V2 liquidation mechanics:**
- **Minimum liquidation:** 5% of outstanding debt (reduced from 20% in V1 — more efficient for bots)
- **Maximum liquidation:** 100% of debt
- **Bonus:** Starts at 7% immediately, decays to 2% over 3 hours — first mover wins
- **Who can liquidate:** Anyone holding SunPLS, or the Stability Pool acting on their behalf

**Step-by-step (manual):**
1. Open **Vault Dashboard → Liquidate tab**
2. Click **Scan All Vaults** — finds all vaults below 110% CR
3. Click **Liquidate** on any eligible vault
4. Enter SunPLS amount to repay (≥ minimum shown)
5. Click **Confirm Liquidation**

The contract takes your SunPLS, burns it, and sends you proportional PLS collateral plus the bonus.

---

## Redemptions

Redemptions enforce the peg. When SunPLS trades below R, anyone can buy it cheaply on the market and redeem it at the full R rate — extracting the spread as profit.

**Eligibility:** Vaults at or below 130% CR can be redeemed against. Vaults above 130% are completely immune.

**What happens during a redemption:**
1. Choose a target vault (CR ≤ 130%) and specify SunPLS to burn
2. You receive: `SunPLS amount × R` worth of PLS, minus 0.5% fee
3. The 0.5% fee goes to the vault owner
4. The vault's debt decreases by the SunPLS burned
5. The vault's collateral decreases by the PLS paid out

**Redemptions always execute at R, not the market price.** No slippage. No price impact on the redemption itself. Guaranteed rate regardless of AMM conditions.

**Why this creates the peg:**
If SunPLS = 0.95 WPLS on market but R = 1.00 WPLS, buying SunPLS and redeeming earns +5% risk-free. This arbitrage continues until the market price rises back to R.

**For vault owners:** Maintain CR above 130% to be immune to redemption. The 0.5% fee is compensation for the involuntary reduction of your position.

---

## V2 Protocol Improvements

SunPLS V2 introduces structural improvements over V1, making the protocol safer at higher TVL and more accessible to keeper bots and DeFi integrations.

### Surplus Buffer
Stability fees accumulate as a **Surplus Buffer** (in SunPLS). The protocol's equity — absorbs bad debt before systemic risk propagates. Visible on-chain in the System State panel.

### Bad Debt Accounting
V1 silently socialized uncovered liquidation losses. V2 tracks them explicitly in `badDebtAccumulated`. **System Equity** = Surplus Buffer − Bad Debt. Positive = solvent. Negative = bad debt exceeds collected fees. Never hidden, always auditable.

### Reconciliation
`reconcile()` nets the surplus buffer against bad debt. Called automatically inside vault operations but triggerable by anyone from the Protocol Tools panel.

### Inverted Dutch Auction
V1 liquidation bonus grew from 2% to 5% over 3 hours — incentivizing bots to *wait*, leaving vaults underwater longer. V2 flips this: bonus starts at 7% and decays to 2% over 3 hours. First mover wins. Bad debt window collapses from hours to minutes.

### Trust-Minimized Burn
V1 vault had direct burning authority over any address. V2 requires users to `approve()` first; vault calls `transferFrom(user → vault)` then burns only from its own balance. The vault can never touch tokens it does not hold.

### EIP-2612 Permit Flows
`repayWithPermit`, `liquidateWithPermit`, `redeemWithPermit` — sign off-chain, execute in one transaction. Essential for keeper bots and DeFi integrations.

### Smart Contract Compatibility
V1 used `.transfer()` (2300 gas stipend) — smart contract recipients failed. V2 uses `.call{value}()` throughout. This is what makes the Stability Pool possible.

### Reduced Minimum Liquidation
V1 required liquidators to repay at least 20% of a vault's debt. V2 drops this to 5%, making smaller positions liquidatable by a wider range of bots.

---

## Stability Pool

The Stability Pool (`SunPLS_StabilityPool.sol`) is a pre-funded liquidation backstop ready to deploy alongside V2 when TVL warrants it. It is not yet deployed.

### What it does

Depositors lock SunPLS into the pool and earn PLS liquidation rewards. When a vault falls below 110% CR, any wallet can trigger the pool to liquidate it — the pool burns its pooled SunPLS and receives the vault's collateral plus bonus. That PLS is distributed proportionally to all current depositors.

This solves the core risk of open-market liquidation: in a fast crash, individual keepers may not hold enough SunPLS or may not be positioned to act. The pool is always loaded and always ready.

### Why it only works with V2

V1 used `.transfer()` (2300 gas) to send PLS to the liquidator. Any smart contract recipient with non-trivial logic in `receive()` would revert. The stability pool contract needs to receive PLS and update internal accounting — impossible under the V1 gas constraint. V2's `.call{value}()` removes this restriction entirely. The stability pool was a design goal of V2.

### Share accounting

Virtual shares represent each depositor's proportional claim on pooled SunPLS. The MasterChef accumulator pattern tracks PLS rewards:

```
accRewardPerShare += (plsReceived × PRECISION) / totalShares
pending PLS = shares × accRewardPerShare − rewardDebt
```

When a liquidation burns pool SunPLS, `totalShares` stays constant and `totalSunPLS` shrinks — each share is worth less SunPLS but has earned PLS. Depositors who joined before a liquidation share in its reward. Depositors who join after start fresh.

### Liquidation flow

```
1. Caller invokes pool.liquidate(target, amount)
2. Pool approves vault for exact SunPLS amount
3. Pool calls vault.liquidate(target, amount)
4. Vault pulls SunPLS from pool via transferFrom, burns it
5. Vault sends PLS to pool via .call{value}() → receive()
6. vault.liquidate() returns
7. Pool measures balance delta, deducts 0.5% caller tip, distributes rest to depositors
8. Approval reset to zero
```

### Caller tip

`CALLER_TIP_BPS = 50` (0.5% of PLS received). Paid directly to whoever triggers the liquidation. The vault's liquidation bonus is 2–7%, so a bot calling the pool earns 0.5% of the pool's take — clear gas incentive without meaningfully reducing depositor yield.

### Security decisions

**`receive()` restricted to vault only.** Random PLS sent directly to the pool would be unrecoverable (no admin, no sweep function) and would inflate `address(this).balance` without entering `accRewardPerShare`, causing accounting drift. The restriction ensures the only PLS that ever lands in `receive()` is legitimate liquidation reward.

**`bonusBps` read before `vault.liquidate()`.** After the vault resolves the position, `liquidationInfo()` returns zero — the pre-liquidation reading is the accurate one.

**Approval reset after every liquidation.** `approve(vault, amount)` then `approve(vault, 0)` — no residual allowance left on the vault.

### Deploy when ready

```
SunPLS_StabilityPool(
    address sunpls,  // 0xaac685D900CC42569061d91F6a521658AA397f32
    address vault    // 0x5A87Aa7A3C68ACA0bb0CDe423Bf1f107284135BC
)
```

No owner. No admin. No additional latching required. Users deposit SunPLS immediately after deploy. The vault and token require zero changes — the pool calls them as a standard liquidator.

---

## Emergency Unlock

If you have zero debt, collateral locked, and 30 days have passed since your last deposit, call `emergencyUnlock()` to recover collateral regardless of oracle state. The button appears automatically in the Deposit tab when conditions are met.

---

## Protocol Tools

Three public functions callable by anyone from the Protocol Tools panel:

**`clearBadDebt(address zombieVault)`** — seize collateral from a vault with zero debt but recorded bad debt. Caller receives the PLS for free. Bad debt entry is cleared.

**`settleDebt(uint256 amount)`** — burn your own SunPLS to directly cancel global bad debt. Reduces `badDebtAccumulated`. Does not affect your personal vault.

**`reconcile()`** — net surplus buffer against bad debt. No economic cost beyond gas.

---

## System Invariants

```
I1  — Vault solvency:       CR ≥ 150% required to mint or withdraw
I2  — Liquidation:          Vaults at or below 110% CR can be liquidated
I3  — Redemption:           Only vaults at or below 130% CR can be redeemed against
I4  — Price floor:          SunPLS can always be redeemed at R-value (R_FLOOR = 1 WPLS)
I5  — Oracle resilience:    Stale oracle never blocks deposit, repay, or withdraw
I6  — Rate safety:          Stability rate bounded by Controller invariants
I7  — Immutability:         No admin, no pause, no upgrade after deploy
I8  — Liveness:             Dead oracle never blocks core vault operations
I9  — Debt initialization:  lastDebtAccrual always set on first debt issuance
I10 — Bad debt tracking:    Residual uncovered liquidation debt recorded, never silent
I11 — Trust-minimized burn: Vault can only burn tokens it holds in its own balance
I12 — Surplus accounting:   Stability fees accumulate as surplus buffer, not lost
I13 — Redeem-liq gap:       Vault cannot be liquidated within 5 minutes of redemption
I14 — Pool isolation:       Stability pool is vault-funded only — no stray ETH entry
```

---

## Design Goals

- **Fully autonomous monetary policy** — no human required to run the rate engine
- **No governance control** — no DAO, no multisig, no timelock, no admin
- **Deterministic economic rules** — identical behavior at any TVL scale
- **Strong arbitrage stabilization** — redemption creates a self-enforcing peg floor
- **Oracle failure resilience** — four degradation modes keep the system live
- **Permissionless operation** — any wallet or contract can interact with any function
- **Transparent solvency** — surplus buffer and bad debt visible on-chain at all times
- **Keeper-friendly** — `.call{value}()`, permit flows, stability pool, and caller tips make automation first-class

---

## Deployed Contracts

All contracts on **PulseChain (Chain ID: 369)**. No owner keys. No upgradeability. Immutable.

### V2 — Current (Canonical)

| Contract | Address |
|----------|---------|
| **SunPLS Token v2** | `0xaac685D900CC42569061d91F6a521658AA397f32` |
| **Vault v2** | `0x5A87Aa7A3C68ACA0bb0CDe423Bf1f107284135BC` |
| **Oracle** | `0x0A0E4adFBF38Dd227ed25D4f7e48B44D3a6aCa49` |
| **Controller** | `0xd231F209aCd14e66cbe72b23a0c5C1105651b4c6` |
| **PulseX SunPLS/WPLS Pair** | `0xF003688b899d9f554D705032AE01828Fa0B87054` |
| **WPLS** | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |
| **Stability Pool** | Not yet deployed — see `contracts/SunPLS_StabilityPool.sol` |

**Token:** ERC20 + ERC20Permit (EIP-2612) · 18 decimals · 1B initial supply

**Vault parameters:**
- Min collateral ratio: **150%** · Liquidation threshold: **110%**
- Redemption threshold: **≤ 130% CR**
- Min liquidation: **5%** of debt · Max bonus: **7%** (decays to 2% over 3h)
- Redemption fee: **0.5%** to vault owner
- Withdrawal cooldown: **5 minutes** · Emergency unlock: **30 days** with zero debt
- Debt ceiling: `uint256.max` — real limiters are CR requirements and liquidity

**Starting R:** 1.0 WPLS — matches `R_FLOOR`, `initialR`, and the 1:1 LP seed so P = R = 1e18 at launch with zero controller spread.

---

## Version History

| Version | Status | Notes |
|---------|--------|-------|
| V1.2 | Deprecated | Inverted oracle price formula — non-functional |
| V1.3 | Superseded | Redemption threshold at 150% CR |
| V1.4 | Live (legacy) | Redemption threshold lowered to 130% CR. Uses `.transfer()`, 20% min liquidation. Safe at current TVL. |
| **V2** | **Current** | Surplus buffer, bad debt accounting, inverted Dutch auction, `.call{value}()`, 5% min liquidation, EIP-2612 permit, trust-minimized burn. Designed for higher TVL. |
| V3 (future) | Planned | Deploy `SunPLS_StabilityPool.sol` when TVL warrants. Zero changes to existing contracts. |

V1.4 remains live and is not being shut down. V1 and V2 are parallel deployments with separate tokens. V2 is the recommended system for new positions.

---

## Compiling the Contracts

**⚠️ PulseChain EVM Constraint:** PulseChain supports Shanghai EVM but **not Cancun** (`mcopy` / EIP-5656). OpenZeppelin v5 transitively imports `Bytes.sol` which uses `mcopy` — this will fail on PulseChain. Use OZ v4.9.6 via versioned GitHub URLs.

**Required:**
- Compiler: `pragma solidity ^0.8.20`
- OZ: **v4.9.6 via GitHub URLs** (not npm — npm resolves to OZ v5)
- EVM target: **shanghai**

```solidity
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/utils/math/Math.sol";
```

**Compile in Remix:** Set compiler `0.8.20`, EVM version `shanghai`, deploy via Injected Provider.

**Deploy order:**
```
1. Deploy SunPLS_Token_v2         — 1B seed supply to deployer
2. Create PulseX pair             — seed 1:1 (equal SUNPLS and WPLS)
3. Deploy SunPLS_Oracle           — reads live reserves at deploy
4. Deploy SunPLS_Controller       — initialR = oracle.lastPrice() = 1e18
5. Deploy SunPLS_Vault_v2         — reads oracle.peek() at deploy
6. token.setVault(vault)          — permanent latch, one-time
7. controller.setVault(vault)     — permanent latch, one-time
── system is now fully autonomous ──
8. Deploy SunPLS_StabilityPool    — (when TVL warrants)
   args: (token address, vault address)
   No latching required. Zero changes to existing contracts.
```

**Why 1:1 LP seeding:** Oracle bootstraps `lastPrice` from reserves at deploy. `initialR` is set from `oracle.lastPrice()`. The seed ratio must equal `initialR` so P = R = 1e18 at launch — zero spread, no rate pressure, system starts in equilibrium.

---

## Security Model

**No admin keys.** `setVault()` is the only privileged function and becomes permanently inaccessible after being called once.

**No upgradeability.** No proxies, no beacons, no delegate calls.

**No oracle manipulation.** Stored snapshot TWAP — single-block sandwich cannot influence vault operations.

**Immutable rate engine.** Controller parameters (k, alpha, DELTA_R_MAX, R_FLOOR, epoch duration) are set at deploy and cannot change.

**Trust-minimized token.** Vault can only burn SunPLS it holds. Users must approve first. Vault cannot drain wallets.

**Stability pool isolation.** Pool's `receive()` restricted to vault only — no stray ETH entry, no accounting drift.

**What the contracts cannot do:**
- Mint SunPLS to arbitrary addresses
- Pause or freeze any function
- Change liquidation parameters or collateral requirements
- Redirect or withdraw collateral outside of vault operations
- Modify the fee structure or rate bounds

---

## Frontend Files

Self-contained — no build step required. Serve statically or open directly.

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, rate engine, oracle |
| `liquidations.html` | Dashboard — scan all vaults, liquidate, redeem, inspect any vault |
| `sunpls-vault-v2-abi.json` | Vault ABI (v2 — 11-return vaultInfo, surplus buffer, bad debt) |
| `sunpls-token-v2-abi.json` | Token ABI (ERC20 + ERC20Permit) |
| `sunpls-oracle-abi.json` | Oracle ABI |
| `sunpls-controller-abi.json` | Controller ABI |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `sunplslogo.png` | Protocol logo |
| `contracts/SunPLS_Token_v2.sol` | Token source |
| `contracts/SunPLS_Vault_v2.sol` | Vault source |
| `contracts/SunPLS_Oracle.sol` | Oracle source |
| `contracts/SunPLS_Controller.sol` | Controller source |
| `contracts/SunPLS_StabilityPool.sol` | Stability pool — deploy when TVL warrants |

**GitHub Pages:** Push this folder to a GitHub repo, enable Pages on root branch. `index.html` is served automatically.

---

## Acknowledgements

SunPLS was developed following the **ProjectUSD autonomous stable asset specification**, which provided the architectural framework, safety invariants, and P/R/r feedback model used to construct the protocol.

ProjectUSD specification: https://github.com/Aqua75/ProjectUSD

The intellectual lineage traces from Hayek's *Denationalisation of Money* (1976) through the ProjectUSD specification to this implementation. Three independent lines of reasoning converging on the same architecture across 50 years.

---

*SunPLS is experimental software. No audits have been performed. Use at your own risk. Not financial advice.*

**License: CC-BY-NC-SA-4.0**
