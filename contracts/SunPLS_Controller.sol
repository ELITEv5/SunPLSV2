// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║        ProjectUSD Experimental (SunPLS)Controller v4.3 — ELITE TEAM6 ║
 * ║        Resilient Proportional Controller (SPEC v1-Aligned)           ║
 * ║                                                                      ║
 * ║   Autonomous proportional controller for ProjectUSD stability        ║
 * ║   • Proportional control with deadband + δr_max limiter              ║
 * ║   • 4-mode oracle degradation — cannot be permanently blocked        ║
 * ║   • Linear K decay on stale prices — conservative, not sticky        ║
 * ║   • R updates only on fresh oracle price                             ║
 * ║   • R movement capped at 10% per epoch                               ║
 * ║   • Vault failure never blocks epoch                                 ║
 * ║   • Immutable, permissionless, zero governance                       ║
 * ║   • SPEC ref: Ch.3, Ch.5.3, Invariants I1–I12                        ║
 * ║                                                                      ║
 * ║   CHANGELOG v4.3:                                                    ║
 * ║   • Fixed _previewPrice() always returning fresh=false.              ║
 * ║     Previously, previewNextEpoch() always predicted Mode B           ║
 * ║     (degraded K, R not moving) even when the oracle was healthy      ║
 * ║     and triggerEpoch() would execute a full Mode A epoch. Root       ║
 * ║     cause: _previewPrice() is a view function and can only call      ║
 * ║     peek(), which maps to Mode B. Fix: use oracle.isHealthy() as a   ║
 * ║     view-compatible Mode A proxy. If isHealthy() returns true,       ║
 * ║     _previewPrice() returns (peek price, fresh=true, mode=0, K)      ║
 * ║     matching real Mode A behavior. Fallback to Mode B/C/D unchanged. ║
 * ║                                                                      ║
 * ║   CHANGELOG v4.2:                                                    ║
 * ║   • Removed _vault constructor parameter. vault is now set via       ║
 * ║     setVault(address) — a one-time latch callable only by the        ║
 * ║     deployer. After setVault() is called, vaultSet latches true      ║
 * ║     permanently and the function reverts for all future callers      ║
 * ║     including the deployer. Eliminates Controller ↔ Vault circular   ║
 * ║     deployment dependency without requiring nonce prediction.        ║
 * ║   • triggerEpoch() requires vaultSet before executing.               ║
 * ║   • deployer stored as immutable — set once at construction.         ║
 * ║   • VaultSet(address vault) event emitted on latch.                  ║
 * ║   • Post-latch security identical to v4.1 immutable design.          ║
 * ║                                                                      ║
 * ║   CHANGELOG v4.1:                                                    ║
 * ║   • Mode B (_resolvePrice peek fallback): no longer resets           ║
 * ║     lastKnownPTime to block.timestamp. Price age now correctly       ║
 * ║     reflects elapsed time since last confirmed fresh (Mode A) read.  ║
 * ║     K-decay in Modes B and C is now accurate. Only initializes       ║
 * ║     lastKnownPTime on the very first call if never set by Mode A.    ║
 * ║   • _previewPrice() now mirrors real _resolvePrice() degradation:    ║
 * ║     peek result → Mode B (fresh=false, K-decayed). Preview no        ║
 * ║     longer incorrectly predicts R movement during oracle fallback.   ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                        SYSTEM INVARIANTS
 * ═══════════════════════════════════════════════════════════════════════
 *
 * I1.  Rate Bounds:      MIN_RATE ≤ r ≤ MAX_RATE at all times
 * I2.  Rate Stability:   |Δr| ≤ DELTA_R_MAX per epoch (before clamp)
 * I3.  R Damping:        R moves ≤ ALPHA × |P - R| per epoch
 * I4.  R Floor:          R ≥ R_FLOOR always (prevents division by zero)
 * I5.  R Cap:            R moves ≤ MAX_R_MOVE_BPS (10%) per epoch
 * I6.  R Freshness:      R only updates when oracle price is fresh (Mode A)
 * I7.  Closed Loop:      Only input = P (oracle). Only output = r (vault).
 * I8.  Determinism:      Same P → same r. No randomness. No governance.
 * I9.  Deadband:         No rate change if ε ≤ DEADBAND (0.1%)
 * I10. Monotonicity:     Sustained P > R → r increases. P < R → r decreases.
 * I11. Immutability:     No owner. No pause. No upgrade. No override.
 * I12. Liveness:         Oracle failure NEVER permanently blocks epochs.
 * I13. Vault Resilience: Vault revert NEVER permanently blocks epochs.
 * I14. Vault Latch:      vault address set exactly once via setVault().
 *                        Permanently immutable after latch closes.
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                     ORACLE DEGRADATION MODES
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Mode A — Fresh price  [oracle.update() returns P > 0]
 *   effectiveK = K (100% gain)
 *   R updates toward P
 *   lastKnownP and lastKnownPTime both updated
 *   Normal full control loop
 *
 * Mode B — Peek fallback  [update() fails, oracle.peek() returns P > 0]
 *   effectiveK = K × (1 - age/MAX_P_AGE)  ← linear decay
 *   age = time since last Mode A (lastKnownPTime NOT reset here)
 *   lastKnownP updated to peek value; lastKnownPTime unchanged
 *   R does NOT update
 *   Rate still adjusts, conservatively
 *
 * Mode C — Stored fallback  [both calls fail, lastKnownP age ≤ MAX_P_AGE]
 *   effectiveK = K × (1 - age/MAX_P_AGE)  ← same linear decay
 *   age continues from same lastKnownPTime baseline as Mode B
 *   R does NOT update
 *   Rate still adjusts, increasingly conservatively as price ages
 *
 * Mode D — Dead oracle  [no usable price at all]
 *   r frozen at last value
 *   R unchanged
 *   Epoch still advances — system never permanently stalls
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                   DEPLOYMENT SEQUENCE (v4.2)
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   Step 1: Deploy Token        (no vault arg)
 *   Step 2: Deploy Oracle       (pair, wpls, token)
 *   Step 3: Deploy Controller   (oracle, initialR, epochDuration, k, alpha)
 *   Step 4: Deploy Vault        (wpls, token, oracle, controller)
 *   Step 5: token.setVault(vault)       ← one tx, latches forever
 *   Step 6: controller.setVault(vault)  ← one tx, latches forever
 *
 *   No nonce prediction. No session discipline. Steps 5+6 any order.
 *
 * ═══════════════════════════════════════════════════════════════════════
 *                   RECOMMENDED DEPLOYMENT PARAMETERS
 * ═══════════════════════════════════════════════════════════════════════
 *
 *   EPOCH_DURATION = 3600        (1 hour — responsive, not twitchy)
 *   K              = 1e15        (0.1% gain — 1% depeg → 0.1% rate Δ)
 *   ALPHA          = 5e15        (0.5% damping — R tracks P slowly)
 *   initialR       = oracle.lastPrice() at deploy time
 *
 * ═══════════════════════════════════════════════════════════════════════
 */

