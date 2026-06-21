// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║        SunPLS RAI — Controller v1.0                                  ║
 * ║        Sticky Proportional Controller (PulseChain RAI)               ║
 * ║                                                                      ║
 * ║   Philosophy: THE MARKET CHASES R. R DOES NOT CHASE THE MARKET.     ║
 * ║                                                                      ║
 * ║   This is the core departure from SunPLS v2 and the fix for RAI's   ║
 * ║   primary weakness. In RAI, the redemption price drifted toward      ║
 * ║   market price too willingly. Users could never be sure what R       ║
 * ║   would be next week. Confidence in R collapsed.                     ║
 * ║                                                                      ║
 * ║   Here: ALPHA is 10x smaller (5e14 vs 5e15). R moves at most        ║
 * ║   0.005% per epoch during a 1% deviation. A sustained 10% market    ║
 * ║   deviation causes R to drift ~0.12%/day. Users know R is stable    ║
 * ║   week-to-week. The market is expected to converge to R, not the    ║
 * ║   other way around.                                                  ║
 * ║                                                                      ║
 * ║   WHAT CHANGED FROM v4.3                                             ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   ✓ ALPHA: 5e14 (was 5e15) — R is 10× stickier                      ║
 * ║   ✓ MIN_RATE: 0 (was -5e16) — NO NEGATIVE RATES EVER                ║
 * ║   ✓ MAX_RATE: 30e16 (was 20e16) — stronger contraction headroom     ║
 * ║   ✓ MAX_R_MOVE_BPS: 100 (was 1000) — R can move max 1% per epoch    ║
 * ║   ✓ EPOCH_DURATION: 1800s recommended (was 3600) — more responsive  ║
 * ║                                                                      ║
 * ║   WHY NO NEGATIVE RATES                                              ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   RAI's negative rates (paying borrowers to hold positions) were     ║
 * ║   the single most confusing feature. "I get paid to borrow?" drew   ║
 * ║   mercenary capital that fled the moment rates normalized.           ║
 * ║   Sustained market-below-R scenarios are handled differently here:  ║
 * ║   Rate falls to 0% (free borrowing). Existing borrowers profitably  ║
 * ║   repay (their SunPLS buys back more WPLS than they put up). Supply ║
 * ║   contracts naturally. No negative rate confusion.                  ║
 * ║                                                                      ║
 * ║   WHAT'S PRESERVED FROM v4.3 (UNCHANGED)                            ║
 * ║   ─────────────────────────────────────────────────────────────────  ║
 * ║   ✓ 4-mode oracle degradation (A/B/C/D)                              ║
 * ║   ✓ Linear K decay on stale prices                                   ║
 * ║   ✓ Proportional control with deadband                               ║
 * ║   ✓ DELTA_R_MAX limiter                                              ║
 * ║   ✓ Emergency health override at vault CR < 120%                    ║
 * ║   ✓ Immutable, permissionless, zero governance (I11)                 ║
 * ║   ✓ Vault latch (one-time setVault)                                  ║
 * ║   ✓ All 14 system invariants                                         ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                        SYSTEM INVARIANTS
 * ═══════════════════════════════════════════════════════════════════════
 *
 * I1.  Rate Bounds:      MIN_RATE (0) ≤ r ≤ MAX_RATE (30%) at all times
 * I2.  Rate Stability:   |Δr| ≤ DELTA_R_MAX per epoch (before clamp)
 * I3.  R Damping:        R moves ≤ ALPHA × |P - R| per epoch
 * I4.  R Floor:          R ≥ R_FLOOR always (prevents division by zero)
 * I5.  R Cap:            R moves ≤ MAX_R_MOVE_BPS (1%) per epoch
 * I6.  R Freshness:      R only updates when oracle price is fresh (Mode A)
 * I7.  Closed Loop:      Only input = P (oracle). Only output = r (vault).
 * I8.  Determinism:      Same P → same r. No randomness. No governance.
 * I9.  Deadband:         No rate change if ε ≤ DEADBAND (0.1%)
 * I10. Monotonicity:     Sustained P > R → r increases. P < R → r decreases (to 0 floor).
 * I11. Immutability:     No owner. No pause. No upgrade. No override.
 * I12. Liveness:         Oracle failure NEVER permanently blocks epochs.
 * I13. Vault Resilience: Vault revert NEVER permanently blocks epochs.
 * I14. Vault Latch:      vault address set exactly once via setVault().
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                     ORACLE DEGRADATION MODES (unchanged)
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Mode A — Fresh price  → full K, R may update
 * Mode B — Peek fallback → K decayed by price age, R frozen
 * Mode C — Stored fallback → K continues decaying, R frozen
 * Mode D — Dead oracle → r frozen, epoch still advances
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                   DEPLOYMENT PARAMETERS (recommended)
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   EPOCH_DURATION = 1800        (30 min — more responsive than v2)
 *   K              = 1e15        (0.1% proportional gain — unchanged)
 *   ALPHA          = 5e14        (0.05% damping — 10× stickier than v2)
 *   initialR       = spot price of SunPLS/WPLS pair at deploy
 *
 * ═══════════════════════════════════════════════════════════════════════
 */

