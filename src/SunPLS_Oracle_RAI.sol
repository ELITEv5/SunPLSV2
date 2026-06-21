// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║        SunPLS RAI — Oracle v1.0                                      ║
 * ║        Single-Pair TWAP Oracle (SunPLS/WPLS on PulseX)              ║
 * ║                                                                      ║
 * ║   Identical to SunPLS Oracle v1.2 (no functional changes).          ║
 * ║   Tracks SunPLS/WPLS market price — the P that the Controller       ║
 * ║   compares against R to compute stability fee adjustments.           ║
 * ║                                                                      ║
 * ║   PRICE DIRECTION: WPLS per SunPLS (1e18 scale)                      ║
 * ║   When R = 1e18: 1 SunPLS redeems for 1 WPLS.                       ║
 * ║   When market price P > R: SunPLS trades above redemption value.    ║
 * ║                                                                      ║
 * ║   ANTI-MANIPULATION:                                                 ║
 * ║   • TWAP (60s min window) — flash loan resistant                     ║
 * ║   • Creeping: moves >5% require 3 confirmations + 10% step           ║
 * ║   • 1% tolerance band on creep confirmations (v1.2 fix)              ║
 * ║   • Bootstraps from live reserves at deploy — no magic number        ║
 * ║                                                                      ║
 * ║   Deploy: pool must have liquidity before deploying this oracle.     ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

