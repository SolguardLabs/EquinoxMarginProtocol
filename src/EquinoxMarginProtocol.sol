// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEquinoxOracle} from "./interfaces/IEquinoxOracle.sol";
import {IEquinoxToken} from "./interfaces/IEquinoxToken.sol";
import {AccountTypes} from "./libraries/AccountTypes.sol";
import {FixedPoint} from "./libraries/FixedPoint.sol";
import {InterestRateModel} from "./libraries/InterestRateModel.sol";
import {RiskMath} from "./libraries/RiskMath.sol";

contract EquinoxMarginProtocol {
    using FixedPoint for uint256;
    using FixedPoint for int256;
    using AccountTypes for AccountTypes.SubAccount;

    uint256 public constant MIN_COLLATERAL_FACTOR_BPS = 1_000;
    uint256 public constant MAX_COLLATERAL_FACTOR_BPS = 9_500;
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 2_000;
    uint256 public constant MIN_LEVERAGE_BPS = 10_000;
    uint256 public constant MAX_LEVERAGE_BPS = 100_000;

    address public owner;
    IEquinoxOracle public oracle;
    bool public paused;
    uint256 public transferSequence;

    bytes32[] private _assetList;
    bytes32[] private _marketList;

    mapping(bytes32 => AccountTypes.AssetConfig) private _assets;
    mapping(bytes32 => AccountTypes.MarketConfig) private _markets;
    mapping(bytes32 => AccountTypes.LiquidityPool) private _pools;
    mapping(address => mapping(bytes32 => uint256)) public liquidityShares;
    mapping(address => mapping(uint256 => AccountTypes.SubAccount)) private _accounts;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event PauseUpdated(bool paused);
    event AssetRegistered(bytes32 indexed asset, address indexed token, uint8 decimals);
    event AssetRiskUpdated(
        bytes32 indexed asset,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps
    );
    event MarketRegistered(
        bytes32 indexed marketId,
        bytes32 indexed baseAsset,
        bytes32 indexed quoteAsset
    );
    event MarketUpdated(bytes32 indexed marketId, bool active, bool reduceOnly);
    event InterestRateUpdated(
        bytes32 indexed asset,
        uint256 baseRatePerSecond,
        uint256 slope1PerSecond,
        uint256 slope2PerSecond,
        uint256 kinkUtilization
    );
    event InterestAccrued(
        bytes32 indexed asset,
        uint256 indexBefore,
        uint256 indexAfter,
        uint256 interestAccrued,
        uint256 reserveAccrued
    );
    event LiquidityDeposited(
        address indexed provider,
        bytes32 indexed asset,
        uint256 amount,
        uint256 shares
    );
    event LiquidityWithdrawn(
        address indexed provider,
        bytes32 indexed asset,
        uint256 amount,
        uint256 shares
    );
    event MarginDeposited(
        address indexed owner,
        uint256 indexed subAccountId,
        bytes32 indexed asset,
        uint256 amount
    );
    event MarginWithdrawn(
        address indexed owner,
        uint256 indexed subAccountId,
        bytes32 indexed asset,
        uint256 amount
    );
    event PositionOpened(
        address indexed owner,
        uint256 indexed subAccountId,
        bytes32 indexed marketId,
        int256 sizeDelta,
        uint256 notionalValue,
        uint256 entryPrice
    );
    event PositionClosed(
        address indexed owner,
        uint256 indexed subAccountId,
        bytes32 indexed marketId,
        int256 sizeDelta,
        uint256 notionalValue,
        int256 pnlValue
    );
    event DebtIncreased(
        address indexed owner,
        uint256 indexed subAccountId,
        bytes32 indexed asset,
        uint256 amount,
        uint256 index
    );
    event DebtRepaid(
        address indexed owner,
        uint256 indexed subAccountId,
        bytes32 indexed asset,
        uint256 amount,
        uint256 remainingDebt
    );
    event PositionTransferred(
        address indexed owner,
        uint256 indexed sourceSubAccount,
        uint256 indexed targetSubAccount,
        bytes32 marketId,
        uint256 portionBps,
        uint256 principalMoved,
        uint256 transferId
    );
    event Liquidated(
        address indexed liquidator,
        address indexed accountOwner,
        uint256 indexed subAccountId,
        bytes32 marketId,
        bytes32 debtAsset,
        bytes32 seizeAsset,
        uint256 repaidAmount,
        uint256 seizedAmount
    );
    event ReserveCollected(bytes32 indexed asset, uint256 amount, address indexed recipient);

    error NotOwner();
    error Paused();
    error ZeroAddress();
    error ZeroAmount();
    error AssetExists(bytes32 asset);
    error AssetMissing(bytes32 asset);
    error MarketExists(bytes32 marketId);
    error MarketMissing(bytes32 marketId);
    error MarketInactive(bytes32 marketId);
    error InvalidRiskParameter();
    error InsufficientLiquidity(bytes32 asset);
    error InsufficientShares();
    error InsufficientMargin();
    error AccountNotHealthy();
    error AccountNotLiquidatable();
    error PositionMissing(bytes32 marketId);
    error PositionDirectionMismatch();
    error InvalidPortion();
    error TransferToSelf();
    error DebtMissing(bytes32 asset);
    error TokenTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier assetRegistered(bytes32 asset) {
        if (!_assets[asset].registered) revert AssetMissing(asset);
        _;
    }

    modifier marketRegistered(bytes32 marketId) {
        if (!_markets[marketId].registered) revert MarketMissing(marketId);
        _;
    }

    constructor(address oracle_) {
        if (oracle_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        oracle = IEquinoxOracle(oracle_);
        emit OwnershipTransferred(address(0), msg.sender);
        emit OracleUpdated(address(0), oracle_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IEquinoxOracle(newOracle);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseUpdated(paused_);
    }

    function registerAsset(
        bytes32 asset,
        address token,
        uint8 decimals_,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        bool collateralEnabled,
        bool borrowEnabled
    ) external onlyOwner {
        if (asset == bytes32(0) || token == address(0)) revert ZeroAddress();
        if (_assets[asset].registered) revert AssetExists(asset);
        _validateAssetRisk(collateralFactorBps, liquidationThresholdBps, liquidationBonusBps);

        _assets[asset] = AccountTypes.AssetConfig({
            id: asset,
            token: token,
            decimals: decimals_,
            collateralFactorBps: collateralFactorBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            collateralEnabled: collateralEnabled,
            borrowEnabled: borrowEnabled,
            registered: true
        });

        AccountTypes.LiquidityPool storage pool = _pools[asset];
        pool.asset = asset;
        pool.borrowIndex = FixedPoint.WAD;
        pool.lastAccrualTime = block.timestamp;
        pool.reserveFactorBps = 1_000;
        pool.baseRatePerSecond = InterestRateModel.conservativeDefaultBaseRate();
        pool.slope1PerSecond = InterestRateModel.conservativeDefaultSlope1();
        pool.slope2PerSecond = InterestRateModel.conservativeDefaultSlope2();
        pool.kinkUtilization = InterestRateModel.defaultKink();
        pool.initialized = true;

        _assetList.push(asset);
        emit AssetRegistered(asset, token, decimals_);
        emit AssetRiskUpdated(
            asset,
            collateralFactorBps,
            liquidationThresholdBps,
            liquidationBonusBps
        );
        emit InterestRateUpdated(
            asset,
            pool.baseRatePerSecond,
            pool.slope1PerSecond,
            pool.slope2PerSecond,
            pool.kinkUtilization
        );
    }

    function configureAssetRisk(
        bytes32 asset,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        bool collateralEnabled,
        bool borrowEnabled
    ) external onlyOwner assetRegistered(asset) {
        _validateAssetRisk(collateralFactorBps, liquidationThresholdBps, liquidationBonusBps);
        AccountTypes.AssetConfig storage config = _assets[asset];
        config.collateralFactorBps = collateralFactorBps;
        config.liquidationThresholdBps = liquidationThresholdBps;
        config.liquidationBonusBps = liquidationBonusBps;
        config.collateralEnabled = collateralEnabled;
        config.borrowEnabled = borrowEnabled;
        emit AssetRiskUpdated(
            asset,
            collateralFactorBps,
            liquidationThresholdBps,
            liquidationBonusBps
        );
    }

    function configureInterestRate(
        bytes32 asset,
        uint256 baseRatePerSecond,
        uint256 slope1PerSecond,
        uint256 slope2PerSecond,
        uint256 kinkUtilization,
        uint256 reserveFactorBps
    ) external onlyOwner assetRegistered(asset) {
        if (kinkUtilization == 0 || kinkUtilization > FixedPoint.WAD) revert InvalidRiskParameter();
        if (reserveFactorBps > 5_000) revert InvalidRiskParameter();
        _accrue(asset);
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        pool.baseRatePerSecond = baseRatePerSecond;
        pool.slope1PerSecond = slope1PerSecond;
        pool.slope2PerSecond = slope2PerSecond;
        pool.kinkUtilization = kinkUtilization;
        pool.reserveFactorBps = reserveFactorBps;
        emit InterestRateUpdated(
            asset,
            baseRatePerSecond,
            slope1PerSecond,
            slope2PerSecond,
            kinkUtilization
        );
    }

    function registerMarket(
        bytes32 marketId,
        bytes32 baseAsset,
        bytes32 quoteAsset,
        uint256 maxLeverageBps,
        uint256 maintenanceMarginBps,
        uint256 takerFeeBps,
        uint256 liquidationCloseFactorBps
    ) external onlyOwner assetRegistered(baseAsset) assetRegistered(quoteAsset) {
        if (marketId == bytes32(0)) revert ZeroAddress();
        if (_markets[marketId].registered) revert MarketExists(marketId);
        if (!_assets[quoteAsset].borrowEnabled) revert InvalidRiskParameter();
        if (maxLeverageBps < MIN_LEVERAGE_BPS || maxLeverageBps > MAX_LEVERAGE_BPS) {
            revert InvalidRiskParameter();
        }
        if (maintenanceMarginBps == 0 || maintenanceMarginBps >= FixedPoint.BPS)
            revert InvalidRiskParameter();
        if (takerFeeBps > 100) revert InvalidRiskParameter();
        if (liquidationCloseFactorBps == 0 || liquidationCloseFactorBps > FixedPoint.BPS) {
            revert InvalidRiskParameter();
        }

        _markets[marketId] = AccountTypes.MarketConfig({
            id: marketId,
            baseAsset: baseAsset,
            quoteAsset: quoteAsset,
            maxLeverageBps: maxLeverageBps,
            maintenanceMarginBps: maintenanceMarginBps,
            takerFeeBps: takerFeeBps,
            liquidationCloseFactorBps: liquidationCloseFactorBps,
            reduceOnly: false,
            active: true,
            registered: true
        });
        _marketList.push(marketId);
        emit MarketRegistered(marketId, baseAsset, quoteAsset);
        emit MarketUpdated(marketId, true, false);
    }

    function setMarketMode(
        bytes32 marketId,
        bool active,
        bool reduceOnly
    ) external onlyOwner marketRegistered(marketId) {
        AccountTypes.MarketConfig storage market = _markets[marketId];
        market.active = active;
        market.reduceOnly = reduceOnly;
        emit MarketUpdated(marketId, active, reduceOnly);
    }

    function depositLiquidity(
        bytes32 asset,
        uint256 amount
    ) external whenNotPaused assetRegistered(asset) returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        _accrue(asset);
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        uint256 navBefore = _poolNetAssets(asset);
        shares = pool.totalShares == 0 || navBefore == 0
            ? amount
            : FixedPoint.mulDiv(amount, pool.totalShares, navBefore);
        pool.totalShares += shares;
        pool.cash += amount;
        liquidityShares[msg.sender][asset] += shares;
        _pullToken(asset, msg.sender, amount);
        emit LiquidityDeposited(msg.sender, asset, amount, shares);
    }

    function withdrawLiquidity(
        bytes32 asset,
        uint256 shares
    ) external whenNotPaused assetRegistered(asset) returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        _accrue(asset);
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        uint256 providerShares = liquidityShares[msg.sender][asset];
        if (providerShares < shares) revert InsufficientShares();
        amount = FixedPoint.mulDiv(shares, _poolNetAssets(asset), pool.totalShares);
        if (pool.cash < amount) revert InsufficientLiquidity(asset);
        unchecked {
            liquidityShares[msg.sender][asset] = providerShares - shares;
            pool.totalShares -= shares;
            pool.cash -= amount;
        }
        _pushToken(asset, msg.sender, amount);
        emit LiquidityWithdrawn(msg.sender, asset, amount, shares);
    }

    function collectReserves(
        bytes32 asset,
        address recipient,
        uint256 amount
    ) external onlyOwner assetRegistered(asset) {
        if (recipient == address(0)) revert ZeroAddress();
        _accrue(asset);
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        if (amount > pool.reserveBalance || amount > pool.cash) revert InsufficientLiquidity(asset);
        pool.reserveBalance -= amount;
        pool.cash -= amount;
        _pushToken(asset, recipient, amount);
        emit ReserveCollected(asset, amount, recipient);
    }

    function depositMargin(
        uint256 subAccountId,
        bytes32 asset,
        uint256 amount
    ) external whenNotPaused assetRegistered(asset) {
        _depositMarginFor(msg.sender, subAccountId, asset, amount, msg.sender);
    }

    function withdrawMargin(
        uint256 subAccountId,
        bytes32 asset,
        uint256 amount
    ) external whenNotPaused assetRegistered(asset) {
        if (amount == 0) revert ZeroAmount();
        AccountTypes.SubAccount storage account = _account(msg.sender, subAccountId);
        _removeCollateralAmount(account, asset, amount);
        _requireHealthyOrEmpty(msg.sender, subAccountId);
        _pushToken(asset, msg.sender, amount);
        emit MarginWithdrawn(msg.sender, subAccountId, asset, amount);
    }

    function openPosition(
        uint256 subAccountId,
        bytes32 marketId,
        bool isLong,
        uint256 notionalValue,
        bytes32 collateralAsset,
        uint256 collateralAmount
    ) external whenNotPaused marketRegistered(marketId) assetRegistered(collateralAsset) {
        if (notionalValue == 0) revert ZeroAmount();
        AccountTypes.MarketConfig memory market = _markets[marketId];
        if (!market.active || market.reduceOnly) revert MarketInactive(marketId);
        if (collateralAmount != 0) {
            _depositMarginFor(
                msg.sender,
                subAccountId,
                collateralAsset,
                collateralAmount,
                msg.sender
            );
        }

        _accrue(market.quoteAsset);
        uint256 basePrice = oracle.getPrice(market.baseAsset);
        uint256 quotePrice = oracle.getPrice(market.quoteAsset);
        AccountTypes.SubAccount storage account = _account(msg.sender, subAccountId);
        uint256 initialMarginValue = RiskMath.initialMarginForNotional(
            notionalValue,
            market.maxLeverageBps
        );
        uint256 borrowValue = notionalValue > initialMarginValue
            ? notionalValue - initialMarginValue
            : 0;
        uint256 feeValue = notionalValue.mulBps(market.takerFeeBps);
        uint256 borrowAmount = RiskMath.tokenAmount(
            borrowValue + feeValue,
            quotePrice,
            _assets[market.quoteAsset].decimals
        );

        if (borrowAmount != 0) {
            _borrowIntoAccount(msg.sender, subAccountId, account, market.quoteAsset, borrowAmount);
        }

        uint256 baseSize = RiskMath.sizeFromNotional(notionalValue, basePrice);
        int256 signedDelta = isLong ? int256(baseSize) : -int256(baseSize);
        _increasePosition(account, marketId, signedDelta, notionalValue, basePrice);
        _requireHealthy(msg.sender, subAccountId);
        emit PositionOpened(
            msg.sender,
            subAccountId,
            marketId,
            signedDelta,
            notionalValue,
            basePrice
        );
    }

    function addMargin(
        uint256 subAccountId,
        bytes32 asset,
        uint256 amount
    ) external whenNotPaused assetRegistered(asset) {
        _depositMarginFor(msg.sender, subAccountId, asset, amount, msg.sender);
    }

    function repayDebt(
        uint256 subAccountId,
        bytes32 asset,
        uint256 amount
    ) external whenNotPaused assetRegistered(asset) {
        if (amount == 0) revert ZeroAmount();
        _accrue(asset);
        AccountTypes.SubAccount storage account = _account(msg.sender, subAccountId);
        uint256 currentDebt = _debtCurrent(account, asset);
        if (currentDebt == 0) revert DebtMissing(asset);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        _pullToken(asset, msg.sender, repayAmount);
        _applyDebtRepayment(msg.sender, subAccountId, account, asset, repayAmount);
        _requireHealthyOrEmpty(msg.sender, subAccountId);
    }

    function closePosition(
        uint256 subAccountId,
        bytes32 marketId,
        uint256 notionalValue
    ) external whenNotPaused marketRegistered(marketId) {
        if (notionalValue == 0) revert ZeroAmount();
        AccountTypes.MarketConfig memory market = _markets[marketId];
        _accrue(market.quoteAsset);
        AccountTypes.SubAccount storage account = _account(msg.sender, subAccountId);
        AccountTypes.Position storage position = account.positions[marketId];
        if (!position.exists || position.openNotional == 0) revert PositionMissing(marketId);
        if (notionalValue > position.openNotional) {
            notionalValue = position.openNotional;
        }

        uint256 basePrice = oracle.getPrice(market.baseAsset);
        uint256 portionBps = FixedPoint.mulDiv(
            notionalValue,
            FixedPoint.BPS,
            position.openNotional
        );
        int256 pnlValue = _positionPnlValue(position, basePrice).signedMulBps(portionBps);
        int256 sizeDelta = _reducePosition(account, marketId, portionBps, basePrice);

        if (pnlValue > 0) {
            _creditPositivePnl(account, market.quoteAsset, uint256(pnlValue));
        } else if (pnlValue < 0) {
            _consumeCollateralValue(account, market.quoteAsset, FixedPoint.abs(pnlValue));
        }

        uint256 debtValue = _debtValue(account, market.quoteAsset);
        uint256 repayValue = debtValue.mulBps(portionBps);
        uint256 quotePrice = oracle.getPrice(market.quoteAsset);
        uint256 repayAmount = RiskMath.tokenAmount(
            repayValue,
            quotePrice,
            _assets[market.quoteAsset].decimals
        );
        if (repayAmount != 0) {
            _settleDebtUsingMarginOrWallet(
                msg.sender,
                subAccountId,
                account,
                market.quoteAsset,
                repayAmount
            );
        }

        _requireHealthyOrEmpty(msg.sender, subAccountId);
        emit PositionClosed(msg.sender, subAccountId, marketId, sizeDelta, notionalValue, pnlValue);
    }

    function transferPosition(
        uint256 sourceSubAccount,
        uint256 targetSubAccount,
        bytes32 marketId,
        uint256 portionBps
    )
        external
        whenNotPaused
        marketRegistered(marketId)
        returns (AccountTypes.TransferReceipt memory receipt)
    {
        if (sourceSubAccount == targetSubAccount) revert TransferToSelf();
        if (portionBps == 0 || portionBps > FixedPoint.BPS) revert InvalidPortion();
        AccountTypes.MarketConfig memory market = _markets[marketId];
        _accrue(market.quoteAsset);

        AccountTypes.SubAccount storage source = _account(msg.sender, sourceSubAccount);
        AccountTypes.SubAccount storage target = _account(msg.sender, targetSubAccount);
        AccountTypes.Position storage sourcePosition = source.positions[marketId];
        if (!sourcePosition.exists || sourcePosition.openNotional == 0)
            revert PositionMissing(marketId);

        uint256 basePrice = oracle.getPrice(market.baseAsset);
        _moveCollateral(source, target, portionBps);
        int256 movedSize = _movePosition(source, target, marketId, portionBps, basePrice);
        uint256 principalMoved = _moveDebtForTransfer(
            source,
            target,
            market.quoteAsset,
            portionBps
        );

        transferSequence += 1;
        receipt = AccountTypes.TransferReceipt({
            owner: msg.sender,
            sourceSubAccount: sourceSubAccount,
            targetSubAccount: targetSubAccount,
            marketId: marketId,
            positionPortionBps: portionBps,
            principalMoved: principalMoved,
            collateralMovedValue: 0,
            issuedAt: block.timestamp
        });
        _requireHealthyOrEmpty(msg.sender, sourceSubAccount);
        _requireHealthy(msg.sender, targetSubAccount);
        emit PositionTransferred(
            msg.sender,
            sourceSubAccount,
            targetSubAccount,
            marketId,
            portionBps,
            principalMoved,
            transferSequence
        );
        movedSize;
    }

    function quoteLiquidation(
        address accountOwner,
        uint256 subAccountId,
        bytes32 marketId,
        bytes32 seizeAsset,
        uint256 repayAmount
    )
        public
        view
        marketRegistered(marketId)
        assetRegistered(seizeAsset)
        returns (AccountTypes.LiquidationQuote memory quote)
    {
        AccountTypes.MarketConfig memory market = _markets[marketId];
        AccountTypes.SubAccount storage account = _accounts[accountOwner][subAccountId];
        AccountTypes.AccountSnapshot memory snapshot = _snapshot(accountOwner, subAccountId);
        uint256 currentDebt = _debtCurrentView(account, market.quoteAsset);
        if (repayAmount > currentDebt) repayAmount = currentDebt;
        uint256 maxRepay = currentDebt.mulBps(market.liquidationCloseFactorBps);
        if (repayAmount > maxRepay) repayAmount = maxRepay;
        uint256 repayValue = _assetValue(market.quoteAsset, repayAmount);
        uint256 seizeValue = RiskMath.liquidationSeizeValue(
            repayValue,
            _assets[seizeAsset].liquidationBonusBps
        );
        uint256 seizeAmount = _assetAmount(seizeAsset, seizeValue);
        uint256 closeNotional = account.positions[marketId].openNotional == 0
            ? 0
            : account.positions[marketId].openNotional.mulBps(
                currentDebt == 0 ? 0 : FixedPoint.mulDiv(repayAmount, FixedPoint.BPS, currentDebt)
            );
        quote = AccountTypes.LiquidationQuote({
            marketId: marketId,
            debtAsset: market.quoteAsset,
            seizeAsset: seizeAsset,
            repayAmount: repayAmount,
            repayPrincipal: _principalForRepay(account, market.quoteAsset, repayAmount),
            seizeAmount: seizeAmount,
            closeNotional: closeNotional,
            bonusValue: seizeValue - repayValue,
            healthBeforeBps: snapshot.marginRatioBps
        });
    }

    function liquidate(
        address accountOwner,
        uint256 subAccountId,
        bytes32 marketId,
        bytes32 seizeAsset,
        uint256 repayAmount
    ) external whenNotPaused marketRegistered(marketId) assetRegistered(seizeAsset) {
        AccountTypes.MarketConfig memory market = _markets[marketId];
        _accrue(market.quoteAsset);
        AccountTypes.SubAccount storage account = _account(accountOwner, subAccountId);
        AccountTypes.AccountSnapshot memory beforeSnapshot = _snapshot(accountOwner, subAccountId);
        if (!beforeSnapshot.liquidatable) revert AccountNotLiquidatable();

        AccountTypes.LiquidationQuote memory quote = quoteLiquidation(
            accountOwner,
            subAccountId,
            marketId,
            seizeAsset,
            repayAmount
        );
        if (quote.repayAmount == 0 || quote.seizeAmount == 0) revert ZeroAmount();

        _pullToken(market.quoteAsset, msg.sender, quote.repayAmount);
        _applyDebtRepayment(
            accountOwner,
            subAccountId,
            account,
            market.quoteAsset,
            quote.repayAmount
        );
        _removeCollateralAmount(account, seizeAsset, quote.seizeAmount);
        _pushToken(seizeAsset, msg.sender, quote.seizeAmount);

        AccountTypes.Position storage position = account.positions[marketId];
        if (position.exists && position.openNotional != 0) {
            uint256 closeBps = position.openNotional == 0
                ? 0
                : FixedPoint.mulDiv(quote.closeNotional, FixedPoint.BPS, position.openNotional);
            if (closeBps != 0) {
                _reducePosition(account, marketId, closeBps, oracle.getPrice(market.baseAsset));
            }
        }

        emit Liquidated(
            msg.sender,
            accountOwner,
            subAccountId,
            marketId,
            market.quoteAsset,
            seizeAsset,
            quote.repayAmount,
            quote.seizeAmount
        );
    }

    function accrueInterest(
        bytes32 asset
    ) external assetRegistered(asset) returns (uint256 indexAfter) {
        indexAfter = _accrue(asset);
    }

    function getAssets() external view returns (bytes32[] memory) {
        return _assetList;
    }

    function getMarkets() external view returns (bytes32[] memory) {
        return _marketList;
    }

    function assetConfig(
        bytes32 asset
    ) external view assetRegistered(asset) returns (AccountTypes.AssetConfig memory) {
        return _assets[asset];
    }

    function marketConfig(
        bytes32 marketId
    ) external view marketRegistered(marketId) returns (AccountTypes.MarketConfig memory) {
        return _markets[marketId];
    }

    function poolState(
        bytes32 asset
    )
        external
        view
        assetRegistered(asset)
        returns (
            uint256 cash,
            uint256 totalShares,
            uint256 totalBorrowDebt,
            uint256 borrowIndex,
            uint256 reserveBalance,
            uint256 utilization
        )
    {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        uint256 debt = _poolDebtCurrent(asset);
        return (
            pool.cash,
            pool.totalShares,
            debt,
            pool.borrowIndex,
            pool.reserveBalance,
            InterestRateModel.utilization(pool.cash, debt)
        );
    }

    function previewLiquidityWithdrawal(
        bytes32 asset,
        uint256 shares
    ) external view assetRegistered(asset) returns (uint256) {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        if (pool.totalShares == 0) return 0;
        return FixedPoint.mulDiv(shares, _poolNetAssets(asset), pool.totalShares);
    }

    function collateralBalance(
        address accountOwner,
        uint256 subAccountId,
        bytes32 asset
    ) external view assetRegistered(asset) returns (uint256) {
        return _accounts[accountOwner][subAccountId].collateral[asset];
    }

    function collateralAssets(
        address accountOwner,
        uint256 subAccountId
    ) external view returns (bytes32[] memory) {
        return _accounts[accountOwner][subAccountId].collateralAssets;
    }

    function debtAssets(
        address accountOwner,
        uint256 subAccountId
    ) external view returns (bytes32[] memory) {
        return _accounts[accountOwner][subAccountId].debtAssets;
    }

    function positionMarkets(
        address accountOwner,
        uint256 subAccountId
    ) external view returns (bytes32[] memory) {
        return _accounts[accountOwner][subAccountId].marketIds;
    }

    function debtOf(
        address accountOwner,
        uint256 subAccountId,
        bytes32 asset
    )
        external
        view
        assetRegistered(asset)
        returns (uint256 principal, uint256 index, uint256 currentDebt)
    {
        AccountTypes.DebtPosition storage debt = _accounts[accountOwner][subAccountId].debts[asset];
        return (
            debt.principal,
            debt.index,
            _debtCurrentView(_accounts[accountOwner][subAccountId], asset)
        );
    }

    function positionOf(
        address accountOwner,
        uint256 subAccountId,
        bytes32 marketId
    )
        external
        view
        marketRegistered(marketId)
        returns (
            int256 size,
            uint256 entryPrice,
            uint256 openNotional,
            int256 unrealizedPnl,
            uint256 updatedAt
        )
    {
        AccountTypes.Position storage position = _accounts[accountOwner][subAccountId].positions[
            marketId
        ];
        uint256 price = oracle.getPrice(_markets[marketId].baseAsset);
        return (
            position.size,
            position.entryPrice,
            position.openNotional,
            _positionPnlValue(position, price),
            position.updatedAt
        );
    }

    function accountSnapshot(
        address accountOwner,
        uint256 subAccountId
    ) external view returns (AccountTypes.AccountSnapshot memory) {
        return _snapshot(accountOwner, subAccountId);
    }

    function _depositMarginFor(
        address accountOwner,
        uint256 subAccountId,
        bytes32 asset,
        uint256 amount,
        address payer
    ) internal {
        if (amount == 0) revert ZeroAmount();
        AccountTypes.AssetConfig memory config = _assets[asset];
        if (!config.collateralEnabled) revert InvalidRiskParameter();
        AccountTypes.SubAccount storage account = _account(accountOwner, subAccountId);
        _addCollateralAmount(account, asset, amount);
        _pullToken(asset, payer, amount);
        emit MarginDeposited(accountOwner, subAccountId, asset, amount);
    }

    function _borrowIntoAccount(
        address accountOwner,
        uint256 subAccountId,
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 amount
    ) internal {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        if (pool.cash < amount) revert InsufficientLiquidity(asset);
        uint256 normalizedPoolDebt = FixedPoint.mulDivUp(amount, FixedPoint.WAD, pool.borrowIndex);
        pool.cash -= amount;
        pool.totalBorrowPrincipal += normalizedPoolDebt;
        _increaseDebt(account, asset, amount, pool.borrowIndex);
        emit DebtIncreased(accountOwner, subAccountId, asset, amount, pool.borrowIndex);
    }

    function _increaseDebt(
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 amount,
        uint256 currentIndex
    ) internal {
        AccountTypes.DebtPosition storage debt = account.debts[asset];
        uint256 currentDebt = _debtCurrent(account, asset);
        if (debt.principal == 0) {
            _trackDebtAsset(account, asset);
            debt.asset = asset;
            debt.createdAt = block.timestamp;
        }
        debt.principal = currentDebt + amount;
        debt.index = currentIndex;
        debt.updatedAt = block.timestamp;
    }

    function _applyDebtRepayment(
        address accountOwner,
        uint256 subAccountId,
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 amount
    ) internal {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        AccountTypes.DebtPosition storage debt = account.debts[asset];
        uint256 currentDebt = _debtCurrent(account, asset);
        if (currentDebt == 0) revert DebtMissing(asset);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        uint256 principalReduction = _principalForRepay(account, asset, repayAmount);
        if (principalReduction > debt.principal) {
            principalReduction = debt.principal;
        }
        uint256 poolReduction = FixedPoint.mulDivUp(repayAmount, FixedPoint.WAD, pool.borrowIndex);
        if (poolReduction > pool.totalBorrowPrincipal) {
            poolReduction = pool.totalBorrowPrincipal;
        }
        pool.cash += repayAmount;
        pool.totalBorrowPrincipal -= poolReduction;
        debt.principal -= principalReduction;
        debt.updatedAt = block.timestamp;
        if (debt.principal == 0) {
            debt.index = 0;
            debt.createdAt = 0;
            _untrackDebtAsset(account, asset);
        }
        emit DebtRepaid(
            accountOwner,
            subAccountId,
            asset,
            repayAmount,
            _debtCurrent(account, asset)
        );
    }

    function _settleDebtUsingMarginOrWallet(
        address accountOwner,
        uint256 subAccountId,
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 repayAmount
    ) internal {
        uint256 currentDebt = _debtCurrent(account, asset);
        if (repayAmount > currentDebt) repayAmount = currentDebt;
        uint256 fromMargin = _useCollateralAmount(account, asset, repayAmount);
        uint256 fromWallet = repayAmount - fromMargin;
        if (fromWallet != 0) {
            _pullToken(asset, accountOwner, fromWallet);
        }
        _applyDebtRepayment(accountOwner, subAccountId, account, asset, repayAmount);
    }

    function _increasePosition(
        AccountTypes.SubAccount storage account,
        bytes32 marketId,
        int256 sizeDelta,
        uint256 notionalValue,
        uint256 entryPrice
    ) internal {
        AccountTypes.Position storage position = account.positions[marketId];
        if (!position.exists || position.openNotional == 0) {
            _trackMarket(account, marketId);
            position.marketId = marketId;
            position.size = sizeDelta;
            position.entryPrice = entryPrice;
            position.openNotional = notionalValue;
            position.openedAt = block.timestamp;
            position.updatedAt = block.timestamp;
            position.exists = true;
            return;
        }
        if (FixedPoint.sign(position.size) != FixedPoint.sign(sizeDelta))
            revert PositionDirectionMismatch();
        uint256 newNotional = position.openNotional + notionalValue;
        position.entryPrice = FixedPoint.weightedAverage(
            position.entryPrice,
            position.openNotional,
            entryPrice,
            notionalValue
        );
        position.openNotional = newNotional;
        position.size += sizeDelta;
        position.updatedAt = block.timestamp;
    }

    function _reducePosition(
        AccountTypes.SubAccount storage account,
        bytes32 marketId,
        uint256 portionBps,
        uint256 price
    ) internal returns (int256 sizeDelta) {
        if (portionBps == 0 || portionBps > FixedPoint.BPS) revert InvalidPortion();
        AccountTypes.Position storage position = account.positions[marketId];
        if (!position.exists || position.openNotional == 0) revert PositionMissing(marketId);
        int256 oldSize = position.size;
        uint256 notionalReduction = position.openNotional.mulBps(portionBps);
        int256 absSizeReduction = int256(FixedPoint.abs(position.size).mulBps(portionBps));
        sizeDelta = position.size > 0 ? -absSizeReduction : absSizeReduction;
        position.size += sizeDelta;
        position.openNotional -= notionalReduction;
        position.updatedAt = block.timestamp;
        price;
        if (position.openNotional == 0 || position.size == 0) {
            delete account.positions[marketId];
            _untrackMarket(account, marketId);
            sizeDelta = -oldSize;
        }
    }

    function _movePosition(
        AccountTypes.SubAccount storage source,
        AccountTypes.SubAccount storage target,
        bytes32 marketId,
        uint256 portionBps,
        uint256 price
    ) internal returns (int256 movedSize) {
        AccountTypes.Position storage sourcePosition = source.positions[marketId];
        uint256 movedNotional = sourcePosition.openNotional.mulBps(portionBps);
        int256 absMovedSize = int256(FixedPoint.abs(sourcePosition.size).mulBps(portionBps));
        movedSize = sourcePosition.size > 0 ? absMovedSize : -absMovedSize;
        uint256 entryPrice = sourcePosition.entryPrice;
        _reducePosition(source, marketId, portionBps, price);
        _increasePosition(target, marketId, movedSize, movedNotional, entryPrice);
    }

    function _moveCollateral(
        AccountTypes.SubAccount storage source,
        AccountTypes.SubAccount storage target,
        uint256 portionBps
    ) internal {
        bytes32[] memory listed = source.collateralAssets;
        for (uint256 i = 0; i < listed.length; i++) {
            bytes32 asset = listed[i];
            uint256 amount = source.collateral[asset].mulBps(portionBps);
            if (amount == 0) continue;
            _removeCollateralAmount(source, asset, amount);
            _addCollateralAmount(target, asset, amount);
        }
    }

    function _moveDebtForTransfer(
        AccountTypes.SubAccount storage source,
        AccountTypes.SubAccount storage target,
        bytes32 asset,
        uint256 portionBps
    ) internal returns (uint256 principalMoved) {
        AccountTypes.DebtPosition storage sourceDebt = source.debts[asset];
        if (sourceDebt.principal == 0) return 0;
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        principalMoved = sourceDebt.principal.mulBps(portionBps);
        if (principalMoved == 0) return 0;

        sourceDebt.principal -= principalMoved;
        sourceDebt.updatedAt = block.timestamp;
        if (sourceDebt.principal == 0) {
            sourceDebt.index = 0;
            sourceDebt.createdAt = 0;
            _untrackDebtAsset(source, asset);
        }

        AccountTypes.DebtPosition storage targetDebt = target.debts[asset];
        if (targetDebt.principal == 0) {
            _trackDebtAsset(target, asset);
            targetDebt.asset = asset;
            targetDebt.principal = principalMoved;
            targetDebt.index = pool.borrowIndex;
            targetDebt.createdAt = block.timestamp;
            targetDebt.updatedAt = block.timestamp;
            return principalMoved;
        }

        uint256 totalPrincipal = targetDebt.principal + principalMoved;
        targetDebt.index = FixedPoint.weightedAverage(
            targetDebt.index,
            targetDebt.principal,
            pool.borrowIndex,
            principalMoved
        );
        targetDebt.principal = totalPrincipal;
        targetDebt.updatedAt = block.timestamp;
    }

    function _addCollateralAmount(
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (account.collateral[asset] == 0) {
            _trackCollateralAsset(account, asset);
        }
        account.collateral[asset] += amount;
    }

    function _removeCollateralAmount(
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 amount
    ) internal {
        uint256 balance = account.collateral[asset];
        if (balance < amount) revert InsufficientMargin();
        unchecked {
            account.collateral[asset] = balance - amount;
        }
        if (account.collateral[asset] == 0) {
            _untrackCollateralAsset(account, asset);
        }
    }

    function _useCollateralAmount(
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 desiredAmount
    ) internal returns (uint256 used) {
        uint256 balance = account.collateral[asset];
        used = balance < desiredAmount ? balance : desiredAmount;
        if (used != 0) {
            _removeCollateralAmount(account, asset, used);
        }
    }

    function _consumeCollateralValue(
        AccountTypes.SubAccount storage account,
        bytes32 preferredAsset,
        uint256 value
    ) internal {
        uint256 remaining = value;
        remaining = _consumeCollateralValueFromAsset(account, preferredAsset, remaining);
        bytes32[] memory listed = account.collateralAssets;
        for (uint256 i = 0; i < listed.length && remaining != 0; i++) {
            if (listed[i] == preferredAsset) continue;
            remaining = _consumeCollateralValueFromAsset(account, listed[i], remaining);
        }
        if (remaining != 0) revert InsufficientMargin();
    }

    function _consumeCollateralValueFromAsset(
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 remainingValue
    ) internal returns (uint256) {
        uint256 balance = account.collateral[asset];
        if (balance == 0 || remainingValue == 0) return remainingValue;
        uint256 availableValue = _assetValue(asset, balance);
        uint256 takeValue = remainingValue < availableValue ? remainingValue : availableValue;
        uint256 amount = _assetAmount(asset, takeValue);
        if (amount > balance) amount = balance;
        if (amount != 0) {
            _removeCollateralAmount(account, asset, amount);
        }
        uint256 actualValue = _assetValue(asset, amount);
        return remainingValue > actualValue ? remainingValue - actualValue : 0;
    }

    function _creditPositivePnl(
        AccountTypes.SubAccount storage account,
        bytes32 quoteAsset,
        uint256 pnlValue
    ) internal {
        uint256 amount = _assetAmount(quoteAsset, pnlValue);
        AccountTypes.LiquidityPool storage pool = _pools[quoteAsset];
        if (pool.cash < amount) revert InsufficientLiquidity(quoteAsset);
        pool.cash -= amount;
        _addCollateralAmount(account, quoteAsset, amount);
    }

    function _snapshot(
        address accountOwner,
        uint256 subAccountId
    ) internal view returns (AccountTypes.AccountSnapshot memory snapshot) {
        AccountTypes.SubAccount storage account = _accounts[accountOwner][subAccountId];
        bytes32[] memory collateralList = account.collateralAssets;
        for (uint256 i = 0; i < collateralList.length; i++) {
            bytes32 asset = collateralList[i];
            uint256 value = _assetValue(asset, account.collateral[asset]);
            snapshot.collateralValue += value;
            snapshot.weightedCollateralValue += value.mulBps(_assets[asset].collateralFactorBps);
        }

        bytes32[] memory debtList = account.debtAssets;
        for (uint256 i = 0; i < debtList.length; i++) {
            bytes32 asset = debtList[i];
            snapshot.debtValue += _assetValue(asset, _debtCurrentView(account, asset));
        }

        bytes32[] memory markets = account.marketIds;
        for (uint256 i = 0; i < markets.length; i++) {
            bytes32 marketId = markets[i];
            AccountTypes.Position storage position = account.positions[marketId];
            if (!position.exists || position.openNotional == 0) continue;
            AccountTypes.MarketConfig memory market = _markets[marketId];
            uint256 price = oracle.getPrice(market.baseAsset);
            snapshot.unrealizedPnl += _positionPnlValue(position, price);
            snapshot.initialRequirement += RiskMath.initialMarginForNotional(
                position.openNotional,
                market.maxLeverageBps
            );
            snapshot.maintenanceRequirement += RiskMath.maintenanceForNotional(
                position.openNotional,
                market.maintenanceMarginBps
            );
        }

        snapshot.marginRatioBps = RiskMath.marginRatioBps(
            snapshot.weightedCollateralValue,
            snapshot.debtValue,
            snapshot.unrealizedPnl
        );
        snapshot.healthy = RiskMath.isHealthy(
            RiskMath.HealthInputs({
                weightedCollateralValue: snapshot.weightedCollateralValue,
                debtValue: snapshot.debtValue,
                unrealizedPnl: snapshot.unrealizedPnl,
                initialRequirement: snapshot.initialRequirement,
                maintenanceRequirement: snapshot.maintenanceRequirement
            })
        );
        snapshot.liquidatable = RiskMath.isLiquidatable(
            RiskMath.HealthInputs({
                weightedCollateralValue: snapshot.weightedCollateralValue,
                debtValue: snapshot.debtValue,
                unrealizedPnl: snapshot.unrealizedPnl,
                initialRequirement: snapshot.initialRequirement,
                maintenanceRequirement: snapshot.maintenanceRequirement
            })
        );
    }

    function _requireHealthy(address accountOwner, uint256 subAccountId) internal view {
        if (!_snapshot(accountOwner, subAccountId).healthy) revert AccountNotHealthy();
    }

    function _requireHealthyOrEmpty(address accountOwner, uint256 subAccountId) internal view {
        AccountTypes.SubAccount storage account = _accounts[accountOwner][subAccountId];
        if (
            account.collateralAssets.length == 0 &&
            account.debtAssets.length == 0 &&
            account.marketIds.length == 0
        ) {
            return;
        }
        _requireHealthy(accountOwner, subAccountId);
    }

    function _positionPnlValue(
        AccountTypes.Position storage position,
        uint256 currentPrice
    ) internal view returns (int256) {
        if (!position.exists || position.openNotional == 0) return 0;
        return RiskMath.pnlForPosition(position.size, position.entryPrice, currentPrice);
    }

    function _debtCurrent(
        AccountTypes.SubAccount storage account,
        bytes32 asset
    ) internal view returns (uint256) {
        return _debtCurrentView(account, asset);
    }

    function _debtCurrentView(
        AccountTypes.SubAccount storage account,
        bytes32 asset
    ) internal view returns (uint256) {
        AccountTypes.DebtPosition storage debt = account.debts[asset];
        if (debt.principal == 0) return 0;
        uint256 index = debt.index == 0 ? FixedPoint.WAD : debt.index;
        return InterestRateModel.effectiveDebt(debt.principal, index, _pools[asset].borrowIndex);
    }

    function _debtValue(
        AccountTypes.SubAccount storage account,
        bytes32 asset
    ) internal view returns (uint256) {
        return _assetValue(asset, _debtCurrentView(account, asset));
    }

    function _principalForRepay(
        AccountTypes.SubAccount storage account,
        bytes32 asset,
        uint256 repayAmount
    ) internal view returns (uint256) {
        AccountTypes.DebtPosition storage debt = account.debts[asset];
        if (debt.principal == 0) return 0;
        return RiskMath.debtToPrincipal(repayAmount, debt.index, _pools[asset].borrowIndex);
    }

    function _poolDebtCurrent(bytes32 asset) internal view returns (uint256) {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        if (pool.totalBorrowPrincipal == 0) return 0;
        return FixedPoint.mulDivUp(pool.totalBorrowPrincipal, pool.borrowIndex, FixedPoint.WAD);
    }

    function _poolNetAssets(bytes32 asset) internal view returns (uint256) {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        uint256 gross = pool.cash + _poolDebtCurrent(asset);
        if (gross <= pool.reserveBalance) return 0;
        return gross - pool.reserveBalance;
    }

    function _accrue(bytes32 asset) internal returns (uint256 indexAfter) {
        AccountTypes.LiquidityPool storage pool = _pools[asset];
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        uint256 currentDebt = _poolDebtCurrent(asset);
        InterestRateModel.AccrualPreview memory preview = InterestRateModel.previewAccrual(
            pool.cash,
            currentDebt,
            pool.borrowIndex,
            elapsed,
            pool.reserveFactorBps,
            pool.baseRatePerSecond,
            pool.slope1PerSecond,
            pool.slope2PerSecond,
            pool.kinkUtilization
        );
        pool.borrowIndex = preview.indexAfter;
        pool.lastAccrualTime = block.timestamp;
        if (preview.reserveAccrued != 0) {
            pool.reserveBalance += preview.reserveAccrued;
        }
        emit InterestAccrued(
            asset,
            preview.indexBefore,
            preview.indexAfter,
            preview.interestAccrued,
            preview.reserveAccrued
        );
        return preview.indexAfter;
    }

    function _assetValue(bytes32 asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        AccountTypes.AssetConfig memory config = _assets[asset];
        return RiskMath.tokenValue(amount, oracle.getPrice(asset), config.decimals);
    }

    function _assetAmount(bytes32 asset, uint256 value) internal view returns (uint256) {
        if (value == 0) return 0;
        AccountTypes.AssetConfig memory config = _assets[asset];
        return RiskMath.tokenAmount(value, oracle.getPrice(asset), config.decimals);
    }

    function _account(
        address accountOwner,
        uint256 subAccountId
    ) internal returns (AccountTypes.SubAccount storage account) {
        account = _accounts[accountOwner][subAccountId];
        account.markActive();
    }

    function _validateAssetRisk(
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps
    ) internal pure {
        if (
            collateralFactorBps < MIN_COLLATERAL_FACTOR_BPS ||
            collateralFactorBps > MAX_COLLATERAL_FACTOR_BPS ||
            liquidationThresholdBps == 0 ||
            liquidationThresholdBps > collateralFactorBps ||
            liquidationBonusBps > MAX_LIQUIDATION_BONUS_BPS
        ) {
            revert InvalidRiskParameter();
        }
    }

    function _pullToken(bytes32 asset, address from, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = IEquinoxToken(_assets[asset].token).transferFrom(from, address(this), amount);
        if (!ok) revert TokenTransferFailed();
    }

    function _pushToken(bytes32 asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = IEquinoxToken(_assets[asset].token).transfer(to, amount);
        if (!ok) revert TokenTransferFailed();
    }

    function _trackCollateralAsset(
        AccountTypes.SubAccount storage account,
        bytes32 asset
    ) internal {
        if (!_contains(account.collateralAssets, asset)) {
            account.collateralAssets.push(asset);
        }
    }

    function _untrackCollateralAsset(
        AccountTypes.SubAccount storage account,
        bytes32 asset
    ) internal {
        _removeFromList(account.collateralAssets, asset);
    }

    function _trackDebtAsset(AccountTypes.SubAccount storage account, bytes32 asset) internal {
        if (!_contains(account.debtAssets, asset)) {
            account.debtAssets.push(asset);
        }
    }

    function _untrackDebtAsset(AccountTypes.SubAccount storage account, bytes32 asset) internal {
        _removeFromList(account.debtAssets, asset);
    }

    function _trackMarket(AccountTypes.SubAccount storage account, bytes32 marketId) internal {
        if (!_contains(account.marketIds, marketId)) {
            account.marketIds.push(marketId);
        }
    }

    function _untrackMarket(AccountTypes.SubAccount storage account, bytes32 marketId) internal {
        _removeFromList(account.marketIds, marketId);
    }

    function _contains(bytes32[] storage list, bytes32 id) internal view returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id) return true;
        }
        return false;
    }

    function _removeFromList(bytes32[] storage list, bytes32 id) internal {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] != id) continue;
            list[i] = list[list.length - 1];
            list.pop();
            return;
        }
    }
}
