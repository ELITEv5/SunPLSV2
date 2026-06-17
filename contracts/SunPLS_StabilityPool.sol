// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║       SunPLS Stability Pool — ELITE TEAM6                           ║
 * ║       Autonomous Liquidation Backstop — ProjectUSD Architecture     ║
 * ║                                                                      ║
 * ║  PURPOSE                                                             ║
 * ║  ──────                                                              ║
 * ║  Pre-funded liquidation backstop for the SunPLS v2 vault.           ║
 * ║  Depositors lock SunPLS to earn PLS liquidation rewards.            ║
 * ║  Anyone can trigger a liquidation using pooled SunPLS.              ║
 * ║  Rewards are distributed proportionally to all depositors.          ║
 * ║                                                                      ║
 * ║  WHY THIS WORKS WITH V2 AND NOT V1                                  ║
 * ║  ─────────────────────────────────                                  ║
 * ║  V1 vault used .transfer() (2300 gas stipend). Any smart contract   ║
 * ║  receiving PLS from a liquidation would revert if its receive()     ║
 * ║  did anything beyond accepting ETH.                                 ║
 * ║  V2 vault uses .call{value}() — no gas limit. This contract        ║
 * ║  receives PLS cleanly mid-liquidation and accounts for it after.    ║
 * ║                                                                      ║
 * ║  SHARE ACCOUNTING                                                    ║
 * ║  ────────────────                                                    ║
 * ║  Virtual shares represent proportional ownership of pooled SunPLS.  ║
 * ║  When the pool liquidates a vault, SunPLS is burned and PLS         ║
 * ║  arrives. totalSunPLS decreases; totalShares stays the same.        ║
 * ║  Each share is now backed by less SunPLS but has earned PLS.        ║
 * ║                                                                      ║
 * ║  PLS rewards use the MasterChef accumulator pattern:                ║
 * ║    accRewardPerShare += (plsReceived × PRECISION) / totalShares     ║
 * ║  Each user's pending PLS = shares × accRewardPerShare − rewardDebt  ║
 * ║                                                                      ║
 * ║  LIQUIDATION FLOW                                                    ║
 * ║  ─────────────────                                                   ║
 * ║  1. Caller invokes pool.liquidate(target, amount)                   ║
 * ║  2. Pool approves vault for SunPLS amount                           ║
 * ║  3. Pool calls vault.liquidate(target, amount)                      ║
 * ║  4. Vault pulls SunPLS from pool via transferFrom, burns it         ║
 * ║  5. Vault sends PLS to pool via .call{value}() → receive()          ║
 * ║  6. vault.liquidate() returns                                       ║
 * ║  7. Pool measures balance delta, updates accRewardPerShare          ║
 * ║  8. Depositors can claim PLS at any time                            ║
 * ║                                                                      ║
 * ║  NO ADMIN KEYS — ownerless — immutable after deploy                  ║
 * ║                                                                      ║
 * ║  Deploy args: sunpls (token), vault (v2 vault address)              ║
 * ║                                                                      ║
 * ║  Dev:     ELITE TEAM6                                               ║
 * ║  Website: https://www.sundaitoken.com                               ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/security/ReentrancyGuard.sol";

// ── INTERFACES ────────────────────────────────────────────────────────────────

interface ISunPLSVault {
    function liquidate(address user, uint256 repayAmount) external;
    function liquidationInfo(address user) external view returns (
        uint256 debt,
        uint256 minRepay,
        uint256 reward,
        uint256 bonusBps
    );
    function vaultInfo(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 collateralValueInSunPLS,
        uint256 ratio,
        uint256 mintable,
        int256  rate,
        uint256 redemptionVal,
        bool    liquidatable,
        bool    redeemable,
        bool    oracleHealthy,
        uint256 systemRatio
    );
}

// ── CONTRACT ─────────────────────────────────────────────────────────────────

