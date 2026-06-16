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
   - [Auto Mode (Recommended)](#auto-mode-recommended)
   - [Step 1: Deposit PLS](#step-1-deposit-pls)
   - [Step 2: Mint SunPLS](#step-2-mint-sunpls)
   - [Step 3: Monitor Your Vault](#step-3-monitor-your-vault)
   - [Step 4: Repay Debt](#step-4-repay-debt)
   - [Step 5: Withdraw Collateral](#step-5-withdraw-collateral)
10. [Vault Health Zones](#vault-health-zones)
11. [Liquidations](#liquidations)
12. [Redemptions](#redemptions)
13. [V2 Protocol Improvements](#v2-protocol-improvements)
14. [Emergency Unlock](#emergency-unlock)
15. [Protocol Tools](#protocol-tools)
16. [System Invariants](#system-invariants)
17. [Design Goals](#design-goals)
18. [Deployed Contracts](#deployed-contracts)
19. [Version History](#version-history)
20. [Compiling the Contracts](#compiling-the-contracts)
21. [Security Model](#security-model)
22. [Frontend Files](#frontend-files)
23. [Acknowledgements](#acknowledgements)

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

The SunPLS protocol is composed of four core components:

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
```

Each component performs a dedicated role. The token is minted and burned by the vault. The oracle feeds the market price to the controller. The controller outputs the stability rate and R value used by the vault. No component has privileged access beyond its defined role.

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
Anyone can click "Trigger Epoch" in the Rate Engine panel to advance the controller. Bots and keeper contracts can also trigger epochs — V2 uses `.call{value}()` throughout, so smart contract callers work without the 2300-gas restriction of V1.

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

The fastest way to get started:

1. Connect your wallet (MetaMask on PulseChain, chain ID 369)
2. Switch to the **Auto** tab
3. Enter the amount of PLS you want to deposit
4. The interface previews how much SunPLS you will receive at 155% CR
5. Click **1-Click Auto Mint**

This executes `depositAndAutoMintPLS()` — a single transaction that deposits PLS as collateral and mints SunPLS, automatically targeting 155% collateralization ratio. This gives you a 5% buffer above the 150% minimum.

---

### Step 1: Deposit PLS

Switch to the **Deposit** tab, enter your PLS amount, click **Deposit PLS**.

**What happens:**
- Your PLS is wrapped to WPLS and stored in the vault contract as collateral
- A 5-minute withdrawal cooldown begins (prevents flash loan attacks)
- Depositing alone creates no debt — you can deposit and wait before minting

You can deposit multiple times. Each deposit resets the 5-minute cooldown.

---

### Step 2: Mint SunPLS

Switch to the **Mint** tab, enter the SunPLS amount to borrow, click **Mint SunPLS**.

**What happens:**
- The contract checks your resulting CR will be at least 150%
- SunPLS is minted to your wallet
- Your debt begins accruing the stability rate from this moment

**CR formula:**
```
CR = (Collateral in WPLS × Oracle Price P) ÷ SunPLS Debt × 100%
```

Example: 1,500 PLS collateral, P = 1.0 WPLS/SunPLS, 1,000 SunPLS debt → CR = 150%.

The live preview updates as you type. **Mint Max Safe** mints the exact maximum at 150% CR — use with caution, it leaves no headroom.

---

### Step 3: Monitor Your Vault

Your vault health is shown in the **My Vault** card:

| Field | What it means |
|-------|--------------|
| **Collateral** | WPLS locked in the vault |
| **Debt** | SunPLS currently owed (grows with positive rate) |
| **CR Ratio** | Your collateralization ratio — keep above 150% |
| **Rate (APR)** | Current stability rate — positive means debt grows |
| **Coll Value** | Collateral worth in SunPLS at current oracle price |
| **Mintable** | Additional SunPLS you can borrow at 150% CR |

The **CR gauge arc** animates green → amber → red as your ratio drops. A warning banner appears at the top when your CR falls below 130%. A pulsing red border appears below 110% — act immediately at this level.

---

### Step 4: Repay Debt

**Repay specific amount:** Burns SunPLS and reduces your debt balance. Instant, no cooldown, no fee.

**Repay to Safe (150%):** Auto-calculates and repays exactly what is needed to return to 150% CR. Use this after a price drop to stop being eligible for redemption.

**Check Liquidation Risk:** Plain-language assessment of your current exposure.

**Note on debt accrual:** If the rate is +2% APR and you minted 1,000 SunPLS, after one year you owe ~1,020 SunPLS. Monitor the Rate (APR) field and repay periodically if the rate is positive.

---

### Step 5: Withdraw Collateral

**Withdraw specific amount:** Pulls PLS back to your wallet. Fails if result drops CR below 150%.

**Withdraw Max Safe:** Calculates and withdraws maximum PLS while keeping CR at exactly 150%.

**Repay All & Withdraw Everything (Auto tab):** Full vault exit in one transaction. Requires SunPLS equal to current total debt in your wallet.

**5-minute cooldown** applies after every deposit. The cooldown banner appears automatically when active.

---

## Vault Health Zones

| CR Range | Zone | What can happen |
|----------|------|----------------|
| **150%+** | Safe | Normal operation. Immune to both redemption and liquidation. |
| **110–149%** | Redeemable | SunPLS holders can redeem against your vault. They burn SunPLS and take PLS at the R rate. Your debt and collateral both decrease proportionally. A 0.5% fee stays with you. |
| **Below 110%** | Liquidatable | Liquidators can repay a portion of your debt (minimum 5%) and receive your collateral at a bonus (up to 7%). Act immediately — add collateral or repay debt. |

**Recommended target:** 170%+ CR to absorb price swings without falling into the redeemable zone.

---

## Liquidations

When a vault's CR falls below 110%, it becomes liquidatable.

**V2 liquidation mechanics:**
- **Minimum liquidation:** 5% of outstanding debt (reduced from 20% in V1 — more efficient for bots)
- **Maximum liquidation:** 100% of debt
- **Bonus:** 7% at minimum repayment, scaling toward 2% for larger repayments (inverted Dutch auction over 3 hours)
- **Who can liquidate:** Anyone holding SunPLS

**Step-by-step:**
1. Open **Vault Dashboard → Liquidate tab**
2. Click **Scan All Vaults** — finds all vaults below 110% CR
3. Click **Liquidate** on any eligible vault
4. Enter SunPLS amount to repay (≥ the minimum shown)
5. Preview shows exact PLS reward
6. Click **Confirm Liquidation**

The contract takes your SunPLS, burns it, and sends you the equivalent PLS collateral plus the liquidation bonus. Partial liquidations are fully supported — your reward is proportional to the amount you repay.

---

## Redemptions

Redemptions enforce the peg. When SunPLS trades below R, anyone can buy it cheaply on the market and redeem it at the full R rate — extracting the spread as profit.

**What happens during a redemption:**
1. You choose a target vault (must be below 150% CR) and specify SunPLS to burn
2. You receive: `SunPLS amount × R` worth of PLS, minus 0.5% fee
3. The 0.5% fee goes to the vault owner
4. The vault's debt decreases by the SunPLS burned
5. The vault's collateral decreases by the PLS paid out

**Redemptions always execute at R, not the market price.** No slippage. No price impact. You always receive exactly `SunPLS × R` of collateral regardless of current AMM conditions.

**Why this creates the peg:**
If SunPLS = 0.95 WPLS on market but R = 1.00 WPLS, buying SunPLS and redeeming earns +5% risk-free. This arbitrage continues until the market price rises back to R.

**For vault owners:** Keep your CR above 150% to be immune to redemption. If your CR falls into the redeemable zone, you can be redeemed against any time without warning. The 0.5% fee you receive is compensation for the involuntary reduction of your position.

**Step-by-step:**
1. Open **Vault Dashboard → Redeem tab**
2. Click **Scan All Vaults** to find vaults below 150% CR
3. Click **Redeem** on your target vault
4. Enter SunPLS to burn — preview shows exact PLS output, fee, and R value used
5. Click **Confirm Redemption**

---

## V2 Protocol Improvements

SunPLS V2 introduces structural improvements over V1, making the protocol safer at higher TVL and more accessible to keeper bots and DeFi integrations.

### Surplus Buffer

Every time the stability rate is positive, accrued fees accumulate in a **Surplus Buffer** (measured in SunPLS). This is the protocol's equity — it absorbs bad debt before any systemic risk propagates.

- Grows when the stability rate is positive and debt is outstanding
- Used to offset bad debt via `reconcile()`
- Displayed in the System State panel in real time

### Bad Debt Accounting

V1 silently socialized any uncovered liquidation losses. V2 tracks them explicitly:

- `badDebtAccumulated` — total SunPLS debt not covered by any vault's collateral
- Displayed in the System State panel (red when non-zero)
- Never disappears until offset by surplus or settled manually
- **System Equity** = Surplus Buffer − Bad Debt. Positive = solvent. Negative = bad debt exceeds fees collected.

### Reconciliation

`reconcile()` is a public, permissionless function that nets the surplus buffer against bad debt. Called automatically inside vault operations but triggerable by anyone at any time from the Protocol Tools panel.

### Trust-Minimized Burn

V1 used `burn(address from, amount)` — the vault had direct burning authority over any address. V2 requires users to `approve()` first, then the vault calls `transferFrom(user → vault)` before burning only from its own balance. The vault can never touch tokens it does not hold.

### EIP-2612 Permit Flows

V2 adds `repayWithPermit`, `liquidateWithPermit`, and `redeemWithPermit`. Users can sign an off-chain permit message instead of a separate `approve` transaction, reducing two-transaction flows to one. Essential for keeper bots and advanced integrations.

### Smart Contract Compatibility

V1 used `.transfer()` (2300 gas stipend) for PLS payments — smart contract recipients with non-trivial `receive()` logic would fail. V2 uses `.call{value}()` throughout. Keeper bots, MEV searchers, and DeFi integrations work without restriction.

### Reduced Minimum Liquidation

V1 required liquidators to repay at least 20% of a vault's debt per liquidation. V2 drops this to 5%. Smaller positions become liquidatable by a wider range of bots, improving system safety at all TVL levels.

---

## Emergency Unlock

If you have zero debt, collateral locked, and 30 days have passed since your last deposit, you can call `emergencyUnlock()` to recover your collateral regardless of any oracle or protocol state.

**When relevant:**
- Oracle is permanently offline and normal withdrawal path requires a price check
- You deposited collateral but never minted, then lost access and later regained it
- Any edge case where the normal withdrawal path is blocked

The Emergency Unlock button appears automatically in the Deposit tab when conditions are met. Zero debt is required — repay all outstanding SunPLS first.

---

## Protocol Tools

Three advanced public functions in the **Protocol Tools** panel, callable by anyone:

### Clear Bad Debt
```solidity
vault.clearBadDebt(address zombieVault)
```
If a vault has zero debt but recorded bad debt against it (a "zombie vault"), anyone can call this to seize the zombie's remaining collateral. The caller receives the PLS for free. The bad debt entry is cleared. This rewards anyone who processes edge cases and cleans up the accounting.

### Settle Debt
```solidity
vault.settleDebt(uint256 amount)
```
Anyone can burn their own SunPLS to directly cancel accumulated bad debt at the protocol level. This does not affect the caller's personal vault — it reduces the global `badDebtAccumulated` counter. Community members who want to contribute to protocol health can use this.

### Reconcile
```solidity
vault.reconcile()
```
Nets surplus buffer against bad debt. No economic cost beyond gas. Called automatically inside most vault operations. Trigger manually at any time to force an up-to-date accounting state.

---

## System Invariants

The protocol enforces the following invariants at all times:

```
I1  — Vault solvency:       CR ≥ 150% required to mint or withdraw
I2  — Liquidation:          Vaults below 110% CR can be liquidated
I3  — Redemption:           Only vaults below 150% CR can be redeemed against
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
```

These invariants ensure the system remains safe under degraded conditions — stale oracle, low liquidity, high bad debt, or extreme price moves.

---

## Design Goals

SunPLS was designed with the following principles:

- **Fully autonomous monetary policy** — no human required to run the rate engine
- **No governance control** — no DAO, no multisig, no timelock, no admin
- **Deterministic economic rules** — identical behavior at any TVL scale
- **Strong arbitrage stabilization** — redemption creates a self-enforcing peg floor
- **Oracle failure resilience** — four degradation modes keep the system live
- **Permissionless operation** — any wallet or contract can interact with any function
- **Transparent solvency** — surplus buffer and bad debt visible on-chain at all times

The protocol behaves as a self-contained economic machine. It does not require trust in any individual, team, or organization. The code is the bank. The Controller is the central bank policy. The math is the guarantee.

---

## Deployed Contracts

All contracts deployed on **PulseChain (Chain ID: 369)**. No owner keys. No upgradeability. Immutable.

### V2 — Current (Canonical)

| Contract | Address |
|----------|---------|
| **SunPLS Token v2** | `0xaac685D900CC42569061d91F6a521658AA397f32` |
| **Vault v2** | `0x5A87Aa7A3C68ACA0bb0CDe423Bf1f107284135BC` |
| **Oracle** | `0x0A0E4adFBF38Dd227ed25D4f7e48B44D3a6aCa49` |
| **Controller** | `0xd231F209aCd14e66cbe72b23a0c5C1105651b4c6` |
| **PulseX SunPLS/WPLS Pair** | `0xF003688b899d9f554D705032AE01828Fa0B87054` |
| **WPLS** | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |

**Token details:**
- Name: SunPLS | Symbol: SUNPLS | Decimals: 18
- Standard: ERC20 + ERC20Permit (EIP-2612)
- Initial supply: 1,000,000,000 minted at deploy to seed the PulseX pair
- Starting R: 1.0 WPLS (1:1 with PLS — matches R_FLOOR and oracle bootstrap)

**Vault parameters:**
- Min collateral ratio: 150% | Liquidation threshold: 110%
- Redemption threshold: below 150% CR
- Min liquidation: 5% of debt | Max bonus: 7%
- Redemption fee: 0.5% (to vault owner)
- Withdrawal cooldown: 5 minutes | Emergency unlock: 30 days with zero debt
- Debt ceiling: `uint256.max` (uncapped — real limiters are CR and liquidity)

---

## Version History

| Version | Status | Notes |
|---------|--------|-------|
| V1.2 | Deprecated | Inverted oracle price formula — non-functional |
| V1.3 | Superseded | Redemption threshold was 150% CR |
| V1.4 | Live (legacy) | Canonical V1 — redemption threshold lowered to 130% CR, on-chain vault enumeration added. Uses `.transfer()` (2300 gas), 20% min liquidation. Safe at current TVL. |
| V2 | **Current** | Surplus buffer, bad debt accounting, reconcile, `.call{value}()`, 5% min liquidation, EIP-2612 permit flows, trust-minimized burn. Designed for higher TVL. |

V1.4 remains live and is not being shut down. V1 and V2 are parallel deployments with separate token contracts. V2 is the recommended system for new positions.

---

## Compiling the Contracts

**⚠️ PulseChain EVM Constraint:** PulseChain supports Shanghai EVM but **not Cancun** opcodes (including `mcopy` / EIP-5656). OpenZeppelin v5 transitively imports `Bytes.sol` which uses `mcopy` — this will fail on PulseChain.

**Required setup:**
- Compiler: `pragma solidity ^0.8.20`
- OZ version: **v4.9.6 via versioned GitHub URLs** (not npm, which resolves to OZ v5)
- EVM target: Shanghai

**GitHub import URLs used in these contracts:**
```solidity
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/utils/math/Math.sol";
```

**Compile in Remix IDE:**
1. Set compiler to `0.8.20` — do not use 0.8.24+
2. Set EVM version to `shanghai` in Advanced Compiler Settings
3. Import the `.sol` files — GitHub URLs resolve OZ v4.9.6 automatically
4. Deploy via Injected Provider (MetaMask on PulseChain)

**Deploy order:**
```
1. Deploy SunPLS_Token_v2    — 1B seed supply minted to deployer
2. Create PulseX pair        — seed 1:1 (equal SUNPLS and WPLS amounts)
3. Deploy SunPLS_Oracle      — reads live pair reserves at deploy
4. Deploy SunPLS_Controller  — initialR = oracle.lastPrice() (= 1e18 at 1:1 seed)
5. Deploy SunPLS_Vault_v2    — reads oracle.peek() at deploy, must be healthy
6. token.setVault(vault)     — permanent latch, one-time only
7. controller.setVault(vault)— permanent latch, one-time only
```

After step 7 the system is fully autonomous. No further deployer action is possible or required.

**Why 1:1 LP seeding:** The oracle bootstraps `lastPrice` from live AMM reserves in its constructor. `initialR` in the Controller is set from `oracle.lastPrice()` at deploy. The LP seed ratio must equal `initialR` so that P = R = 1e18 at launch — zero spread, no rate pressure, system starts in equilibrium. R_FLOOR = 1e18 makes this the only architecturally correct starting point.

---

## Security Model

**No admin keys.** There are no `onlyOwner` functions in V2 beyond the one-time `setVault()` latch, which becomes permanently inaccessible after being called once. No timelock needed — there is nothing to govern.

**No upgradeability.** No proxy patterns, no beacon patterns, no delegate calls. The contracts are exactly what was deployed.

**No oracle manipulation surface.** The oracle uses a stored snapshot rather than a live AMM read — a single-block sandwich cannot influence vault operations.

**Immutable rate engine.** The Controller's parameters (k, alpha, DELTA_R_MAX, R_FLOOR, epoch duration) are set at deploy time and cannot be changed by anyone.

**Trust-minimized token.** The vault can only burn SunPLS it holds in its own balance. Users must explicitly approve before any token transfer. The vault cannot drain wallets.

**What the contracts cannot do:**
- Mint SunPLS to arbitrary addresses
- Pause or freeze any function
- Change liquidation parameters or collateral requirements
- Withdraw or redirect collateral (it is only released via vault operations)
- Modify the fee structure or rate bounds

---

## Frontend Files

Self-contained frontend — no build step required. Serve statically or open directly.

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, rate engine, oracle |
| `liquidations.html` | Dashboard — scan all vaults, liquidate, redeem, inspect any vault |
| `sunpls-vault-v2-abi.json` | Vault ABI (v2 — 11-return vaultInfo, surplus buffer, bad debt) |
| `sunpls-token-v2-abi.json` | Token ABI (ERC20 + ERC20Permit) |
| `sunpls-oracle-abi.json` | Oracle ABI |
| `sunpls-controller-abi.json` | Controller ABI |
| `ethers.umd.min.js` | ethers.js v6 bundled (no CDN dependency) |
| `sunplslogo.png` | Protocol logo |
| `contracts/` | Solidity source for all four V2 contracts |

**GitHub Pages:** Push this folder to a GitHub repo, enable Pages on root branch. `index.html` at root is served automatically.

---

## Acknowledgements

SunPLS was developed following the **ProjectUSD autonomous stable asset specification**, which provided the architectural framework, safety invariants, and P/R/r feedback model used to construct the protocol.

ProjectUSD specification: https://github.com/Aqua75/ProjectUSD

The intellectual lineage traces from Hayek's *Denationalisation of Money* (1976) through the ProjectUSD specification to this implementation. Three independent lines of reasoning converging on the same architecture across 50 years.

---

*SunPLS is experimental software. No audits have been performed. Use at your own risk. Not financial advice.*

**License: CC-BY-NC-SA-4.0**
