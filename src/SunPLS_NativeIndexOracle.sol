// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * @title SunPLS Native Purchasing Power Index
 * @notice Read-only PulseChain-native activity index for SunPLS.
 *
 * The index starts at 1e18 on deploy. Each non-WPLS component is measured as
 * WPLS per unit of that asset, normalized to its deployment price. If the
 * native basket becomes more expensive in WPLS terms, the index rises.
 *
 * This contract does not control R. It is the observation layer that lets the
 * protocol publish and study a PulseChain-native purchasing power target before
 * wiring it into monetary policy.
 */

interface INativeIndexPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

contract SunPLSNativeIndexOracle {
    struct ComponentConfig {
        bytes32 symbol;
        address pair;
        address asset;
        uint16 weightBps;
    }

    struct Component {
        bytes32 symbol;
        INativeIndexPair pair;
        address asset;
        bool assetIsToken0;
        uint16 weightBps;
        uint256 initialPrice;
        uint256 lastPrice;
        uint256 priceCumulativeLast;
        uint32 blockTimestampLast;
        uint256 lastPriceTimestamp;
    }

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_TWAP_INTERVAL = 60;
    uint256 public constant MAX_INDEX_AGE = 2 hours;
    uint256 public constant MAX_INDEX_MOVE_BPS = 100; // accepted index moves <= 1% per update

    address public immutable wpls;
    uint16 public immutable wplsWeightBps;
    uint16 public immutable gasWeightBps;
    uint256 public immutable initialGasPrice;

    Component[] private _components;

    uint256 public lastRawIndex;
    uint256 public lastIndex;
    uint256 public lastGasPrice;
    uint256 public lastIndexTimestamp;

    event ComponentUpdated(bytes32 indexed symbol, uint256 price, uint256 timestamp);
    event NativeIndexUpdated(
        uint256 rawIndex, uint256 acceptedIndex, uint256 timestamp, bool capped
    );

    constructor(
        address _wpls,
        uint16 _wplsWeightBps,
        uint16 _gasWeightBps,
        uint256 _initialGasPrice,
        ComponentConfig[] memory configs
    ) {
        require(_wpls != address(0), "Zero WPLS");
        require(configs.length <= 8, "Too many components");

        wpls = _wpls;
        wplsWeightBps = _wplsWeightBps;
        gasWeightBps = _gasWeightBps;
        initialGasPrice = _initialGasPrice;

        uint256 totalWeight = uint256(_wplsWeightBps) + uint256(_gasWeightBps);
        if (_gasWeightBps > 0) require(_initialGasPrice > 0, "Zero gas baseline");

        for (uint256 i = 0; i < configs.length; i++) {
            ComponentConfig memory cfg = configs[i];
            require(cfg.symbol != bytes32(0), "Missing symbol");
            require(cfg.pair != address(0) && cfg.asset != address(0), "Zero component");
            require(cfg.weightBps > 0, "Zero weight");
            totalWeight += cfg.weightBps;

            INativeIndexPair pair = INativeIndexPair(cfg.pair);
            address token0 = pair.token0();
            address token1 = pair.token1();
            bool assetIsToken0 = token0 == cfg.asset;
            require(assetIsToken0 || token1 == cfg.asset, "Pair missing asset");
            require(token0 == _wpls || token1 == _wpls, "Pair missing WPLS");

            (uint112 r0, uint112 r1, uint32 ts) = pair.getReserves();
            require(r0 > 0 && r1 > 0, "No liquidity");

            uint256 initialPrice = assetIsToken0
                ? (uint256(r1) * PRECISION) / uint256(r0)
                : (uint256(r0) * PRECISION) / uint256(r1);
            require(initialPrice > 0, "Zero initial price");

            uint256 cumulative =
                assetIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();

            _components.push(
                Component({
                    symbol: cfg.symbol,
                    pair: pair,
                    asset: cfg.asset,
                    assetIsToken0: assetIsToken0,
                    weightBps: cfg.weightBps,
                    initialPrice: initialPrice,
                    lastPrice: initialPrice,
                    priceCumulativeLast: cumulative,
                    blockTimestampLast: ts,
                    lastPriceTimestamp: block.timestamp
                })
            );
        }

        require(totalWeight == 10_000, "Weights must total 100%");

        lastRawIndex = PRECISION;
        lastIndex = PRECISION;
        lastGasPrice = _initialGasPrice;
        lastIndexTimestamp = block.timestamp;
    }

    function update() external returns (uint256 rawIndex, uint256 acceptedIndex) {
        rawIndex = _computeUpdatedRawIndex();
        lastRawIndex = rawIndex;

        bool capped;
        (acceptedIndex, capped) = _capIndexMove(lastIndex, rawIndex);
        lastIndex = acceptedIndex;
        lastIndexTimestamp = block.timestamp;

        emit NativeIndexUpdated(rawIndex, acceptedIndex, block.timestamp, capped);
    }

    function peek() external view returns (uint256 index, uint256 timestamp) {
        return (lastIndex, lastIndexTimestamp);
    }

    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    function component(uint256 i)
        external
        view
        returns (
            bytes32 symbol,
            address pair,
            address asset,
            uint16 weightBps,
            uint256 initialPrice,
            uint256 lastPrice,
            uint256 lastPriceTimestamp
        )
    {
        Component storage c = _components[i];
        return (
            c.symbol,
            address(c.pair),
            c.asset,
            c.weightBps,
            c.initialPrice,
            c.lastPrice,
            c.lastPriceTimestamp
        );
    }

    function isHealthy() external view returns (bool) {
        if (block.timestamp - lastIndexTimestamp > MAX_INDEX_AGE) return false;
        for (uint256 i = 0; i < _components.length; i++) {
            if (block.timestamp - _components[i].lastPriceTimestamp > MAX_INDEX_AGE) return false;
        }
        return true;
    }

    function currentRawIndex() external view returns (uint256) {
        uint256 weighted = uint256(wplsWeightBps) * PRECISION;

        for (uint256 i = 0; i < _components.length; i++) {
            Component storage c = _components[i];
            uint256 price = _spotPrice(c);
            weighted += uint256(c.weightBps) * ((price * PRECISION) / c.initialPrice);
        }

        if (gasWeightBps > 0) {
            uint256 gasPrice = block.basefee;
            if (gasPrice == 0) gasPrice = lastGasPrice;
            weighted += uint256(gasWeightBps) * ((gasPrice * PRECISION) / initialGasPrice);
        }

        return weighted / 10_000;
    }

    function _computeUpdatedRawIndex() internal returns (uint256) {
        uint256 weighted = uint256(wplsWeightBps) * PRECISION;

        for (uint256 i = 0; i < _components.length; i++) {
            uint256 price = _updateComponent(i);
            Component storage c = _components[i];
            weighted += uint256(c.weightBps) * ((price * PRECISION) / c.initialPrice);
        }

        if (gasWeightBps > 0) {
            uint256 gasPrice = block.basefee;
            if (gasPrice == 0) gasPrice = lastGasPrice;
            lastGasPrice = gasPrice;
            weighted += uint256(gasWeightBps) * ((gasPrice * PRECISION) / initialGasPrice);
        }

        return weighted / 10_000;
    }

    function _updateComponent(uint256 i) internal returns (uint256) {
        Component storage c = _components[i];

        if (block.timestamp - c.lastPriceTimestamp < MIN_TWAP_INTERVAL) {
            return c.lastPrice;
        }

        (uint112 r0, uint112 r1, uint32 tsPair) = c.pair.getReserves();
        require(r0 > 0 && r1 > 0, "No liquidity");

        uint32 elapsed = uint32(block.timestamp) - c.blockTimestampLast;
        uint256 price = elapsed < MIN_TWAP_INTERVAL
            ? _spotPrice(c, r0, r1)
            : _twapPrice(c, r0, r1, tsPair, elapsed);

        c.lastPrice = price;
        c.lastPriceTimestamp = block.timestamp;

        emit ComponentUpdated(c.symbol, price, block.timestamp);
        return price;
    }

    function _spotPrice(Component storage c) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = c.pair.getReserves();
        if (r0 == 0 || r1 == 0) return c.lastPrice;
        return _spotPrice(c, r0, r1);
    }

    function _spotPrice(Component storage c, uint112 r0, uint112 r1)
        internal
        view
        returns (uint256)
    {
        return c.assetIsToken0
            ? (uint256(r1) * PRECISION) / uint256(r0)
            : (uint256(r0) * PRECISION) / uint256(r1);
    }

    function _twapPrice(Component storage c, uint112 r0, uint112 r1, uint32 tsPair, uint32 elapsed)
        internal
        returns (uint256)
    {
        uint256 cumulative =
            c.assetIsToken0 ? c.pair.price0CumulativeLast() : c.pair.price1CumulativeLast();

        unchecked {
            uint32 gap = uint32(block.timestamp) - tsPair;
            if (gap > 0) {
                uint256 instantQ112 = c.assetIsToken0
                    ? (uint256(r1) << 112) / uint256(r0)
                    : (uint256(r0) << 112) / uint256(r1);
                cumulative += instantQ112 * gap;
            }
        }

        uint256 diff = cumulative - c.priceCumulativeLast;
        uint256 twap = (diff * PRECISION) / (uint256(elapsed) << 112);

        c.priceCumulativeLast = cumulative;
        c.blockTimestampLast = uint32(block.timestamp);
        return twap;
    }

    function _capIndexMove(uint256 previous, uint256 raw)
        internal
        pure
        returns (uint256 cappedIndex, bool capped)
    {
        if (previous == 0) return (raw, false);

        uint256 maxMove = (previous * MAX_INDEX_MOVE_BPS) / 10_000;
        if (maxMove == 0) maxMove = 1;

        if (raw > previous + maxMove) return (previous + maxMove, true);
        if (raw + maxMove < previous) return (previous - maxMove, true);
        return (raw, false);
    }
}