contract SunPLSOracleRAI {
    IUniswapV2Pair public immutable pair;
    address public immutable wpls;
    address public immutable sunpls;
    bool public immutable wplsIsToken0;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_DEVIATION_BPS = 500; // 5% instant-accept threshold
    uint256 public constant MIN_TWAP_INTERVAL = 60; // seconds, flash loan defense
    uint256 public constant MAX_PRICE_AGE = 300; // 5 min — health window
    uint8 private constant MAX_CONFIRMATIONS = 3;
    uint16 private constant CREEP_STEP_BPS = 1000; // 10% per creep step
    uint16 private constant CANDIDATE_TOLERANCE_BPS = 100; // 1% band

    uint256 public lastPrice;
    uint256 public lastUpdateTimestamp;
    uint256 public lastPriceTimestamp;

    uint256 private priceCumulativeLast;
    uint32 private blockTimestampLast;
    uint256 private pendingPrice;
    uint8 private confirmations;

    event PriceUpdated(uint256 price, uint256 timestamp, bool creeping);

    constructor(address _pair, address _wpls, address _sunpls) {
        require(_pair != address(0) && _wpls != address(0) && _sunpls != address(0), "Zero address");

        pair = IUniswapV2Pair(_pair);
        wpls = _wpls;
        sunpls = _sunpls;

        address t0 = IUniswapV2Pair(_pair).token0();
        address t1 = IUniswapV2Pair(_pair).token1();
        bool _wplsIsToken0 = (t0 == _wpls);
        require(_wplsIsToken0 || t1 == _wpls, "Pair missing WPLS");
        require(t0 == _sunpls || t1 == _sunpls, "Pair missing SunPLS");
        wplsIsToken0 = _wplsIsToken0;

        (,, uint32 ts) = IUniswapV2Pair(_pair).getReserves();
        blockTimestampLast = ts;
        priceCumulativeLast = _wplsIsToken0
            ? IUniswapV2Pair(_pair).price1CumulativeLast()
            : IUniswapV2Pair(_pair).price0CumulativeLast();

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(_pair).getReserves();
        require(r0 > 0 && r1 > 0, "No liquidity at deploy");

        uint256 initialPrice = _wplsIsToken0
            ? (uint256(r0) * PRECISION) / uint256(r1)
            : (uint256(r1) * PRECISION) / uint256(r0);

        require(initialPrice > 0, "Zero initial price");
        lastPrice = initialPrice;
        lastUpdateTimestamp = block.timestamp;
        lastPriceTimestamp = block.timestamp;
    }

    function update() external returns (uint256 price, uint256 timestamp) {
        return _updateIfNeeded();
    }

    function peek() external view returns (uint256 price, uint256 timestamp) {
        return (lastPrice, lastPriceTimestamp);
    }

    function isHealthy() external view returns (bool) {
        return (block.timestamp - lastPriceTimestamp) < (MAX_PRICE_AGE * 2);
    }

    function _updateIfNeeded() internal returns (uint256, uint256) {
        if (block.timestamp - lastUpdateTimestamp < MIN_TWAP_INTERVAL) {
            return (lastPrice, lastPriceTimestamp);
        }

        (uint112 r0, uint112 r1, uint32 tsPair) = pair.getReserves();
        require(r0 > 0 && r1 > 0, "No liquidity");

        uint32 elapsed = uint32(block.timestamp) - blockTimestampLast;
        uint256 newPrice =
            elapsed < MIN_TWAP_INTERVAL ? _spotPrice(r0, r1) : _twapPrice(r0, r1, tsPair, elapsed);

        lastUpdateTimestamp = block.timestamp;
        _applyCreepingOrAccept(newPrice);
        return (lastPrice, lastPriceTimestamp);
    }

    function _spotPrice(uint112 r0, uint112 r1) internal view returns (uint256) {
        return wplsIsToken0
            ? (uint256(r0) * PRECISION) / uint256(r1)
            : (uint256(r1) * PRECISION) / uint256(r0);
    }

    function _twapPrice(uint112 r0, uint112 r1, uint32 tsPair, uint32 elapsed)
        internal
        returns (uint256)
    {
        uint256 cumulative =
            wplsIsToken0 ? pair.price1CumulativeLast() : pair.price0CumulativeLast();

        unchecked {
            uint32 gap = uint32(block.timestamp) - tsPair;
            if (gap > 0) {
                uint256 instantQ112 = wplsIsToken0
                    ? (uint256(r0) << 112) / uint256(r1)
                    : (uint256(r1) << 112) / uint256(r0);
                cumulative += instantQ112 * gap;
            }
        }

        uint256 diff = cumulative - priceCumulativeLast;
        uint256 twap = (diff * PRECISION) / (uint256(elapsed) << 112);

        priceCumulativeLast = cumulative;
        blockTimestampLast = uint32(block.timestamp);
        return twap;
    }

    function _applyCreepingOrAccept(uint256 newPrice) internal {
        if (lastPrice == 0) {
            lastPrice = newPrice;
            lastPriceTimestamp = block.timestamp;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return;
        }

        uint256 diff = newPrice > lastPrice ? newPrice - lastPrice : lastPrice - newPrice;
        uint256 deviationBps = (diff * 10_000) / lastPrice;

        if (deviationBps <= MAX_DEVIATION_BPS) {
            lastPrice = newPrice;
            lastPriceTimestamp = block.timestamp;
            confirmations = 0;
            pendingPrice = 0;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return;
        }

        bool sameCandidate = false;
        if (pendingPrice > 0) {
            uint256 d = newPrice > pendingPrice ? newPrice - pendingPrice : pendingPrice - newPrice;
            sameCandidate = (d * 10_000) / pendingPrice <= CANDIDATE_TOLERANCE_BPS;
        }

        if (sameCandidate) {
            pendingPrice = newPrice;
            confirmations++;
        } else {
            pendingPrice = newPrice;
            confirmations = 1;
        }

        if (confirmations >= MAX_CONFIRMATIONS) {
            uint256 step = pendingPrice > lastPrice
                ? ((pendingPrice - lastPrice) * CREEP_STEP_BPS) / 10_000
                : ((lastPrice - pendingPrice) * CREEP_STEP_BPS) / 10_000;

            lastPrice = pendingPrice > lastPrice ? lastPrice + step : lastPrice - step;

            lastPriceTimestamp = block.timestamp;
            confirmations = 0;
            pendingPrice = 0;
            emit PriceUpdated(lastPrice, block.timestamp, true);
        }
    }

    function getSpotPrice() external view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return lastPrice;
        return _spotPrice(r0, r1);
    }

    function getCreepingState()
        external
        view
        returns (uint256 pending, uint8 confs, bool isCreeping)
    {
        return (pendingPrice, confirmations, pendingPrice > 0);
    }
}
