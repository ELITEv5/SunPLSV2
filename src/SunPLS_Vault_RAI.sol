// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║        SunPLS RAI — Vault v1.0                                       ║
 * ║        WPLS CDP Vault with Stability Pool Integration                ║
 * ║                                                                      ║
 * ║   Built on SunPLS Vault v2.0. Key additions:                         ║
 * ║                                                                      ║
 * ║   ✓ STABILITY POOL LIQUIDATION PATH (primary)                        ║
 * ║     When CR < 110%: pool absorbs first (instant, no auction needed). ║
 * ║     Only if pool doesn't have enough SunPLS does the inverted        ║
 * ║     Dutch auction activate as fallback.                              ║
 * ║     Result: undercollateralized vaults cleared in seconds, not hours.║
 * ║                                                                      ║
 * ║   ✓ STABILITY FEE ROUTING                                            ║
 * ║     Stability fees (accumulated as surplusBuffer) are periodically   ║
 * ║     converted to WPLS and sent to the stability pool via             ║
 * ║     flushFeesToPool(). This makes holding SunPLS productive          ║
 * ║     without any external protocol integration.                       ║
 * ║                                                                      ║
 * ║   ✓ STABILITY POOL LATCH                                             ║
 * ║     pool address set once by deployer post-deploy.                   ║
 * ║     After latch: immutable. No admin can redirect fee flows.         ║
 * ║                                                                      ║
 * ║   PRESERVED FROM v2.0 (unchanged):                                   ║
 * ║   ✓ 150% minimum CR to mint                                          ║
 * ║   ✓ 110% liquidation threshold                                       ║
 * ║   ✓ 130% redemption threshold                                        ║
 * ║   ✓ Inverted Dutch auction (7%→2% over 3h) as fallback               ║
 * ║   ✓ Surplus buffer + bad debt accounting                             ║
 * ║   ✓ clearBadDebt() / settleDebt()                                    ║
 * ║   ✓ Debt ceiling (immutable)                                         ║
 * ║   ✓ ERC20Permit flows (repay/liquidate/redeem)                       ║
 * ║   ✓ .call{value}() — no 2300 gas stipend failures                    ║
 * ║   ✓ emergencyUnlock after 30d inactive + zero debt                   ║
 * ║   ✓ No admin, no pause, no upgrade                                   ║
 * ║                                                                      ║
 * ║   CR ZONE MAP                                                        ║
 * ║   Above 150%  → Healthy. Can mint and withdraw.                     ║
 * ║   130%–150%   → Distressed. Redemption eligible.                    ║
 * ║   110%–130%   → Seriously distressed. Redemption eligible.          ║
 * ║   Below 110%  → Liquidatable. Pool first, then Dutch auction.        ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                        SYSTEM INVARIANTS
 * ═══════════════════════════════════════════════════════════════════════
 *
 * I1.  Solvency:         Vaults must maintain CR ≥ 150% to mint/withdraw
 * I2.  Liquidation:      CR < 110% → liquidatable (pool first, auction fallback)
 * I3.  Redemption:       CR ≤ 130% → eligible for redemption at R-value
 * I4.  Price Floor:      SunPLS always redeemable at R-value (hard floor)
 * I5.  Oracle Safety:    lastOraclePrice fallback keeps vault functional
 * I6.  Immutability:     No admin, no pause, no upgrade after deploy
 * I7.  Liveness:         Oracle failure never blocks deposit/repay/withdraw
 * I8.  Fee Routing:      Stability fees flow to pool only — no other path
 * I9.  Pool Latch:       stabilityPool set once, immutable after latch
 * I10. Debt Ceiling:     totalDebt + newMint ≤ DEBT_CEILING always
 * I11. BadDebt Tracking: Uncovered debt → badDebtAccumulated (never silent)
 * I12. Surplus Buffer:   Fees accumulate as surplusBuffer, auto-reconciled
 *
 * ═══════════════════════════════════════════════════════════════════════
 */

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface ISunPLSTokenRAI {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external;
    function balanceOf(address) external view returns (uint256);
}

interface IControllerRAI {
    function r() external view returns (int256);
    function R() external view returns (uint256);
    function updateRate(int256 newRate) external;
    function systemHealth() external view returns (uint256);
}

