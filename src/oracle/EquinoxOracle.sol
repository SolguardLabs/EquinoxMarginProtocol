// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEquinoxOracle} from "../interfaces/IEquinoxOracle.sol";

contract EquinoxOracle is IEquinoxOracle {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
    }

    address public owner;
    uint256 public maxDelay = 2 hours;

    mapping(address => bool) public publishers;
    mapping(bytes32 => PriceData) private _prices;

    error NotOwner();
    error NotPublisher();
    error ZeroPrice();
    error StalePrice(bytes32 asset);
    error MissingPrice(bytes32 asset);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPublisher() {
        if (!publishers[msg.sender]) revert NotPublisher();
        _;
    }

    constructor(address initialOwner) {
        owner = initialOwner;
        publishers[initialOwner] = true;
        emit PublisherUpdated(initialOwner, true);
    }

    function setPublisher(address publisher, bool enabled) external onlyOwner {
        publishers[publisher] = enabled;
        emit PublisherUpdated(publisher, enabled);
    }

    function setMaxDelay(uint256 maxDelay_) external onlyOwner {
        maxDelay = maxDelay_;
        emit StalenessUpdated(maxDelay_);
    }

    function postPrice(bytes32 asset, uint256 price) external onlyPublisher {
        if (price == 0) revert ZeroPrice();
        _prices[asset] = PriceData({price: price, updatedAt: block.timestamp});
        emit PricePosted(asset, price, block.timestamp, msg.sender);
    }

    function postPrices(
        bytes32[] calldata assets,
        uint256[] calldata prices
    ) external onlyPublisher {
        require(assets.length == prices.length, "ORACLE_LENGTH");
        for (uint256 i = 0; i < assets.length; i++) {
            if (prices[i] == 0) revert ZeroPrice();
            _prices[assets[i]] = PriceData({price: prices[i], updatedAt: block.timestamp});
            emit PricePosted(assets[i], prices[i], block.timestamp, msg.sender);
        }
    }

    function getPrice(bytes32 asset) external view override returns (uint256 price) {
        PriceData memory data = _prices[asset];
        if (data.price == 0) revert MissingPrice(asset);
        if (block.timestamp > data.updatedAt + maxDelay) revert StalePrice(asset);
        return data.price;
    }

    function getPriceUnsafe(
        bytes32 asset
    ) external view override returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = _prices[asset];
        return (data.price, data.updatedAt);
    }

    function isFresh(bytes32 asset) external view override returns (bool) {
        PriceData memory data = _prices[asset];
        return data.price != 0 && block.timestamp <= data.updatedAt + maxDelay;
    }
}
