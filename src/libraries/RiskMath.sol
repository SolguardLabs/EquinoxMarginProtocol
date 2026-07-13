// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPoint } from "./FixedPoint.sol";

library RiskMath {
    using FixedPoint for uint256;

    struct MarginTerms {
        uint256 initialMarginBps;
        uint256 maintenanceMarginBps;
        uint256 liquidationCloseFactorBps;
    }

    struct HealthInputs {
        uint256 weightedCollateralValue;
        uint256 debtValue;
        int256 unrealizedPnl;
        uint256 initialRequirement;
        uint256 maintenanceRequirement;
    }

    uint256 internal constant MIN_MARGIN_RATIO_BPS = 1;

    function tokenValue(
        uint256 amount,
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        return FixedPoint.mulDiv(amount, price, 10 ** uint256(decimals));
    }

    function tokenAmount(
        uint256 value,
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        return FixedPoint.mulDiv(value, 10 ** uint256(decimals), price);
    }

    function weightedValue(uint256 rawValue, uint256 factorBps) internal pure returns (uint256) {
        return rawValue.mulBps(factorBps);
    }

    function initialMarginForNotional(
        uint256 notional,
        uint256 maxLeverageBps
    ) internal pure returns (uint256) {
        if (maxLeverageBps == 0) return type(uint256).max;
        return FixedPoint.mulDivUp(notional, FixedPoint.BPS, maxLeverageBps);
    }

    function maintenanceForNotional(
        uint256 notional,
        uint256 maintenanceMarginBps
    ) internal pure returns (uint256) {
        return notional.mulBps(maintenanceMarginBps);
    }

    function equity(
        uint256 weightedCollateralValue,
        int256 unrealizedPnl
    ) internal pure returns (int256) {
        if (unrealizedPnl >= 0) {
            return int256(weightedCollateralValue) + unrealizedPnl;
        }
        return int256(weightedCollateralValue) - int256(FixedPoint.abs(unrealizedPnl));
    }

    function marginRatioBps(
        uint256 weightedCollateralValue,
        uint256 debtValue,
        int256 unrealizedPnl
    ) internal pure returns (uint256) {
        if (debtValue == 0) {
            return type(uint256).max;
        }
        int256 eq = equity(weightedCollateralValue, unrealizedPnl);
        if (eq <= 0) {
            return 0;
        }
        return FixedPoint.mulDiv(uint256(eq), FixedPoint.BPS, debtValue);
    }

    function isHealthy(HealthInputs memory inputs) internal pure returns (bool) {
        int256 eq = equity(inputs.weightedCollateralValue, inputs.unrealizedPnl);
        if (eq <= 0) return false;
        return uint256(eq) >= inputs.initialRequirement;
    }

    function isLiquidatable(HealthInputs memory inputs) internal pure returns (bool) {
        int256 eq = equity(inputs.weightedCollateralValue, inputs.unrealizedPnl);
        if (inputs.debtValue == 0) return false;
        if (eq <= 0) return true;
        return uint256(eq) < inputs.maintenanceRequirement;
    }

    function pnlForPosition(
        int256 signedSize,
        uint256 entryPrice,
        uint256 currentPrice
    ) internal pure returns (int256) {
        if (signedSize == 0 || entryPrice == 0) return 0;
        int256 priceDelta = int256(currentPrice) - int256(entryPrice);
        return (signedSize * priceDelta) / int256(FixedPoint.WAD);
    }

    function notionalFromSize(int256 signedSize, uint256 price) internal pure returns (uint256) {
        return FixedPoint.mulDiv(FixedPoint.abs(signedSize), price, FixedPoint.WAD);
    }

    function sizeFromNotional(uint256 notional, uint256 price) internal pure returns (uint256) {
        return FixedPoint.mulDiv(notional, FixedPoint.WAD, price);
    }

    function closePortion(
        uint256 amount,
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return FixedPoint.mulDiv(amount, numerator, denominator);
    }

    function debtToPrincipal(
        uint256 debtAmount,
        uint256 accountIndex,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (debtAmount == 0) return 0;
        return FixedPoint.mulDivUp(debtAmount, accountIndex, currentIndex);
    }

    function principalToDebt(
        uint256 principal,
        uint256 accountIndex,
        uint256 currentIndex
    ) internal pure returns (uint256) {
        if (principal == 0) return 0;
        return FixedPoint.mulDivUp(principal, currentIndex, accountIndex);
    }

    function liquidationSeizeValue(
        uint256 repayValue,
        uint256 liquidationBonusBps
    ) internal pure returns (uint256) {
        return repayValue.addBps(liquidationBonusBps);
    }

    function closeFactorAmount(
        uint256 currentDebt,
        uint256 closeFactorBps
    ) internal pure returns (uint256) {
        return currentDebt.mulBps(closeFactorBps);
    }
}
