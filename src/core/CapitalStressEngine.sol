// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract CapitalStressEngine {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_COVERAGE_BPS = 100_000;

    uint256 public constant SIGNAL_SHORTFALL = 1 << 0;
    uint256 public constant SIGNAL_OPEN_INTEREST = 1 << 1;
    uint256 public constant SIGNAL_CONCENTRATION = 1 << 2;
    uint256 public constant SIGNAL_ORACLE_CONFIDENCE = 1 << 3;
    uint256 public constant SIGNAL_LIQUIDITY = 1 << 4;

    enum RiskBand {
        Nominal,
        Watch,
        Guarded,
        Critical
    }

    struct StressPolicy {
        uint256 priceShockBps;
        uint256 liquidationHaircutBps;
        uint256 liquidityHaircutBps;
        uint256 fundingShockBps;
        uint256 concentrationAddonBps;
        uint256 minimumCoverageBps;
        uint256 watchCoverageBps;
        uint256 maxOpenInterestBps;
        uint256 maxConcentrationBps;
        uint256 minOracleConfidenceBps;
    }

    struct MarketExposure {
        bytes32 marketId;
        uint256 grossLongNotional;
        uint256 grossShortNotional;
        uint256 openInterestCap;
        uint256 maintenanceCollateral;
        uint256 liquidCollateral;
        uint256 liquidityDepth;
        uint256 liquidationQueue;
        uint256 fundingReceivable;
        uint256 fundingPayable;
        uint256 largestAccountNotional;
        uint256 oracleConfidenceBps;
    }

    struct MarketAssessment {
        bytes32 marketId;
        uint256 grossOpenInterest;
        uint256 directionalExposure;
        uint256 stressedLoss;
        uint256 stressedCollateral;
        uint256 stressedLiquidity;
        uint256 requiredCapital;
        uint256 availableCapital;
        uint256 surplus;
        uint256 shortfall;
        uint256 coverageBps;
        uint256 openInterestUtilizationBps;
        uint256 concentrationBps;
        uint256 signals;
        RiskBand band;
    }

    struct PortfolioAssessment {
        MarketAssessment[] markets;
        uint256 totalRequiredCapital;
        uint256 totalAvailableCapital;
        uint256 totalSurplus;
        uint256 totalShortfall;
        uint256 aggregateCoverageBps;
        uint256 marketsAtRisk;
        uint256 aggregateSignals;
        RiskBand worstBand;
    }

    error InvalidPolicy();
    error InvalidExposure(bytes32 marketId);
    error DuplicateMarket(bytes32 marketId);

    function assessMarket(
        MarketExposure calldata exposure,
        StressPolicy calldata policy
    ) public pure returns (MarketAssessment memory assessment) {
        _validatePolicy(policy);
        _validateExposure(exposure);

        uint256 grossOpenInterest = exposure.grossLongNotional + exposure.grossShortNotional;
        uint256 directionalExposure = _absoluteDifference(
            exposure.grossLongNotional,
            exposure.grossShortNotional
        );
        uint256 matchedExposure = _minimum(exposure.grossLongNotional, exposure.grossShortNotional);

        uint256 directionalLoss = _mulBpsUp(directionalExposure, policy.priceShockBps);
        uint256 basisLoss = _mulDivUp(matchedExposure, policy.priceShockBps, BPS * 4);
        uint256 confidenceLoss = _mulBpsUp(grossOpenInterest, BPS - exposure.oracleConfidenceBps);
        uint256 stressedLoss = directionalLoss + basisLoss + confidenceLoss;

        uint256 liquidationNeed = exposure.liquidationQueue +
            _mulBpsUp(exposure.liquidationQueue, policy.liquidationHaircutBps);
        uint256 netFundingPayable = exposure.fundingPayable > exposure.fundingReceivable
            ? exposure.fundingPayable - exposure.fundingReceivable
            : 0;
        uint256 fundingNeed = netFundingPayable +
            _mulBpsUp(netFundingPayable, policy.fundingShockBps);
        uint256 concentrationAddon = _mulBpsUp(
            exposure.largestAccountNotional,
            policy.concentrationAddonBps
        );
        uint256 requiredCapital = stressedLoss + liquidationNeed + fundingNeed + concentrationAddon;

        uint256 stressedCollateral = exposure.maintenanceCollateral +
            _afterHaircut(exposure.liquidCollateral, policy.liquidityHaircutBps);
        uint256 stressedLiquidity = _afterHaircut(
            exposure.liquidityDepth,
            policy.liquidityHaircutBps
        );
        uint256 availableCapital = stressedCollateral + stressedLiquidity;
        uint256 surplus = availableCapital > requiredCapital
            ? availableCapital - requiredCapital
            : 0;
        uint256 shortfall = requiredCapital > availableCapital
            ? requiredCapital - availableCapital
            : 0;
        uint256 coverageBps = requiredCapital == 0
            ? MAX_COVERAGE_BPS
            : _minimum((availableCapital * BPS) / requiredCapital, MAX_COVERAGE_BPS);
        uint256 openInterestUtilizationBps = _ratioBps(grossOpenInterest, exposure.openInterestCap);
        uint256 concentrationBps = grossOpenInterest == 0
            ? 0
            : _ratioBps(exposure.largestAccountNotional, grossOpenInterest);

        uint256 signals;
        if (shortfall != 0) signals |= SIGNAL_SHORTFALL;
        if (openInterestUtilizationBps > policy.maxOpenInterestBps) {
            signals |= SIGNAL_OPEN_INTEREST;
        }
        if (concentrationBps > policy.maxConcentrationBps) {
            signals |= SIGNAL_CONCENTRATION;
        }
        if (exposure.oracleConfidenceBps < policy.minOracleConfidenceBps) {
            signals |= SIGNAL_ORACLE_CONFIDENCE;
        }
        if (stressedLiquidity < exposure.liquidationQueue) signals |= SIGNAL_LIQUIDITY;

        RiskBand band = _classify(coverageBps, shortfall, signals, policy);
        assessment = MarketAssessment({
            marketId: exposure.marketId,
            grossOpenInterest: grossOpenInterest,
            directionalExposure: directionalExposure,
            stressedLoss: stressedLoss,
            stressedCollateral: stressedCollateral,
            stressedLiquidity: stressedLiquidity,
            requiredCapital: requiredCapital,
            availableCapital: availableCapital,
            surplus: surplus,
            shortfall: shortfall,
            coverageBps: coverageBps,
            openInterestUtilizationBps: openInterestUtilizationBps,
            concentrationBps: concentrationBps,
            signals: signals,
            band: band
        });
    }

    function assessPortfolio(
        MarketExposure[] calldata exposures,
        StressPolicy calldata policy
    ) external pure returns (PortfolioAssessment memory portfolio) {
        _validatePolicy(policy);
        MarketAssessment[] memory markets = new MarketAssessment[](exposures.length);
        RiskBand worstBand = RiskBand.Nominal;

        for (uint256 i = 0; i < exposures.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (exposures[i].marketId == exposures[j].marketId) {
                    revert DuplicateMarket(exposures[i].marketId);
                }
            }

            MarketAssessment memory market = assessMarket(exposures[i], policy);
            markets[i] = market;
            portfolio.totalRequiredCapital += market.requiredCapital;
            portfolio.totalAvailableCapital += market.availableCapital;
            portfolio.totalSurplus += market.surplus;
            portfolio.totalShortfall += market.shortfall;
            portfolio.aggregateSignals |= market.signals;
            if (market.band != RiskBand.Nominal) portfolio.marketsAtRisk += 1;
            if (uint8(market.band) > uint8(worstBand)) worstBand = market.band;
        }

        portfolio.markets = markets;
        portfolio.worstBand = worstBand;
        portfolio.aggregateCoverageBps = portfolio.totalRequiredCapital == 0
            ? MAX_COVERAGE_BPS
            : _minimum(
                (portfolio.totalAvailableCapital * BPS) / portfolio.totalRequiredCapital,
                MAX_COVERAGE_BPS
            );
    }

    function _classify(
        uint256 coverageBps,
        uint256 shortfall,
        uint256 signals,
        StressPolicy calldata policy
    ) private pure returns (RiskBand) {
        if (
            shortfall != 0 ||
            (signals & SIGNAL_ORACLE_CONFIDENCE) != 0 ||
            (signals & SIGNAL_LIQUIDITY) != 0
        ) return RiskBand.Critical;
        if (coverageBps < policy.minimumCoverageBps || (signals & SIGNAL_OPEN_INTEREST) != 0)
            return RiskBand.Guarded;
        if (coverageBps < policy.watchCoverageBps || (signals & SIGNAL_CONCENTRATION) != 0)
            return RiskBand.Watch;
        return RiskBand.Nominal;
    }

    function _validatePolicy(StressPolicy calldata policy) private pure {
        if (
            policy.priceShockBps == 0 ||
            policy.priceShockBps > BPS ||
            policy.liquidationHaircutBps > BPS ||
            policy.liquidityHaircutBps > BPS ||
            policy.fundingShockBps > 50_000 ||
            policy.concentrationAddonBps > BPS ||
            policy.minimumCoverageBps < BPS ||
            policy.watchCoverageBps < policy.minimumCoverageBps ||
            policy.watchCoverageBps > MAX_COVERAGE_BPS ||
            policy.maxOpenInterestBps < BPS ||
            policy.maxOpenInterestBps > MAX_COVERAGE_BPS ||
            policy.maxConcentrationBps == 0 ||
            policy.maxConcentrationBps > BPS ||
            policy.minOracleConfidenceBps > BPS
        ) revert InvalidPolicy();
    }

    function _validateExposure(MarketExposure calldata exposure) private pure {
        uint256 grossOpenInterest = exposure.grossLongNotional + exposure.grossShortNotional;
        if (
            exposure.marketId == bytes32(0) ||
            exposure.openInterestCap == 0 ||
            exposure.oracleConfidenceBps > BPS ||
            exposure.largestAccountNotional > grossOpenInterest
        ) revert InvalidExposure(exposure.marketId);
    }

    function _afterHaircut(uint256 value, uint256 haircutBps) private pure returns (uint256) {
        return (value * (BPS - haircutBps)) / BPS;
    }

    function _mulBpsUp(uint256 value, uint256 bps) private pure returns (uint256) {
        return _mulDivUp(value, bps, BPS);
    }

    function _mulDivUp(
        uint256 value,
        uint256 multiplier,
        uint256 denominator
    ) private pure returns (uint256) {
        if (value == 0 || multiplier == 0) return 0;
        return (value * multiplier + denominator - 1) / denominator;
    }

    function _ratioBps(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (numerator * BPS) / denominator;
    }

    function _absoluteDifference(uint256 left, uint256 right) private pure returns (uint256) {
        return left > right ? left - right : right - left;
    }

    function _minimum(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
