# SunPLS — A Native Floating Monetary Asset for PulseChain

---

## The Core Idea

Every financial system eventually needs a unit of account — something to price things in.

Most DeFi protocols use USD-pegged stablecoins for this. That works, but it means the entire system is denominated in a unit controlled by the US Federal Reserve. Borrow against your crypto, pay fees in USD, measure your gains in USD. The native chain asset (ETH, PLS) is the fuel, but USD is the measuring stick.

**SunPLS proposes a different measuring stick.**

SunPLS is a WPLS-collateralized asset that doesn't peg to any external currency. Instead, it has a floating redemption price — called **R** — that acts as an internal reference rate. R is set by the market and adjusted slowly by a controller based on supply and demand signals. The system's goal isn't to make 1 SunPLS = $1. The goal is for SunPLS to become its own stable monetary unit, denominated in PLS — native to PulseChain, not tethered to the outside world.

---

## Why This Matters: The Problem with USD Pegs

USD-pegged stablecoins (DAI, USDC, etc.) are useful, but they carry fundamental assumptions:

- **External dependency.** The peg is only as good as the mechanism maintaining it — arbitrage bots, Maker governance, Circle's bank accounts. Remove those and the peg breaks.
- **Dollar debasement.** If you're holding a USD stablecoin over years and the dollar inflates 30%, your "stable" coin lost 30% of purchasing power.
- **Regulatory exposure.** Any USD-pegged asset can be frozen, blacklisted, or depegged through regulatory pressure on the peg mechanism.

A floating, native, protocol-issued monetary asset sidesteps all of this. It doesn't try to be a dollar. It tries to be **its own thing** — something the PulseChain ecosystem prices goods and services in over time.

This is the original vision of money: a medium of exchange that a community agrees to use, with its value emerging from that agreement rather than being imposed by an external authority.

---

## What RAI Proved — And Where It Fell Short

**RAI** (Reflexer Finance, Ethereum) was the first serious attempt at this. It launched in 2021 as ETH-backed, non-pegged, and governance-minimized. The thesis was right: create an asset that floats freely against the dollar, priced by the market, with on-chain monetary policy controlling the rate of change.

RAI proved the concept works. But it had three design flaws that limited its adoption:

### Flaw 1 — R Chased the Market Instead of the Market Chasing R

RAI's proportional-integral controller was tuned aggressively. When the market price of RAI diverged from R, the controller moved R toward the market quickly. This meant R was always chasing where the market already was — providing almost no stability signal.

The point of R is to be an **anchor** the market orients around. If R moves as fast as the market, it's not an anchor. RAI's controller essentially turned the monetary policy into a tracking algorithm rather than a reference rate.

**SunPLS fix:** ALPHA is tuned 10× smaller. R moves slowly and deliberately. The market is expected to chase R, not the other way around. This is what creates the monetary premium — the sense that R represents something real and stable, not just a lagging average of recent prices.

### Flaw 2 — Negative Interest Rates

When the market price of RAI was above R (meaning demand was too high), RAI's controller could set negative interest rates — meaning borrowers were actually *paid* to borrow. This attracted mercenary capital: bots and traders who borrowed RAI purely to capture the rate subsidy, then exited the moment rates normalized. It created volatility rather than stability.

Beyond the mechanics, negative rates are psychologically confusing. "You're paying me to borrow?" undermines confidence in the system.

**SunPLS fix:** `MIN_RATE = 0`. Interest rates are always zero or positive. At worst, borrowing is free. There is no subsidy for borrowing — only a cost for excessive borrowing when R needs to contract. This is intuitive and removes the mercenary dynamic entirely.

### Flaw 3 — Holding RAI Earned Nothing

RAI holders had no yield mechanism. You could hold RAI if you believed in the vision, but there was no protocol-native reason to hold it over time. Liquidity was thin, and without a structural reason for demand, the monetary premium never developed.

**SunPLS fix:** The **Stability Pool** creates a structural demand for holding SunPLS. Deposit SunPLS into the pool and earn WPLS from liquidation proceeds and stability fees. This means: the more the protocol is used, the more value flows to SunPLS holders. Holding SunPLS becomes productive.

---

## SunPLS vs RAI — Technical Comparison

| Dimension | RAI (Reflexer) | SunPLS |
|---|---|---|
| Collateral | ETH | WPLS (native PulseChain) |
| Peg target | None (floating) | None (floating) |
| Controller gain (ALPHA) | High — R chases market | 10× lower — market chases R |
| Minimum interest rate | Negative (paid to borrow) | Zero — never subsidized |
| Maximum rate | ~20% | 30% |
| Max R move per epoch | ~10% | 1% (sticky) |
| Epoch duration | Variable | 30 minutes |
| Yield for holders | None | Stability Pool (WPLS yield) |
| Liquidation mechanism | Dutch auction | Pool-first, auction fallback |
| Governance token | FLX (later minimized) | None — ever |
| Admin keys | Initially present | None from day 1 |
| Debt ceiling | Fixed in governance | Time-based, immutable schedule |

---

## How SunPLS Actually Works

### Opening a Vault

A user deposits WPLS as collateral and mints SunPLS against it at a minimum 150% collateral ratio. If WPLS is worth 1,000 PLS, they can mint up to ~666 SunPLS. The minted SunPLS enters circulation.

### R — The Redemption Price

R is the price at which SunPLS can always be redeemed for WPLS. It starts at roughly the market price of SunPLS at launch and drifts slowly based on the controller's assessment of supply and demand.

