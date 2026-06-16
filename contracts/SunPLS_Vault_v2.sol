// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║           SunPLS Vault v2.0 — ELITE TEAM6                            ║
 * ║           Autonomous Stable Asset — ProjectUSD Architecture          ║
 * ║                                                                      ║
 * ║   Runs in parallel with v1.4. Oracle and Controller are shared.      ║
 * ║   New token (v2) required — trust-minimized burn model changed.      ║
 * ║                                                                      ║
 * ║   ═══════════════════════════════════════════════════════════════    ║
 * ║   WHAT CHANGED FROM v1.4                                             ║
 * ║   ═══════════════════════════════════════════════════════════════    ║
 * ║                                                                      ║
 * ║   BUG FIX — ETH transfer model                                       ║
 * ║   v1.4 used payable.transfer() — 2300 gas stipend, fails for any     ║
 * ║   smart contract caller (keepers, MEV bots, liquidation bots,        ║
 * ║   redemption arbitrageurs). The actors the protocol needs most.      ║
 * ║   v2.0 uses .call{value}() with explicit success check everywhere.   ║
 * ║                                                                      ║
 * ║   INVERTED DUTCH AUCTION                                             ║
 * ║   v1.4: bonus starts at 2%, grows to 5% over 3h.                     ║
 * ║          Creates incentive to WAIT — bots earn more by delaying.     ║
 * ║          Vault stays underwater longer, bad debt risk grows.         ║
 * ║   v2.0: bonus starts at 7%, decays to 2% over 3h.                    ║
 * ║          First mover wins. Immediate liquidation is optimal.         ║
 * ║          Bad debt window collapses to minutes instead of hours.      ║
 * ║                                                                      ║
 * ║   SURPLUS BUFFER + BAD DEBT SYSTEM                                   ║
 * ║   Stability fees accumulate as surplusBuffer (in SunPLS units).      ║
 * ║   When a zombie vault is cleared, debt is written off against        ║
 * ║   surplus first, remainder becomes badDebtAccumulated.               ║
 * ║   Auto-reconciliation runs after every fee accrual.                  ║
 * ║   clearBadDebt(user) — anyone seizes zombie collateral free.         ║
 * ║   settleDebt(amount) — anyone burns SunPLS to cancel bad debt.       ║
 * ║   systemEquity() — net surplus minus bad debt on-chain.              ║
 * ║                                                                      ║
 * ║   DEBT CEILING                                                       ║
 * ║   Immutable. Set at deploy time. mint() and depositAndAutoMintPLS()  ║
 * ║   revert if minting would breach it.                                 ║
 * ║                                                                      ║
 * ║   PERMIT-BASED SINGLE-TRANSACTION FLOWS                              ║
 * ║   repayWithPermit, liquidateWithPermit, redeemWithPermit.            ║
 * ║   Keepers and agents: sign offline, execute in one tx.               ║
 * ║   No prior approve() needed.                                         ║
 * ║                                                                      ║
 * ║   TRUST-MINIMIZED BURN                                               ║
 * ║   Vault pulls SunPLS from user via safeTransferFrom, then calls      ║
 * ║   sunpls.burn(amount) to burn from its own balance.                  ║
 * ║   Burn path requires a visible ERC20 transfer — no silent drain.     ║
 * ║                                                                      ║
 * ║   SMALLER FIXES                                                      ║
 * ║   _clearDebtDust() helper — consistent dust accounting across all    ║
 * ║   repay paths (surplusBuffer adjusted when debt dust is forgiven).   ║
 * ║   MIN_LIQUIDATION_BPS lowered 20% → 5% (less friction for bots).     ║
 * ║                                                                      ║
 * ║   ═══════════════════════════════════════════════════════════════    ║
 * ║   PRESERVED FROM v1.4 (unchanged behavior)                           ║
 * ║   ═══════════════════════════════════════════════════════════════    ║
 * ║   ✓ 150% minimum collateral ratio                                    ║
 * ║   ✓ Dynamic interest rate r from Controller (supports negative)      ║
 * ║   ✓ Redemption at R-value — hard price floor below R                 ║
 * ║   ✓ 130% redemption ratio — only distressed vaults eligible          ║
 * ║   ✓ 5-minute post-redemption liquidation gap (anti-griefing)         ║
 * ║   ✓ 110% liquidation threshold                                       ║
 * ║   ✓ 4-mode oracle fallback — lastOraclePrice never bricks the vault  ║
 * ║   ✓ 10% volatility filter on oracle price updates                    ║
 * ║   ✓ Vault enumeration registry (append-only vaultOwners[])           ║
 * ║   ✓ emergencyUnlock after 30 days inactive + zero debt               ║
 * ║   ✓ depositPLS, deposit, depositAndAutoMintPLS                       ║
 * ║   ✓ withdrawPLS, withdrawWPLS, repayAndWithdrawAll                   ║
 * ║   ✓ VaultOpened, VaultUnderwater, VaultRecovered, InterestAccrued    ║
 * ║   ✓ No admin keys, no pause, no upgrade — immutable after deploy     ║
 * ║                                                                      ║
 * ║   Deploy args: wpls, sunpls, oracle, controller, debtCeiling         ║
 * ║   Oracle and Controller addresses: reuse v1 deployed contracts       ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   Website: https://www.sundaitoken.com                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                        SYSTEM INVARIANTS
 * ═══════════════════════════════════════════════════════════════════════
 *
 * I1.  Solvency:         All vaults must maintain CR >= 150% to mint/withdraw
 * I2.  Liquidation:      Vaults below 110% CR can be liquidated
 * I3.  Redemption:       Vaults at or below 130% CR can be redeemed against
 * I4.  Price Floor:      SunPLS can always be redeemed at R-value
 * I5.  Oracle Safety:    lastOraclePrice fallback prevents oracle-bricking
 * I6.  Rate Safety:      Interest rate bounded by Controller invariants
 * I7.  Immutability:     No admin, no pause, no upgrade after deploy
 * I8.  Liveness:         Dead oracle never blocks deposit/repay/withdraw
 * I9.  Debt Init:        lastDebtAccrual always set on first debt issuance
 * I10. Auction Anchor:   Dutch auction elapsed from undercollateralized start
 * I11. BadDebt Tracking: Uncovered debt → badDebtAccumulated (never silent)
 * I12. Redeem-Liq Gap:   Vault cannot be liquidated within 5min of redemption
 * I13. Surplus Buffer:   Stability fees accumulate as surplusBuffer and are
 *                        applied against badDebtAccumulated automatically
 * I14. Ceiling:          totalDebt + newMint <= DEBT_CEILING always
 * I15. Dust Sync:        surplusBuffer reduced whenever debt dust forgiven
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                     CR ZONE MAP
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   Above 150%  — Healthy. Immune to redemption. Can mint and withdraw.
 *   130%–150%   — Distressed. Redemption eligible. Cannot mint more.
 *   110%–130%   — Seriously distressed. Redemption eligible.
 *   Below 110%  — Liquidatable. Inverted Dutch auction active.
 *
 * ═══════════════════════════════════════════════════════════════════════
 */

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/utils/math/Math.sol";

