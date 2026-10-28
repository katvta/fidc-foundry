// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title YieldCalculator
/// @notice Library for handling yield scaling in the FIDC system
library YieldCalculator {
    uint256 public constant PRECISION = 10000; // base 100% = 10000 BPS
    uint256 public constant MAX_TIME_YIELD = 365 days; // 1 year maximum for yield calculation

    /**
     * @notice Converts an amount from its native decimals to WAD (18 decimals)
     * @dev ✅ FIX: Adiciona guard para prevenir overflow com decimais absurdos
     * @param amount Amount in native decimals
     * @param decimals Number of decimals (must be <= 18)
     * @return Amount in WAD (18 decimals)
     */
    function scaleToWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        require(decimals <= 18, "Unsupported decimals");
        if (decimals == 18) {
            return amount;
        }
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    /**
     * @notice Converts an amount from WAD back to its native decimals
     * @dev ✅ FIX: Adiciona guard para prevenir overflow com decimais absurdos
     * @param wadAmount Amount in WAD (18 decimals)
     * @param decimals Number of decimals (must be <= 18)
     * @return Amount in native decimals
     */
    function scaleFromWad(uint256 wadAmount, uint8 decimals) internal pure returns (uint256) {
        require(decimals <= 18, "Unsupported decimals");
        if (decimals == 18) {
            return wadAmount;
        } else if (decimals < 18) {
            return wadAmount / (10 ** (18 - decimals));
        } else {
            return wadAmount * (10 ** (decimals - 18));
        }
    }
}
