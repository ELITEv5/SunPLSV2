// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║         SunPLS Oracle v1.2 — ELITE TEAM6                             ║
 * ║         Single-Pair TWAP Oracle for PulseChain                       ║
 * ║                                                                      ║
 * ║   Reads SunPLS/WPLS pair from PulseX                                 ║
 * ║                                                                      ║
 * ║   PRICE DIRECTION: WPLS per SunPLS (1e18 scale)                      ║
 * ║   Example: 100_000e18 = 1 SunPLS costs 100,000 PLS                   ║
 * ║   This matches Controller's R (also WPLS per SunPLS)                 ║
 * ║   ε = |P - R| / R is meaningful only when P and R share units        ║
 * ║                                                                      ║
 * ║   UNISWAP V2 CUMULATIVE PRICE DIRECTION:                             ║
 * ║   price0Cumulative = token1/token0 (in Q112 fixed point)             ║
 * ║   price1Cumulative = token0/token1 (in Q112 fixed point)             ║
 * ║   When wplsIsToken0: we want WPLS/SunPLS = token0/token1             ║
 * ║     → use price1CumulativeLast                                       ║
 * ║   When wplsIsToken1: we want WPLS/SunPLS = token1/token0             ║
 * ║     → use price0CumulativeLast                                       ║
 * ║                                                                      ║
 * ║   ANTI-MANIPULATION:                                                 ║
 * ║   • TWAP (60s window) for manipulation resistance                    ║
 * ║   • Creeping: deviations >5% require 3 confirmations + 10% step      ║
 * ║   • Candidate tolerance band: rolling TWAP windows naturally produce ║
 * ║     slightly different values each call. Confirmations now accumulate║
 * ║     if the new reading is within 1% of pendingPrice, preventing      ║
 * ║     legitimate large moves from stalling indefinitely.               ║
 * ║   • Flash loan defense: MIN_TWAP_INTERVAL between updates            ║
 * ║   • Bootstrap from live reserves (no magic number starting price)    ║
 * ║                                                                      ║
 * ║   CHANGELOG v1.2:                                                    ║
 * ║   • Fixed creeping confirmation stall on large legitimate moves.     ║
 * ║     Previously: confirmations required newPrice == pendingPrice      ║
 * ║     (exact equality). Rolling TWAP windows produce fractionally      ║
 * ║     different values each call (e.g. 40.1e18, 40.2e18, 40.15e18),    ║
 * ║     causing confirmations to reset to 1 on every call. A sustained   ║
 * ║     PLS pump could leave the oracle permanently stuck tracking a     ║
 * ║     stale price, forcing indefinite Controller Mode B/C degradation. ║
 * ║     Fix: CANDIDATE_TOLERANCE_BPS = 100 (1%) tolerance band. Any      ║
 * ║     new TWAP reading within 1% of pendingPrice counts as the same    ║
 * ║     candidate and increments confirmations. Genuine reversals (>1%   ║
 * ║     away from pendingPrice) still reset the counter. pendingPrice    ║
 * ║     updates to the latest reading within the band so it tracks the   ║
 * ║     rolling TWAP accurately.                                         ║
 * ║                                                                      ║
 * ║   CHANGELOG v1.1:                                                    ║
 * ║   • Split lastUpdateTimestamp (call gate) from lastPriceTimestamp    ║
 * ║     (when lastPrice last actually changed). isHealthy() and peek()   ║
 * ║     now use lastPriceTimestamp so health/staleness signals are       ║
 * ║     accurate even during creep confirmation accumulation.            ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                   CREEPING MECHANISM — HOW IT WORKS
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Small moves (≤5%): accepted immediately every call.
 *
 * Large moves (>5%): require confirmation before creeping:
 *
 *   1. First reading above threshold → pendingPrice = newPrice, confirmations = 1
 *   2. Subsequent readings within 1% of pendingPrice → confirmations++
 *      pendingPrice updates to latest reading (tracks rolling TWAP)
 *   3. Reading >1% away from pendingPrice → genuine reversal detected,
 *      pendingPrice = newPrice, confirmations = 1 (fresh start)
 *   4. Once confirmations >= MAX_CONFIRMATIONS (3):
 *      → creep lastPrice by CREEP_STEP_BPS (10%) toward pendingPrice
 *      → reset confirmation state
 *      → repeat until lastPrice converges to pendingPrice
 *
 * Example — PLS pumps 40%:
 *   Call 1: TWAP = 140e18. Deviation 40% > 5%. pending=140e18, conf=1
 *   Call 2: TWAP = 140.2e18. Within 1% of 140e18. pending=140.2e18, conf=2
 *   Call 3: TWAP = 139.9e18. Within 1% of 140.2e18. pending=139.9e18, conf=3
 *   → Creep: lastPrice moves 10% toward 139.9e18
 *   Repeat until converged. Total time: ~(40/10) × 3 × 60s = ~12 minutes.
 *
 * ═══════════════════════════════════════════════════════════════════════
 */

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

