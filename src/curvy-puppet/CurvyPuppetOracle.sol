// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Ownable} from "solady/auth/Ownable.sol";

contract CurvyPuppetOracle is Ownable {
    mapping(address asset => Price) public prices;

    struct Price {
        uint256 value;
        uint256 expiration;
    }

    error InvalidPrice();
    error InvalidExpiration();
    error StalePrice();
    error UnsupportedAsset();

    constructor() {
        _initializeOwner(msg.sender);
    }

    function getPrice(address asset) external view returns (Price memory) {
        Price memory price = prices[asset];

        if (price.value == 0) revert UnsupportedAsset();
        // so the price is only available before expiration
        if (block.timestamp > price.expiration) revert StalePrice();

        return price;
    }

    // who create this ORACLE can change the price []
    function setPrice(address asset, uint256 value, uint256 expiration) external onlyOwner {
        if (value == 0) revert InvalidPrice();

        //@audit: the price would never be resetted if timestamp >= last expiration
        if (expiration <= block.timestamp || expiration > block.timestamp + 2 days) revert InvalidExpiration();
        prices[asset] = Price(value, expiration);
    }
}
