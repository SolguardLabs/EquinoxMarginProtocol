// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEquinoxOracle {
    event PricePosted(
        bytes32 indexed asset,
        uint256 price,
        uint256 timestamp,
        address indexed publisher
    );
    event PublisherUpdated(address indexed publisher, bool enabled);
    event StalenessUpdated(uint256 maxDelay);

    function getPrice(bytes32 asset) external view returns (uint256 price);

    function getPriceUnsafe(bytes32 asset) external view returns (uint256 price, uint256 updatedAt);

    function isFresh(bytes32 asset) external view returns (bool);
}