- If SunPLS trades **above R** — demand is high, the controller slowly raises the interest rate, which incentivizes borrowers to repay (reducing supply) and arbitrageurs to redeem SunPLS for WPLS at R (hard floor).
- If SunPLS trades **below R** — demand is low, the controller lowers the interest rate toward zero, making borrowing cheaper and encouraging new vaults to open (increasing supply pressure in the opposite direction).

Over time, if R functions as intended, the market price of SunPLS stays close to R not because of a peg mechanism, but because R represents the redemption guarantee — you can always get R worth of WPLS for 1 SunPLS.

### The Hard Price Floor

Any SunPLS holder can redeem directly against the protocol at R, taking WPLS from the most distressed vaults (CR ≤ 130%). This creates an absolute price floor: no rational actor should sell SunPLS for less than R if they can redeem at R. This is the mechanism that makes R meaningful — not just an oracle number, but an actual guarantee.

### Liquidations — Pool First

When a vault's collateral ratio drops below 110%, it becomes liquidatable. SunPLS uses a two-path system:

1. **Stability Pool (primary):** If the pool has enough SunPLS, the vault is instantly cleared. Pool depositors absorb the debt and receive the collateral (WPLS) at a discount — typically better than market. This is fast, clean, and penalizes nobody.

2. **Dutch Auction (fallback):** If the pool is empty or insufficient, a Dutch auction begins. The liquidation bonus starts at 7% and decays to 2% over 3 hours. First mover wins — any SunPLS holder can participate.

The pool-first design means liquidations are usually instant, which keeps the protocol solvent during fast market moves.

### The Stability Pool — Structural SunPLS Demand

Depositing SunPLS into the Stability Pool is the core yield mechanism. Depositors earn:
- **WPLS from liquidations** — when a vault is liquidated, depositors absorb the debt at a discount (they burn SunPLS worth less WPLS than they receive)
- **Stability fees** — the interest paid by borrowers flows to the pool as WPLS

This creates a flywheel: more borrowing → more fees → better yield for pool depositors → more demand to hold SunPLS → R holds its value → borrowers pay appropriate rates → more borrowing.

---

## Why PulseChain Specifically

PulseChain has several properties that make SunPLS a natural fit:

**WPLS is the native collateral.** PulseChain's native asset is PLS, a high-velocity, liquid token. Using it as collateral for a native monetary asset creates a tight coupling between the chain's growth and the monetary asset's utility. As PulseChain grows, WPLS gains value, vaults become healthier, and the protocol strengthens.

**No existing native floating asset.** PulseChain has USD-pegged stablecoins (DAI bridged copies, USDC), but nothing denominated in PLS-native terms. SunPLS fills that gap.

**Community alignment.** PulseChain was built around the thesis that native assets should capture value. SunPLS extends that thesis to money itself — a monetary asset native to PulseChain, priced in PulseChain terms, governed by no one.

---

## The Immutability Guarantee

SunPLS is deployed with zero admin keys, zero pause functions, zero upgrade paths.

The debt ceiling is not set by governance — it follows a two-stage schedule burned into the contract bytecode at deploy:

```
0–30 days:  100,000,000,000 SunPLS (100B — 30-day bug-catching window)
30 days +:  unlimited (type(uint256).max)
```

After the bootstrap window, the 150% collateral ratio requirement is the only practical limit. The protocol can grow without restriction.

No multisig. No DAO. No team wallet. The contracts will run exactly as deployed for as long as PulseChain runs.

This is a deliberate design choice. The strongest monetary assets in history derive their value partly from the impossibility of arbitrary change. Gold can't be inflated. Bitcoin's supply schedule can't be altered. SunPLS's rules can't be changed. That property is rare and valuable.

---

## Deployed Contracts (PulseChain Mainnet)

| Contract | Address |
|---|---|
| SunPLS Token | `0x5d29509551378B55E0e79e3e9a7f610aC1f281D5` |
| Vault | `0xfbBd23B115FE4540e07A2d57004D0503Bb37B29e` |
| Oracle | `0xC74b5d405276FF87Ad798acCF104c6E727cfe66b` |
| Controller | `0x6828BD8c3eF04aA927374a45b4796A3cb6C54945` |
| Stability Pool | `0xeec42299EC0564A1804e8D7De87bE9463bf151B2` |
| PulseX Pair (SunPLS/WPLS) | `0x4803EB64649d6647900149D6e60E3b45B13561E1` |

All contracts verified on Sourcify (exact_match).

---

## The Honest Risk Disclosure

SunPLS is experimental. The honest risks are:

- **Thin liquidity early on.** If the SunPLS/WPLS market is thin, R may not function as an effective anchor. The monetary premium develops over time with adoption.
- **Oracle dependency.** SunPLS uses a TWAP oracle from the PulseX pair. The oracle is only as good as the pair's liquidity. Thin markets can be manipulated.
- **The R mechanism is novel.** RAI's history shows the theory works, but adoption is hard. SunPLS may follow the same path — technically sound but lacking the network effect to become a genuine unit of account.
- **No backstop.** There's no protocol treasury, no team, no DAO to step in if things go wrong. The system either works on its own terms or it doesn't.

These risks are real. SunPLS is not a finished product — it's an experiment in building money from first principles on a new chain.

---

## Summary

SunPLS is an attempt to answer a simple question: *can PulseChain have its own money?*

Not a dollar proxy. Not a wrapped external asset. A monetary unit that emerges from the economic activity of the chain itself, anchored by a redemption guarantee, with its value determined by the community that uses it.

RAI showed it's possible. SunPLS takes that proof-of-concept and improves the three things that held RAI back: a stickier R that actually anchors, no negative rates that attract mercenaries, and a yield mechanism that rewards long-term holders.

Whether it succeeds depends on adoption. But the foundation is sound, the rules are immutable, and the experiment is live.
