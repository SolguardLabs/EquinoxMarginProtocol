import { ethers } from "hardhat";

export const ASSETS = {
    USDC: ethers.encodeBytes32String("USDC"),
    WETH: ethers.encodeBytes32String("WETH"),
    WBTC: ethers.encodeBytes32String("WBTC"),
    ETH_PERP: ethers.encodeBytes32String("ETH-PERP"),
};

export const YEAR = 365n * 24n * 60n * 60n;

export function wad(value: string): bigint {
    return ethers.parseEther(value);
}

export async function increaseTime(seconds: bigint): Promise<void> {
    await ethers.provider.send("evm_increaseTime", [Number(seconds)]);
    await ethers.provider.send("evm_mine", []);
}

export async function deployEquinoxFixture() {
    const [deployer, lp, trader, liquidator, treasury] = await ethers.getSigners();

    const Oracle = await ethers.getContractFactory("EquinoxOracle");
    const oracle = await Oracle.deploy(deployer.address);
    await oracle.waitForDeployment();
    await oracle.setMaxDelay(400n * 24n * 60n * 60n);

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20.deploy("Equinox USD", "eUSD", 18);
    const weth = await MockERC20.deploy("Wrapped Ether", "WETH", 18);
    const wbtc = await MockERC20.deploy("Wrapped Bitcoin", "WBTC", 18);
    await Promise.all([
        usdc.waitForDeployment(),
        weth.waitForDeployment(),
        wbtc.waitForDeployment(),
    ]);

    const Protocol = await ethers.getContractFactory("EquinoxMarginProtocol");
    const protocol = await Protocol.deploy(await oracle.getAddress());
    await protocol.waitForDeployment();

    await oracle.postPrices(
        [ASSETS.USDC, ASSETS.WETH, ASSETS.WBTC],
        [wad("1"), wad("2000"), wad("30000")],
    );

    await protocol.registerAsset(
        ASSETS.USDC,
        await usdc.getAddress(),
        18,
        9500,
        9000,
        500,
        true,
        true,
    );
    await protocol.registerAsset(
        ASSETS.WETH,
        await weth.getAddress(),
        18,
        8000,
        7500,
        800,
        true,
        false,
    );
    await protocol.registerAsset(
        ASSETS.WBTC,
        await wbtc.getAddress(),
        18,
        7800,
        7200,
        900,
        true,
        false,
    );

    await protocol.configureInterestRate(
        ASSETS.USDC,
        wad("0.10") / YEAR,
        wad("0.50") / YEAR,
        wad("2.00") / YEAR,
        wad("0.80"),
        1000,
    );

    await protocol.registerMarket(ASSETS.ETH_PERP, ASSETS.WETH, ASSETS.USDC, 50000, 800, 0, 5000);

    const protocolAddress = await protocol.getAddress();
    const mintedUsd = wad("1000000");
    const mintedWeth = wad("1000");
    const mintedBtc = wad("100");

    for (const account of [lp, trader, liquidator, treasury]) {
        await usdc.mint(account.address, mintedUsd);
        await weth.mint(account.address, mintedWeth);
        await wbtc.mint(account.address, mintedBtc);
        await usdc.connect(account).approve(protocolAddress, ethers.MaxUint256);
        await weth.connect(account).approve(protocolAddress, ethers.MaxUint256);
        await wbtc.connect(account).approve(protocolAddress, ethers.MaxUint256);
    }

    await protocol.connect(lp).depositLiquidity(ASSETS.USDC, wad("750000"));

    return {
        deployer,
        lp,
        trader,
        liquidator,
        treasury,
        oracle,
        protocol,
        usdc,
        weth,
        wbtc,
    };
}
