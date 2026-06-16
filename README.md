# SunPLS V2

**Autonomous · Ownerless · Immutable · PulseChain**

SunPLS is a decentralized CDP (Collateralized Debt Position) protocol on PulseChain. Users lock WPLS as collateral and mint SunPLS — a synthetic token whose value is pegged to PLS itself through an autonomous monetary policy engine. There are no admin keys, no upgradeability, no owner functions. Once deployed, the contracts run forever without human intervention.

---

## Table of Contents

1. [What is SunPLS?](#what-is-sunpls)
2. [The Floating Peg — R vs P](#the-floating-peg--r-vs-p)
3. [The Rate Engine (Controller)](#the-rate-engine-controller)
4. [The Oracle](#the-oracle)
5. [How to Use the Protocol](#how-to-use-the-protocol)
   - [Auto Mode (Recommended)](#auto-mode-recommended)
   - [Step 1: Deposit PLS](#step-1-deposit-pls)
   - [Step 2: Mint SunPLS](#step-2-mint-sunpls)
   - [Step 3: Monitor Your Vault](#step-3-monitor-your-vault)
   - [Step 4: Repay Debt](#step-4-repay-debt)
   - [Step 5: Withdraw Collateral](#step-5-withdraw-collateral)
6. [Vault Health Zones](#vault-health-zones)
7. [Liquidations](#liquidations)
8. [Redemptions](#redemptions)
9. [V2 Protocol Improvements](#v2-protocol-improvements)
   - [Surplus Buffer](#surplus-buffer)
   - [Bad Debt Accounting](#bad-debt-accounting)
   - [Reconciliation](#reconciliation)
   - [Trust-Minimized Burn](#trust-minimized-burn)
   - [EIP-2612 Permit Flows](#eip-2612-permit-flows)
   - [Smart Contract Compatibility](#smart-contract-compatibility)
10. [Emergency Unlock](#emergency-unlock)
11. [Protocol Tools](#protocol-tools)
12. [Deployed Contracts](#deployed-contracts)
13. [Compiling the Contracts](#compiling-the-contracts)
14. [Security Model](#security-model)
15. [Frontend Files](#frontend-files)

---

## What is SunPLS?

SunPLS is a PLS-backed synthetic token. Unlike stablecoins pegged to USD, SunPLS is pegged to **PLS itself** — specifically, 1 SunPLS targets a redemption value (R) of 1 WPLS at launch, with R allowed to drift based on market conditions.

**The core mechanic:**
- You deposit WPLS (Wrapped PLS) as collateral into a vault
- You borrow SunPLS against that collateral at a minimum 150% collateralization ratio
- You pay a stability rate (can be positive or negative) that accumulates as debt over time
- If your vault falls below the liquidation threshold, liquidators can close it for a bonus
- Anyone holding SunPLS can redeem it for PLS collateral at the R rate from eligible vaults

SunPLS has no central bank, no governance multisig, no admin keys. The monetary policy is executed entirely by the on-chain Controller contract based on the spread between the market price (P) and the redemption value (R).

---

## The Floating Peg — R vs P

Two prices govern SunPLS:

| Symbol | Name | What it is |
|--------|------|-----------|
| **P** | Oracle Price | The live market price of SunPLS in WPLS, from the PulseX AMM via TWAP |
| **R** | Redemption Value | The protocol's target price — the amount of WPLS you receive when redeeming 1 SunPLS |

**The relationship between P and R:**

- When **P > R** (SunPLS trading above target): the Controller raises the stability rate, making borrowing more expensive. This discourages new minting and encourages holders to sell, pushing P back toward R.
- When **P < R** (SunPLS trading below target): the Controller lowers the stability rate (potentially negative — effectively a subsidy). This encourages new minting and makes redemptions profitable, pulling P back toward R.

**R starts at 1.0 WPLS** (1:1 with PLS). The Controller can drift R upward or downward by a maximum of `DELTA_R_MAX = 0.0005 WPLS` per epoch. Over time, R represents the protocol's best estimate of the equilibrium exchange rate between SunPLS and PLS.

**R is the floor and peg.** The `R_FLOOR = 1e18` (1 WPLS) means R will never fall below 1 PLS per SunPLS — the protocol enforces this in every redemption and liquidation calculation.

---

## The Rate Engine (Controller)

The Controller is an autonomous monetary policy engine that runs in epochs (default: 1 hour each). Any wallet can trigger a new epoch — it is fully permissionless.

**Each epoch the Controller:**
1. Reads the current oracle price (P) and the current R value
2. Calculates the spread: `spread = (P - R) / R`
3. Adjusts R by up to `DELTA_R_MAX` in the direction that closes the spread
4. Calculates a new stability rate that will be applied to all outstanding debt

**Stability Rate:**
- The rate is an annualized percentage applied continuously to your debt
- A **positive rate** means your debt grows over time — you owe more SunPLS than you minted
- A **negative rate** means your debt shrinks over time — the protocol is subsidizing borrowers
- The rate is displayed on the vault interface as `+X.XX% APR` or `-X.XX% APR`
- Current rate is visible on your vault's "Rate (APR)" field — check this regularly

**Epoch triggering:**
- Shown as "Can Trigger: Yes/No" in the Controller panel
- Anyone can click "Trigger Epoch" to advance the rate engine
- Bots and keepers can trigger epochs programmatically (the v2 contracts use `.call{value}()` so smart contracts can trigger epochs)

---

## The Oracle

The oracle reads the PulseX SunPLS/WPLS AMM pair and produces a time-weighted average price (TWAP). It is a standalone contract that anyone can update.

**Key points:**
- `oracle.update()` stores a snapshot of the AMM reserves with a timestamp
- `oracle.peek()` returns the latest stored price and its timestamp
- `oracle.isHealthy()` returns true if the stored price is less than 24 hours old
- If the oracle goes stale (>24h without an update), vault operations that depend on price will revert or produce degraded results
- The oracle status is shown in the "Oracle Status" panel on the vault page
- If you see "Oracle stale", click **Update Oracle Price** to refresh it (costs a small amount of gas, no economic cost)

---

## How to Use the Protocol

### Auto Mode (Recommended)

The fastest way to get started:

1. Connect your wallet (MetaMask on PulseChain, chain ID 369)
2. Switch to the **Auto** tab
3. Enter the amount of PLS you want to deposit
4. The interface shows you how much SunPLS you will receive at 155% CR
5. Click **1-Click Auto Mint**

This executes `depositAndAutoMintPLS()` — a single transaction that deposits your PLS as collateral and mints SunPLS in one step, automatically targeting a 155% collateralization ratio. This gives you a 5% safety buffer above the 150% minimum.

---

### Step 1: Deposit PLS

Switch to the **Deposit** tab and enter your PLS amount, then click **Deposit PLS**.

**What happens:**
- Your PLS is wrapped to WPLS and stored in the vault contract as collateral
- A 5-minute withdrawal cooldown begins (prevents flash loan attacks)
- Your collateral value in SunPLS is calculated using the current oracle price P

**Important:**
- You can deposit multiple times — each deposit resets the 5-minute cooldown
- Depositing does not create any debt — you can deposit and wait before minting
- The deposit is held 1:1 by the vault contract in WPLS

---

### Step 2: Mint SunPLS

Switch to the **Mint** tab and enter the amount of SunPLS to borrow, then click **Mint SunPLS**.

**What happens:**
- The contract checks that your resulting collateralization ratio (CR) will be at least 150%
- SunPLS is minted directly to your wallet
- Your debt balance begins accruing the stability rate from this moment

**Understanding the CR calculation:**
```
CR = (collateral in WPLS × oracle price P) / SunPLS debt × 100%
```

At 150% CR, for every 1.5 WPLS worth of collateral you hold, you can borrow 1 SunPLS.

**Tips:**
- The live preview shows your projected CR as you type — stay above 155%+ for a comfortable buffer
- Click **Mint Max Safe (150%)** to mint the maximum possible at exactly 150% CR
- The higher your CR, the safer you are from liquidation and redemption

---

### Step 3: Monitor Your Vault

Your vault's health is displayed in the **My Vault** card at the top of the page:

| Field | What it means |
|-------|--------------|
| **Collateral** | How much PLS (as WPLS) you have locked in the vault |
| **Debt** | How much SunPLS you currently owe (grows with positive rate) |
| **CR Ratio** | Your current collateralization ratio — keep this above 150% |
| **Rate (APR)** | The current stability rate — positive means debt grows, negative means it shrinks |
| **Coll Value** | Your collateral's worth expressed in SunPLS at the current oracle price |
| **Mintable** | How much more SunPLS you can borrow and stay above 150% CR |

**The CR gauge** in the top-left of the vault card provides an at-a-glance visual:
- Green arc → CR above 150% (safe zone)
- Amber arc → CR approaching 150% (caution zone)
- Red arc → CR below 130% (danger zone — liquidation and redemption risk)

**Health alerts:**
- The page shows a warning banner at the top when your CR drops below 130%
- A pulsing red border appears at CR below 110% (liquidation imminent)
- If you see these alerts, add more collateral or repay debt immediately

---

### Step 4: Repay Debt

Switch to the **Repay** tab. You have several options:

**Repay a specific amount:**
Enter SunPLS to repay and click **Repay Debt**. The contract burns the SunPLS and reduces your debt balance. There is no cooldown on repayments — you can repay at any time.

**Repay to Safe (150% CR):**
Click **Repay to Safe (150%)** to automatically calculate and repay exactly the amount needed to bring your CR back to 150%. Useful when your vault is under pressure and you want to return to the minimum safe level without repaying more than necessary.

**Check Liquidation Risk:**
Click **Check Liquidation Risk** to see a plain-language assessment of your vault's current danger level and whether liquidators can currently act on your vault.

**Note on debt accrual:** Your debt grows continuously (or shrinks) at the current stability rate. The rate compounds per second against your debt balance. This means if the rate is +2% APR and you minted 1000 SunPLS, after one year you will owe approximately 1020 SunPLS. Check your "Rate (APR)" field regularly.

---

### Step 5: Withdraw Collateral

Switch to the **Withdraw** tab. Enter a PLS amount and click **Withdraw PLS**.

**Rules:**
- You cannot withdraw if it would drop your CR below 150% (unless you have zero debt)
- You cannot withdraw within 5 minutes of your most recent deposit (cooldown)
- The cooldown warning banner appears automatically when the lock is active

**Withdraw Max Safe:**
Click **Withdraw Max Safe (Stay 150%)** to automatically calculate and withdraw the maximum PLS while keeping your CR exactly at 150%. This is the safest way to take out as much collateral as possible without triggering liquidation.

**Repay All & Withdraw Everything (Auto tab):**
For a full exit, go to the **Auto** tab and click **Repay All & Withdraw Everything**. This executes in a single transaction: it repays your entire debt balance and withdraws all of your collateral. You will need enough SunPLS in your wallet to cover your full debt (including any accrued interest).

---

## Vault Health Zones

| CR Range | Zone | What happens |
|----------|------|-------------|
| **150%+** | Safe | Normal operation. No one can touch your vault. |
| **130–149%** | Redeemable | SunPLS holders can redeem against your vault, paying R per SunPLS and receiving your collateral. Your debt is reduced proportionally. |
| **Below 110%** | Liquidatable | Liquidators can repay a portion of your debt (minimum 5%) and receive your collateral at a bonus (up to 7%). |

**How to stay safe:**
- Target 170%+ CR for a comfortable buffer against price volatility
- Watch the stability rate — a rising positive rate grows your debt even if price stays flat
- Add collateral when PLS price drops, or repay debt when you have spare SunPLS

---

## Liquidations

When a vault's CR falls below 110%, the vault becomes liquidatable. Liquidators can repay part or all of the vault's debt in exchange for the vault's PLS collateral plus a liquidation bonus.

**Liquidation mechanics:**
- **Minimum liquidation:** 5% of the outstanding debt (reduces bot friction vs. 20% in v1)
- **Maximum liquidation:** 100% of the outstanding debt
- **Bonus:** Starts at 7% for small liquidations, scales toward 2% for full liquidations — calibrated to keep liquidations profitable for bots without punishing vault owners excessively
- **Who can liquidate:** Anyone with SunPLS in their wallet
- **How:** Go to the **Vault Dashboard → Liquidate tab**, scan for liquidatable vaults, then click "Liquidate" on any eligible vault

**Step-by-step liquidation:**
1. Click **Vault Dashboard** → open the **Liquidate** tab
2. Click **Scan All Vaults** — the dashboard reads every registered vault on-chain
3. Any vault below 110% CR appears in the table with its debt, minimum repay amount, and estimated PLS reward
4. Click **Liquidate** on your chosen vault
5. In the modal: enter how much SunPLS you want to repay (must be at least the minimum)
6. The preview shows you the PLS you will receive
7. Click **Confirm Liquidation** — the contract takes your SunPLS, burns it, and sends you the equivalent collateral plus bonus

**Partial vs. full liquidation:**
- You do not have to liquidate the full debt — liquidate what you can afford
- Your PLS reward is proportional to the amount you repay
- The bonus percentage is fixed by the vault's `bonusBps` (shown in the table)

**After liquidation:**
- If a vault is liquidated below the minimum CR threshold and collateral runs out before all debt is covered, the remaining uncovered debt becomes **bad debt** — tracked separately in the surplus buffer accounting system

---

## Redemptions

Redemptions are how SunPLS maintains its peg. When SunPLS trades below R (the redemption value), holders can profitably burn SunPLS and receive PLS at the R rate, directly from undercollateralized vaults.

**Who can be redeemed against:**
- Any vault with CR between 110% and 150% is eligible for redemption
- The vault with the *lowest* CR is typically the most efficient target
- You cannot redeem against a vault above 150% CR

**What happens during a redemption:**
1. You choose a target vault and specify how much SunPLS to burn
2. The contract calculates PLS owed to you: `SunPLS amount × R`
3. 0.5% of that PLS goes to the vault owner as a fee
4. The rest is sent to you
5. The vault's debt is reduced by the SunPLS you burned
6. The vault's collateral is reduced by the PLS paid out

**Why this creates the peg:**
- If SunPLS trades at 0.95 WPLS on the market but R = 1.00 WPLS, you can buy SunPLS cheaply on the market and redeem it at the full R rate — earning a profit
- This arbitrage continues until SunPLS price rises back to R
- Vault owners with low CR are incentivized to top up their collateral to avoid being redeemed against

**Step-by-step redemption:**
1. Go to **Vault Dashboard → Redeem tab**
2. Click **Scan All Vaults** to find redeemable (CR < 150%) vaults
3. Click **Redeem** on your target vault
4. Enter the amount of SunPLS to burn
5. The preview shows: PLS you receive, fee to vault owner, and the R value used
6. Click **Confirm Redemption**

**Redemption rate (`R`):**
Redemptions always execute at the Controller's current R value, not the oracle spot price. This means redemptions have no slippage — you always receive exactly `(SunPLS × R)` worth of PLS, minus the 0.5% fee. R is shown in the live ticker at the top of both pages.

---

## V2 Protocol Improvements

SunPLS V2 introduces several structural improvements over V1, making the protocol safer at higher TVL.

### Surplus Buffer

Every time the stability rate is positive, accrued fees go into a **Surplus Buffer** measured in SunPLS units. The surplus buffer is the protocol's equity — it absorbs bad debt before any systemic risk propagates.

- Displayed as "Surplus Buffer" in the System State panel
- Grows when the stability rate is positive and debt is outstanding
- Used to offset bad debt via the `reconcile()` function
- Represents the protocol's profit/equity over time

### Bad Debt Accounting

If a liquidation leaves a vault with debt but no collateral, that remaining debt becomes **bad debt**. In V1 this was silently socialized. In V2 it is explicitly tracked:

- Displayed as "Bad Debt" in the System State panel (shown in red when non-zero)
- Bad debt does not disappear — it remains until either the surplus buffer covers it (via reconcile) or someone calls `settleDebt()`
- **System Equity** = Surplus Buffer − Bad Debt. A positive equity means the protocol is solvent. A negative equity (shown in red) means bad debt has exceeded accumulated fees.

### Reconciliation

`reconcile()` is a public function anyone can call. It nets the surplus buffer against outstanding bad debt:

- If surplus > bad debt: bad debt goes to zero, surplus is reduced by that amount
- If bad debt > surplus: surplus goes to zero, bad debt is reduced by the surplus amount
- The contract calls this internally after liquidations, but you can trigger it manually from the Protocol Tools panel

### Trust-Minimized Burn

In V1, the vault could call `burn(address from, amount)` on the token — meaning the vault contract had direct burning authority over any address's tokens. In V2, the burn is trust-minimized:

- Users call `token.approve(vault, amount)` first
- The vault calls `token.transferFrom(user → vault)` to pull the tokens
- The vault then calls `token.burn()` which only burns from the vault's own balance
- The vault can never burn tokens from an address it does not control

### EIP-2612 Permit Flows

V2 adds `repayWithPermit`, `liquidateWithPermit`, and `redeemWithPermit` functions. These allow users to sign an off-chain permit message instead of sending a separate `approve` transaction — reducing liquidation and repayment from a 2-transaction flow to a single transaction. Useful for keeper bots and advanced users.

### Smart Contract Compatibility

V1 used `.transfer()` to send PLS, which has a 2300 gas stipend. Smart contract callers (keeper bots, MEV searchers, DeFi integrations) that implement `receive()` with non-trivial logic would fail. V2 uses `.call{value}()` throughout, removing this restriction entirely.

---

## Emergency Unlock

If you have zero debt but still have collateral locked, and 30 days have passed since your last deposit, you can call `emergencyUnlock()` to recover your collateral regardless of any oracle or protocol state.

**When this is relevant:**
- If the oracle goes permanently offline and you cannot withdraw normally
- If you deposited collateral but never minted, then lost access and later regained it
- Any scenario where the normal withdrawal path is blocked

**How to use it:**
1. Ensure your debt is fully repaid (zero balance)
2. Wait 30 days from your last deposit
3. In the Deposit tab, the "Emergency Unlock (30-day Recovery)" button will appear and become active
4. Click it to recover all of your collateral in one transaction

---

## Protocol Tools

Three advanced functions available in the **Protocol Tools** panel (bottom of the vault page), callable by anyone:

### Clear Bad Debt
```
vault.clearBadDebt(address zombieVault)
```
If a vault has zero debt but the protocol recorded bad debt against it (a "zombie vault"), anyone can call this to seize the zombie vault's collateral. The caller receives the PLS collateral for free, and the bad debt entry for that address is cleared. This cleans up the accounting and rewards anyone who processes these edge cases.

### Settle Debt
```
vault.settleDebt(uint256 amount)
```
Anyone can burn their own SunPLS to directly cancel accumulated bad debt on the protocol level. This is not a personal repayment — it reduces the global `badDebtAccumulated` counter. Community members who want to contribute to protocol health (e.g. backers, supporters) can call this to reduce systemic risk.

### Reconcile
```
vault.reconcile()
```
Nets the surplus buffer against bad debt. No economic cost beyond gas. Called automatically inside vault operations, but can be manually triggered at any time to keep the accounting up to date.

---

## Deployed Contracts

All contracts are deployed on **PulseChain (Chain ID: 369)**. No owner keys. No upgradeable proxies. Immutable.

| Contract | Address |
|----------|---------|
| **SunPLS Token v2** | `0xaac685D900CC42569061d91F6a521658AA397f32` |
| **Vault v2** | `0x5A87Aa7A3C68ACA0bb0CDe423Bf1f107284135BC` |
| **Oracle** | `0x0A0E4adFBF38Dd227ed25D4f7e48B44D3a6aCa49` |
| **Controller** | `0xd231F209aCd14e66cbe72b23a0c5C1105651b4c6` |
| **PulseX SunPLS/WPLS Pair** | `0xF003688b899d9f554D705032AE01828Fa0B87054` |
| **WPLS** | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |

View on PulseScan: [scan.pulsechain.com](https://scan.pulsechain.com)

**Token details:**
- Name: SunPLS
- Symbol: SUNPLS
- Decimals: 18
- Initial supply: 1,000,000,000 (1 billion) minted at deploy to seed the PulseX pair
- Standard: ERC20 + ERC20Permit (EIP-2612)

**Vault parameters:**
- Minimum collateral ratio: 150%
- Liquidation threshold: 110% CR
- Minimum liquidation: 5% of debt
- Redemption threshold: 150% CR (vaults below this are eligible)
- Redemption fee: 0.5% (goes to vault owner)
- Withdrawal cooldown: 5 minutes after deposit
- Emergency unlock: 30 days with zero debt
- Debt ceiling: Uncapped (`uint256.max`) — real limiters are CR requirements and liquidity

---

## Compiling the Contracts

**⚠️ PulseChain EVM Constraint:** PulseChain supports the Shanghai EVM but **does not support Cancun** opcodes (including `mcopy` / EIP-5656). OpenZeppelin v5 transitively imports `Bytes.sol` which uses `mcopy` — this will fail to compile for PulseChain deployment.

**Required setup:**
- Compiler: `pragma solidity ^0.8.20`
- OpenZeppelin: v4.9.6 via **versioned GitHub URLs** (not npm, which resolves to OZ v5)
- EVM target: Shanghai (not Cancun, not Paris)

**The contracts use these specific GitHub import URLs:**
```solidity
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/utils/math/Math.sol";
```

**Compile in Remix IDE:**
1. Open Remix (remix.ethereum.org)
2. Set compiler to `0.8.20` — do NOT use 0.8.24+
3. In Advanced Compiler Settings, set EVM version to `shanghai`
4. Import the `.sol` files from this repo
5. Compile — the GitHub URLs will resolve the OZ v4.9.6 dependencies automatically
6. Deploy via Injected Provider (MetaMask on PulseChain)

**Deploy order:**
1. `SunPLS_Token_v2.sol` — deploys with 1B seed supply to deployer
2. Create PulseX SunPLS/WPLS pair and seed with initial liquidity (1:1 ratio)
3. `SunPLS_Oracle.sol` — takes pair address, WPLS address, SunPLS address
4. `SunPLS_Controller.sol` — takes oracle address, initialR, epochDuration, k, alpha
5. `SunPLS_Vault_v2.sol` — takes WPLS, SunPLS, oracle, controller, debtCeiling
6. Call `token.setVault(vaultAddress)` — one-time, permanent
7. Call `controller.setVault(vaultAddress)` — one-time, permanent

---

## Security Model

**No admin keys.** There are no `onlyOwner` functions in V2 (beyond the one-time `setVault()` latch which becomes inaccessible after being called). No timelock is needed because there is nothing to govern.

**No upgradeability.** The contracts cannot be modified after deployment. There are no proxy patterns, no beacon patterns, no delegate calls.

**No oracle manipulation surface.** The oracle uses a time-weighted average price from the PulseX AMM — a single-block price manipulation cannot influence vault operations.

**Immutable rate engine.** The Controller's parameters (k, alpha, DELTA_R_MAX, R_FLOOR) are set at deploy time and cannot be changed. The rate engine runs autonomously and deterministically.

**Trust-minimized token.** The vault can only burn SunPLS that it holds in its own balance. It cannot drain user wallets even if compromised — users must explicitly approve the vault before any token transfer.

**What the contracts cannot do:**
- Mint SunPLS to arbitrary addresses (only vault can mint, only to the depositor)
- Pause or freeze the protocol
- Change liquidation parameters or collateral requirements
- Rug or withdraw protocol funds (there are no protocol-owned funds)

---

## Frontend Files

The `/` directory contains the complete self-contained frontend. No build step required — open directly in a browser or serve statically.

| File | Purpose |
|------|---------|
| `index.html` | Main vault management UI — deposit, mint, repay, withdraw, monitor |
| `liquidations.html` | Vault dashboard — scan all vaults, liquidate, redeem, inspect |
| `sunpls-vault-v2-abi.json` | Vault contract ABI (v2 — 11-return vaultInfo, surplus buffer, bad debt) |
| `sunpls-token-v2-abi.json` | Token ABI (ERC20 + ERC20Permit) |
| `sunpls-oracle-abi.json` | Oracle ABI |
| `sunpls-controller-abi.json` | Controller ABI |
| `ethers.umd.min.js` | ethers.js v6 (bundled, no CDN dependency) |
| `sunplslogo.png` | Protocol logo |

**GitHub Pages deployment:**
Push this folder to a GitHub repo and enable GitHub Pages (Settings → Pages → Deploy from branch → root). The `index.html` at the root will be served automatically.

---

*SunPLS is experimental software. Use at your own risk. No audits have been performed. This is not financial advice.*