contract SunPLSOracleV2 {

    // ─────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────

    IUniswapV2Pair public immutable pair;
    address        public immutable wpls;
    address        public immutable sunpls;

    /// @notice True if WPLS is token0. Determines which accumulator to use.
    bool public immutable wplsIsToken0;

    // ─────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────

    uint256 public constant PRECISION              = 1e18;

    /// @notice Instant-accept threshold: deviations ≤ 5% accepted immediately
    uint256 public constant MAX_DEVIATION_BPS      = 500;

    /// @notice Minimum seconds between oracle calls — flash loan defense
    uint256 public constant MIN_TWAP_INTERVAL      = 60;

    /// @notice Oracle considered unhealthy if lastPrice not changed within this window
    uint256 public constant MAX_PRICE_AGE          = 300;

    /// @notice Confirmations before a large deviation is accepted (via creep)
    uint8   private constant MAX_CONFIRMATIONS     = 3;

    /// @notice Each creep step moves 10% toward the confirmed price
    uint16  private constant CREEP_STEP_BPS        = 1000;

    /// @notice v1.2: Tolerance band for creep candidate matching.
    ///         Rolling TWAP windows naturally produce fractionally different
    ///         values each call. A new reading within 1% of pendingPrice
    ///         is treated as the same candidate and increments confirmations.
    ///         Genuine reversals (deviation > 1% from pendingPrice) reset.
    uint16  private constant CANDIDATE_TOLERANCE_BPS = 100;

    // ─────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Last accepted price in WPLS per SunPLS (1e18 scale)
    uint256 public lastPrice;

    /// @notice Timestamp of last oracle CALL (used as rate-limit gate).
    ///         Advanced on every _updateIfNeeded() invocation regardless
    ///         of whether lastPrice changed. Do not use for staleness checks.
    uint256 public lastUpdateTimestamp;

    /// @notice Timestamp of last actual lastPrice CHANGE (accepted or creep step).
    ///         Used by isHealthy() and peek() for accurate staleness signals.
    ///         Only advances when lastPrice is written.
    uint256 public lastPriceTimestamp;

    /// @notice Cumulative price snapshot for TWAP (Q112 scale)
    uint256 private priceCumulativeLast;

    /// @notice Pair's blockTimestamp at last TWAP snapshot (seconds, wraps at uint32 max)
    uint32  private blockTimestampLast;

    /// @notice Price awaiting creep confirmation (tracks latest reading in the band)
    uint256 private pendingPrice;

    /// @notice Confirmations accumulated for pendingPrice
    uint8   private confirmations;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event PriceUpdated(uint256 price, uint256 timestamp, bool creeping);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @param _pair   PulseX SunPLS/WPLS pair — must have liquidity at deploy
     * @param _wpls   WPLS token address
     * @param _sunpls SunPLS token address
     *
     * @dev Bootstraps lastPrice from live reserves so the oracle starts
     *      at the real market price. The pool must be seeded before this
     *      contract is deployed.
     */
    constructor(address _pair, address _wpls, address _sunpls) {
        require(
            _pair   != address(0) &&
            _wpls   != address(0) &&
            _sunpls != address(0),
            "Zero address"
        );

        pair   = IUniswapV2Pair(_pair);
        wpls   = _wpls;
        sunpls = _sunpls;

        // Verify both tokens are in the pair
        address t0 = IUniswapV2Pair(_pair).token0();
        address t1 = IUniswapV2Pair(_pair).token1();
        bool _wplsIsToken0 = (t0 == _wpls);
        require(_wplsIsToken0 || t1 == _wpls,    "Pair missing WPLS");
        require(t0 == _sunpls  || t1 == _sunpls, "Pair missing SunPLS");
        wplsIsToken0 = _wplsIsToken0;

        // Seed cumulative accumulator
        (, , uint32 ts) = IUniswapV2Pair(_pair).getReserves();
        blockTimestampLast  = ts;
        priceCumulativeLast = _wplsIsToken0
            ? IUniswapV2Pair(_pair).price1CumulativeLast()
            : IUniswapV2Pair(_pair).price0CumulativeLast();

        // Bootstrap from live spot price — pool must have liquidity
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(_pair).getReserves();
        require(r0 > 0 && r1 > 0, "Pool has no liquidity at deploy");

        uint256 initialPrice = _wplsIsToken0
            ? (uint256(r0) * PRECISION) / uint256(r1)
            : (uint256(r1) * PRECISION) / uint256(r0);

        require(initialPrice > 0, "Zero initial price");
        lastPrice           = initialPrice;
        lastUpdateTimestamp = block.timestamp;
        lastPriceTimestamp  = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────
    // External interface — Controller + Vault compatible
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Update oracle and return current price.
     *         Called by Controller each epoch and Vault on mint/liquidate.
     */
    function update() external returns (uint256 price, uint256 timestamp) {
        return _updateIfNeeded();
    }

    /**
     * @notice Read current price without mutating state.
     *         Returns lastPriceTimestamp — the time lastPrice last changed.
     *         Vault uses this for staleness: block.timestamp - ts <= MAX_ORACLE_STALENESS.
     *         Using lastPriceTimestamp here (not lastUpdateTimestamp) ensures the vault's
     *         staleness check reflects actual price age, not just last call time.
     */
    function peek() external view returns (uint256 price, uint256 timestamp) {
        return (lastPrice, lastPriceTimestamp);
    }

    /**
     * @notice True if lastPrice has changed within 2 × MAX_PRICE_AGE.
     *         Uses lastPriceTimestamp so health accurately reflects price
     *         freshness, not just whether update() was recently called.
     */
    function isHealthy() external view returns (bool) {
        return (block.timestamp - lastPriceTimestamp) < (MAX_PRICE_AGE * 2);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal — update logic
    // ─────────────────────────────────────────────────────────────────────

    function _updateIfNeeded() internal returns (uint256, uint256) {
        // Rate-limit gate: MIN_TWAP_INTERVAL between oracle calls.
        // Uses lastUpdateTimestamp (call time) not lastPriceTimestamp (price time)
        // so the gate works regardless of whether the last call changed the price.
        if (block.timestamp - lastUpdateTimestamp < MIN_TWAP_INTERVAL) {
            return (lastPrice, lastPriceTimestamp);
        }

        (uint112 r0, uint112 r1, uint32 tsPair) = pair.getReserves();
        require(r0 > 0 && r1 > 0, "No liquidity");

        uint32 elapsed = uint32(block.timestamp) - blockTimestampLast;

        uint256 newPrice;
        if (elapsed < MIN_TWAP_INTERVAL) {
            newPrice = _spotPrice(r0, r1);
        } else {
            newPrice = _twapPrice(r0, r1, tsPair, elapsed);
        }

        // Advance call gate timestamp BEFORE applying creep so the rate-limit
        // applies even if _applyCreepingOrAccept doesn't change lastPrice.
        lastUpdateTimestamp = block.timestamp;

        _applyCreepingOrAccept(newPrice);
        return (lastPrice, lastPriceTimestamp);
    }

    /**
     * @dev Spot price: WPLS per SunPLS from current reserves.
     */
    function _spotPrice(uint112 r0, uint112 r1) internal view returns (uint256) {
        return wplsIsToken0
            ? (uint256(r0) * PRECISION) / uint256(r1)
            : (uint256(r1) * PRECISION) / uint256(r0);
    }

    /**
     * @dev TWAP price: WPLS per SunPLS from cumulative accumulators.
     */
    function _twapPrice(
        uint112 r0,
        uint112 r1,
        uint32  tsPair,
        uint32  elapsed
    ) internal returns (uint256) {
        uint256 cumulative = wplsIsToken0
            ? pair.price1CumulativeLast()
            : pair.price0CumulativeLast();

        unchecked {
            uint32 gapSinceSync = uint32(block.timestamp) - tsPair;
            if (gapSinceSync > 0) {
                uint256 instantQ112 = wplsIsToken0
                    ? (uint256(r0) << 112) / uint256(r1)
                    : (uint256(r1) << 112) / uint256(r0);
                cumulative += instantQ112 * gapSinceSync;
            }
        }

        uint256 diff = cumulative - priceCumulativeLast;
        uint256 twap = (diff * PRECISION) / (uint256(elapsed) << 112);

        priceCumulativeLast = cumulative;
        blockTimestampLast  = uint32(block.timestamp);

        return twap;
    }

    /**
     * @dev Accept price immediately if deviation ≤ MAX_DEVIATION_BPS.
     *      For larger moves: accumulate MAX_CONFIRMATIONS using a tolerance
     *      band, then creep CREEP_STEP_BPS (10%) toward the confirmed price.
     *
     * v1.2 CHANGE — candidate matching:
     *      Old: confirmations++ only if newPrice == pendingPrice (exact).
     *      New: confirmations++ if newPrice is within CANDIDATE_TOLERANCE_BPS
     *           (1%) of pendingPrice. pendingPrice updates to newPrice so it
     *           tracks the rolling TWAP within the band.
     *
     *      Why: TWAP windows roll forward each call, producing slightly
     *      different values (e.g. 140.1e18 vs 140.2e18) even for a sustained
     *      price. Exact equality never accumulates. The 1% band is tight enough
     *      to reject genuine reversals while wide enough to absorb TWAP drift.
     *
     *      lastPriceTimestamp is ONLY updated when lastPrice actually changes.
     *      lastUpdateTimestamp is updated by _updateIfNeeded() before this call.
     */
    function _applyCreepingOrAccept(uint256 newPrice) internal {
        if (lastPrice == 0) {
            lastPrice          = newPrice;
            lastPriceTimestamp = block.timestamp;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return;
        }

        uint256 diff         = newPrice > lastPrice ? newPrice - lastPrice : lastPrice - newPrice;
        uint256 deviationBps = (diff * 10_000) / lastPrice;

        if (deviationBps <= MAX_DEVIATION_BPS) {
            // Small move — accept immediately, clear pending state
            lastPrice          = newPrice;
            lastPriceTimestamp = block.timestamp;
            confirmations      = 0;
            pendingPrice       = 0;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return;
        }

        // Large move — check if newPrice is within tolerance band of pendingPrice
        // v1.2: tolerance band replaces exact equality check
        bool sameCandidate = false;
        if (pendingPrice > 0) {
            uint256 candidateDiff = newPrice > pendingPrice
                ? newPrice - pendingPrice
                : pendingPrice - newPrice;
            sameCandidate = (candidateDiff * 10_000) / pendingPrice <= CANDIDATE_TOLERANCE_BPS;
        }

        if (sameCandidate) {
            // Within 1% of current candidate — count as confirmation.
            // Update pendingPrice to latest reading so it tracks TWAP drift.
            pendingPrice = newPrice;
            confirmations++;
        } else {
            // Genuine new candidate (reversal or first reading) — reset
            pendingPrice  = newPrice;
            confirmations = 1;
        }

        if (confirmations >= MAX_CONFIRMATIONS) {
            // Creep 10% toward confirmed price
            uint256 step = pendingPrice > lastPrice
                ? ((pendingPrice - lastPrice) * CREEP_STEP_BPS) / 10_000
                : ((lastPrice - pendingPrice) * CREEP_STEP_BPS) / 10_000;

            lastPrice = pendingPrice > lastPrice
                ? lastPrice + step
                : lastPrice - step;

            // Price changed — update price timestamp
            lastPriceTimestamp = block.timestamp;

            confirmations = 0;
            pendingPrice  = 0;
            emit PriceUpdated(lastPrice, block.timestamp, true);
        }

        // NOTE: lastUpdateTimestamp already advanced in _updateIfNeeded().
        // We do NOT touch it here. During confirmation accumulation, lastPrice
        // is unchanged and lastPriceTimestamp correctly remains stale.
    }

    // ─────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Current spot price from reserves (no state change).
    function getSpotPrice() external view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return lastPrice;
        return _spotPrice(r0, r1);
    }

    /// @notice Oracle configuration for on-chain verification.
    function getConfig()
        external
        view
        returns (
            address pairAddress,
            address wplsAddress,
            address sunplsAddress,
            bool    wplsIsToken0Flag,
            uint256 maxDeviationBps,
            uint256 minTwapInterval,
            uint256 maxPriceAge,
            uint256 candidateToleranceBps
        )
    {
        return (
            address(pair),
            wpls,
            sunpls,
            wplsIsToken0,
            MAX_DEVIATION_BPS,
            MIN_TWAP_INTERVAL,
            MAX_PRICE_AGE,
            CANDIDATE_TOLERANCE_BPS
        );
    }

    /// @notice Creeping state for dashboards and monitoring.
    function getCreepingState()
        external
        view
        returns (
            uint256 pending,
            uint8   confirmCount,
            bool    isCreeping
        )
    {
        return (pendingPrice, confirmations, pendingPrice > 0);
    }
}
