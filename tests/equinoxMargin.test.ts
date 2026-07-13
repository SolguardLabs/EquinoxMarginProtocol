import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { ASSETS, deployEquinoxFixture, increaseTime, wad } from "./helpers/deploy";

describe("EquinoxMarginProtocol", function () {
    it("opens isolated positions and accrues internal borrow interest", async function () {
        const { protocol, trader } = await deployEquinoxFixture();

        await protocol
            .connect(trader)
            .openPosition(1, ASSETS.ETH_PERP, true, wad("10000"), ASSETS.WETH, wad("2"));

        const debtBefore = await protocol.debtOf(trader.address, 1, ASSETS.USDC);
        expect(debtBefore[2]).to.equal(wad("8000"));

        await increaseTime(45n * 24n * 60n * 60n);
        await protocol.accrueInterest(ASSETS.USDC);

        const debtAfter = await protocol.debtOf(trader.address, 1, ASSETS.USDC);
        expect(debtAfter[2]).to.be.gt(debtBefore[2]);

        await protocol.connect(trader).addMargin(1, ASSETS.USDC, wad("500"));
        const snapshot = await protocol.accountSnapshot(trader.address, 1);
        expect(snapshot.healthy).to.equal(true);
        expect(snapshot.debtValue).to.be.gt(wad("8000"));
    });

    it("adds margin and closes a profitable position through the account ledger", async function () {
        const { oracle, protocol, trader } = await deployEquinoxFixture();

        await protocol
            .connect(trader)
            .openPosition(7, ASSETS.ETH_PERP, true, wad("6000"), ASSETS.WETH, wad("1.5"));

        await oracle.postPrice(ASSETS.WETH, wad("2200"));
        await expect(protocol.connect(trader).closePosition(7, ASSETS.ETH_PERP, wad("6000")))
            .to.emit(protocol, "PositionClosed")
            .withArgs(trader.address, 7, ASSETS.ETH_PERP, anyValue, wad("6000"), anyValue);

        const debt = await protocol.debtOf(trader.address, 7, ASSETS.USDC);
        const position = await protocol.positionOf(trader.address, 7, ASSETS.ETH_PERP);
        expect(debt[2]).to.equal(0);
        expect(position[2]).to.equal(0);
    });

    it("moves a live position between isolated subaccounts", async function () {
        const { protocol, trader } = await deployEquinoxFixture();

        await protocol
            .connect(trader)
            .openPosition(11, ASSETS.ETH_PERP, true, wad("8000"), ASSETS.WETH, wad("2"));

        await expect(protocol.connect(trader).transferPosition(11, 12, ASSETS.ETH_PERP, 5000))
            .to.emit(protocol, "PositionTransferred")
            .withArgs(trader.address, 11, 12, ASSETS.ETH_PERP, 5000, wad("3200"), 1);

        const sourcePosition = await protocol.positionOf(trader.address, 11, ASSETS.ETH_PERP);
        const targetPosition = await protocol.positionOf(trader.address, 12, ASSETS.ETH_PERP);
        const sourceDebt = await protocol.debtOf(trader.address, 11, ASSETS.USDC);
        const targetDebt = await protocol.debtOf(trader.address, 12, ASSETS.USDC);
        const sourceCollateral = await protocol.collateralBalance(trader.address, 11, ASSETS.WETH);
        const targetCollateral = await protocol.collateralBalance(trader.address, 12, ASSETS.WETH);

        expect(sourcePosition[2]).to.equal(wad("4000"));
        expect(targetPosition[2]).to.equal(wad("4000"));
        expect(sourceDebt[0]).to.equal(wad("3200"));
        expect(targetDebt[0]).to.equal(wad("3200"));
        expect(sourceDebt[2]).to.be.gte(wad("3200"));
        expect(sourceDebt[2]).to.be.lt(wad("3200.001"));
        expect(targetDebt[2]).to.be.gte(wad("3200"));
        expect(targetDebt[2]).to.be.lt(wad("3200.001"));
        expect(sourceCollateral).to.equal(wad("1"));
        expect(targetCollateral).to.equal(wad("1"));

        expect((await protocol.accountSnapshot(trader.address, 11)).healthy).to.equal(true);
        expect((await protocol.accountSnapshot(trader.address, 12)).healthy).to.equal(true);
    });

    it("performs partial liquidation when margin falls below maintenance", async function () {
        const { oracle, protocol, trader, liquidator, weth } = await deployEquinoxFixture();

        await protocol
            .connect(trader)
            .openPosition(21, ASSETS.ETH_PERP, true, wad("10000"), ASSETS.WETH, wad("2"));

        await oracle.postPrice(ASSETS.WETH, wad("1200"));
        const snapshot = await protocol.accountSnapshot(trader.address, 21);
        expect(snapshot.liquidatable).to.equal(true);

        const liquidatorWethBefore = await weth.balanceOf(liquidator.address);
        await expect(
            protocol
                .connect(liquidator)
                .liquidate(trader.address, 21, ASSETS.ETH_PERP, ASSETS.WETH, wad("1000")),
        ).to.emit(protocol, "Liquidated");

        const liquidatorWethAfter = await weth.balanceOf(liquidator.address);
        const debtAfter = await protocol.debtOf(trader.address, 21, ASSETS.USDC);
        const positionAfter = await protocol.positionOf(trader.address, 21, ASSETS.ETH_PERP);

        expect(liquidatorWethAfter).to.be.gt(liquidatorWethBefore);
        expect(debtAfter[2]).to.be.lt(wad("8000"));
        expect(positionAfter[2]).to.be.lt(wad("10000"));
    });

    it("keeps liquidity accounting available for providers", async function () {
        const { protocol, lp, trader } = await deployEquinoxFixture();

        const poolBefore = await protocol.poolState(ASSETS.USDC);
        await protocol
            .connect(trader)
            .openPosition(31, ASSETS.ETH_PERP, true, wad("5000"), ASSETS.WETH, wad("1.2"));
        const poolAfterBorrow = await protocol.poolState(ASSETS.USDC);

        expect(poolAfterBorrow[0]).to.equal(poolBefore[0] - wad("4000"));
        expect(poolAfterBorrow[2]).to.equal(wad("4000"));

        const shares = await protocol.liquidityShares(lp.address, ASSETS.USDC);
        const preview = await protocol.previewLiquidityWithdrawal(ASSETS.USDC, shares / 10n);
        expect(preview).to.be.gt(0);
    });
});