interface IProjectUSDVault {
    function updateRate(int256 newRate) external;
    function systemHealth() external view returns (uint256);
}

interface IProjectUSDOracle {
    function update() external returns (uint256 price, uint256 timestamp);
    function peek()   external view   returns (uint256 price, uint256 timestamp);
    function isHealthy() external view returns (bool);
}

contract ProjectUSDController {

    // ─────────────────────────────────────────────────────────────────────
    // Deployer — immutable, used only to gate setVault()
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Deployer address. Only power: call setVault() once.
    ///         Zero ongoing authority after vault is set.
    address private immutable deployer;

    // ─────────────────────────────────────────────────────────────────────
    // Vault — one-time latch (v4.2)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The vault this controller pushes rates to.
    ///         address(0) until setVault() is called.
    ///         Immutable in practice — cannot be changed after latch closes.
    IProjectUSDVault public vault;

    /// @notice True once setVault() has been called. Permanently latched.
    bool public vaultSet;

    // ─────────────────────────────────────────────────────────────────────
    // Immutable oracle + tunable params (set once at construction)
    // ─────────────────────────────────────────────────────────────────────

    IProjectUSDOracle public immutable oracle;

    /// @notice Seconds between epochs. Recommended: 3600 (1 hour).
    uint256 public immutable EPOCH_DURATION;

    /// @notice Proportional gain. Recommended: 1e15 (0.1%).
    uint256 public immutable K;

    /// @notice R damping factor. Recommended: 5e15 (0.5%).
    uint256 public immutable ALPHA;

    // ─────────────────────────────────────────────────────────────────────
    // Locked constants
    // ─────────────────────────────────────────────────────────────────────

    uint256 private constant PRECISION = 1e18;

    uint256 public constant DEADBAND    = 1e15;
    int256  public constant DELTA_R_MAX = 5e14;
    int256  public constant MIN_RATE    = -5e16;
    int256  public constant MAX_RATE    = 20e16;
    uint256 public constant R_FLOOR     = 1e18;
    uint256 public constant MAX_P_AGE   = 24 hours;
    uint256 public constant MAX_R_MOVE_BPS             = 1000;
    uint256 public constant EMERGENCY_HEALTH_THRESHOLD = 120;

    // ─────────────────────────────────────────────────────────────────────
    // Mutable state
    // ─────────────────────────────────────────────────────────────────────

    uint256 public R;
    int256  public r;

    uint256 public lastEpochTime;
    uint256 public epochCount;

    /// @notice Price from last confirmed Mode A (fresh oracle.update()) read.
    uint256 public lastKnownP;

    /// @notice Timestamp of last confirmed Mode A read.
    ///         This is the anchor for K-decay in Modes B and C.
    ///         ONLY updated when oracle.update() returns a valid price.
    ///         Mode B (peek fallback) does NOT reset this — intentional.
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

    /// @notice Emitted once when vault address is permanently set.
    event VaultSet(address indexed vault);

    event EpochTriggered(
        uint256 indexed epochNumber,
        uint256 timestamp,
        uint256 priceP,
        uint256 redemptionR,
        int256  newRate,
        uint256 epsilon,
        bool    limiterHit,
        uint8   oracleMode,
        uint256 effectiveKBps
    );

    event EpochFrozen(
        uint256 indexed epochNumber,
        uint256 timestamp
    );

    event VaultUpdateFailed(
        uint256 indexed epochNumber,
        int256  attemptedRate
    );

    event EmergencyRate(
        uint256 indexed epochNumber,
        uint256 timestamp,
        uint256 vaultHealth,
        int256  forcedRate
    );

    event OracleFallback(
        uint256 indexed epochNumber,
        uint8   mode,
        uint256 priceUsed,
        uint256 priceAge,
        uint256 effectiveKBps
    );

    // ─────────────────────────────────────────────────────────────────────
    // Constructor — vault address NOT required here (v4.2)
    // ─────────────────────────────────────────────────────────────────────

    constructor(
        address _oracle,
        uint256 _initialR,
        uint256 _epochDuration,
        uint256 _k,
        uint256 _alpha
    ) {
        require(_oracle        != address(0),           "Zero oracle address");
        require(_epochDuration >= 600  && _epochDuration <= 86400, "Epoch: 10min to 24h");
        require(_k     >= 1e13 && _k     <= 1e16,       "K: 0.001% to 1%");
        require(_alpha >= 1e13 && _alpha <= 1e16,       "Alpha: 0.001% to 1%");
        require(_initialR >= R_FLOOR,                   "Initial R below floor");

        deployer = msg.sender;
        oracle   = IProjectUSDOracle(_oracle);

        R             = _initialR;
        r             = 0;
        lastEpochTime = block.timestamp;

        EPOCH_DURATION = _epochDuration;
        K              = _k;
        ALPHA          = _alpha;

        // Seed price buffer from oracle at deploy — counts as Mode A seed
        // so lastKnownPTime is set correctly for decay calculations from genesis.
        try IProjectUSDOracle(_oracle).peek() returns (uint256 p, uint256 ts) {
            if (p > 0) {
                lastKnownP     = p;
                lastKnownPTime = ts > 0 ? ts : block.timestamp;
            }
        } catch {}
    }

    // ─────────────────────────────────────────────────────────────────────
    // One-time vault latch (v4.2)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Set the vault address. Callable exactly once by the deployer.
     *
     * @dev Called after Vault is deployed (Step 6 of deployment sequence).
     *      Once called, vaultSet latches true permanently. The deployer
     *      has no further authority over this contract.
     *
     *      Security: vault = address(0) until this is called.
     *      triggerEpoch() requires vaultSet, so the controller is inert
     *      until the vault is connected. This window is safe — no liquidity
     *      or SunPLS exists between deploy and latch.
     *
     * @param _vault Address of the deployed SunPLSVault contract.
     */
    function setVault(address _vault) external {
        require(msg.sender == deployer, "Only deployer");
        require(!vaultSet,              "Vault already set");
        require(_vault != address(0),   "Zero vault address");

        vault    = IProjectUSDVault(_vault);
        vaultSet = true;

        emit VaultSet(_vault);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Oracle price resolution — 4-mode degradation
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Returns the best available price and the effective K to use.
     *
     * fresh=true only for Mode A. R must only be updated when fresh=true.
     *
     * KEY INVARIANT (v4.1 fix):
     *   lastKnownPTime is ONLY updated in Mode A (live oracle.update()).
     *   Mode B (peek fallback) updates lastKnownP (the price value) but
     *   does NOT reset lastKnownPTime. This means K-decay in Modes B and C
     *   both measure age from the same baseline — the last real oracle read.
     */
    function _resolvePrice()
        internal
        returns (
            uint256 P,
            bool    fresh,
            uint8   mode,
            uint256 effectiveK
        )
    {
        // ── Mode A: live price from oracle ───────────────────────────────
        try oracle.update() returns (uint256 p, uint256 ts) {
            if (p > 0) {
                lastKnownP     = p;
                lastKnownPTime = ts > 0 ? ts : block.timestamp;
                return (p, true, 0, K);
            }
        } catch {}

        // ── Mode B: stale price from peek() ─────────────────────────────
        try oracle.peek() returns (uint256 p, uint256) {
            if (p > 0) {
                if (lastKnownPTime == 0) lastKnownPTime = block.timestamp;

                uint256 age    = block.timestamp - lastKnownPTime;
                uint256 kDecay = _decayedK(age);
                uint256 kBps   = (kDecay * 10_000) / K;

                lastKnownP = p;

                emit OracleFallback(epochCount + 1, 1, p, age, kBps);
                return (p, false, 1, kDecay);
            }
        } catch {}

        // ── Mode C: stored price from Controller buffer ──────────────────
        if (lastKnownP > 0) {
            uint256 age = block.timestamp - lastKnownPTime;
            if (age <= MAX_P_AGE) {
                uint256 kDecay = _decayedK(age);
                uint256 kBps   = (kDecay * 10_000) / K;
                emit OracleFallback(epochCount + 1, 2, lastKnownP, age, kBps);
                return (lastKnownP, false, 1, kDecay);
            }
        }

        // ── Mode D: no usable price ──────────────────────────────────────
        return (0, false, 2, 0);
    }

    /**
     * @dev Linear K decay by price age.
     *      effectiveK = K × (MAX_P_AGE - age) / MAX_P_AGE
     *      Returns minimum 1 (not 0) so formula never divides by zero downstream.
     */
    function _decayedK(uint256 age) internal view returns (uint256) {
        if (age >= MAX_P_AGE) return 1;
        return K - (K * age) / MAX_P_AGE;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core control loop
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Trigger a new control epoch. Permissionless — callable by anyone.
     *         Cannot be permanently blocked by oracle or vault failures.
     *
     * @dev Requires vaultSet (v4.2) — controller is inert until vault is linked.
     */
    function triggerEpoch() external {
        require(vaultSet, "Vault not set: call setVault() first");
        require(block.timestamp >= lastEpochTime + EPOCH_DURATION, "Epoch not ready");

        // 1. Emergency health check
        try vault.systemHealth() returns (uint256 health) {
            if (health < EMERGENCY_HEALTH_THRESHOLD) {
                r = MAX_RATE;
                emergencyEpochs++;
                try vault.updateRate(r) {} catch {
                    emit VaultUpdateFailed(epochCount + 1, r);
                }
                lastEpochTime = block.timestamp;
                epochCount++;
                emit EmergencyRate(epochCount, block.timestamp, health, r);
                return;
            }
        } catch {}

        // 2. Resolve price with full fallback chain
        (uint256 P, bool fresh, uint8 oracleMode, uint256 effectiveK) = _resolvePrice();

        // ── Mode D: no price — freeze rate, advance epoch ────────────────
        if (P == 0) {
            frozenEpochs++;
            lastEpochTime = block.timestamp;
            epochCount++;
            emit EpochFrozen(epochCount, block.timestamp);
            return;
        }

        if (oracleMode > 0) oracleFallbacks++;

        // 3. Compute deviation ε = |P − R| / R
        uint256 epsilon;
        bool    priceAbove;

        if (P > R) {
            epsilon    = ((P - R) * PRECISION) / R;
            priceAbove = true;
        } else {
            epsilon    = ((R - P) * PRECISION) / R;
            priceAbove = false;
        }

        // 4. Deadband — ignore noise
        if (epsilon <= DEADBAND) {
            deadbandSkips++;
            lastEpochTime = block.timestamp;
            epochCount++;
            emit EpochTriggered(
                epochCount, block.timestamp, P, R, r,
                epsilon, false, oracleMode,
                fresh ? 10_000 : (effectiveK * 10_000) / K
            );
            return;
        }

        // 5. Proportional rate adjustment
        int256 deltaR     = int256((effectiveK * epsilon) / PRECISION);
        bool   limiterHit = false;

        if (deltaR > DELTA_R_MAX) {
            deltaR     = DELTA_R_MAX;
            limiterHit = true;
            limiterHits++;
        }

        // 6. Apply direction
        int256 newRate = priceAbove ? r + deltaR : r - deltaR;

        // 7. Clamp to absolute bounds (Invariant I1)
        if (newRate > MAX_RATE) newRate = MAX_RATE;
        if (newRate < MIN_RATE) newRate = MIN_RATE;

        r = newRate;

        // 8. Dampen R toward P — fresh price only (Invariants I3, I6)
        if (fresh) {
            _stepR(P);
        }

        // 9. Push rate to vault — failure logged, never fatal (Invariant I13)
        try vault.updateRate(r) {} catch {
            emit VaultUpdateFailed(epochCount + 1, r);
        }

        // 10. Advance epoch
        lastEpochTime = block.timestamp;
        epochCount++;

        uint256 kBps = fresh ? 10_000 : (effectiveK * 10_000) / K;
        emit EpochTriggered(
            epochCount, block.timestamp, P, R, r,
            epsilon, limiterHit, oracleMode, kBps
        );
    }

    /**
     * @dev Step R toward P by ALPHA, capped at MAX_R_MOVE_BPS per epoch.
     */
    function _stepR(uint256 P) internal {
        int256 delta  = int256(P) - int256(R);
        int256 rAdj   = (delta * int256(ALPHA)) / int256(PRECISION);

        uint256 maxMove = (R * MAX_R_MOVE_BPS) / 10_000;
        if (rAdj >  int256(maxMove)) rAdj =  int256(maxMove);
        if (rAdj < -int256(maxMove)) rAdj = -int256(maxMove);

        if (rAdj > 0) {
            R += uint256(rAdj);
        } else if (rAdj < 0) {
            uint256 decrease = uint256(-rAdj);
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
            int256  currentRate,
            uint256 lastEpoch,
            uint256 timeUntilNext,
            uint256 epochs,
            uint256 limiterHitCount,
            uint256 deadbandSkipCount,
            uint256 oracleFallbackCount,
            uint256 frozenEpochCount,
            bool    canTrigger,
            uint256 storedPrice,
            uint256 storedPriceAge
        )
    {
        redemptionValue     = R;
        currentRate         = r;
        lastEpoch           = lastEpochTime;
        timeUntilNext       = lastEpochTime + EPOCH_DURATION > block.timestamp
            ? lastEpochTime + EPOCH_DURATION - block.timestamp
            : 0;
        epochs              = epochCount;
        limiterHitCount     = limiterHits;
        deadbandSkipCount   = deadbandSkips;
        oracleFallbackCount = oracleFallbacks;
        frozenEpochCount    = frozenEpochs;
        canTrigger          = block.timestamp >= lastEpochTime + EPOCH_DURATION;
        storedPrice         = lastKnownP;
        storedPriceAge      = lastKnownP > 0 ? block.timestamp - lastKnownPTime : 0;
    }

    function previewNextEpoch()
        external
        view
        returns (
            int256  expectedRate,
            uint256 expectedR,
            uint256 expectedEpsilon,
            bool    wouldTriggerLimiter,
            bool    inDeadband,
            bool    wouldFreeze,
            uint8   expectedOracleMode,
            uint256 effectiveKBps
        )
    {
        (uint256 P, bool fresh, uint8 mode, uint256 effK) = _previewPrice();

        if (P == 0) {
            return (r, R, 0, false, false, true, 2, 0);
        }

        expectedOracleMode = mode;
        effectiveKBps      = fresh ? 10_000 : (effK * 10_000) / K;

        (uint256 epsilon, bool priceAbove) = _computeEpsilon(P);
        expectedEpsilon = epsilon;

        if (epsilon <= DEADBAND) {
            return (r, R, epsilon, false, true, false, mode, effectiveKBps);
        }

        (expectedRate, wouldTriggerLimiter) = _previewRate(effK, epsilon, priceAbove);

        expectedR   = fresh ? _previewR(P) : R;
        inDeadband  = false;
        wouldFreeze = false;
    }

    /**
     * @dev View-only price resolution for previewNextEpoch().
     *
     * v4.3 fix: _previewPrice() now correctly predicts Mode A when the oracle
     * is healthy. Previously, all paths returned fresh=false because the only
     * view-compatible oracle call is peek() which maps to Mode B. This caused
     * previewNextEpoch() to always predict "R will not move, degraded K" even
     * when triggerEpoch() would execute a full Mode A epoch.
     *
     * Fix: oracle.isHealthy() is a view function. If it returns true, the oracle
     * has a fresh price and update() would succeed — predict Mode A (fresh=true,
     * full K, R moves). If isHealthy() returns false, fall through to Mode B/C/D
     * exactly as before.
     *
     * Not 100% guaranteed to match real execution (isHealthy uses 2x MAX_PRICE_AGE
     * window, update() could still fail for other reasons) but dramatically more
     * accurate than always predicting Mode B regardless of oracle health.
     */
    function _previewPrice()
        internal
        view
        returns (uint256 P, bool fresh, uint8 mode, uint256 effK)
    {
        // Mode A proxy: oracle.isHealthy() is view-compatible.
        // If healthy, peek() price is fresh — predict Mode A behavior.
        try oracle.isHealthy() returns (bool healthy) {
            if (healthy) {
                try oracle.peek() returns (uint256 p, uint256) {
                    if (p > 0) {
                        return (p, true, 0, K);
                    }
                } catch {}
            }
        } catch {}

        // Mode B: oracle not healthy but peek() still returns a price
        try oracle.peek() returns (uint256 p, uint256) {
            if (p > 0) {
                uint256 pTime  = lastKnownPTime > 0 ? lastKnownPTime : block.timestamp;
                uint256 age    = block.timestamp - pTime;
                uint256 kDecay = age >= MAX_P_AGE ? 1 : K - (K * age) / MAX_P_AGE;
                return (p, false, 1, kDecay);
            }
        } catch {}

        // Mode C: stored price
        if (lastKnownP > 0) {
            uint256 age = lastKnownPTime > 0 ? block.timestamp - lastKnownPTime : 0;
            if (age <= MAX_P_AGE) {
                uint256 kDecay = age >= MAX_P_AGE ? 1 : K - (K * age) / MAX_P_AGE;
                return (lastKnownP, false, 1, kDecay);
            }
        }

        // Mode D
        return (0, false, 2, 0);
    }

    function _computeEpsilon(uint256 P)
        internal
        view
        returns (uint256 epsilon, bool priceAbove)
    {
        if (P > R) {
            epsilon    = ((P - R) * PRECISION) / R;
            priceAbove = true;
        } else {
            epsilon    = ((R - P) * PRECISION) / R;
            priceAbove = false;
        }
    }

    function _previewRate(uint256 effK, uint256 epsilon, bool priceAbove)
        internal
        view
        returns (int256 expectedRate, bool wouldTriggerLimiter)
    {
        int256 deltaR = int256((effK * epsilon) / PRECISION);
        wouldTriggerLimiter = deltaR > DELTA_R_MAX;
        if (deltaR > DELTA_R_MAX) deltaR = DELTA_R_MAX;
        expectedRate = priceAbove ? r + deltaR : r - deltaR;
        if (expectedRate > MAX_RATE) expectedRate = MAX_RATE;
        if (expectedRate < MIN_RATE) expectedRate = MIN_RATE;
    }

    function _previewR(uint256 P)
        internal
        view
        returns (uint256 expectedR)
    {
        int256 delta    = int256(P) - int256(R);
        int256 rAdj     = (delta * int256(ALPHA)) / int256(PRECISION);
        uint256 maxMove = (R * MAX_R_MOVE_BPS) / 10_000;
        if (rAdj >  int256(maxMove)) rAdj =  int256(maxMove);
        if (rAdj < -int256(maxMove)) rAdj = -int256(maxMove);
        if (rAdj > 0) {
            expectedR = R + uint256(rAdj);
        } else if (rAdj < 0) {
            uint256 decrease = uint256(-rAdj);
            expectedR = R > decrease ? R - decrease : R_FLOOR;
        } else {
            expectedR = R;
        }
        if (expectedR < R_FLOOR) expectedR = R_FLOOR;
    }

    function oracleStatus()
        external
        view
        returns (
            bool    oracleReportsHealthy,
            bool    controllerHasStoredPrice,
            uint256 storedPriceAge,
            bool    storedPriceUsable,
            uint256 currentEffectiveKBps,
            uint8   expectedMode
        )
    {
        try oracle.isHealthy() returns (bool h) {
            oracleReportsHealthy = h;
        } catch {
            oracleReportsHealthy = false;
        }

        controllerHasStoredPrice = lastKnownP > 0;
        storedPriceAge           = lastKnownP > 0 ? block.timestamp - lastKnownPTime : 0;
        storedPriceUsable        = lastKnownP > 0 && storedPriceAge <= MAX_P_AGE;

        if (oracleReportsHealthy) {
            expectedMode         = 0;
            currentEffectiveKBps = 10_000;
        } else if (storedPriceUsable) {
            expectedMode = 1;
            uint256 kDecay = storedPriceAge >= MAX_P_AGE
                ? 1
                : K - (K * storedPriceAge) / MAX_P_AGE;
            currentEffectiveKBps = (kDecay * 10_000) / K;
        } else {
            expectedMode         = 2;
            currentEffectiveKBps = 0;
        }
    }

    function getParameters()
        external
        view
        returns (
            uint256 epochDuration,
            uint256 kGain,
            uint256 alphaDamping,
            uint256 deadband,
            int256  deltaRMax,
            int256  minRate,
            int256  maxRate,
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
}
