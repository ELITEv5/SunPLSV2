// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║        SunPLS RAI — Stability Pool v1.1                              ║
 * ║        Share-Based Accounting (Codex audit fixes applied)            ║
 * ║                                                                      ║
 * ║   v1.0 BUGS FIXED IN THIS VERSION                                   ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   CRITICAL: v1.0 reduced `totalDeposits` on absorb but left         ║
 * ║   individual `deposits[user]` unchanged. Early withdrawers could    ║
 * ║   drain their full original balance; later users got nothing.       ║
 * ║   Fix: share-based accounting. Each deposit mints shares. Absorbing ║
 * ║   SunPLS reduces the per-share SunPLS value proportionally for all  ║
 * ║   depositors simultaneously. No user can withdraw more than their   ║
 * ║   fair share.                                                        ║
 * ║                                                                      ║
 * ║   CRITICAL: v1.0 called sunpls.burn() which is vault-only.          ║
 * ║   Fix: SunPLS_Token_RAI.setPool() now authorises the pool to burn.  ║
 * ║                                                                      ║
 * ║   HOW SHARE ACCOUNTING WORKS                                         ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   On deposit:                                                        ║
 * ║     shares_minted = amount * totalShares / totalDeposits            ║
 * ║     (or 1:1 if pool is empty)                                        ║
 * ║   On absorb (liquidation):                                           ║
 * ║     totalDeposits -= debtBurned       (SunPLS shrinks)              ║
 * ║     totalShares   unchanged           (shares don't change)          ║
 * ║     → each share is worth less SunPLS (proportional loss)            ║
 * ║     → each share earns WPLS reward   (proportional gain)             ║
 * ║   On withdraw:                                                       ║
 * ║     sunpls_out = userShares * totalDeposits / totalShares           ║
 * ║     → user gets their proportional SunPLS after all absorptions     ║
 * ║                                                                      ║
 * ║   WPLS REWARD ACCOUNTING                                             ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   Uses reward-per-share (Synthetix pattern) not reward-per-token,   ║
 * ║   because shares don't change during absorb events. This gives      ║
 * ║   correct reward tracking regardless of when liquidations occur.    ║
 * ║                                                                      ║
 * ║     accWplsPerShare: cumulative WPLS per share (1e18 scale)         ║
 * ║     userShareDebt[u]: accWplsPerShare at last user interaction      ║
 * ║     pendingWpls[u]: claimable WPLS frozen at last interaction       ║
 * ║                                                                      ║
 * ║   DEPLOYMENT NOTE                                                    ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   Token.setPool(pool) must be called in addition to existing latches ║
 * ║   so that absorb() can call sunpls.burn().                           ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface ISunPLSToken {
    function burn(uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SunPLSStabilityPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────

    ISunPLSToken public immutable sunpls;
    address public immutable wpls;
    address private immutable deployer;

    // ─────────────────────────────────────────────────────────────────────
    // Vault latch — only vault can call absorb() and receiveFees()
    // ─────────────────────────────────────────────────────────────────────

    address public vault;
    bool public vaultSet;

    // ─────────────────────────────────────────────────────────────────────
    // Share accounting
    //
    // totalDeposits: actual SunPLS held in the contract
    //   - increases on deposit
    //   - decreases on absorb (liquidation burn) and withdraw
    //
    // totalShares: virtual share count
    //   - increases on deposit
    //   - decreases on withdraw
    //   - UNCHANGED on absorb — this is the key: after absorb,
    //     each share represents less SunPLS (proportional loss for all)
    //
    // shares[user]: user's share count
    //   - SunPLS withdrawable = shares[user] * totalDeposits / totalShares
    // ─────────────────────────────────────────────────────────────────────

    uint256 public totalShares;
    uint256 public totalDeposits;
    mapping(address => uint256) public shares;

    // ─────────────────────────────────────────────────────────────────────
    // WPLS reward accounting (reward-per-share, Synthetix pattern)
    //
    // Tracks WPLS per SHARE (not per SunPLS) because shares don't change
    // during absorb events, making the accumulator monotonically increasing.
    // ─────────────────────────────────────────────────────────────────────

    uint256 private constant PRECISION = 1e18;

    uint256 public accWplsPerShare;
    mapping(address => uint256) private userShareDebt;
    mapping(address => uint256) private pendingWpls;

    // WPLS received while pool had zero depositors — queued and distributed
    // to the first depositor. Prevents fee WPLS from becoming permanently stuck.
    uint256 public undistributedWPLS;

    // ─────────────────────────────────────────────────────────────────────
    // Lifetime stats
    // ─────────────────────────────────────────────────────────────────────

    uint256 public totalSunPLSAbsorbed;
    uint256 public totalWPLSFromLiquid;
    uint256 public totalWPLSFromFees;
    uint256 public liquidationCount;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event VaultSet(address indexed vault);

    event Deposited(
        address indexed user, uint256 sunplsAmount, uint256 sharesMinted, uint256 newTotalShares
    );
    event Withdrawn(
        address indexed user, uint256 sunplsAmount, uint256 sharesBurned, uint256 newTotalShares
    );
    event WPLSClaimed(address indexed user, uint256 amount);

    event LiquidationAbsorbed(
        address indexed liquidatedVault,
        uint256 sunplsBurned,
        uint256 wplsReceived,
        uint256 newAccWplsPerShare
    );

    event FeesReceived(uint256 wplsAmount, uint256 newAccWplsPerShare);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address _sunpls, address _wpls) {
        require(_sunpls != address(0), "Zero sunpls");
        require(_wpls != address(0), "Zero wpls");
        sunpls = ISunPLSToken(_sunpls);
        wpls = _wpls;
        deployer = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Vault latch
    // ─────────────────────────────────────────────────────────────────────

    function setVault(address _vault) external {
        require(msg.sender == deployer, "Only deployer");
        require(!vaultSet, "Already set");
        require(_vault != address(0), "Zero address");
        vault = _vault;
        vaultSet = true;
        emit VaultSet(_vault);
    }

    modifier onlyVault() {
        require(vaultSet && msg.sender == vault, "Only vault");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Reward helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Compute and freeze pending WPLS for a user before any balance change.
    ///      Must be called at the start of deposit(), withdraw(), claimWPLS().
    function _settleUser(address user) internal {
        uint256 userShares = shares[user];
        if (userShares > 0) {
            uint256 delta = accWplsPerShare - userShareDebt[user];
            if (delta > 0) {
                pendingWpls[user] += Math.mulDiv(delta, userShares, PRECISION);
            }
        }
        userShareDebt[user] = accWplsPerShare;
    }

    /// @dev Distribute WPLS to all current shareholders by incrementing accWplsPerShare.
    ///      If no shares exist, queues WPLS in undistributedWPLS for the first depositor.
    function _distributeWPLS(uint256 wplsAmount) internal {
        if (wplsAmount == 0) return;
        if (totalShares == 0) {
            undistributedWPLS += wplsAmount;
            return;
        }
        accWplsPerShare += Math.mulDiv(wplsAmount, PRECISION, totalShares);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Depositor interface
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit SunPLS to earn WPLS yield from liquidations and fees.
     *         Mints shares proportional to your fraction of the pool.
     *
     * @param amount Amount of SunPLS to deposit.
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");

        _settleUser(msg.sender);

        IERC20(address(sunpls)).safeTransferFrom(msg.sender, address(this), amount);

        uint256 sharesToMint;
        if (totalShares == 0 || totalDeposits == 0) {
            // First depositor or after full drain: 1:1
            sharesToMint = amount;
        } else {
            // Shares proportional to current pool size
            // sharesToMint = amount * totalShares / totalDeposits
            sharesToMint = Math.mulDiv(amount, totalShares, totalDeposits);
        }
        require(sharesToMint > 0, "Zero shares - dust deposit");

        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        totalDeposits += amount;

        // Flush any WPLS that arrived while the pool had no depositors.
        // Done after shares are minted (and after _settleUser snapshotted userShareDebt),
        // so the first depositor correctly earns the queued rewards through their new shares.
        if (undistributedWPLS > 0) {
            accWplsPerShare += Math.mulDiv(undistributedWPLS, PRECISION, totalShares);
            undistributedWPLS = 0;
        }

        emit Deposited(msg.sender, amount, sharesToMint, totalShares);
    }

    /**
     * @notice Withdraw SunPLS proportional to share of pool.
     *         After liquidations, you receive less SunPLS than deposited
     *         (your share was used to cover debt), but you earned WPLS to compensate.
     *
     * @param sunplsAmount  Approximate SunPLS to withdraw.
     *                      Converted to shares internally; actual amount may
     *                      differ slightly due to rounding.
     */
    function withdraw(uint256 sunplsAmount) external nonReentrant {
        require(sunplsAmount > 0, "Zero amount");
        require(totalDeposits > 0 && totalShares > 0, "Empty pool");

        _settleUser(msg.sender);

        // Convert requested SunPLS to shares (round up to prevent dust attacks)
        uint256 sharesToBurn =
            Math.mulDiv(sunplsAmount, totalShares, totalDeposits, Math.Rounding.Up);
        require(shares[msg.sender] >= sharesToBurn, "Insufficient shares");

        // Actual SunPLS out is the precise share redemption value
        uint256 sunplsOut = Math.mulDiv(sharesToBurn, totalDeposits, totalShares);
        require(sunplsOut > 0, "Zero output");

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalDeposits -= sunplsOut;

        IERC20(address(sunpls)).safeTransfer(msg.sender, sunplsOut);
        emit Withdrawn(msg.sender, sunplsOut, sharesToBurn, totalShares);
    }

    /**
     * @notice Withdraw all SunPLS for caller's shares.
     */
    function withdrawAll() external nonReentrant {
        uint256 userShares = shares[msg.sender];
        require(userShares > 0, "No deposit");

        _settleUser(msg.sender);

        uint256 sunplsOut = Math.mulDiv(userShares, totalDeposits, totalShares);

        shares[msg.sender] = 0;
        totalShares -= userShares;
        totalDeposits -= sunplsOut;

        if (sunplsOut > 0) {
            IERC20(address(sunpls)).safeTransfer(msg.sender, sunplsOut);
        }
        emit Withdrawn(msg.sender, sunplsOut, userShares, totalShares);
    }

    /**
     * @notice Claim all pending WPLS earnings without withdrawing SunPLS.
     */
    function claimWPLS() external nonReentrant {
        _settleUser(msg.sender);
        uint256 amount = pendingWpls[msg.sender];
        require(amount > 0, "Nothing to claim");
        pendingWpls[msg.sender] = 0;
        IERC20(wpls).safeTransfer(msg.sender, amount);
        emit WPLSClaimed(msg.sender, amount);
    }

    /**
     * @notice Withdraw all SunPLS and claim all WPLS in one transaction.
     */
    function withdrawAllAndClaim() external nonReentrant {
        uint256 userShares = shares[msg.sender];

        _settleUser(msg.sender);

        uint256 sunplsOut = userShares > 0 && totalShares > 0
            ? Math.mulDiv(userShares, totalDeposits, totalShares)
            : 0;

        if (userShares > 0) {
            shares[msg.sender] = 0;
            totalShares -= userShares;
            totalDeposits -= sunplsOut;
            if (sunplsOut > 0) {
                IERC20(address(sunpls)).safeTransfer(msg.sender, sunplsOut);
            }
            emit Withdrawn(msg.sender, sunplsOut, userShares, totalShares);
        }

        uint256 wplsAmount = pendingWpls[msg.sender];
        if (wplsAmount > 0) {
            pendingWpls[msg.sender] = 0;
            IERC20(wpls).safeTransfer(msg.sender, wplsAmount);
            emit WPLSClaimed(msg.sender, wplsAmount);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Vault interface
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Called by vault during pool liquidation.
     *         Vault must transfer wplsCollateral to this contract BEFORE calling.
     *
     *         Flow:
     *         1. Distribute WPLS to shareholders (before reducing pool)
     *         2. Burn debtAmount of SunPLS from pool
     *         3. Reduce totalDeposits — each remaining share is now worth less SunPLS
     *         4. totalShares unchanged — the "loss" propagates through share value
     *
     * @param debtAmount      SunPLS debt of the liquidated vault.
     * @param wplsCollateral  WPLS amount already transferred to this contract.
     * @param liquidatedVault Vault address (for event).
     * @return absorbed       True if pool absorbed the liquidation.
     */
    function absorb(uint256 debtAmount, uint256 wplsCollateral, address liquidatedVault)
        external
        onlyVault
        nonReentrant
        returns (bool absorbed)
    {
        require(debtAmount > 0, "Zero debt");

        if (totalDeposits <= debtAmount || totalShares == 0) {
            // Partial absorption not supported in v1 — vault falls back to auction.
            // Exact full-pool absorption is also rejected because this share model
            // cannot clear each user's share mapping without iteration.
            return false;
        }

        // Step 1: Distribute WPLS to shareholders BEFORE reducing pool size.
        //         accWplsPerShare increases relative to current totalShares.
        _distributeWPLS(wplsCollateral);

        // Step 2: Burn SunPLS. Pool holds them, token.setPool() authorizes this.
        sunpls.burn(debtAmount);

        // Step 3: Reduce pool size. Existing shares now represent less SunPLS.
        totalDeposits -= debtAmount;
        // totalShares unchanged — proportional loss already reflected in totalDeposits.

        totalSunPLSAbsorbed += debtAmount;
        totalWPLSFromLiquid += wplsCollateral;
        liquidationCount++;

        emit LiquidationAbsorbed(liquidatedVault, debtAmount, wplsCollateral, accWplsPerShare);
        return true;
    }

    /**
     * @notice Called by vault to route stability fee WPLS to depositors.
     *         Vault must transfer wplsAmount to this contract BEFORE calling.
     *
     * @param wplsAmount WPLS already transferred to this contract.
     */
    function receiveFees(uint256 wplsAmount) external onlyVault {
        require(wplsAmount > 0, "Zero fees");
        _distributeWPLS(wplsAmount);
        totalWPLSFromFees += wplsAmount;
        emit FeesReceived(wplsAmount, accWplsPerShare);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice SunPLS redeemable by a user right now (their share of the pool).
     */
    function sunplsOf(address user) external view returns (uint256) {
        if (totalShares == 0 || shares[user] == 0) return 0;
        return Math.mulDiv(shares[user], totalDeposits, totalShares);
    }

    /**
     * @notice Pending WPLS claimable by a user right now.
     */
    function pendingReward(address user) external view returns (uint256) {
        uint256 userShares = shares[user];
        if (userShares == 0) return pendingWpls[user];
        uint256 delta = accWplsPerShare - userShareDebt[user];
        uint256 fromNew = Math.mulDiv(delta, userShares, PRECISION);
        return pendingWpls[user] + fromNew;
    }

    /**
     * @notice Full depositor summary.
     */
    function depositorInfo(address user)
        external
        view
        returns (
            uint256 sunplsRedeemable,
            uint256 wplsClaimable,
            uint256 userShares_,
            uint256 sharePercent // in basis points (10000 = 100%)
        )
    {
        uint256 userShares = shares[user];
        sunplsRedeemable = totalShares > 0 ? Math.mulDiv(userShares, totalDeposits, totalShares) : 0;

        uint256 delta = accWplsPerShare - userShareDebt[user];
        uint256 fromNew = userShares > 0 ? Math.mulDiv(delta, userShares, PRECISION) : 0;
        wplsClaimable = pendingWpls[user] + fromNew;

        userShares_ = userShares;
        sharePercent = totalShares > 0 ? Math.mulDiv(userShares, 10_000, totalShares) : 0;
    }

    /**
     * @notice Pool-level stats for dashboards.
     */
    function poolStats()
        external
        view
        returns (
            uint256 totalSunPLSDeposited,
            uint256 totalSharesOutstanding,
            uint256 sunplsPerShare_1e18,
            uint256 totalWPLSHeld,
            uint256 lifetimeSunPLSAbsorbed,
            uint256 lifetimeWPLSFromLiquidations,
            uint256 lifetimeWPLSFromFees,
            uint256 totalLiquidations,
            uint256 currentAccWplsPerShare
        )
    {
        totalSunPLSDeposited = totalDeposits;
        totalSharesOutstanding = totalShares;
        sunplsPerShare_1e18 =
            totalShares > 0 ? Math.mulDiv(totalDeposits, PRECISION, totalShares) : PRECISION;
        totalWPLSHeld = IERC20(wpls).balanceOf(address(this));
        lifetimeSunPLSAbsorbed = totalSunPLSAbsorbed;
        lifetimeWPLSFromLiquidations = totalWPLSFromLiquid;
        lifetimeWPLSFromFees = totalWPLSFromFees;
        totalLiquidations = liquidationCount;
        currentAccWplsPerShare = accWplsPerShare;
    }

    /**
     * @notice True if pool has enough SunPLS to cover a full debt absorption.
     */
    function canAbsorb(uint256 debtAmount) external view returns (bool) {
        return totalDeposits > debtAmount && totalShares > 0;
    }
}
