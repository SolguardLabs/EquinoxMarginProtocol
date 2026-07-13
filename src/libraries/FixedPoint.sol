// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library FixedPoint {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    int256 internal constant SIGNED_WAD = 1e18;

    error DivisionByZero();
    error BpsTooLarge();
    error CastOverflow();

    function wad() internal pure returns (uint256) {
        return WAD;
    }

    function ray() internal pure returns (uint256) {
        return RAY;
    }

    function bps() internal pure returns (uint256) {
        return BPS;
    }

    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, b, WAD);
    }

    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, WAD, b);
    }

    function mulRay(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, b, RAY);
    }

    function divRay(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, RAY, b);
    }

    function mulBps(uint256 amount, uint256 rateBps) internal pure returns (uint256) {
        if (rateBps > BPS) revert BpsTooLarge();
        return mulDiv(amount, rateBps, BPS);
    }

    function addBps(uint256 amount, uint256 rateBps) internal pure returns (uint256) {
        return amount + mulDiv(amount, rateBps, BPS);
    }

    function subBps(uint256 amount, uint256 rateBps) internal pure returns (uint256) {
        return amount - mulDiv(amount, rateBps, BPS);
    }

    function complementBps(uint256 rateBps) internal pure returns (uint256) {
        if (rateBps > BPS) revert BpsTooLarge();
        return BPS - rateBps;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        return (a * b) / denominator;
    }

    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        if (a == 0 || b == 0) return 0;
        return ((a * b) - 1) / denominator + 1;
    }

    function abs(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function sign(int256 value) internal pure returns (int256) {
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }

    function toInt256(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) revert CastOverflow();
        return int256(value);
    }

    function signedMulWad(int256 a, int256 b) internal pure returns (int256) {
        return (a * b) / SIGNED_WAD;
    }

    function signedDivWad(int256 a, int256 b) internal pure returns (int256) {
        if (b == 0) revert DivisionByZero();
        return (a * SIGNED_WAD) / b;
    }

    function signedMulBps(int256 amount, uint256 rateBps) internal pure returns (int256) {
        if (rateBps > BPS) revert BpsTooLarge();
        return (amount * int256(rateBps)) / int256(BPS);
    }

    function weightedAverage(
        uint256 currentValue,
        uint256 currentWeight,
        uint256 incomingValue,
        uint256 incomingWeight
    ) internal pure returns (uint256) {
        uint256 totalWeight = currentWeight + incomingWeight;
        if (totalWeight == 0) return 0;
        return ((currentValue * currentWeight) + (incomingValue * incomingWeight)) / totalWeight;
    }

    function withinTolerance(
        uint256 actual,
        uint256 expected,
        uint256 toleranceBps
    ) internal pure returns (bool) {
        uint256 lower = subBps(expected, toleranceBps);
        uint256 upper = addBps(expected, toleranceBps);
        return actual >= lower && actual <= upper;
    }

    function clamp(uint256 value, uint256 lower, uint256 upper) internal pure returns (uint256) {
        if (value < lower) return lower;
        if (value > upper) return upper;
        return value;
    }
}