import "./SunPLS_Token_v2.sol";

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface ISunPLSOracle {
    function update()    external returns (uint256 price, uint256 timestamp);
    function peek()      external view   returns (uint256 price, uint256 timestamp);
    function isHealthy() external view   returns (bool);
}

interface IProjectUSDController {
    function R() external view returns (uint256);
}

contract SunPLSVault_v2 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20                public immutable wpls;
    SunPLS                public immutable sunpls;
    ISunPLSOracle         public immutable oracle;
    IProjectUSDController public immutable controller;

    /// @notice Protocol-level debt ceiling (SunPLS, 1e18 units). Set at deploy, immutable.
    uint256               public immutable DEBT_CEILING;

    string public constant VERSION = "SunPLSVault_v2.0";

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant COLLATERAL_RATIO           = 150;
    uint256 public constant LIQUIDATION_RATIO          = 110;
    uint256 public constant REDEMPTION_RATIO           = 130;
    uint256 public constant AUTOMINT_RATIO             = 155;
    uint256 public constant MIN_SYSTEM_HEALTH          = 130;

    uint256 public constant MIN_ACTION_AMOUNT          = 1e14;
    uint256 public constant WITHDRAW_COOLDOWN          = 300;
    uint256 public constant LIQUIDATION_COOLDOWN       = 600;
    uint256 public constant REDEMPTION_LIQUIDATION_GAP = 300;
    uint256 public constant SECONDS_PER_YEAR           = 31_536_000;
    uint256 public constant REDEMPTION_FEE_BPS         = 50;

    /// @notice v2.0 inverted Dutch auction: max bonus immediately, decays over 3h.
    ///         v1.4: 2% → 5% (growing over time — rewarded waiting).
    ///         v2.0: 7% → 2% (decaying over time — rewards immediate action).
    ///         Liquidation bots act at t=0 for maximum bonus. Vault clears fast.
    uint256 public constant MAX_BONUS_BPS              = 700;   // 7% at auction start
    uint256 public constant MIN_BONUS_BPS              = 200;   // 2% at auction end
    uint256 public constant AUCTION_TIME               = 3 hours;

    /// @notice v2.0: lowered from 20% to 5%. Less friction for bots doing
    ///         partial liquidations; still prevents dust griefing.
    uint256 public constant MIN_LIQUIDATION_BPS        = 500;

    uint256 public constant MAX_VOLATILITY_BPS         = 1000;
    uint256 public constant MAX_ORACLE_STALENESS       = 600;
    uint256 public constant EMERGENCY_UNLOCK_TIME      = 30 days;

    /*//////////////////////////////////////////////////////////////
                              VAULT STRUCT
    //////////////////////////////////////////////////////////////*/

    struct Vault {
        uint256 collateral;
        uint256 debt;
        uint256 lastDepositTime;
        uint256 lastLiquidationTime;
        uint256 lastDebtAccrual;
        uint256 undercollateralizedSince;
        uint256 lastRedemptionTime;
    }

    mapping(address => Vault) public vaults;

    /*//////////////////////////////////////////////////////////////
                              REGISTRY
    //////////////////////////////////////////////////////////////*/

    address[] public vaultOwners;
    mapping(address => bool) public isVaultOwner;

    /*//////////////////////////////////////////////////////////////
                              GLOBAL STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalCollateral;
    uint256 public totalDebt;
    int256  public currentRate;
    uint256 public lastOraclePrice;
    uint256 public lastOracleUpdateTime;

    // ── Surplus buffer and bad debt ──────────────────────────────────────────
    // surplusBuffer: stability fees accumulated as protocol equity (SunPLS units).
    //   Applied automatically against bad debt via _reconcile().
    //   Reduced when debt dust is forgiven (_clearDebtDust).
    // badDebtAccumulated: uncovered debt from zombie vault clearances.
    //   Reduced by reconciliation, settleDebt(), and clearBadDebt() surplus cover.
    uint256 public surplusBuffer;
    uint256 public badDebtAccumulated;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 amount, uint256 ratio);
    event Withdraw(address indexed user, uint256 amount, uint256 ratio);
    event Mint(address indexed user, uint256 amount, uint256 ratio);
    event Repay(address indexed user, uint256 amount, uint256 ratio);
    event Liquidation(
        address indexed user,
        uint256 repayAmount,
        address indexed liquidator,
        uint256 reward,
        uint256 ratio
    );
    event Redemption(
        address indexed redeemer,
        address indexed targetVault,
        uint256 sunplsBurned,
        uint256 plsReceived,
        uint256 feeRetainedByVault,
        uint256 redemptionValue
    );
    event RateUpdated(int256 oldRate, int256 newRate, uint256 timestamp);
    event OraclePriceAccepted(uint256 price, uint256 timestamp);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    event VaultOpened(address indexed user, uint256 timestamp);
    event VaultUnderwater(address indexed user, uint256 since);
    event VaultRecovered(address indexed user, uint256 timestamp);
    event InterestAccrued(address indexed user, uint256 oldDebt, uint256 newDebt, uint256 timestamp);
    event BadDebtCleared(
        address indexed vaultOwner,
        uint256 debtWrittenOff,
        uint256 collateralSeized,
        address indexed caller,
        uint256 coveredBySurplus,
        uint256 uncovered
    );
    event BadDebtSettled(address indexed settler, uint256 amount);
    event SurplusReconciled(uint256 applied);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _wpls,
        address _sunpls,
        address _oracle,
        address _controller,
        uint256 _debtCeiling
    ) {
        require(
            _wpls       != address(0) &&
            _sunpls     != address(0) &&
            _oracle     != address(0) &&
            _controller != address(0),
            "Zero address"
        );
        require(_debtCeiling > 0, "Zero ceiling");

        wpls         = IERC20(_wpls);
        sunpls       = SunPLS(_sunpls);
        oracle       = ISunPLSOracle(_oracle);
        controller   = IProjectUSDController(_controller);
        DEBT_CEILING = _debtCeiling;

        (uint256 initialPrice, uint256 initialTs) = ISunPLSOracle(_oracle).peek();
        require(initialPrice > 0, "Oracle not ready at deploy");
        lastOraclePrice      = initialPrice;
        lastOracleUpdateTime = initialTs > 0 ? initialTs : block.timestamp;
        currentRate = 0;
    }

    /*//////////////////////////////////////////////////////////////
                         CONTROLLER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function updateRate(int256 newRate) external {
        require(msg.sender == address(controller), "Only controller");
        int256 oldRate = currentRate;
        currentRate = newRate;
        emit RateUpdated(oldRate, newRate, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                     SURPLUS BUFFER & BAD DEBT
    //////////////////////////////////////////////////////////////*/

    function _reconcile() internal {
        if (surplusBuffer > 0 && badDebtAccumulated > 0) {
            uint256 applied = surplusBuffer < badDebtAccumulated
                ? surplusBuffer
                : badDebtAccumulated;
            surplusBuffer        -= applied;
            badDebtAccumulated   -= applied;
            emit SurplusReconciled(applied);
        }
    }

    /// @notice Manually trigger surplus-to-bad-debt reconciliation.
    ///         Callable by anyone — keepers, bots, or users.
    function reconcile() external nonReentrant {
        _reconcile();
    }

    /// @notice Net system equity in SunPLS units.
    ///         Positive: surplus > bad debt. Negative: bad debt exceeds surplus.
    function systemEquity() external view returns (int256) {
        return int256(surplusBuffer) - int256(badDebtAccumulated);
    }

    /// @notice Clear a zombie vault (collateral value < 100% of debt at current price).
    ///         Caller seizes all WPLS collateral free — incentive to clear promptly.
    ///         Debt written off against surplusBuffer first; remainder → badDebtAccumulated.
    ///         No SunPLS required to call — the collateral seizure is the reward.
    function clearBadDebt(address user) external nonReentrant {
        Vault storage v = vaults[user];
        require(v.debt > 0, "No debt");

        uint256 price = _viewPrice();
        require(price > 0, "No price");

        // Only callable when collateral is worth less than 100% of debt.
        // If collateral still covers debt (even partially above 100%), use liquidate().
        uint256 collateralValue = Math.mulDiv(v.collateral, 1e18, price);
        require(collateralValue < v.debt, "Not fully underwater - use liquidate()");

        uint256 collateral = v.collateral;
        uint256 debt       = v.debt;

        totalCollateral -= collateral;
        totalDebt       -= debt;
        delete vaults[user];

        uint256 covered  = surplusBuffer < debt ? surplusBuffer : debt;
        surplusBuffer   -= covered;
        uint256 uncovered = debt - covered;
        if (uncovered > 0) badDebtAccumulated += uncovered;

        _sendPLS(msg.sender, collateral);

        emit BadDebtCleared(user, debt, collateral, msg.sender, covered, uncovered);
    }

    /// @notice Burn SunPLS to directly cancel an equal amount of accumulated bad debt.
    ///         Anyone can call — protocol supporters, token holders, vault owners.
    function settleDebt(uint256 amount) external nonReentrant {
        require(amount > 0 && badDebtAccumulated >= amount, "Invalid settle amount");
        _collectAndBurn(msg.sender, amount);
        badDebtAccumulated -= amount;
        emit BadDebtSettled(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _safePrice() internal returns (uint256) {
        try oracle.update() returns (uint256 freshPrice, uint256 freshTs) {
            if (freshPrice > 0) {
                if (lastOraclePrice > 0) {
                    uint256 diff = freshPrice > lastOraclePrice
                        ? freshPrice - lastOraclePrice
                        : lastOraclePrice - freshPrice;
                    uint256 volatilityBps = (diff * 10_000) / lastOraclePrice;
                    if (volatilityBps > MAX_VOLATILITY_BPS) {
                        return lastOraclePrice;
                    }
                }
                lastOraclePrice      = freshPrice;
                lastOracleUpdateTime = freshTs > 0 ? freshTs : block.timestamp;
                emit OraclePriceAccepted(freshPrice, block.timestamp);
                return freshPrice;
            }
        } catch {}

        require(lastOraclePrice > 0, "No valid oracle price");
        return lastOraclePrice;
    }

    function _viewPrice() internal view returns (uint256) {
        try oracle.peek() returns (uint256 p, uint256 ts) {
            if (p > 0 && (ts == 0 || block.timestamp - ts <= MAX_ORACLE_STALENESS)) {
                return p;
            }
        } catch {}
        return lastOraclePrice;
    }

    function _redemptionValue() internal view returns (uint256) {
        try controller.R() returns (uint256 rVal) {
            if (rVal > 0) return rVal;
        } catch {}
        return lastOraclePrice > 0 ? lastOraclePrice : 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Send PLS safely. Uses .call to support smart contract recipients.
    ///      v1.4 used .transfer() (2300 gas limit) which fails for contract callers.
    function _sendPLS(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "PLS transfer failed");
    }

    /// @dev Pull SunPLS from user to vault, then burn from vault's own balance.
    ///      Trust-minimized: burn path always requires a visible ERC20 transfer.
    function _collectAndBurn(address from, uint256 amount) internal {
        IERC20(address(sunpls)).safeTransferFrom(from, address(this), amount);
        sunpls.burn(amount);
    }

    /// @dev Forgive sub-dust residual debt and keep surplusBuffer in sync.
    ///      Called from every path that can leave v.debt > 0 but negligible.
    function _clearDebtDust(Vault storage v) internal {
        if (v.debt > 0 && v.debt <= 1e12) {
            uint256 dust = v.debt;
            totalDebt   -= dust;
            if (surplusBuffer >= dust) surplusBuffer -= dust;
            else surplusBuffer = 0;
            v.debt = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    function _touch(address user) internal {
        Vault storage v = vaults[user];
        if (v.debt > 0 && v.lastDebtAccrual > 0) {
            _accrueInterest(user, v);
        }
    }

    function _accrueInterest(address user, Vault storage v) internal {
        if (v.debt == 0) {
            v.lastDebtAccrual = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - v.lastDebtAccrual;
        if (elapsed == 0) return;
        if (elapsed > SECONDS_PER_YEAR) elapsed = SECONDS_PER_YEAR;

        int256 interest = (int256(v.debt) * currentRate * int256(elapsed))
            / (int256(SECONDS_PER_YEAR) * 1e18);

        if (interest != 0) {
            uint256 oldDebt = v.debt;

            if (interest > 0) {
                uint256 inc = uint256(interest);
                v.debt        += inc;
                totalDebt     += inc;
                surplusBuffer += inc;  // positive fees accumulate as protocol equity
            } else {
                uint256 dec = uint256(-interest);
                if (dec >= v.debt) {
                    // Negative rates zeroed this vault's debt entirely —
                    // adjust surplus for the debt that was forgiven
                    if (surplusBuffer >= v.debt) surplusBuffer -= v.debt;
                    else surplusBuffer = 0;
                    totalDebt -= v.debt;
                    v.debt = 0;
                } else {
                    v.debt    -= dec;
                    totalDebt -= dec;
                    // Negative interest reduces future surplus expectation —
                    // walk back the buffer proportionally
                    if (surplusBuffer >= dec) surplusBuffer -= dec;
                    else surplusBuffer = 0;
                }
            }

            if (v.debt != oldDebt) {
                emit InterestAccrued(user, oldDebt, v.debt, block.timestamp);
            }
        }

        v.lastDebtAccrual = block.timestamp;
        _clearDebtDust(v);
        _reconcile();
    }

    function _issueDebt(address user, uint256 amount) internal {
        Vault storage v = vaults[user];
        if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
        v.debt    += amount;
        totalDebt += amount;
        sunpls.mint(user, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         SAFETY CHECKS
    //////////////////////////////////////////////////////////////*/

    function _isAtLiquidationThreshold(uint256 col, uint256 debt) internal view returns (bool) {
        if (debt == 0) return false;
        uint256 p = _viewPrice();
        if (p == 0) return false;
        return Math.mulDiv(col, 1e18 * 100, p) < debt * LIQUIDATION_RATIO;
    }

    function _isSafeAtRatio(
        uint256 col, uint256 debt, uint256 price, uint256 ratio
    ) internal pure returns (bool) {
        if (debt == 0) return true;
        return Math.mulDiv(col, 1e18 * 100, price) >= debt * ratio;
    }

    function _collateralRatio(address user) internal view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return type(uint256).max;
        uint256 p = _viewPrice();
        if (p == 0) return type(uint256).max;
        return Math.mulDiv(v.collateral, 1e18 * 100, v.debt * p);
    }

    function systemHealth() public view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        uint256 p = _viewPrice();
        if (p == 0) return type(uint256).max;
        return Math.mulDiv(totalCollateral, 1e18 * 100, totalDebt * p);
    }

    /*//////////////////////////////////////////////////////////////
                            REGISTRY
    //////////////////////////////////////////////////////////////*/

    function _addCollateral(address user, uint256 amount) internal {
        Vault storage v = vaults[user];

        if (!isVaultOwner[user]) {
            isVaultOwner[user] = true;
            vaultOwners.push(user);
            emit VaultOpened(user, block.timestamp);
        }

        v.collateral     += amount;
        v.lastDepositTime = block.timestamp;
        totalCollateral  += amount;

        if (v.undercollateralizedSince > 0 && !_isAtLiquidationThreshold(v.collateral, v.debt)) {
            v.undercollateralizedSince = 0;
            emit VaultRecovered(user, block.timestamp);
        }

        emit Deposit(user, amount, _collateralRatio(user));
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function depositPLS() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        IWPLS(address(wpls)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        wpls.safeTransferFrom(msg.sender, address(this), amount);
        _addCollateral(msg.sender, amount);
    }

    function depositAndAutoMintPLS() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Too small");
        require(systemHealth() >= MIN_SYSTEM_HEALTH, "System undercollateralized");
        _touch(msg.sender);

        IWPLS(address(wpls)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);

        uint256 price       = _safePrice();
        uint256 colValue    = Math.mulDiv(msg.value, 1e18, price);
        uint256 mintAmount  = (colValue * 100) / AUTOMINT_RATIO;
        if (mintAmount == 0) return;

        require(totalDebt + mintAmount <= DEBT_CEILING, "Debt ceiling reached");

        Vault storage v = vaults[msg.sender];
        require(
            _isSafeAtRatio(v.collateral, v.debt + mintAmount, price, COLLATERAL_RATIO),
            "Automint exceeds limit"
        );
        _issueDebt(msg.sender, mintAmount);
        emit Mint(msg.sender, mintAmount, _collateralRatio(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                            MINT
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero mint");
        require(systemHealth() >= MIN_SYSTEM_HEALTH, "System undercollateralized");
        _touch(msg.sender);

        Vault storage v = vaults[msg.sender];
        uint256 price   = _safePrice();
        require(totalDebt + amount <= DEBT_CEILING, "Debt ceiling reached");
        require(
            _isSafeAtRatio(v.collateral, v.debt + amount, price, COLLATERAL_RATIO),
            "Insufficient collateral"
        );

        _issueDebt(msg.sender, amount);
        emit Mint(msg.sender, amount, _collateralRatio(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                            REPAY
    //////////////////////////////////////////////////////////////*/

    function _doRepay(uint256 amount) internal {
        _touch(msg.sender);
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.debt >= amount, "Invalid repay amount");

        _collectAndBurn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;
        _clearDebtDust(v);

        if (v.undercollateralizedSince > 0 && !_isAtLiquidationThreshold(v.collateral, v.debt)) {
            v.undercollateralizedSince = 0;
            emit VaultRecovered(msg.sender, block.timestamp);
        }

        emit Repay(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function repay(uint256 amount) external nonReentrant {
        _doRepay(amount);
    }

    /// @notice Repay in a single transaction using EIP-2612 permit.
    ///         Sign a permit offline. No prior approve() needed.
    function repayWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 pV, bytes32 pR, bytes32 pS
    ) external nonReentrant {
        sunpls.permit(msg.sender, address(this), amount, deadline, pV, pR, pS);
        _doRepay(amount);
    }

    function repayAndWithdrawAll() external nonReentrant {
        _touch(msg.sender);
        Vault storage v = vaults[msg.sender];

        uint256 debt = v.debt;
        uint256 col  = v.collateral;

        require(debt > 0 || col > 0, "Nothing to do");

        if (debt > 0) {
            _collectAndBurn(msg.sender, debt);
            totalDebt -= debt;
            v.debt = 0;
            emit Repay(msg.sender, debt, type(uint256).max);
        }

        if (col > 0) {
            totalCollateral -= col;
            delete vaults[msg.sender];
            IWPLS(address(wpls)).withdraw(col);
            _sendPLS(msg.sender, col);
            emit Withdraw(msg.sender, col, type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function withdrawPLS(uint256 amount) external nonReentrant {
        _touch(msg.sender);
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid amount");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown active");

        v.collateral    -= amount;
        totalCollateral -= amount;

        uint256 p = _safePrice();
        require(
            _isSafeAtRatio(v.collateral, v.debt, p, COLLATERAL_RATIO),
            "Would breach 150% CR"
        );

        IWPLS(address(wpls)).withdraw(amount);
        _sendPLS(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function withdrawWPLS(uint256 amount) external nonReentrant {
        _touch(msg.sender);
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid amount");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown active");

        v.collateral    -= amount;
        totalCollateral -= amount;

        uint256 p = _safePrice();
        require(
            _isSafeAtRatio(v.collateral, v.debt, p, COLLATERAL_RATIO),
            "Would breach 150% CR"
        );

        wpls.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function emergencyUnlock() external nonReentrant {
        _touch(msg.sender);
        Vault storage v = vaults[msg.sender];
        require(v.debt == 0, "Repay debt first");
        require(v.collateral > 0, "No collateral");
        require(block.timestamp > v.lastDepositTime + EMERGENCY_UNLOCK_TIME, "Too early");

        uint256 col     = v.collateral;
        totalCollateral -= col;
        delete vaults[msg.sender];

        IWPLS(address(wpls)).withdraw(col);
        _sendPLS(msg.sender, col);
        emit EmergencyWithdraw(msg.sender, col);
    }

    /*//////////////////////////////////////////////////////////////
                        REDEMPTION MECHANISM
    //////////////////////////////////////////////////////////////*/

    function _doRedeem(uint256 sunplsAmount, address targetVault) internal {
        require(sunplsAmount >= MIN_ACTION_AMOUNT, "Too small");
        require(targetVault != address(0), "Zero vault");
        require(targetVault != msg.sender, "Cannot self-redeem");

        _touch(targetVault);

        Vault storage v = vaults[targetVault];
        require(v.debt >= sunplsAmount, "Exceeds vault debt");

        uint256 targetCR = _collateralRatio(targetVault);
        require(targetCR <= REDEMPTION_RATIO, "Vault CR too high to redeem against");

        uint256 R = _redemptionValue();
        require(R > 0, "No R value");

        uint256 plsOut = Math.mulDiv(sunplsAmount, R, 1e18);
        require(plsOut > 0, "Redemption too small");
        require(plsOut <= v.collateral, "Insufficient vault collateral");

        uint256 feeAmount     = (plsOut * REDEMPTION_FEE_BPS) / 10_000;
        uint256 plsToRedeemer = plsOut - feeAmount;

        _collectAndBurn(msg.sender, sunplsAmount);

        v.debt               -= sunplsAmount;
        totalDebt            -= sunplsAmount;
        v.collateral         -= plsToRedeemer;
        totalCollateral      -= plsToRedeemer;
        v.lastRedemptionTime  = block.timestamp;

        if (v.undercollateralizedSince > 0 && !_isAtLiquidationThreshold(v.collateral, v.debt)) {
            v.undercollateralizedSince = 0;
            emit VaultRecovered(targetVault, block.timestamp);
        }

        IWPLS(address(wpls)).withdraw(plsToRedeemer);
        _sendPLS(msg.sender, plsToRedeemer);

        emit Redemption(msg.sender, targetVault, sunplsAmount, plsToRedeemer, feeAmount, R);
    }

    function redeem(uint256 sunplsAmount, address targetVault) external nonReentrant {
        _doRedeem(sunplsAmount, targetVault);
    }

    /// @notice Redeem in a single transaction using EIP-2612 permit.
    ///         Sign a permit offline. No prior approve() needed.
    function redeemWithPermit(
        uint256 sunplsAmount,
        address targetVault,
        uint256 deadline,
        uint8 pV, bytes32 pR, bytes32 pS
    ) external nonReentrant {
        sunpls.permit(msg.sender, address(this), sunplsAmount, deadline, pV, pR, pS);
        _doRedeem(sunplsAmount, targetVault);
    }

    /*//////////////////////////////////////////////////////////////
                        DUTCH AUCTION LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function _doLiquidate(address user, uint256 repayAmount) internal {
        require(user != msg.sender, "Cannot self-liquidate");
        _touch(user);

        Vault storage v = vaults[user];
        require(v.debt > 0, "No debt");
        require(_isAtLiquidationThreshold(v.collateral, v.debt), "Vault is safe");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid repay amount");
        require(
            repayAmount * 10_000 >= v.debt * MIN_LIQUIDATION_BPS,
            "Below min liquidation size"
        );
        require(
            block.timestamp > v.lastLiquidationTime + LIQUIDATION_COOLDOWN,
            "Liquidation cooldown"
        );
        require(
            block.timestamp > v.lastRedemptionTime + REDEMPTION_LIQUIDATION_GAP,
            "Recently redeemed: wait before liquidating"
        );

        if (v.undercollateralizedSince == 0) {
            v.undercollateralizedSince = block.timestamp;
            emit VaultUnderwater(user, block.timestamp);
        }

        uint256 price   = _safePrice();
        uint256 base    = Math.mulDiv(repayAmount, price, 1e18);

        // Inverted Dutch auction: bonus starts at MAX_BONUS_BPS (7%), decays to
        // MIN_BONUS_BPS (2%) over AUCTION_TIME. Acts immediately = maximum reward.
        uint256 elapsed = block.timestamp - v.undercollateralizedSince;
        if (elapsed > AUCTION_TIME) elapsed = AUCTION_TIME;
        uint256 bonusBps = MAX_BONUS_BPS - (
            (MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed / AUCTION_TIME
        );
        uint256 bonus  = (base * bonusBps) / 10_000;
        uint256 reward = base + bonus;

        // Cap reward at available collateral. If the vault is still underwater
        // after this liquidation (debt remaining with zero or near-zero collateral),
        // clearBadDebt() handles write-off in SunPLS units — the correct unit for
        // surplusBuffer and badDebtAccumulated. Mixing WPLS collateral shortfall
        // with SunPLS debt units here would corrupt both ledgers.
        if (reward > v.collateral) {
            reward = v.collateral;
        }

        _collectAndBurn(msg.sender, repayAmount);

        v.debt          -= repayAmount;
        totalDebt       -= repayAmount;
        v.collateral    -= reward;
        totalCollateral -= reward;
        v.lastLiquidationTime = block.timestamp;

        if (!_isAtLiquidationThreshold(v.collateral, v.debt)) {
            v.undercollateralizedSince = 0;
            emit VaultRecovered(user, block.timestamp);
        }

        IWPLS(address(wpls)).withdraw(reward);
        _sendPLS(msg.sender, reward);

        emit Liquidation(user, repayAmount, msg.sender, reward, _collateralRatio(user));
    }

    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        _doLiquidate(user, repayAmount);
    }

    /// @notice Liquidate in a single transaction using EIP-2612 permit.
    ///         Liquidation bots: sign offline, liquidate in one tx.
    function liquidateWithPermit(
        address user,
        uint256 repayAmount,
        uint256 deadline,
        uint8 pV, bytes32 pR, bytes32 pS
    ) external nonReentrant {
        sunpls.permit(msg.sender, address(this), repayAmount, deadline, pV, pR, pS);
        _doLiquidate(user, repayAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function canLiquidate(address user) public view returns (bool) {
        Vault storage v = vaults[user];
        if (!_isAtLiquidationThreshold(v.collateral, v.debt)) return false;
        return block.timestamp > v.lastRedemptionTime + REDEMPTION_LIQUIDATION_GAP;
    }

    function canRedeem(address user) public view returns (bool) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return false;
        return _collateralRatio(user) <= REDEMPTION_RATIO;
    }

    function vaultInfo(address user)
        external view
        returns (
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
        )
    {
        Vault storage v = vaults[user];
        collateral = v.collateral;
        debt       = v.debt;

        uint256 p     = _viewPrice();
        oracleHealthy = oracle.isHealthy();

        collateralValueInSunPLS = p > 0 ? Math.mulDiv(collateral, 1e18, p) : 0;
        ratio = _collateralRatio(user);

        uint256 maxDebt = p > 0
            ? Math.mulDiv(collateral, 1e18 * 100, p * COLLATERAL_RATIO)
            : 0;
        mintable     = maxDebt > debt ? maxDebt - debt : 0;
        rate         = currentRate;
        redemptionVal = _redemptionValue();
        liquidatable = canLiquidate(user);
        redeemable   = canRedeem(user);
        systemRatio  = systemHealth();
    }

    function liquidationInfo(address user)
        external view
        returns (uint256 debt, uint256 minRepay, uint256 reward, uint256 bonusBps)
    {
        Vault storage v = vaults[user];
        if (v.debt == 0 || !_isAtLiquidationThreshold(v.collateral, v.debt)) {
            return (0, 0, 0, 0);
        }

        uint256 p = _viewPrice();
        if (p == 0) return (0, 0, 0, 0);

        debt     = v.debt;
        minRepay = (v.debt * MIN_LIQUIDATION_BPS) / 10_000;
        uint256 base = Math.mulDiv(minRepay, p, 1e18);

        uint256 anchor  = v.undercollateralizedSince > 0
            ? v.undercollateralizedSince
            : block.timestamp;
        uint256 elapsed = block.timestamp - anchor;
        if (elapsed > AUCTION_TIME) elapsed = AUCTION_TIME;

        // Inverted: starts at MAX_BONUS_BPS, decays to MIN_BONUS_BPS
        bonusBps = MAX_BONUS_BPS - ((MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed / AUCTION_TIME);
        uint256 bonus = (base * bonusBps) / 10_000;
        reward = base + bonus;
        if (reward > v.collateral) reward = v.collateral;
    }

    function repayToHealth(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return 0;
        uint256 p = _viewPrice();
        if (p == 0) return 0;
        uint256 maxSafeDebt = Math.mulDiv(v.collateral, 1e18 * 100, p * COLLATERAL_RATIO);
        return v.debt > maxSafeDebt ? v.debt - maxSafeDebt : 0;
    }

    function maxMint(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.collateral == 0) return 0;
        uint256 p = _viewPrice();
        if (p == 0) return 0;
        uint256 maxDebt = Math.mulDiv(v.collateral, 1e18 * 100, p * COLLATERAL_RATIO);
        return maxDebt > v.debt ? maxDebt - v.debt : 0;
    }

    function redemptionPreview(address targetVault, uint256 sunplsAmount)
        external view
        returns (uint256 plsToRedeemer, uint256 feeToOwner, uint256 R, bool eligible)
    {
        eligible = canRedeem(targetVault);
        Vault storage v = vaults[targetVault];
        if (v.debt < sunplsAmount) eligible = false;

        R = _redemptionValue();
        if (R > 0 && sunplsAmount > 0) {
            uint256 plsOut = Math.mulDiv(sunplsAmount, R, 1e18);
            feeToOwner     = (plsOut * REDEMPTION_FEE_BPS) / 10_000;
            plsToRedeemer  = plsOut - feeToOwner;
        }
    }

    function getVaultCount() external view returns (uint256) {
        return vaultOwners.length;
    }

    function getVaultOwner(uint256 index) external view returns (address) {
        return vaultOwners[index];
    }

    /*//////////////////////////////////////////////////////////////
                              FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