interface IVault {
    function updateRate(int256 newRate) external;
    function systemHealth() external view returns (uint256);
}

interface IOracle {
    function update() external returns (uint256 price, uint256 timestamp);
    function peek() external view returns (uint256 price, uint256 timestamp);
    function isHealthy() external view returns (bool);
}

contract SunPLSControllerRAI {
    // ─────────────────────────────────────────────────────────────────────
    // Vault latch
    // ─────────────────────────────────────────────────────────────────────

    address private immutable deployer;

    IVault public vault;
    bool public vaultSet;

    // ─────────────────────────────────────────────────────────────────────
    // Oracle + tunable params (immutable after construction)
    // ─────────────────────────────────────────────────────────────────────

    IOracle public immutable oracle;

    uint256 public immutable EPOCH_DURATION;
    uint256 public immutable K;
    uint256 public immutable ALPHA;

    // ─────────────────────────────────────────────────────────────────────
    // Constants — RAI changes marked ★
    // ─────────────────────────────────────────────────────────────────────

    uint256 private constant PRECISION = 1e18;

    uint256 public constant DEADBAND = 1e15; // 0.1% — unchanged
    int256 public constant DELTA_R_MAX = 5e14; // unchanged
    uint256 private constant DELTA_R_MAX_UINT = 5e14;
    int256 public constant MIN_RATE = 0; // ★ WAS: -5e16 (-5%). No negative rates.
    int256 public constant MAX_RATE = 30e16; // ★ WAS: 20e16 (20%). More contraction headroom.
    uint256 public constant R_FLOOR = 1e15; // 0.001 WPLS minimum (prevents div/zero)
    uint256 public constant MAX_P_AGE = 24 hours; // unchanged
    uint256 public constant MAX_R_MOVE_BPS = 100; // ★ WAS: 1000 (10%). Now 1% max per epoch.
    uint256 public constant EMERGENCY_HEALTH_THRESHOLD = 12000; // 120% in bps — systemHealth() returns bps

    // ─────────────────────────────────────────────────────────────────────
    // Mutable state
    // ─────────────────────────────────────────────────────────────────────

    uint256 public R; // Redemption price: WPLS per SunPLS (1e18 scale)
    int256 public r; // Current stability fee (annualized, 1e18 = 100%)

    uint256 public lastEpochTime;
    uint256 public epochCount;

    uint256 public lastKnownP;
    uint256 public lastKnownPTime;

    // Telemetry
    uint256 public limiterHits;
    uint256 public deadbandSkips;
    uint256 public oracleFallbacks;
    uint256 public frozenEpochs;
    uint256 public emergencyEpochs;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event VaultSet(address indexed vault);

    event EpochTriggered(
        uint256 indexed epochNumber,
        uint256 timestamp,
        uint256 priceP,
        uint256 redemptionR,
        int256 newRate,
        uint256 epsilon,
        bool limiterHit,
        uint8 oracleMode,
        uint256 effectiveKBps
    );

    event EpochFrozen(uint256 indexed epochNumber, uint256 timestamp);

    event VaultUpdateFailed(uint256 indexed epochNumber, int256 attemptedRate);

    event EmergencyRate(
        uint256 indexed epochNumber, uint256 timestamp, uint256 vaultHealth, int256 forcedRate
    );

    event OracleFallback(
        uint256 indexed epochNumber,
        uint8 mode,
        uint256 priceUsed,
        uint256 priceAge,
        uint256 effectiveKBps
    );

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @param _oracle        SunPLS/WPLS oracle address.
     * @param _initialR      Starting redemption price (WPLS per SunPLS, 1e18 scale).
     *                       Use oracle.peek() price at deploy time.
     * @param _epochDuration Seconds between epochs. Recommended: 1800 (30 min).
     * @param _k             Proportional gain. Recommended: 1e15 (0.1%).
     * @param _alpha         R damping. Recommended: 5e14 (0.05% — 10× stickier than v2).
     */
    constructor(
        address _oracle,
        uint256 _initialR,
        uint256 _epochDuration,
        uint256 _k,
        uint256 _alpha
    ) {
        require(_oracle != address(0), "Zero oracle");
        require(_epochDuration >= 600 && _epochDuration <= 86400, "Epoch: 10min-24h");
        require(_k >= 1e13 && _k <= 1e16, "K: 0.001%-1%");
        require(_alpha >= 1e13 && _alpha <= 5e15, "Alpha: 0.001%-0.5%");
        require(_initialR >= R_FLOOR, "Initial R below floor");

        deployer = msg.sender;
        oracle = IOracle(_oracle);
        R = _initialR;
        r = 0;
        lastEpochTime = block.timestamp;
        EPOCH_DURATION = _epochDuration;
        K = _k;
        ALPHA = _alpha;

        try IOracle(_oracle).peek() returns (uint256 p, uint256 ts) {
            if (p > 0) {
                lastKnownP = p;
                lastKnownPTime = ts > 0 ? ts : block.timestamp;
            }
        } catch { }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Vault latch
    // ─────────────────────────────────────────────────────────────────────

    function setVault(address _vault) external {
        require(msg.sender == deployer, "Only deployer");
        require(!vaultSet, "Already set");
        require(_vault != address(0), "Zero address");
        vault = IVault(_vault);
        vaultSet = true;
        emit VaultSet(_vault);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Oracle resolution — 4-mode degradation (identical to v4.3)
    // ─────────────────────────────────────────────────────────────────────

    function _resolvePrice()
        internal
        returns (uint256 P, bool fresh, uint8 mode, uint256 effectiveK)
    {
        // Mode A — only accepted as fresh if the price timestamp is current.
        // oracle.update() can return a mid-creep price whose underlying ts is stale;
        // accepting it as Mode A would let R move on old price data.
        try oracle.update() returns (uint256 p, uint256 ts) {
            if (p > 0 && (ts == 0 || block.timestamp - ts <= MAX_P_AGE)) {
                lastKnownP = p;
                lastKnownPTime = ts > 0 ? ts : block.timestamp;
                return (p, true, 0, K);
            }
        } catch { }

        // Mode B
        try oracle.peek() returns (uint256 p, uint256) {
            if (p > 0) {
                if (lastKnownPTime == 0) lastKnownPTime = block.timestamp;
                uint256 age = block.timestamp - lastKnownPTime;
                uint256 kDecay = _decayedK(age);
                lastKnownP = p;
                emit OracleFallback(epochCount + 1, 1, p, age, (kDecay * 10_000) / K);
                return (p, false, 1, kDecay);
            }
        } catch { }

        // Mode C
        if (lastKnownP > 0) {
            uint256 age = block.timestamp - lastKnownPTime;
            if (age <= MAX_P_AGE) {
                uint256 kDecay = _decayedK(age);
                emit OracleFallback(epochCount + 1, 2, lastKnownP, age, (kDecay * 10_000) / K);
                return (lastKnownP, false, 1, kDecay);
            }
        }

        // Mode D
        return (0, false, 2, 0);
    }

    function _decayedK(uint256 age) internal view returns (uint256) {
        if (age >= MAX_P_AGE) return 1;
        return K - (K * age) / MAX_P_AGE;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core control loop
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Trigger a control epoch. Permissionless.
     *
     * @dev Rate logic change vs v4.3:
     *      MIN_RATE = 0: when P < R, r decreases toward 0 and stops there.
     *      There are no negative rates. The natural incentive to close
     *      (profitable at P < R) contracts supply without negative rate confusion.
     */
    function triggerEpoch() external {
        require(vaultSet, "Vault not latched");
        require(block.timestamp >= lastEpochTime + EPOCH_DURATION, "Epoch not ready");

        // Emergency: force max rate if system health critical
        try vault.systemHealth() returns (uint256 health) {
            if (health < EMERGENCY_HEALTH_THRESHOLD) {
                r = MAX_RATE;
                emergencyEpochs++;
                try vault.updateRate(r) { }
                catch {
                    emit VaultUpdateFailed(epochCount + 1, r);
                }
                lastEpochTime = block.timestamp;
                epochCount++;
                emit EmergencyRate(epochCount, block.timestamp, health, r);
                return;
            }
        } catch { }

        (uint256 P, bool fresh, uint8 oracleMode, uint256 effectiveK) = _resolvePrice();

        if (P == 0) {
            frozenEpochs++;
            lastEpochTime = block.timestamp;
            epochCount++;
            emit EpochFrozen(epochCount, block.timestamp);
            return;
        }

        if (oracleMode > 0) oracleFallbacks++;

        // Compute deviation ε
        uint256 epsilon;
        bool priceAbove;

        if (P > R) {
            epsilon = ((P - R) * PRECISION) / R;
            priceAbove = true;
        } else {
            epsilon = ((R - P) * PRECISION) / R;
            priceAbove = false;
        }

        // Deadband
        if (epsilon <= DEADBAND) {
            deadbandSkips++;
            lastEpochTime = block.timestamp;
            epochCount++;
            emit EpochTriggered(
                epochCount,
                block.timestamp,
                P,
                R,
                r,
                epsilon,
                false,
                oracleMode,
                fresh ? 10_000 : (effectiveK * 10_000) / K
            );
            return;
        }

        // Proportional rate adjustment
        uint256 rawDeltaR = Math.mulDiv(effectiveK, epsilon, PRECISION);
        // casting to int256 is safe because the value is capped below int256 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 deltaR = rawDeltaR > DELTA_R_MAX_UINT ? DELTA_R_MAX : int256(rawDeltaR);
        bool limiterHit = false;

        if (rawDeltaR > DELTA_R_MAX_UINT) {
            limiterHit = true;
            limiterHits++;
        }

        int256 newRate = priceAbove ? r + deltaR : r - deltaR;

        // Clamp — MIN_RATE = 0, no negative rates
        if (newRate > MAX_RATE) newRate = MAX_RATE;
        if (newRate < MIN_RATE) newRate = MIN_RATE;

        r = newRate;

        // Step R toward P — slowly (MAX_R_MOVE_BPS = 1%), fresh price only
        if (fresh) {
            _stepR(P);
        }

        try vault.updateRate(r) { }
        catch {
            emit VaultUpdateFailed(epochCount + 1, r);
        }

        lastEpochTime = block.timestamp;
        epochCount++;

        emit EpochTriggered(
            epochCount,
            block.timestamp,
            P,
            R,
            r,
            epsilon,
            limiterHit,
            oracleMode,
            fresh ? 10_000 : (effectiveK * 10_000) / K
        );
    }

    /**
     * @dev Nudge R toward P, capped at MAX_R_MOVE_BPS (1%) per epoch.
     *
     *      With ALPHA = 5e14 (0.05%) and a 1% deviation:
     *        rAdj = 0.01 * R * 0.0005 = 0.000005 * R = 0.0005% per epoch
     *      At 30-min epochs, R drifts ~0.024%/day at 1% sustained deviation.
     *      Meaningful drift only during multi-week sustained dislocations.
     */
    function _stepR(uint256 P) internal {
        uint256 maxMove = (R * MAX_R_MOVE_BPS) / 10_000;

        if (P > R) {
            uint256 increase = Math.mulDiv(P - R, ALPHA, PRECISION);
            if (increase > maxMove) increase = maxMove;
            R += increase;
        } else if (P < R) {
            uint256 decrease = Math.mulDiv(R - P, ALPHA, PRECISION);
            if (decrease > maxMove) decrease = maxMove;
            R = R > decrease ? R - decrease : R_FLOOR;
        }

        if (R < R_FLOOR) R = R_FLOOR;
    }

    // ─────────────────────────────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────────────────────────────

    function getCurrentState()
        external
        view
        returns (
            uint256 redemptionValue,
            int256 currentRate,
            uint256 lastEpoch,
            uint256 timeUntilNext,
            uint256 epochs,
            uint256 limiterHitCount,
            uint256 deadbandSkipCount,
            uint256 oracleFallbackCount,
            uint256 frozenEpochCount,
            bool canTrigger,
            uint256 storedPrice,
            uint256 storedPriceAge
        )
    {
        redemptionValue = R;
        currentRate = r;
        lastEpoch = lastEpochTime;
        timeUntilNext = lastEpochTime + EPOCH_DURATION > block.timestamp
            ? lastEpochTime + EPOCH_DURATION - block.timestamp
            : 0;
        epochs = epochCount;
        limiterHitCount = limiterHits;
        deadbandSkipCount = deadbandSkips;
        oracleFallbackCount = oracleFallbacks;
        frozenEpochCount = frozenEpochs;
        canTrigger = block.timestamp >= lastEpochTime + EPOCH_DURATION;
        storedPrice = lastKnownP;
        storedPriceAge = lastKnownP > 0 ? block.timestamp - lastKnownPTime : 0;
    }

    function previewNextEpoch()
        external
        view
        returns (
            int256 expectedRate,
            uint256 expectedR,
            uint256 expectedEpsilon,
            bool wouldTriggerLimiter,
            bool inDeadband,
            bool wouldFreeze,
            uint8 expectedOracleMode,
            uint256 effectiveKBps
        )
    {
        (uint256 P, bool fresh, uint8 mode, uint256 effK) = _previewPrice();

        if (P == 0) return (r, R, 0, false, false, true, 2, 0);

        expectedOracleMode = mode;
        effectiveKBps = fresh ? 10_000 : (effK * 10_000) / K;

        uint256 epsilon;
        bool priceAbove;
        if (P > R) {
            epsilon = ((P - R) * PRECISION) / R;
            priceAbove = true;
        } else {
            epsilon = ((R - P) * PRECISION) / R;
        }
        expectedEpsilon = epsilon;

        if (epsilon <= DEADBAND) return (r, R, epsilon, false, true, false, mode, effectiveKBps);

        uint256 rawDeltaRv = Math.mulDiv(effK, epsilon, PRECISION);
        // casting to int256 is safe because the value is capped below int256 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 deltaRv = rawDeltaRv > DELTA_R_MAX_UINT ? DELTA_R_MAX : int256(rawDeltaRv);
        wouldTriggerLimiter = rawDeltaRv > DELTA_R_MAX_UINT;
        expectedRate = priceAbove ? r + deltaRv : r - deltaRv;
        if (expectedRate > MAX_RATE) expectedRate = MAX_RATE;
        if (expectedRate < MIN_RATE) expectedRate = MIN_RATE;

        expectedR = fresh ? _previewR(P) : R;
        inDeadband = false;
        wouldFreeze = false;
    }

    function _previewPrice()
        internal
        view
        returns (uint256 P, bool fresh, uint8 mode, uint256 effK)
    {
        try oracle.isHealthy() returns (bool healthy) {
            if (healthy) {
                try oracle.peek() returns (uint256 p, uint256 ts) {
                    if (p > 0 && (ts == 0 || block.timestamp - ts <= MAX_P_AGE)) {
                        return (p, true, 0, K);
                    }
                } catch { }
            }
        } catch { }

        try oracle.peek() returns (uint256 p, uint256 ts) {
            if (p > 0) {
                uint256 pTime =
                    ts > 0 ? ts : (lastKnownPTime > 0 ? lastKnownPTime : block.timestamp);
                uint256 age = block.timestamp - pTime;
                uint256 kDecay = age >= MAX_P_AGE ? 1 : K - (K * age) / MAX_P_AGE;
                return (p, false, 1, kDecay);
            }
        } catch { }

        if (lastKnownP > 0) {
            uint256 age = lastKnownPTime > 0 ? block.timestamp - lastKnownPTime : 0;
            if (age <= MAX_P_AGE) {
                uint256 kDecay = age >= MAX_P_AGE ? 1 : K - (K * age) / MAX_P_AGE;
                return (lastKnownP, false, 1, kDecay);
            }
        }

        return (0, false, 2, 0);
    }

    function _previewR(uint256 P) internal view returns (uint256 expectedR) {
        uint256 maxMove = (R * MAX_R_MOVE_BPS) / 10_000;
        if (P > R) {
            uint256 increase = Math.mulDiv(P - R, ALPHA, PRECISION);
            if (increase > maxMove) increase = maxMove;
            expectedR = R + increase;
        } else if (P < R) {
            uint256 d = Math.mulDiv(R - P, ALPHA, PRECISION);
            if (d > maxMove) d = maxMove;
            expectedR = R > d ? R - d : R_FLOOR;
        } else {
            expectedR = R;
        }
        if (expectedR < R_FLOOR) expectedR = R_FLOOR;
    }

    function getParameters()
        external
        view
        returns (
            uint256 epochDuration,
            uint256 kGain,
            uint256 alphaDamping,
            uint256 deadband,
            int256 deltaRMax,
            int256 minRate,
            int256 maxRate,
            uint256 rFloor,
            uint256 maxPAge,
            uint256 maxRMoveBps
        )
    {
        return (
            EPOCH_DURATION,
            K,
            ALPHA,
            DEADBAND,
            DELTA_R_MAX,
            MIN_RATE,
            MAX_RATE,
            R_FLOOR,
            MAX_P_AGE,
            MAX_R_MOVE_BPS
        );
    }

    function oracleStatus()
        external
        view
        returns (
            bool oracleHealthy,
            bool hasStoredPrice,
            uint256 storedPriceAge,
            bool storedPriceUsable,
            uint256 currentEffectiveKBps,
            uint8 expectedMode
        )
    {
        try oracle.isHealthy() returns (bool h) {
            oracleHealthy = h;
        } catch { }
        hasStoredPrice = lastKnownP > 0;
        storedPriceAge = lastKnownP > 0 ? block.timestamp - lastKnownPTime : 0;
        storedPriceUsable = lastKnownP > 0 && storedPriceAge <= MAX_P_AGE;

        if (oracleHealthy) {
            expectedMode = 0;
            currentEffectiveKBps = 10_000;
        } else if (storedPriceUsable) {
            expectedMode = 1;
            uint256 kDecay = storedPriceAge >= MAX_P_AGE ? 1 : K - (K * storedPriceAge) / MAX_P_AGE;
            currentEffectiveKBps = (kDecay * 10_000) / K;
        } else {
            expectedMode = 2;
            currentEffectiveKBps = 0;
        }
    }
}
