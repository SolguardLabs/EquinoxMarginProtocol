// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPoint} from "../libraries/FixedPoint.sol";

library ExecutionCodec {
    using FixedPoint for uint256;
    using FixedPoint for int256;

    enum IntentType {
        Open,
        Increase,
        Reduce,
        Close,
        Transfer,
        Liquidate
    }

    enum TimeInForce {
        Immediate,
        GoodTilBlock,
        GoodTilTime,
        MakerOnly
    }

    struct ExecutionLimits {
        uint256 minPrice;
        uint256 maxPrice;
        uint256 maxFeeValue;
        uint256 maxSlippageBps;
        uint256 deadline;
        uint256 allowedDelay;
    }

    struct OrderIntent {
        address owner;
        uint256 subAccountId;
        bytes32 marketId;
        IntentType intentType;
        TimeInForce timeInForce;
        bool isLong;
        bool reduceOnly;
        uint256 notionalValue;
        uint256 collateralAmount;
        bytes32 collateralAsset;
        uint256 nonce;
        ExecutionLimits limits;
    }

    struct FillReport {
        bytes32 intentHash;
        address executor;
        uint256 fillNotional;
        uint256 executionPrice;
        uint256 feeValue;
        uint256 filledAt;
        bool finalFill;
    }

    struct FeeBreakdown {
        uint256 protocolFee;
        uint256 liquidityFee;
        uint256 executorFee;
        uint256 totalFee;
    }

    struct AccountDelta {
        int256 signedSizeDelta;
        int256 signedPnlValue;
        uint256 debtIncreaseValue;
        uint256 debtDecreaseValue;
        uint256 collateralInValue;
        uint256 collateralOutValue;
    }

    struct NettingResult {
        int256 sizeAfter;
        uint256 notionalAfter;
        uint256 averageEntryPrice;
        uint256 closedNotional;
        bool directionChanged;
        bool fullyClosed;
    }

    error ExpiredIntent();
    error InvalidPrice();
    error SlippageExceeded();
    error FeeExceeded();
    error ReduceOnlyViolation();
    error InvalidFill();

    function hashIntent(OrderIntent memory intent) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    intent.owner,
                    intent.subAccountId,
                    intent.marketId,
                    intent.intentType,
                    intent.timeInForce,
                    intent.isLong,
                    intent.reduceOnly,
                    intent.notionalValue,
                    intent.collateralAmount,
                    intent.collateralAsset,
                    intent.nonce,
                    hashLimits(intent.limits)
                )
            );
    }

    function hashLimits(ExecutionLimits memory limits) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    limits.minPrice,
                    limits.maxPrice,
                    limits.maxFeeValue,
                    limits.maxSlippageBps,
                    limits.deadline,
                    limits.allowedDelay
                )
            );
    }

    function hashFill(FillReport memory fill) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    fill.intentHash,
                    fill.executor,
                    fill.fillNotional,
                    fill.executionPrice,
                    fill.feeValue,
                    fill.filledAt,
                    fill.finalFill
                )
            );
    }

    function validateTiming(
        OrderIntent memory intent,
        uint256 blockNumber,
        uint256 timestamp
    ) internal pure {
        if (intent.timeInForce == TimeInForce.Immediate) {
            return;
        }
        if (
            intent.timeInForce == TimeInForce.GoodTilBlock && blockNumber > intent.limits.deadline
        ) {
            revert ExpiredIntent();
        }
        if (intent.timeInForce == TimeInForce.GoodTilTime && timestamp > intent.limits.deadline) {
            revert ExpiredIntent();
        }
        if (
            intent.timeInForce == TimeInForce.MakerOnly &&
            timestamp > intent.limits.deadline + intent.limits.allowedDelay
        ) {
            revert ExpiredIntent();
        }
    }

    function validatePrice(ExecutionLimits memory limits, uint256 executionPrice) internal pure {
        if (executionPrice == 0) revert InvalidPrice();
        if (limits.minPrice != 0 && executionPrice < limits.minPrice) revert InvalidPrice();
        if (limits.maxPrice != 0 && executionPrice > limits.maxPrice) revert InvalidPrice();
    }

    function validateFee(ExecutionLimits memory limits, uint256 feeValue) internal pure {
        if (limits.maxFeeValue != 0 && feeValue > limits.maxFeeValue) revert FeeExceeded();
    }

    function validateSlippage(
        uint256 quotedPrice,
        uint256 executionPrice,
        uint256 maxSlippageBps
    ) internal pure {
        if (quotedPrice == 0 || executionPrice == 0) revert InvalidPrice();
        if (maxSlippageBps == 0) return;
        uint256 lower = quotedPrice.subBps(maxSlippageBps);
        uint256 upper = quotedPrice.addBps(maxSlippageBps);
        if (executionPrice < lower || executionPrice > upper) revert SlippageExceeded();
    }

    function validateReduceOnly(
        bool reduceOnly,
        int256 currentSize,
        int256 sizeDelta
    ) internal pure {
        if (!reduceOnly) return;
        if (currentSize == 0 || FixedPoint.sign(currentSize) == FixedPoint.sign(sizeDelta)) {
            revert ReduceOnlyViolation();
        }
        if (FixedPoint.abs(sizeDelta) > FixedPoint.abs(currentSize)) {
            revert ReduceOnlyViolation();
        }
    }

    function fillableNotional(
        uint256 requestedNotional,
        uint256 remainingCapacity
    ) internal pure returns (uint256) {
        return requestedNotional < remainingCapacity ? requestedNotional : remainingCapacity;
    }

    function isFinalFill(
        uint256 fillNotional,
        uint256 requestedNotional
    ) internal pure returns (bool) {
        if (requestedNotional == 0) revert InvalidFill();
        return fillNotional >= requestedNotional;
    }

    function quoteFees(
        uint256 notionalValue,
        uint256 protocolFeeBps,
        uint256 liquidityFeeBps,
        uint256 executorFeeBps
    ) internal pure returns (FeeBreakdown memory fees) {
        fees.protocolFee = notionalValue.mulBps(protocolFeeBps);
        fees.liquidityFee = notionalValue.mulBps(liquidityFeeBps);
        fees.executorFee = notionalValue.mulBps(executorFeeBps);
        fees.totalFee = fees.protocolFee + fees.liquidityFee + fees.executorFee;
    }

    function quoteSizeDelta(
        bool isLong,
        uint256 notionalValue,
        uint256 executionPrice
    ) internal pure returns (int256) {
        if (executionPrice == 0) revert InvalidPrice();
        uint256 size = FixedPoint.mulDiv(notionalValue, FixedPoint.WAD, executionPrice);
        return isLong ? int256(size) : -int256(size);
    }

    function pnlForClose(
        int256 currentSize,
        uint256 entryPrice,
        uint256 executionPrice,
        uint256 closeBps
    ) internal pure returns (int256) {
        int256 priceDelta = int256(executionPrice) - int256(entryPrice);
        int256 totalPnl = (currentSize * priceDelta) / int256(FixedPoint.WAD);
        return totalPnl.signedMulBps(closeBps);
    }

    function closeBpsForNotional(
        uint256 closeNotional,
        uint256 openNotional
    ) internal pure returns (uint256) {
        if (openNotional == 0) revert InvalidFill();
        uint256 bps = FixedPoint.mulDiv(closeNotional, FixedPoint.BPS, openNotional);
        return bps > FixedPoint.BPS ? FixedPoint.BPS : bps;
    }

    function applyFill(
        int256 currentSize,
        uint256 currentNotional,
        uint256 currentEntryPrice,
        int256 sizeDelta,
        uint256 fillNotional,
        uint256 executionPrice
    ) internal pure returns (NettingResult memory result) {
        if (fillNotional == 0) revert InvalidFill();
        if (currentSize == 0 || FixedPoint.sign(currentSize) == FixedPoint.sign(sizeDelta)) {
            result.sizeAfter = currentSize + sizeDelta;
            result.notionalAfter = currentNotional + fillNotional;
            result.averageEntryPrice = FixedPoint.weightedAverage(
                currentEntryPrice,
                currentNotional,
                executionPrice,
                fillNotional
            );
            return result;
        }

        uint256 currentAbs = FixedPoint.abs(currentSize);
        uint256 deltaAbs = FixedPoint.abs(sizeDelta);
        if (deltaAbs < currentAbs) {
            uint256 closeBps = FixedPoint.mulDiv(deltaAbs, FixedPoint.BPS, currentAbs);
            result.sizeAfter = currentSize + sizeDelta;
            result.closedNotional = currentNotional.mulBps(closeBps);
            result.notionalAfter = currentNotional - result.closedNotional;
            result.averageEntryPrice = currentEntryPrice;
            return result;
        }

        if (deltaAbs == currentAbs) {
            result.fullyClosed = true;
            result.closedNotional = currentNotional;
            return result;
        }

        uint256 residualSize = deltaAbs - currentAbs;
        result.directionChanged = true;
        result.closedNotional = currentNotional;
        result.sizeAfter = sizeDelta > 0 ? int256(residualSize) : -int256(residualSize);
        result.notionalAfter = FixedPoint.mulDiv(residualSize, executionPrice, FixedPoint.WAD);
        result.averageEntryPrice = executionPrice;
    }

    function mergeDeltas(
        AccountDelta memory left,
        AccountDelta memory right
    ) internal pure returns (AccountDelta memory merged) {
        merged.signedSizeDelta = left.signedSizeDelta + right.signedSizeDelta;
        merged.signedPnlValue = left.signedPnlValue + right.signedPnlValue;
        merged.debtIncreaseValue = left.debtIncreaseValue + right.debtIncreaseValue;
        merged.debtDecreaseValue = left.debtDecreaseValue + right.debtDecreaseValue;
        merged.collateralInValue = left.collateralInValue + right.collateralInValue;
        merged.collateralOutValue = left.collateralOutValue + right.collateralOutValue;
    }

    function scaleDelta(
        AccountDelta memory delta,
        uint256 portionBps
    ) internal pure returns (AccountDelta memory scaled) {
        scaled.signedSizeDelta = delta.signedSizeDelta.signedMulBps(portionBps);
        scaled.signedPnlValue = delta.signedPnlValue.signedMulBps(portionBps);
        scaled.debtIncreaseValue = delta.debtIncreaseValue.mulBps(portionBps);
        scaled.debtDecreaseValue = delta.debtDecreaseValue.mulBps(portionBps);
        scaled.collateralInValue = delta.collateralInValue.mulBps(portionBps);
        scaled.collateralOutValue = delta.collateralOutValue.mulBps(portionBps);
    }

    function netCollateralDelta(AccountDelta memory delta) internal pure returns (int256) {
        return
            int256(delta.collateralInValue) +
            delta.signedPnlValue -
            int256(delta.collateralOutValue);
    }

    function netDebtDelta(AccountDelta memory delta) internal pure returns (int256) {
        return int256(delta.debtIncreaseValue) - int256(delta.debtDecreaseValue);
    }

    function shouldRejectMakerOnly(
        TimeInForce timeInForce,
        uint256 crossedSpreadBps
    ) internal pure returns (bool) {
        return timeInForce == TimeInForce.MakerOnly && crossedSpreadBps != 0;
    }
}
