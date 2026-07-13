// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EquinoxMarginProtocol } from "../EquinoxMarginProtocol.sol";
import { AccountTypes } from "../libraries/AccountTypes.sol";

contract EquinoxLens {
    struct AssetView {
        bytes32 asset;
        address token;
        uint8 decimals;
        uint256 price;
        uint256 collateralFactorBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        bool collateralEnabled;
        bool borrowEnabled;
    }

    struct PoolView {
        bytes32 asset;
        uint256 cash;
        uint256 totalShares;
        uint256 totalBorrowDebt;
        uint256 borrowIndex;
        uint256 reserveBalance;
        uint256 utilization;
        uint256 netAssets;
    }

    struct MarketView {
        bytes32 marketId;
        bytes32 baseAsset;
        bytes32 quoteAsset;
        uint256 maxLeverageBps;
        uint256 maintenanceMarginBps;
        uint256 takerFeeBps;
        uint256 liquidationCloseFactorBps;
        bool reduceOnly;
        bool active;
        AssetView base;
        AssetView quote;
        PoolView quotePool;
    }

    struct CollateralLine {
        bytes32 asset;
        uint256 balance;
        uint256 value;
    }

    struct DebtLine {
        bytes32 asset;
        uint256 principal;
        uint256 index;
        uint256 currentDebt;
        uint256 value;
    }

    struct PositionLine {
        bytes32 marketId;
        int256 size;
        uint256 entryPrice;
        uint256 openNotional;
        int256 unrealizedPnl;
        uint256 updatedAt;
    }

    struct AccountView {
        address owner;
        uint256 subAccountId;
        AccountTypes.AccountSnapshot snapshot;
        CollateralLine[] collateral;
        DebtLine[] debt;
        PositionLine[] positions;
    }

    function assetView(
        EquinoxMarginProtocol protocol,
        bytes32 asset
    ) public view returns (AssetView memory view_) {
        AccountTypes.AssetConfig memory config = protocol.assetConfig(asset);
        uint256 price;
        try protocol.oracle().getPrice(asset) returns (uint256 oraclePrice) {
            price = oraclePrice;
        } catch {
            (price, ) = protocol.oracle().getPriceUnsafe(asset);
        }
        view_ = AssetView({
            asset: asset,
            token: config.token,
            decimals: config.decimals,
            price: price,
            collateralFactorBps: config.collateralFactorBps,
            liquidationThresholdBps: config.liquidationThresholdBps,
            liquidationBonusBps: config.liquidationBonusBps,
            collateralEnabled: config.collateralEnabled,
            borrowEnabled: config.borrowEnabled
        });
    }

    function poolView(
        EquinoxMarginProtocol protocol,
        bytes32 asset
    ) public view returns (PoolView memory view_) {
        (
            uint256 cash,
            uint256 totalShares,
            uint256 totalBorrowDebt,
            uint256 borrowIndex,
            uint256 reserveBalance,
            uint256 utilization
        ) = protocol.poolState(asset);
        uint256 netAssets = cash + totalBorrowDebt;
        if (netAssets > reserveBalance) {
            netAssets -= reserveBalance;
        } else {
            netAssets = 0;
        }
        view_ = PoolView({
            asset: asset,
            cash: cash,
            totalShares: totalShares,
            totalBorrowDebt: totalBorrowDebt,
            borrowIndex: borrowIndex,
            reserveBalance: reserveBalance,
            utilization: utilization,
            netAssets: netAssets
        });
    }

    function marketView(
        EquinoxMarginProtocol protocol,
        bytes32 marketId
    ) external view returns (MarketView memory view_) {
        AccountTypes.MarketConfig memory market = protocol.marketConfig(marketId);
        view_ = MarketView({
            marketId: marketId,
            baseAsset: market.baseAsset,
            quoteAsset: market.quoteAsset,
            maxLeverageBps: market.maxLeverageBps,
            maintenanceMarginBps: market.maintenanceMarginBps,
            takerFeeBps: market.takerFeeBps,
            liquidationCloseFactorBps: market.liquidationCloseFactorBps,
            reduceOnly: market.reduceOnly,
            active: market.active,
            base: assetView(protocol, market.baseAsset),
            quote: assetView(protocol, market.quoteAsset),
            quotePool: poolView(protocol, market.quoteAsset)
        });
    }

    function accountView(
        EquinoxMarginProtocol protocol,
        address owner,
        uint256 subAccountId
    ) external view returns (AccountView memory view_) {
        bytes32[] memory collateralAssets = protocol.collateralAssets(owner, subAccountId);
        bytes32[] memory debtAssets = protocol.debtAssets(owner, subAccountId);
        bytes32[] memory markets = protocol.positionMarkets(owner, subAccountId);
        CollateralLine[] memory collateral = new CollateralLine[](collateralAssets.length);
        DebtLine[] memory debt = new DebtLine[](debtAssets.length);
        PositionLine[] memory positions = new PositionLine[](markets.length);

        for (uint256 i = 0; i < collateralAssets.length; i++) {
            bytes32 asset = collateralAssets[i];
            uint256 balance = protocol.collateralBalance(owner, subAccountId, asset);
            uint256 price = assetView(protocol, asset).price;
            AccountTypes.AssetConfig memory config = protocol.assetConfig(asset);
            collateral[i] = CollateralLine({
                asset: asset,
                balance: balance,
                value: balance == 0 ? 0 : (balance * price) / (10 ** uint256(config.decimals))
            });
        }

        for (uint256 i = 0; i < debtAssets.length; i++) {
            bytes32 asset = debtAssets[i];
            (uint256 principal, uint256 index, uint256 currentDebt) = protocol.debtOf(
                owner,
                subAccountId,
                asset
            );
            uint256 price = assetView(protocol, asset).price;
            AccountTypes.AssetConfig memory config = protocol.assetConfig(asset);
            debt[i] = DebtLine({
                asset: asset,
                principal: principal,
                index: index,
                currentDebt: currentDebt,
                value: currentDebt == 0
                    ? 0
                    : (currentDebt * price) / (10 ** uint256(config.decimals))
            });
        }

        for (uint256 i = 0; i < markets.length; i++) {
            (
                int256 size,
                uint256 entryPrice,
                uint256 openNotional,
                int256 unrealizedPnl,
                uint256 updatedAt
            ) = protocol.positionOf(owner, subAccountId, markets[i]);
            positions[i] = PositionLine({
                marketId: markets[i],
                size: size,
                entryPrice: entryPrice,
                openNotional: openNotional,
                unrealizedPnl: unrealizedPnl,
                updatedAt: updatedAt
            });
        }

        view_ = AccountView({
            owner: owner,
            subAccountId: subAccountId,
            snapshot: protocol.accountSnapshot(owner, subAccountId),
            collateral: collateral,
            debt: debt,
            positions: positions
        });
    }

    function portfolioHealth(
        EquinoxMarginProtocol protocol,
        address owner,
        uint256[] calldata subAccountIds
    )
        external
        view
        returns (
            uint256 collateralValue,
            uint256 weightedCollateralValue,
            uint256 debtValue,
            int256 pnlValue,
            uint256 initialRequirement,
            uint256 maintenanceRequirement,
            bool allHealthy,
            bool anyLiquidatable
        )
    {
        allHealthy = true;
        for (uint256 i = 0; i < subAccountIds.length; i++) {
            AccountTypes.AccountSnapshot memory snapshot = protocol.accountSnapshot(
                owner,
                subAccountIds[i]
            );
            collateralValue += snapshot.collateralValue;
            weightedCollateralValue += snapshot.weightedCollateralValue;
            debtValue += snapshot.debtValue;
            pnlValue += snapshot.unrealizedPnl;
            initialRequirement += snapshot.initialRequirement;
            maintenanceRequirement += snapshot.maintenanceRequirement;
            if (!snapshot.healthy) allHealthy = false;
            if (snapshot.liquidatable) anyLiquidatable = true;
        }
    }
}