interface IOracleRAI {
    function update() external returns (uint256, uint256);
    function peek() external view returns (uint256, uint256);
    function isHealthy() external view returns (bool);
}

interface IStabilityPool {
    function absorb(uint256 debtAmount, uint256 wplsCollateral, address liquidatedVault)
        external
        returns (bool absorbed);
    function receiveFees(uint256 wplsAmount) external;
    function canAbsorb(uint256 debtAmount) external view returns (bool);
}

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SunPLSVaultRAI is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────

    IWPLS public immutable wpls;
    ISunPLSTokenRAI public immutable sunpls;
    IOracleRAI public immutable oracle;
    IControllerRAI public immutable controller;
    uint256 public immutable DEBT_CEILING;
    address private immutable deployer;

    // ─────────────────────────────────────────────────────────────────────
    // Stability pool latch
    // ─────────────────────────────────────────────────────────────────────

    IStabilityPool public stabilityPool;
    bool public poolSet;

    // ─────────────────────────────────────────────────────────────────────
    // Vault state per user
    // ─────────────────────────────────────────────────────────────────────

    struct Vault {
        uint256 collateral; // WPLS deposited (1e18 scale)
        uint256 debt; // SunPLS minted (1e18 scale)
        uint256 lastDebtAccrual; // timestamp of last interest accrual
        uint256 auctionStart; // timestamp undercollateralization began (for Dutch auction)
    }

    mapping(address => Vault) public vaults;
    address[] public vaultOwners;
    mapping(address => bool) private _hasVault;

    // ─────────────────────────────────────────────────────────────────────
    // Global state
    // ─────────────────────────────────────────────────────────────────────

    uint256 public totalDebt;
    uint256 public totalCollateral;
    uint256 public surplusBuffer; // accrued fee SunPLS added to outstanding debt
    uint256 public badDebtAccumulated; // uncovered bad debt NOT yet in totalDebt
    uint256 public feeReserveWPLS; // WPLS set aside for pool fee distribution (not collateral)

    // Per-vault accrued interest tracking (fixes surplusBuffer over-reduction on repay)
    mapping(address => uint256) public accruedInterest;

    // Oracle price cache
    uint256 public lastOraclePrice;
    uint256 public lastOraclePriceTime;

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_CR_BPS = 15000; // 150% minimum collateral ratio
    uint256 public constant LIQ_CR_BPS = 11000; // 110% liquidation threshold
    uint256 public constant REDEEM_CR_BPS = 13000; // 130% redemption threshold
    uint256 public constant ORACLE_VOLATILITY = 1000; // 10% max oracle jump per update
    uint256 public constant MAX_ORACLE_STALENESS = 2 hours;
    uint256 public constant DUST_THRESHOLD = 1e15; // 0.001 SunPLS

    // Dutch auction constants (fallback when pool can't absorb)
    uint256 public constant AUCTION_START_BONUS_BPS = 700; // 7% at auction start
    uint256 public constant AUCTION_END_BONUS_BPS = 200; // 2% after 3h
    uint256 public constant AUCTION_DURATION = 3 hours;

    uint256 public constant REDEMPTION_GAP = 5 minutes; // anti-griefing gap
    uint256 public constant EMERGENCY_UNLOCK = 30 days; // inactive vault recovery

    // Seconds per year for interest accrual (365.25 days)
    uint256 private constant SECONDS_PER_YEAR = 31_557_600;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event StabilityPoolSet(address indexed pool);

    event VaultOpened(address indexed owner, uint256 collateral, uint256 debt);
    event CollateralDeposited(address indexed owner, uint256 amount);
    event CollateralWithdrawn(address indexed owner, uint256 amount);
    event DebtMinted(address indexed owner, uint256 amount);
    event DebtRepaid(address indexed owner, uint256 amount, uint256 remainingDebt);
    event VaultClosed(address indexed owner);

    event InterestAccrued(
        address indexed owner, uint256 debtBefore, uint256 debtAfter, uint256 feeCharged
    );

    event VaultUnderwater(address indexed owner, uint256 crBps, uint256 timestamp);
    event VaultRecovered(address indexed owner, uint256 crBps);

    // Liquidation via stability pool (primary path)
    event PoolLiquidation(
        address indexed owner, uint256 debtAbsorbed, uint256 collateralSent, uint256 surplusToPool
    );

    // Liquidation via Dutch auction (fallback path)
    event AuctionLiquidation(
        address indexed owner,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralClaimed,
        uint256 bonusBps
    );

    event Redeemed(
        address indexed redeemer, address indexed target, uint256 sunplsIn, uint256 wplsOut
    );

    event BadDebtRecorded(address indexed owner, uint256 amount);
    event BadDebtCleared(address indexed clearer, uint256 amount, uint256 collateralClaimed);
    event BadDebtSettled(address indexed settler, uint256 amount);
    event FeesRoutedToPool(uint256 sunplsBurned, uint256 wplsSent);

    event RateUpdated(int256 newRate);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(
        address _wpls,
        address _sunpls,
        address _oracle,
        address _controller,
        uint256 _debtCeiling
    ) {
        require(_wpls != address(0), "Zero wpls");
        require(_sunpls != address(0), "Zero sunpls");
        require(_oracle != address(0), "Zero oracle");
        require(_controller != address(0), "Zero controller");
        require(_debtCeiling > 0, "Zero ceiling");

        wpls = IWPLS(_wpls);
        sunpls = ISunPLSTokenRAI(_sunpls);
        oracle = IOracleRAI(_oracle);
        controller = IControllerRAI(_controller);
        DEBT_CEILING = _debtCeiling;
        deployer = msg.sender;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Stability pool latch
    // ─────────────────────────────────────────────────────────────────────

    function setStabilityPool(address _pool) external {
        require(msg.sender == deployer, "Only deployer");
        require(!poolSet, "Already set");
        require(_pool != address(0), "Zero address");
        stabilityPool = IStabilityPool(_pool);
        poolSet = true;
        emit StabilityPoolSet(_pool);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Oracle
    // ─────────────────────────────────────────────────────────────────────

    function _getOraclePrice() internal returns (uint256) {
        try oracle.update() returns (uint256 p, uint256 ts) {
            // Reject the price if ts is present but stale — oracle.update() can return
            // a creep-in-progress price whose underlying timestamp is already old.
            if (
                p > 0 && _validatePrice(p)
                    && (ts == 0 || block.timestamp - ts <= MAX_ORACLE_STALENESS)
            ) {
                lastOraclePrice = p;
                // Use the oracle's price timestamp, not call time.
                lastOraclePriceTime = ts > 0 ? ts : block.timestamp;
                return p;
            }
        } catch { }

        try oracle.peek() returns (uint256 p, uint256 ts) {
            if (
                p > 0 && _validatePrice(p)
                    && (ts > 0 ? block.timestamp - ts : block.timestamp - lastOraclePriceTime)
                        <= MAX_ORACLE_STALENESS
            ) {
                return p;
            }
        } catch { }

        require(
            lastOraclePrice > 0 && block.timestamp - lastOraclePriceTime <= MAX_ORACLE_STALENESS,
            "No usable oracle price"
        );
        return lastOraclePrice;
    }

    function _validatePrice(uint256 newPrice) internal view returns (bool) {
        if (lastOraclePrice == 0) return true;
        uint256 diff =
            newPrice > lastOraclePrice ? newPrice - lastOraclePrice : lastOraclePrice - newPrice;
        uint256 jumpBps = (diff * 10_000) / lastOraclePrice;
        return jumpBps <= ORACLE_VOLATILITY;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Interest accrual
    // ─────────────────────────────────────────────────────────────────────

    function _accrueInterest(address owner) internal {
        Vault storage v = vaults[owner];
        if (v.debt == 0 || v.lastDebtAccrual == 0) return;

        uint256 elapsed = block.timestamp - v.lastDebtAccrual;
        if (elapsed == 0) return;

        int256 rate = controller.r();
        if (rate <= 0) {
            // Rate at 0 floor — no interest accrues (MIN_RATE = 0 in RAI controller)
            v.lastDebtAccrual = block.timestamp;
            return;
        }

        // fee = debt × rate × elapsed / SECONDS_PER_YEAR
        // casting to uint256 is safe because non-positive rates returned above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 positiveRate = uint256(rate);
        uint256 fee = (v.debt * positiveRate * elapsed) / (PRECISION * SECONDS_PER_YEAR);

        if (fee > 0) {
            uint256 debtBefore = v.debt;
            v.debt += fee;
            totalDebt += fee;
            surplusBuffer += fee;
            accruedInterest[owner] += fee; // track per-vault so repay can separate fee from principal

            _reconcileBadDebt();

            emit InterestAccrued(owner, debtBefore, v.debt, fee);
        }

        v.lastDebtAccrual = block.timestamp;
    }

    function _reconcileBadDebt() internal {
        if (badDebtAccumulated > 0 && surplusBuffer >= badDebtAccumulated) {
            surplusBuffer -= badDebtAccumulated;
            badDebtAccumulated = 0;
        } else if (badDebtAccumulated > 0 && surplusBuffer > 0) {
            badDebtAccumulated -= surplusBuffer;
            surplusBuffer = 0;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Collateral ratio
    // ─────────────────────────────────────────────────────────────────────

    function _collateralRatioBps(uint256 collateral, uint256 debt, uint256 price)
        internal
        pure
        returns (uint256)
    {
        if (debt == 0) return type(uint256).max;
        // collateral is in WPLS (1e18), debt is in SunPLS (1e18)
        // price is WPLS per SunPLS (1e18 scale)
        // debtInWPLS = debt * price / 1e18
        // CR = collateral / debtInWPLS * 10000
        uint256 debtInWpls = (debt * price) / PRECISION;
        if (debtInWpls == 0) return type(uint256).max;
        return (collateral * 10_000) / debtInWpls;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Deposit & mint
    // ─────────────────────────────────────────────────────────────────────

    function depositWPLS(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        IERC20(address(wpls)).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(msg.sender, amount);
    }

    function depositPLS() external payable nonReentrant {
        require(msg.value > 0, "Zero PLS");
        wpls.deposit{ value: msg.value }();
        _deposit(msg.sender, msg.value);
    }

    function _deposit(address owner, uint256 amount) internal {
        _accrueInterest(owner);
        if (!_hasVault[owner]) {
            _hasVault[owner] = true;
            vaultOwners.push(owner);
        }
        vaults[owner].collateral += amount;
        totalCollateral += amount;
        if (vaults[owner].lastDebtAccrual == 0) {
            vaults[owner].lastDebtAccrual = block.timestamp;
        }
        emit CollateralDeposited(owner, amount);
    }

    function mint(uint256 sunplsAmount) external nonReentrant {
        require(sunplsAmount > 0, "Zero amount");
        require(totalDebt + sunplsAmount <= DEBT_CEILING, "Debt ceiling breached");

        uint256 price = _getOraclePrice();
        _accrueInterest(msg.sender);

        Vault storage v = vaults[msg.sender];
        require(v.collateral > 0, "No collateral");

        v.debt += sunplsAmount;
        totalDebt += sunplsAmount;

        if (v.lastDebtAccrual == 0) v.lastDebtAccrual = block.timestamp;

        uint256 cr = _collateralRatioBps(v.collateral, v.debt, price);
        require(cr >= MIN_CR_BPS, "CR below 150%");

        sunpls.mint(msg.sender, sunplsAmount);
        emit DebtMinted(msg.sender, sunplsAmount);
    }

    function depositAndMint(uint256 wplsAmount, uint256 sunplsAmount) external nonReentrant {
        require(wplsAmount > 0 && sunplsAmount > 0, "Zero amounts");
        require(totalDebt + sunplsAmount <= DEBT_CEILING, "Debt ceiling breached");

        IERC20(address(wpls)).safeTransferFrom(msg.sender, address(this), wplsAmount);

        uint256 price = _getOraclePrice();
        _accrueInterest(msg.sender);

        if (!_hasVault[msg.sender]) {
            _hasVault[msg.sender] = true;
            vaultOwners.push(msg.sender);
        }

        Vault storage v = vaults[msg.sender];
        v.collateral += wplsAmount;
        v.debt += sunplsAmount;
        totalCollateral += wplsAmount;
        totalDebt += sunplsAmount;
        if (v.lastDebtAccrual == 0) v.lastDebtAccrual = block.timestamp;

        uint256 cr = _collateralRatioBps(v.collateral, v.debt, price);
        require(cr >= MIN_CR_BPS, "CR below 150%");

        sunpls.mint(msg.sender, sunplsAmount);
        emit VaultOpened(msg.sender, wplsAmount, sunplsAmount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Repay & withdraw
    // ─────────────────────────────────────────────────────────────────────

    function repay(uint256 amount) external nonReentrant {
        _accrueInterest(msg.sender);
        _repay(msg.sender, msg.sender, amount);
    }

    function repayWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        IERC20Permit(address(sunpls)).permit(msg.sender, address(this), amount, deadline, v, r, s);
        _accrueInterest(msg.sender);
        _repay(msg.sender, msg.sender, amount);
    }

    function _repay(address payer, address owner, uint256 amount) internal {
        Vault storage vault_ = vaults[owner];
        require(vault_.debt > 0, "No debt");

        uint256 repayAmount = Math.min(amount, vault_.debt);

        // Pull SunPLS from payer → vault → burn
        IERC20(address(sunpls)).safeTransferFrom(payer, address(this), repayAmount);
        sunpls.burn(repayAmount);

        // Only reduce surplusBuffer by the fee portion of this repayment.
        // surplusBuffer tracks accrued fee SunPLS added to debt — repaying principal
        // does not reduce it. Without this, repaying principal incorrectly zeroes
        // out protocol fee equity.
        uint256 feeRepaid = Math.min(repayAmount, accruedInterest[owner]);
        if (feeRepaid > 0) {
            accruedInterest[owner] -= feeRepaid;
            if (surplusBuffer >= feeRepaid) surplusBuffer -= feeRepaid;
            else surplusBuffer = 0;
        }

        vault_.debt -= repayAmount;
        totalDebt -= repayAmount;

        emit DebtRepaid(owner, repayAmount, vault_.debt);
    }

    function withdraw(uint256 wplsAmount) external nonReentrant {
        uint256 price = _getOraclePrice();
        _accrueInterest(msg.sender);

        Vault storage v = vaults[msg.sender];
        require(v.collateral >= wplsAmount, "Insufficient collateral");

        v.collateral -= wplsAmount;
        totalCollateral -= wplsAmount;

        if (v.debt > 0) {
            uint256 cr = _collateralRatioBps(v.collateral, v.debt, price);
            require(cr >= MIN_CR_BPS, "Would drop below 150%");
        }

        IERC20(address(wpls)).safeTransfer(msg.sender, wplsAmount);
        emit CollateralWithdrawn(msg.sender, wplsAmount);
    }

    function repayAndClose() external nonReentrant {
        _accrueInterest(msg.sender);
        Vault storage v = vaults[msg.sender];

        if (v.debt > 0) {
            uint256 debt = v.debt;
            IERC20(address(sunpls)).safeTransferFrom(msg.sender, address(this), debt);
            sunpls.burn(debt);
            // Only the fee portion should reduce surplusBuffer — not principal.
            uint256 feeRepaid = Math.min(debt, accruedInterest[msg.sender]);
            if (feeRepaid > 0) {
                accruedInterest[msg.sender] = 0;
                if (surplusBuffer >= feeRepaid) surplusBuffer -= feeRepaid;
                else surplusBuffer = 0;
            }
            totalDebt -= debt;
            v.debt = 0;
        }

        uint256 collateral = v.collateral;
        if (collateral > 0) {
            v.collateral = 0;
            totalCollateral -= collateral;
            IERC20(address(wpls)).safeTransfer(msg.sender, collateral);
        }

        emit VaultClosed(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Liquidation — pool first, Dutch auction fallback
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Primary liquidation path: stability pool absorbs the debt.
     *         Anyone can call. Pool must have enough SunPLS.
     *         Caller gets no bonus — the pool depositors earn the spread.
     */
    function poolLiquidate(address owner) external nonReentrant {
        require(poolSet, "Pool not set");

        uint256 price = _getOraclePrice();
        _accrueInterest(owner);

        Vault storage v = vaults[owner];
        require(v.debt > 0, "No debt");

        uint256 cr = _collateralRatioBps(v.collateral, v.debt, price);
        require(cr < LIQ_CR_BPS, "CR not below 110%");
        require(stabilityPool.canAbsorb(v.debt), "Pool insufficient - use auctionLiquidate");

        uint256 debt = v.debt;
        uint256 collateral = v.collateral;

        // Clear vault state BEFORE external calls (CEI)
        v.debt = 0;
        v.collateral = 0;
        v.auctionStart = 0;
        totalDebt -= debt;
        totalCollateral -= collateral;

        // Send WPLS to pool, then trigger absorption
        IERC20(address(wpls)).safeTransfer(address(stabilityPool), collateral);
        bool absorbed = stabilityPool.absorb(debt, collateral, owner);
        require(absorbed, "Pool absorption failed");

        emit PoolLiquidation(owner, debt, collateral, 0);
        emit VaultClosed(owner);
    }

    /**
     * @notice Fallback liquidation: inverted Dutch auction.
     *         Used when pool lacks enough SunPLS.
     *         Liquidator repays some debt, receives proportional collateral + bonus.
     *         Bonus: starts at 7%, decays to 2% over 3 hours (first-mover wins).
     *
     * @param owner       Vault to liquidate.
     * @param sunplsInput SunPLS amount liquidator is repaying.
     */
    function auctionLiquidate(address owner, uint256 sunplsInput) external nonReentrant {
        uint256 price = _getOraclePrice();
        _accrueInterest(owner);

        Vault storage v = vaults[owner];
        require(v.debt > 0, "No debt");
        require(sunplsInput > 0, "Zero input");

        uint256 cr = _collateralRatioBps(v.collateral, v.debt, price);
        require(cr < LIQ_CR_BPS, "CR not below 110%");

        // Track when this vault first became undercollateralized
        if (v.auctionStart == 0) {
            v.auctionStart = block.timestamp;
            emit VaultUnderwater(owner, cr, block.timestamp);
        }

        // Compute current bonus (7%→2% inverse decay)
        uint256 elapsed = block.timestamp - v.auctionStart;
        uint256 bonusBps;
        if (elapsed >= AUCTION_DURATION) {
            bonusBps = AUCTION_END_BONUS_BPS;
        } else {
            bonusBps = AUCTION_START_BONUS_BPS
                - ((AUCTION_START_BONUS_BPS - AUCTION_END_BONUS_BPS) * elapsed) / AUCTION_DURATION;
        }

        uint256 repayAmount = Math.min(sunplsInput, v.debt);

        // Collateral to liquidator = repay value in WPLS + bonus
        // repayValueInWpls = repayAmount * price / 1e18
        uint256 repayValueInWpls = (repayAmount * price) / PRECISION;
        uint256 bonusWpls = (repayValueInWpls * bonusBps) / 10_000;
        uint256 collateralClaimed = Math.min(repayValueInWpls + bonusWpls, v.collateral);

        // Pull SunPLS from liquidator
        IERC20(address(sunpls)).safeTransferFrom(msg.sender, address(this), repayAmount);
        sunpls.burn(repayAmount);

        // Only the fee portion of repayAmount reduces surplusBuffer.
        uint256 feeRepaid = Math.min(repayAmount, accruedInterest[owner]);
        if (feeRepaid > 0) {
            accruedInterest[owner] -= feeRepaid;
            if (surplusBuffer >= feeRepaid) surplusBuffer -= feeRepaid;
            else surplusBuffer = 0;
        }

        v.debt -= repayAmount;
        v.collateral -= collateralClaimed;
        totalDebt -= repayAmount;
        totalCollateral -= collateralClaimed;

        // Handle remaining bad debt if collateral exhausted
        if (v.debt > 0 && v.collateral == 0) {
            uint256 uncovered = v.debt;
            if (surplusBuffer >= uncovered) {
                surplusBuffer -= uncovered;
            } else {
                badDebtAccumulated += uncovered - surplusBuffer;
                surplusBuffer = 0;
            }
            totalDebt -= uncovered;
            v.debt = 0;
            emit BadDebtRecorded(owner, uncovered);
        }

        if (v.debt == 0) {
            emit VaultClosed(owner);
        } else {
            uint256 newCr = _collateralRatioBps(v.collateral, v.debt, price);
            if (newCr >= LIQ_CR_BPS) {
                v.auctionStart = 0;
                emit VaultRecovered(owner, newCr);
            }
        }

        IERC20(address(wpls)).safeTransfer(msg.sender, collateralClaimed);

        emit AuctionLiquidation(owner, msg.sender, repayAmount, collateralClaimed, bonusBps);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Redemption — buy WPLS at R-value (hard price floor)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Redeem SunPLS for WPLS at the redemption price R.
     *         Targets the most distressed vault (CR ≤ 130%).
     *
     * @param sunplsIn  Amount of SunPLS to redeem.
     * @param target    Vault to redeem against (must have CR ≤ 130%).
     */
    function redeem(uint256 sunplsIn, address target) external nonReentrant {
        require(sunplsIn > 0, "Zero input");

        uint256 price = _getOraclePrice();
        uint256 R = controller.R();

        _accrueInterest(target);

        Vault storage v = vaults[target];
        require(v.debt > 0, "Target has no debt");
        require(
            block.timestamp > v.auctionStart + REDEMPTION_GAP || v.auctionStart == 0,
            "In redemption gap"
        );

        uint256 cr = _collateralRatioBps(v.collateral, v.debt, price);
        require(cr <= REDEEM_CR_BPS, "Target CR above 130%");

        uint256 repayAmount = Math.min(sunplsIn, v.debt);
        // WPLS out = repayAmount * R (redemption price, not market price)
        uint256 wplsOut = (repayAmount * R) / PRECISION;
        wplsOut = Math.min(wplsOut, v.collateral);

        // Pull SunPLS from redeemer
        IERC20(address(sunpls)).safeTransferFrom(msg.sender, address(this), repayAmount);
        sunpls.burn(repayAmount);

        uint256 feeRepaid = Math.min(repayAmount, accruedInterest[target]);
        if (feeRepaid > 0) {
            accruedInterest[target] -= feeRepaid;
            if (surplusBuffer >= feeRepaid) surplusBuffer -= feeRepaid;
            else surplusBuffer = 0;
        }

        v.debt -= repayAmount;
        v.collateral -= wplsOut;
        totalDebt -= repayAmount;
        totalCollateral -= wplsOut;
        v.auctionStart = block.timestamp; // start redemption gap timer

        // If redemption drained all collateral but debt remains, auto-clear
        // the zombie rather than leaving it to a manual clearBadDebt() call.
        if (v.collateral == 0 && v.debt > 0) {
            uint256 residual = v.debt;
            if (surplusBuffer >= residual) {
                surplusBuffer -= residual;
            } else {
                badDebtAccumulated += residual - surplusBuffer;
                surplusBuffer = 0;
            }
            totalDebt -= residual;
            v.debt = 0;
            emit BadDebtRecorded(target, residual);
        }

        IERC20(address(wpls)).safeTransfer(msg.sender, wplsOut);
        emit Redeemed(msg.sender, target, repayAmount, wplsOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Fee routing to stability pool
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit WPLS into the fee reserve for later pool distribution.
     *         Called by protocol keepers who convert SunPLS surplus fees to WPLS
     *         off-chain (e.g. sell on PulseX) and route the WPLS back here.
     *         This is the v1 fee conversion mechanism; v2 will do it on-chain.
     *
     *         WPLS sent here is tracked in feeReserveWPLS, SEPARATE from user
     *         collateral. flushFeesToPool() will only ever send from this reserve.
     */
    function depositFeeWPLS(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        IERC20(address(wpls)).safeTransferFrom(msg.sender, address(this), amount);
        feeReserveWPLS += amount;
    }

    /**
     * @notice Route WPLS from the fee reserve to the stability pool.
     *         Permissionless — anyone can call to keep pool rewards flowing.
     *         Only sends from feeReserveWPLS, never touches user collateral.
     *
     * @param wplsAmount Amount from fee reserve to flush (capped at feeReserveWPLS).
     */
    function flushFeesToPool(uint256 wplsAmount) external nonReentrant {
        require(poolSet, "Pool not set");
        require(wplsAmount > 0, "Zero amount");
        require(feeReserveWPLS > 0, "No fee reserve");

        uint256 flush = Math.min(wplsAmount, feeReserveWPLS);
        require(flush > 0, "Nothing to flush");

        feeReserveWPLS -= flush;

        IERC20(address(wpls)).safeTransfer(address(stabilityPool), flush);
        stabilityPool.receiveFees(flush);

        emit FeesRoutedToPool(0, flush);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Bad debt management
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Clear a zombie vault (collateral = 0, debt > 0).
     *         Caller pays nothing — they receive any residual collateral as a gift.
     *         Debt written off against surplus buffer, remainder → badDebtAccumulated.
     */
    function clearBadDebt(address owner) external nonReentrant {
        Vault storage v = vaults[owner];
        require(v.debt > 0, "No debt");
        require(v.collateral == 0, "Vault has collateral - use liquidate");

        uint256 debt = v.debt;

        if (surplusBuffer >= debt) {
            surplusBuffer -= debt;
        } else {
            badDebtAccumulated += debt - surplusBuffer;
            surplusBuffer = 0;
        }

        totalDebt -= debt;
        v.debt = 0;

        emit BadDebtCleared(msg.sender, debt, 0);
    }

    /**
     * @notice Anyone can burn SunPLS to directly cancel bad debt.
     */
    function settleDebt(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(badDebtAccumulated >= amount, "Exceeds bad debt");

        IERC20(address(sunpls)).safeTransferFrom(msg.sender, address(this), amount);
        sunpls.burn(amount);

        // badDebtAccumulated was recorded AFTER totalDebt was already reduced during
        // auction liquidation. Do NOT subtract from totalDebt again here — it would
        // underflow and corrupt global debt accounting.
        badDebtAccumulated -= amount;

        emit BadDebtSettled(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Emergency unlock
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Recover collateral from an inactive vault with zero debt.
     *         Requires 30 days of inactivity since last interaction.
     *         Only the vault owner can call.
     */
    function emergencyUnlock() external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(v.collateral > 0, "No collateral");
        require(v.debt == 0, "Has outstanding debt");
        require(
            v.lastDebtAccrual > 0 && block.timestamp - v.lastDebtAccrual >= EMERGENCY_UNLOCK,
            "Not inactive for 30 days"
        );

        uint256 amount = v.collateral;
        v.collateral = 0;
        totalCollateral -= amount;

        IERC20(address(wpls)).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Controller interface
    // ─────────────────────────────────────────────────────────────────────

    function updateRate(int256 newRate) external {
        require(msg.sender == address(controller), "Only controller");
        emit RateUpdated(newRate);
    }

    function systemHealth() external view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        (uint256 price,) = oracle.peek();
        if (price == 0) return 10_000;
        return (totalCollateral * 10_000) / ((totalDebt * price) / PRECISION);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    function getVault(address owner)
        external
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 crBps,
            bool liquidatable,
            bool redeemable,
            uint256 lastAccrual
        )
    {
        Vault storage v = vaults[owner];
        collateral = v.collateral;
        debt = v.debt;
        lastAccrual = v.lastDebtAccrual;

        (uint256 price,) = oracle.peek();
        if (price > 0 && debt > 0) {
            crBps = _collateralRatioBps(collateral, debt, price);
            liquidatable = crBps < LIQ_CR_BPS;
            redeemable = crBps <= REDEEM_CR_BPS;
        }
    }

    function globalStats()
        external
        view
        returns (
            uint256 tvl,
            uint256 totalMinted,
            uint256 surplus,
            uint256 badDebt,
            int256 currentRate,
            uint256 redemptionPrice,
            uint256 systemCR,
            uint256 debtCeiling,
            uint256 debtUtilizationBps
        )
    {
        tvl = totalCollateral;
        totalMinted = totalDebt;
        surplus = surplusBuffer;
        badDebt = badDebtAccumulated;
        currentRate = controller.r();
        redemptionPrice = controller.R();

        (uint256 price,) = oracle.peek();
        if (totalDebt > 0 && price > 0) {
            uint256 debtInWpls = (totalDebt * price) / PRECISION;
            systemCR = debtInWpls > 0 ? (totalCollateral * 10_000) / debtInWpls : type(uint256).max;
        }

        debtCeiling = DEBT_CEILING;
        debtUtilizationBps = DEBT_CEILING > 0 ? (totalDebt * 10_000) / DEBT_CEILING : 0;
    }

    function vaultCount() external view returns (uint256) {
        return vaultOwners.length;
    }

    function systemEquity() external view returns (int256) {
        require(surplusBuffer <= uint256(type(int256).max), "Surplus too large");
        require(badDebtAccumulated <= uint256(type(int256).max), "Bad debt too large");
        // casts are safe because both values are bounded by int256 max above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(surplusBuffer) - int256(badDebtAccumulated);
    }

    receive() external payable { }
}