contract SunPLSStabilityPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── PRECISION ─────────────────────────────────────────────────────────
    uint256 private constant PRECISION = 1e18;

    // Fraction of PLS reward paid to the address that triggers a liquidation.
    // 50 bps = 0.5%. Incentivizes keeper bots without meaningfully reducing
    // depositor yield — vault bonus is 2–7% so caller always nets above gas.
    uint256 public constant CALLER_TIP_BPS = 50;

    // ── IMMUTABLES ────────────────────────────────────────────────────────
    IERC20          public immutable sunpls;
    ISunPLSVault    public immutable vault;

    // ── GLOBAL STATE ──────────────────────────────────────────────────────

    // Total SunPLS the pool tracks as deposited/remaining (decreases on liquidation)
    uint256 public totalSunPLS;

    // Virtual shares — each depositor's proportional claim on totalSunPLS
    // Shares stay constant through liquidations; SunPLS-per-share shrinks instead
    uint256 public totalShares;

    // Cumulative PLS earned per virtual share (scaled by PRECISION)
    // Monotonically increases each time a liquidation brings PLS in
    uint256 public accRewardPerShare;

    // ── LIFETIME STATS ────────────────────────────────────────────────────
    uint256 public totalPLSDistributed;
    uint256 public totalSunPLSLiquidated;
    uint256 public totalLiquidationCount;

    // ── PER-USER STATE ────────────────────────────────────────────────────
    struct UserInfo {
        uint256 shares;       // virtual shares held
        uint256 rewardDebt;   // accRewardPerShare × shares at last snapshot
        uint256 pendingPLS;   // settled-but-unclaimed PLS rewards
    }
    mapping(address => UserInfo) public users;

    // ── EVENTS ────────────────────────────────────────────────────────────
    event Deposited(
        address indexed user,
        uint256 sunplsAmount,
        uint256 sharesIssued,
        uint256 newTotalShares
    );
    event Withdrawn(
        address indexed user,
        uint256 sunplsReturned,
        uint256 sharesBurned,
        uint256 plsClaimed
    );
    event RewardsClaimed(
        address indexed user,
        uint256 plsAmount
    );
    event PoolLiquidated(
        address indexed triggeredBy,
        address indexed targetVault,
        uint256 sunplsUsed,
        uint256 plsReceived,
        uint256 bonusBps
    );

    // ── CONSTRUCTOR ───────────────────────────────────────────────────────
    constructor(address _sunpls, address _vault) {
        require(_sunpls != address(0) && _vault != address(0), "Zero address");
        sunpls = IERC20(_sunpls);
        vault  = ISunPLSVault(_vault);
    }

    // ── RECEIVE ───────────────────────────────────────────────────────────
    // PLS arrives here from the vault mid-liquidation via .call{value}().
    // Restricted to the vault only — random PLS sent directly to this address
    // would be unrecoverable (no admin, no sweep function) and would silently
    // inflate address(this).balance without entering accRewardPerShare.
    receive() external payable {
        require(msg.sender == address(vault), "SP: only vault");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  USER ACTIONS
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit SunPLS into the stability pool.
     *         Receives virtual shares proportional to current pool size.
     *         Deposits made after liquidations receive proportionally fewer
     *         shares but start fresh on future PLS rewards.
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "SP: zero amount");
        _settleRewards(msg.sender);

        // Mint shares — first depositor gets 1:1, subsequent depositors
        // get shares proportional to their contribution vs current pool
        uint256 sharesToMint;
        if (totalShares == 0 || totalSunPLS == 0) {
            // Bootstrap: first deposit or pool was fully drained by liquidations
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares) / totalSunPLS;
        }
        require(sharesToMint > 0, "SP: shares underflow");

        sunpls.safeTransferFrom(msg.sender, address(this), amount);

        totalSunPLS += amount;
        totalShares += sharesToMint;

        UserInfo storage u = users[msg.sender];
        u.shares    += sharesToMint;
        u.rewardDebt = (u.shares * accRewardPerShare) / PRECISION;

        emit Deposited(msg.sender, amount, sharesToMint, totalShares);
    }

    /**
     * @notice Withdraw a specific number of shares.
     *         Returns proportional SunPLS plus all pending PLS rewards.
     *         If pool SunPLS was fully consumed by liquidations, sunplsReturned
     *         will be zero — PLS rewards are still claimable.
     */
    function withdraw(uint256 shareAmount) external nonReentrant {
        UserInfo storage u = users[msg.sender];
        require(shareAmount > 0,              "SP: zero shares");
        require(shareAmount <= u.shares,      "SP: exceeds balance");

        _settleRewards(msg.sender);

        // Proportional SunPLS — rounds down (dust stays in pool)
        uint256 sunplsOut = totalShares > 0
            ? (shareAmount * totalSunPLS) / totalShares
            : 0;

        u.shares    -= shareAmount;
        totalShares -= shareAmount;
        if (sunplsOut > 0) totalSunPLS -= sunplsOut;

        // Recompute debt for remaining shares
        u.rewardDebt = (u.shares * accRewardPerShare) / PRECISION;

        if (sunplsOut > 0) sunpls.safeTransfer(msg.sender, sunplsOut);

        uint256 plsClaim = u.pendingPLS;
        if (plsClaim > 0) {
            u.pendingPLS = 0;
            _sendPLS(msg.sender, plsClaim);
        }

        emit Withdrawn(msg.sender, sunplsOut, shareAmount, plsClaim);
    }

    /**
     * @notice Withdraw all shares — full exit in one call.
     */
    function withdrawAll() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        require(u.shares > 0, "SP: nothing deposited");

        _settleRewards(msg.sender);

        uint256 shareAmount = u.shares;
        uint256 sunplsOut   = totalShares > 0
            ? (shareAmount * totalSunPLS) / totalShares
            : 0;

        u.shares     = 0;
        u.rewardDebt = 0;
        totalShares -= shareAmount;
        if (sunplsOut > 0) totalSunPLS -= sunplsOut;

        if (sunplsOut > 0) sunpls.safeTransfer(msg.sender, sunplsOut);

        uint256 plsClaim = u.pendingPLS;
        if (plsClaim > 0) {
            u.pendingPLS = 0;
            _sendPLS(msg.sender, plsClaim);
        }

        emit Withdrawn(msg.sender, sunplsOut, shareAmount, plsClaim);
    }

    /**
     * @notice Claim all pending PLS rewards without withdrawing SunPLS.
     */
    function claimRewards() external nonReentrant {
        _settleRewards(msg.sender);
        UserInfo storage u = users[msg.sender];
        uint256 pending = u.pendingPLS;
        require(pending > 0, "SP: nothing to claim");
        u.pendingPLS = 0;
        _sendPLS(msg.sender, pending);
        emit RewardsClaimed(msg.sender, pending);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  LIQUIDATION ACTIONS  (permissionless — anyone can trigger)
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @notice Use pooled SunPLS to liquidate a specific vault.
     *         sunplsAmount must be ≥ vault's minRepay (5% of debt).
     *         PLS reward is distributed to all current depositors.
     *         Caller receives CALLER_TIP_BPS (0.5%) of PLS reward for keeper liveness.
     *
     * @param target       Vault owner address to liquidate
     * @param sunplsAmount SunPLS to repay (≥ minRepay, ≤ vault debt)
     */
    function liquidate(address target, uint256 sunplsAmount) external nonReentrant {
        require(sunplsAmount > 0,                                "SP: zero amount");
        require(totalSunPLS >= sunplsAmount,                     "SP: insufficient pool");
        require(sunpls.balanceOf(address(this)) >= sunplsAmount, "SP: balance mismatch");

        // Read before liquidation — vault state changes after, bonusBps would read zero
        (, , , uint256 bonusBps) = vault.liquidationInfo(target);

        uint256 plsBefore    = address(this).balance;
        uint256 sunplsBefore = sunpls.balanceOf(address(this));

        // Approve exact amount — reset to zero after (defense in depth)
        sunpls.approve(address(vault), sunplsAmount);
        vault.liquidate(target, sunplsAmount);
        // PLS has arrived via receive() by the time this line executes
        sunpls.approve(address(vault), 0);

        uint256 sunplsBurned = sunplsBefore - sunpls.balanceOf(address(this));
        uint256 plsReceived  = address(this).balance - plsBefore;

        require(sunplsBurned > 0, "SP: no SunPLS burned");
        require(plsReceived  > 0, "SP: no PLS received");

        totalSunPLS -= sunplsBurned;

        // Caller tip — incentivizes keeper bots to trigger liquidations promptly
        uint256 callerTip = (plsReceived * CALLER_TIP_BPS) / 10_000;
        uint256 toPool    = plsReceived - callerTip;

        if (callerTip > 0) _sendPLS(msg.sender, callerTip);
        _distributeReward(toPool);

        totalPLSDistributed   += plsReceived;
        totalSunPLSLiquidated += sunplsBurned;
        totalLiquidationCount += 1;

        emit PoolLiquidated(msg.sender, target, sunplsBurned, plsReceived, bonusBps);
    }

    /**
     * @notice Liquidate as much of a vault as the pool can cover.
     *         Caps at: min(pool SunPLS balance, vault total debt).
     *         Will revert if pool has less than vault's minimum repay (5%).
     *
     * @param target Vault owner address to liquidate
     */
    function liquidateMax(address target) external nonReentrant {
        // Read before liquidation for accurate bonusBps in event
        (uint256 debt, uint256 minRepay, , uint256 bonusBps) = vault.liquidationInfo(target);
        require(debt > 0, "SP: vault not liquidatable");

        uint256 poolBalance  = sunpls.balanceOf(address(this));
        uint256 usable       = totalSunPLS < poolBalance ? totalSunPLS : poolBalance;
        // Cap at vault debt — no point sending more than needed
        uint256 sunplsAmount = usable < debt ? usable : debt;

        require(sunplsAmount >= minRepay, "SP: pool below min repay");

        uint256 plsBefore    = address(this).balance;
        uint256 sunplsBefore = sunpls.balanceOf(address(this));

        sunpls.approve(address(vault), sunplsAmount);
        vault.liquidate(target, sunplsAmount);
        sunpls.approve(address(vault), 0);

        uint256 sunplsBurned = sunplsBefore - sunpls.balanceOf(address(this));
        uint256 plsReceived  = address(this).balance - plsBefore;

        require(sunplsBurned > 0, "SP: no SunPLS burned");
        require(plsReceived  > 0, "SP: no PLS received");

        totalSunPLS -= sunplsBurned;

        // Caller tip — incentivizes keeper bots to trigger liquidations promptly
        uint256 callerTip = (plsReceived * CALLER_TIP_BPS) / 10_000;
        uint256 toPool    = plsReceived - callerTip;

        if (callerTip > 0) _sendPLS(msg.sender, callerTip);
        _distributeReward(toPool);

        totalPLSDistributed   += plsReceived;
        totalSunPLSLiquidated += sunplsBurned;
        totalLiquidationCount += 1;

        emit PoolLiquidated(msg.sender, target, sunplsBurned, plsReceived, bonusBps);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @notice PLS rewards claimable by a user right now.
     */
    function pendingRewards(address user) external view returns (uint256) {
        UserInfo storage u = users[user];
        if (u.shares == 0) return u.pendingPLS;
        uint256 accumulated = (u.shares * accRewardPerShare) / PRECISION;
        uint256 earned      = accumulated > u.rewardDebt ? accumulated - u.rewardDebt : 0;
        return u.pendingPLS + earned;
    }

    /**
     * @notice Current SunPLS balance attributable to a user's shares.
     *         Decreases over time as the pool participates in liquidations.
     */
    function userSunPLS(address user) external view returns (uint256) {
        UserInfo storage u = users[user];
        if (totalShares == 0 || u.shares == 0) return 0;
        return (u.shares * totalSunPLS) / totalShares;
    }

    /**
     * @notice SunPLS backing per share (1e18 = 1:1 with SunPLS).
     *         Starts at 1e18 for first depositor, decreases as liquidations consume SunPLS.
     */
    function shareValue() external view returns (uint256) {
        if (totalShares == 0) return PRECISION;
        return (totalSunPLS * PRECISION) / totalShares;
    }

    /**
     * @notice Whether the pool can participate in a liquidation of target.
     *         Returns (canLiquidate, maxUsable, minRequired).
     */
    function liquidationCapacity(address target) external view returns (
        bool   canLiquidate,
        uint256 maxUsable,
        uint256 minRequired
    ) {
        (, uint256 minRepay,,) = vault.liquidationInfo(target);
        (,,,,,,,bool liquidatable,,,) = vault.vaultInfo(target);
        uint256 usable = totalSunPLS < sunpls.balanceOf(address(this))
            ? totalSunPLS
            : sunpls.balanceOf(address(this));
        canLiquidate = liquidatable && usable >= minRepay;
        maxUsable    = usable;
        minRequired  = minRepay;
    }

    /**
     * @notice Full pool snapshot for dashboards and frontends.
     */
    function poolStats() external view returns (
        uint256 _totalSunPLS,
        uint256 _totalShares,
        uint256 _shareValue,
        uint256 _accRewardPerShare,
        uint256 _plsBalance,
        uint256 _totalPLSDistributed,
        uint256 _totalSunPLSLiquidated,
        uint256 _totalLiquidationCount
    ) {
        _totalSunPLS            = totalSunPLS;
        _totalShares            = totalShares;
        _shareValue             = totalShares > 0 ? (totalSunPLS * PRECISION) / totalShares : PRECISION;
        _accRewardPerShare      = accRewardPerShare;
        _plsBalance             = address(this).balance;
        _totalPLSDistributed    = totalPLSDistributed;
        _totalSunPLSLiquidated  = totalSunPLSLiquidated;
        _totalLiquidationCount  = totalLiquidationCount;
    }

    /**
     * @notice Full user snapshot.
     */
    function userStats(address user) external view returns (
        uint256 shares,
        uint256 sunplsValue,
        uint256 pendingPLS,
        uint256 rewardDebt
    ) {
        UserInfo storage u = users[user];
        shares      = u.shares;
        sunplsValue = (totalShares > 0 && u.shares > 0)
            ? (u.shares * totalSunPLS) / totalShares
            : 0;
        // compute pending without mutating state
        uint256 accumulated = (u.shares * accRewardPerShare) / PRECISION;
        uint256 earned      = accumulated > u.rewardDebt ? accumulated - u.rewardDebt : 0;
        pendingPLS  = u.pendingPLS + earned;
        rewardDebt  = u.rewardDebt;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═════════════════════════════════════════════════════════════════════

    /**
     * @dev Settle any unsettled PLS rewards into u.pendingPLS and
     *      update u.rewardDebt to the current accumulator value.
     *      Must be called before any action that changes u.shares.
     */
    function _settleRewards(address user) internal {
        UserInfo storage u = users[user];
        if (u.shares > 0) {
            uint256 accumulated = (u.shares * accRewardPerShare) / PRECISION;
            uint256 earned      = accumulated > u.rewardDebt ? accumulated - u.rewardDebt : 0;
            u.pendingPLS  += earned;
            u.rewardDebt   = accumulated;
        }
    }

    /**
     * @dev Add a PLS reward to the accumulator.
     *      If no shares exist (pool empty), the PLS stays in the contract
     *      and will be swept into the accumulator on the next deposit.
     *      This edge case should never occur in normal operation.
     */
    function _distributeReward(uint256 plsAmount) internal {
        if (totalShares == 0 || plsAmount == 0) return;
        accRewardPerShare += (plsAmount * PRECISION) / totalShares;
    }

    /**
     * @dev Send PLS to an address. Reverts on failure.
     *      Works with both EOAs and smart contracts (no gas limit via .call).
     */
    function _sendPLS(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "SP: PLS transfer failed");
    }
}
