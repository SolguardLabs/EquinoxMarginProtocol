// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPoint} from "./FixedPoint.sol";

library InterestRateModel {
    using FixedPoint for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    struct AccrualPreview {
        uint256 utilization;
        uint256 ratePerSecond;
        uint256 indexBefore;
        uint256 indexAfter;
        uint256 interestAccrued;
        uint256 reserveAccrued;
    }

    function utilization(uint256 cash, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return 0;
        return FixedPoint.mulDiv(debt, FixedPoint.WAD, cash + debt);
    }

    function borrowRatePerSecond(
        uint256 cash,
        uint256 debt,
        uint256 baseRatePerSecond,
        uint256 slope1PerSecond,
        uint256 slope2PerSecond,
        uint256 kinkUtilization
    ) internal pure returns (uint256) {
        uint256 util = utilization(cash, debt);
        if (util <= kinkUtilization) {
            uint256 scaled = kinkUtilization == 0
                ? 0
                : FixedPoint.mulDiv(util, slope1PerSecond, kinkUtilization);
            return baseRatePerSecond + scaled;
        }

        uint256 normalRate = baseRatePerSecond + slope1PerSecond;
        uint256 excessUtil = util - kinkUtilization;
        uint256 excessDenominator = FixedPoint.WAD - kinkUtilization;
        uint256 excessRate = excessDenominator == 0
            ? slope2PerSecond
            : FixedPoint.mulDiv(excessUtil, slope2PerSecond, excessDenominator);
        return normalRate + excessRate;
    }

    function previewAccrual(
        uint256 cash,
        uint256 totalDebt,
        uint256 borrowIndex,
        uint256 elapsed,
        uint256 reserveFactorBps,
        uint256 baseRatePerSecond,
        uint256 slope1PerSecond,
        uint256 slope2PerSecond,
        uint256 kinkUtilization
    ) internal pure returns (AccrualPreview memory preview) {
        preview.utilization = utilization(cash, totalDebt);
        preview.ratePerSecond = borrowRatePerSecond(
            cash,
            totalDebt,
            baseRatePerSecond,
            slope1PerSecond,
            slope2PerSecond,
            kinkUtilization
        );
        preview.indexBefore = borrowIndex;

        if (elapsed == 0 || totalDebt == 0 || preview.ratePerSecond == 0) {
            preview.indexAfter = borrowIndex;
            return preview;
        }

        uint256 interestFactor = preview.ratePerSecond * elapsed;
        uint256 indexDelta = borrowIndex.mulWad(interestFactor);
        preview.indexAfter = borrowIndex + indexDelta;
        preview.interestAccrued = totalDebt.mulWad(interestFactor);
        preview.reserveAccrued = preview.interestAccrued.mulBps(reserveFactorBps);
    }

    function annualRateToPerSecond(uint256 annualRateWad) internal pure returns (uint256) {
        return annualRateWad / SECONDS_PER_YEAR;
    }

    function conservativeDefaultBaseRate() internal pure returns (uint256) {
        return annualRateToPerSecond(3e16);
    }

    function conservativeDefaultSlope1() internal pure returns (uint256) {
        return annualRateToPerSecond(12e16);
    }

    function conservativeDefaultSlope2() internal pure returns (uint256) {
        return annualRateToPerSecond(80e16);
    }

    function defaultKink() internal pure returns (uint256) {
        return 8e17;
    }

    function effectiveDebt(
        uint256 principal,
        uint256 accountIndex,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (principal == 0) return 0;
        return FixedPoint.mulDivUp(principal, currentIndex, accountIndex);
    }

    function normalizeDebt(
        uint256 currentDebt,
        uint256 accountIndex,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (currentDebt == 0) return 0;
        return FixedPoint.mulDivUp(currentDebt, accountIndex, currentIndex);
    }
}
