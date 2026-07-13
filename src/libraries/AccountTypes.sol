// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library AccountTypes {
    enum AccountStatus {
        Empty,
        Active,
        Restricted,
        Liquidating
    }

    enum Side {
        Flat,
        Long,
        Short
    }

    struct AssetConfig {
        bytes32 id;
        address token;
        uint8 decimals;
        uint256 collateralFactorBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        bool collateralEnabled;
        bool borrowEnabled;
        bool registered;
    }

    struct MarketConfig {
        bytes32 id;
        bytes32 baseAsset;
        bytes32 quoteAsset;
        uint256 maxLeverageBps;
        uint256 maintenanceMarginBps;
        uint256 takerFeeBps;
        uint256 liquidationCloseFactorBps;
        bool reduceOnly;
        bool active;
        bool registered;
    }

    struct LiquidityPool {
        bytes32 asset;
        uint256 cash;
        uint256 totalShares;
        uint256 totalBorrowPrincipal;
        uint256 borrowIndex;
        uint256 lastAccrualTime;
        uint256 reserveBalance;
        uint256 reserveFactorBps;
        uint256 baseRatePerSecond;
        uint256 slope1PerSecond;
        uint256 slope2PerSecond;
        uint256 kinkUtilization;
        bool initialized;
    }

    struct DebtPosition {
        bytes32 asset;
        uint256 principal;
        uint256 index;
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct Position {
        bytes32 marketId;
        int256 size;
        uint256 entryPrice;
        uint256 openNotional;
        uint256 lastTransferId;
        uint256 openedAt;
        uint256 updatedAt;
        bool exists;
    }

    struct SubAccount {
        bool initialized;
        AccountStatus status;
        uint64 nonce;
        uint256 lastAction;
        bytes32[] collateralAssets;
        bytes32[] debtAssets;
        bytes32[] marketIds;
        mapping(bytes32 => uint256) collateral;
        mapping(bytes32 => DebtPosition) debts;
        mapping(bytes32 => Position) positions;
    }

    struct AccountSnapshot {
        uint256 collateralValue;
        uint256 weightedCollateralValue;
        uint256 debtValue;
        int256 unrealizedPnl;
        uint256 initialRequirement;
        uint256 maintenanceRequirement;
        uint256 marginRatioBps;
        bool healthy;
        bool liquidatable;
    }

    struct TransferReceipt {
        address owner;
        uint256 sourceSubAccount;
        uint256 targetSubAccount;
        bytes32 marketId;
        uint256 positionPortionBps;
        uint256 principalMoved;
        uint256 collateralMovedValue;
        uint256 issuedAt;
    }

    struct LiquidationQuote {
        bytes32 marketId;
        bytes32 debtAsset;
        bytes32 seizeAsset;
        uint256 repayAmount;
        uint256 repayPrincipal;
        uint256 seizeAmount;
        uint256 closeNotional;
        uint256 bonusValue;
        uint256 healthBeforeBps;
    }

    function side(Position storage position) internal view returns (Side) {
        if (!position.exists || position.size == 0) return Side.Flat;
        return position.size > 0 ? Side.Long : Side.Short;
    }

    function isInitialized(SubAccount storage account) internal view returns (bool) {
        return account.initialized;
    }

    function hasDebt(SubAccount storage account, bytes32 asset) internal view returns (bool) {
        return account.debts[asset].principal != 0;
    }

    function hasCollateral(SubAccount storage account, bytes32 asset) internal view returns (bool) {
        return account.collateral[asset] != 0;
    }

    function hasPosition(
        SubAccount storage account,
        bytes32 marketId
    ) internal view returns (bool) {
        return account.positions[marketId].exists && account.positions[marketId].openNotional != 0;
    }

    function markActive(SubAccount storage account) internal {
        if (!account.initialized) {
            account.initialized = true;
            account.status = AccountStatus.Active;
        }
        account.lastAction = block.timestamp;
        account.nonce += 1;
    }
}
