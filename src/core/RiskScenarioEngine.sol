// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPoint } from "../libraries/FixedPoint.sol";

library RiskScenarioEngine {
    using FixedPoint for uint256;
    using FixedPoint for int256;

    enum ScenarioStatus {
        Healthy,
        InitialDeficit,
        MaintenanceDeficit,
        Insolvent
    }

    struct PriceShock {
        bytes32 asset;
        int256 shockBps;
        uint256 floorPrice;
        uint256 ceilingPrice;
    }

    struct ScenarioCollateral {
        bytes32 asset;
        uint256 amount;
        uint256 price;
        uint8 decimals;
        uint256 factorBps;
    }

    struct ScenarioDebt {
        bytes32 asset;
        uint256 amount;
        uint256 price;
        uint8 decimals;
        uint256 rateShockBps;
    }

    struct ScenarioPosition {
        bytes32 marketId;
        bytes32 baseAsset;
        int256 size;
        uint256 entryPrice;
        uint256 currentPrice;
        uint256 openNotional;
        uint256 initialRequirement;
        uint256 maintenanceRequirement;
    }

    struct ScenarioResult {
        uint256 collateralValue;
        uint256 weightedCollateralValue;
        uint256 debtValue;
        int256 pnlValue;
        uint256 initialRequirement;
        uint256 maintenanceRequirement;
        int256 equityValue;
        uint256 marginRatioBps;
        ScenarioStatus status;
    }

    function shockedPrice(uint256 price, int256 shockBps) internal pure returns (uint256) {
        if (shockBps == 0) return price;
        if (shockBps > 0) {
            return price + price.mulBps(uint256(shockBps));
        }
        uint256 decline = price.mulBps(FixedPoint.abs(shockBps));
        return decline >= price ? 0 : price - decline;
    }

    function boundedShockedPrice(
        PriceShock memory shock,
        uint256 currentPrice
    ) internal pure returns (uint256) {
        uint256 price = shockedPrice(currentPrice, shock.shockBps);
        if (shock.floorPrice != 0 && price < shock.floorPrice) {
            price = shock.floorPrice;
        }
        if (shock.ceilingPrice != 0 && price > shock.ceilingPrice) {
            price = shock.ceilingPrice;
        }
        return price;
    }

    function tokenValue(
        uint256 amount,
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return FixedPoint.mulDiv(amount, price, 10 ** uint256(decimals));
    }

    function collateralValue(
        ScenarioCollateral memory collateral,
        int256 shockBps
    ) internal pure returns (uint256 rawValue, uint256 weightedValue) {
        uint256 price = shockedPrice(collateral.price, shockBps);
        rawValue = tokenValue(collateral.amount, price, collateral.decimals);
        weightedValue = rawValue.mulBps(collateral.factorBps);
    }

    function debtValue(
        ScenarioDebt memory debt,
        int256 priceShockBps
    ) internal pure returns (uint256 value) {
        uint256 price = shockedPrice(debt.price, priceShockBps);
        value = tokenValue(debt.amount, price, debt.decimals);
        if (debt.rateShockBps != 0) {
            value = value.addBps(debt.rateShockBps);
        }
    }

    function positionPnl(
        ScenarioPosition memory position,
        int256 shockBps
    ) internal pure returns (int256) {
        if (position.size == 0 || position.entryPrice == 0) return 0;
        uint256 price = shockedPrice(position.currentPrice, shockBps);
        int256 priceDelta = int256(price) - int256(position.entryPrice);
        return (position.size * priceDelta) / int256(FixedPoint.WAD);
    }

    function evaluate(
        ScenarioCollateral[] memory collaterals,
        ScenarioDebt[] memory debts,
        ScenarioPosition[] memory positions,
        int256 collateralShockBps,
        int256 debtShockBps,
        int256 positionShockBps
    ) internal pure returns (ScenarioResult memory result) {
        for (uint256 i = 0; i < collaterals.length; i++) {
            (uint256 rawValue, uint256 weightedValue) = collateralValue(
                collaterals[i],
                collateralShockBps
            );
            result.collateralValue += rawValue;
            result.weightedCollateralValue += weightedValue;
        }
        for (uint256 i = 0; i < debts.length; i++) {
            result.debtValue += debtValue(debts[i], debtShockBps);
        }
        for (uint256 i = 0; i < positions.length; i++) {
            result.pnlValue += positionPnl(positions[i], positionShockBps);
            result.initialRequirement += positions[i].initialRequirement;
            result.maintenanceRequirement += positions[i].maintenanceRequirement;
        }
        result.equityValue = int256(result.weightedCollateralValue) + result.pnlValue;
        result.marginRatioBps = marginRatio(result.equityValue, result.debtValue);
        result.status = classify(result);
    }

    function classify(ScenarioResult memory result) internal pure returns (ScenarioStatus) {
        if (result.equityValue <= 0) return ScenarioStatus.Insolvent;
        if (uint256(result.equityValue) < result.maintenanceRequirement) {
            return ScenarioStatus.MaintenanceDeficit;
        }
        if (uint256(result.equityValue) < result.initialRequirement) {
            return ScenarioStatus.InitialDeficit;
        }
        return ScenarioStatus.Healthy;
    }

    function marginRatio(int256 equityValue, uint256 debtValue_) internal pure returns (uint256) {
        if (debtValue_ == 0) return type(uint256).max;
        if (equityValue <= 0) return 0;
        return FixedPoint.mulDiv(uint256(equityValue), FixedPoint.BPS, debtValue_);
    }

    function liquidationBuffer(ScenarioResult memory result) internal pure returns (int256) {
        return result.equityValue - int256(result.maintenanceRequirement);
    }

    function initialBuffer(ScenarioResult memory result) internal pure returns (int256) {
        return result.equityValue - int256(result.initialRequirement);
    }

    function worse(
        ScenarioResult memory left,
        ScenarioResult memory right
    ) internal pure returns (ScenarioResult memory) {
        if (uint256(left.status) > uint256(right.status)) return left;
        if (uint256(right.status) > uint256(left.status)) return right;
        return liquidationBuffer(left) <= liquidationBuffer(right) ? left : right;
    }

    function aggregateWorst(
        ScenarioResult[] memory results
    ) internal pure returns (ScenarioResult memory worstResult) {
        if (results.length == 0) return worstResult;
        worstResult = results[0];
        for (uint256 i = 1; i < results.length; i++) {
            worstResult = worse(worstResult, results[i]);
        }
    }

    function shockGrid(
        ScenarioCollateral[] memory collaterals,
        ScenarioDebt[] memory debts,
        ScenarioPosition[] memory positions,
        int256[] memory shocks
    ) internal pure returns (ScenarioResult[] memory results) {
        results = new ScenarioResult[](shocks.length);
        for (uint256 i = 0; i < shocks.length; i++) {
            results[i] = evaluate(collaterals, debts, positions, shocks[i], 0, shocks[i]);
        }
    }

    function weightedAverageStatus(
        ScenarioResult[] memory results,
        uint256[] memory weights
    ) internal pure returns (uint256 score) {
        require(results.length == weights.length, "SCENARIO_LENGTH");
        uint256 totalWeight;
        for (uint256 i = 0; i < results.length; i++) {
            score += uint256(results[i].status) * weights[i];
            totalWeight += weights[i];
        }
        if (totalWeight == 0) return 0;
        return score / totalWeight;
    }

    function recommendedCloseBps(
        ScenarioResult memory result,
        uint256 maxCloseBps
    ) internal pure returns (uint256) {
        if (result.status == ScenarioStatus.Healthy) return 0;
        if (result.equityValue <= 0) return maxCloseBps;
        uint256 deficit = result.maintenanceRequirement > uint256(result.equityValue)
            ? result.maintenanceRequirement - uint256(result.equityValue)
            : 0;
        if (deficit == 0 || result.debtValue == 0) return 0;
        uint256 closeBps = FixedPoint.mulDivUp(deficit, FixedPoint.BPS, result.debtValue);
        return closeBps > maxCloseBps ? maxCloseBps : closeBps;
    }
}
