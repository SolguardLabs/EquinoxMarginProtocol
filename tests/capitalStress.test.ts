import { expect } from "chai";
import { ethers } from "hardhat";

const MARKET_A = ethers.encodeBytes32String("ETH-PERP");
const MARKET_B = ethers.encodeBytes32String("BTC-PERP");

function policy() {
    return {
        priceShockBps: 1500,
        liquidationHaircutBps: 1500,
        liquidityHaircutBps: 2000,
        fundingShockBps: 2500,
        concentrationAddonBps: 500,
        minimumCoverageBps: 12_000,
        watchCoverageBps: 16_000,
        maxOpenInterestBps: 10_000,
        maxConcentrationBps: 4000,
        minOracleConfidenceBps: 9500,
    };
}

function exposure(overrides: Record<string, bigint | string> = {}) {
    return {
        marketId: MARKET_A,
        grossLongNotional: 10_000n,
        grossShortNotional: 8_000n,
        openInterestCap: 30_000n,
        maintenanceCollateral: 10_000n,
        liquidCollateral: 5_000n,
        liquidityDepth: 10_000n,
        liquidationQueue: 1_000n,
        fundingReceivable: 100n,
        fundingPayable: 200n,
        largestAccountNotional: 5_000n,
        oracleConfidenceBps: 9900n,
        ...overrides,
    };
}

describe("CapitalStressEngine", function () {
    async function deployEngine() {
        const Engine = await ethers.getContractFactory("CapitalStressEngine");
        const engine = await Engine.deploy();
        await engine.waitForDeployment();
        return engine;
    }

    it("classifies a funded and diversified market as nominal", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(exposure(), policy());

        expect(result.band).to.equal(0);
        expect(result.shortfall).to.equal(0);
        expect(result.coverageBps).to.be.gt(16_000);
        expect(result.signals).to.equal(0);
    });

    it("reports a critical shortfall under directional stress", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(
            exposure({
                grossLongNotional: 20_000n,
                grossShortNotional: 0n,
                openInterestCap: 25_000n,
                maintenanceCollateral: 100n,
                liquidCollateral: 0n,
                liquidityDepth: 0n,
                liquidationQueue: 0n,
                fundingReceivable: 0n,
                fundingPayable: 0n,
                largestAccountNotional: 4_000n,
                oracleConfidenceBps: 10_000n,
            }),
            policy(),
        );

        expect(result.band).to.equal(3);
        expect(result.shortfall).to.be.gt(0);
        expect(result.signals & 1n).to.equal(1n);
    });

    it("rounds stress requirements conservatively", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(
            exposure({
                grossLongNotional: 1n,
                grossShortNotional: 0n,
                openInterestCap: 10n,
                maintenanceCollateral: 100n,
                liquidCollateral: 0n,
                liquidityDepth: 0n,
                liquidationQueue: 0n,
                fundingReceivable: 0n,
                fundingPayable: 0n,
                largestAccountNotional: 1n,
                oracleConfidenceBps: 10_000n,
            }),
            policy(),
        );

        expect(result.stressedLoss).to.equal(1n);
        expect(result.requiredCapital).to.equal(2n);
    });

    it("applies the liquidity haircut to collateral and depth", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(exposure(), policy());

        expect(result.stressedCollateral).to.equal(14_000n);
        expect(result.stressedLiquidity).to.equal(8_000n);
        expect(result.availableCapital).to.equal(22_000n);
    });

    it("adds a shocked net funding payable to required capital", async function () {
        const engine = await deployEngine();
        const withoutFunding = await engine.assessMarket(
            exposure({ fundingReceivable: 0n, fundingPayable: 0n }),
            policy(),
        );
        const withFunding = await engine.assessMarket(
            exposure({ fundingReceivable: 500n, fundingPayable: 2_000n }),
            policy(),
        );

        expect(withFunding.requiredCapital - withoutFunding.requiredCapital).to.equal(1_875n);
    });

    it("raises a concentration signal without forcing a shortfall", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(
            exposure({ largestAccountNotional: 8_000n }),
            policy(),
        );

        expect(result.signals & 4n).to.equal(4n);
        expect(result.band).to.equal(1);
        expect(result.shortfall).to.equal(0);
    });

    it("raises a guarded band above the open interest policy", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(
            exposure({
                grossLongNotional: 12_000n,
                grossShortNotional: 10_000n,
                openInterestCap: 20_000n,
                maintenanceCollateral: 30_000n,
                largestAccountNotional: 5_000n,
            }),
            policy(),
        );

        expect(result.openInterestUtilizationBps).to.equal(11_000n);
        expect(result.signals & 2n).to.equal(2n);
        expect(result.band).to.equal(2);
    });

    it("treats weak oracle confidence as critical", async function () {
        const engine = await deployEngine();
        const result = await engine.assessMarket(
            exposure({ oracleConfidenceBps: 9000n }),
            policy(),
        );

        expect(result.signals & 8n).to.equal(8n);
        expect(result.band).to.equal(3);
    });

    it("aggregates markets and exposes the worst band", async function () {
        const engine = await deployEngine();
        const stressed = exposure({
            marketId: MARKET_B,
            grossLongNotional: 20_000n,
            grossShortNotional: 0n,
            openInterestCap: 25_000n,
            maintenanceCollateral: 100n,
            liquidCollateral: 0n,
            liquidityDepth: 0n,
            liquidationQueue: 0n,
            fundingReceivable: 0n,
            fundingPayable: 0n,
            largestAccountNotional: 4_000n,
            oracleConfidenceBps: 10_000n,
        });
        const result = await engine.assessPortfolio([exposure(), stressed], policy());

        expect(result.markets.length).to.equal(2);
        expect(result.worstBand).to.equal(3);
        expect(result.marketsAtRisk).to.equal(1);
        expect(result.totalRequiredCapital).to.be.gt(0);
    });

    it("rejects duplicate market identifiers", async function () {
        const engine = await deployEngine();
        await expect(engine.assessPortfolio([exposure(), exposure()], policy()))
            .to.be.revertedWithCustomError(engine, "DuplicateMarket")
            .withArgs(MARKET_A);
    });

    it("rejects incoherent policy thresholds", async function () {
        const engine = await deployEngine();
        await expect(
            engine.assessMarket(exposure(), {
                ...policy(),
                watchCoverageBps: 11_000,
            }),
        ).to.be.revertedWithCustomError(engine, "InvalidPolicy");
    });
});
