// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Chainlink Aggregator V3 Interface
/// @notice Minimal subset of the Chainlink `AggregatorV3Interface` used by `LuciRoyaltyModel`.
interface IAggregatorV3 {
    /// @notice Number of decimals the feed's `answer` is denominated in
    function decimals() external view returns (uint8);

    /// @notice Latest round data reported by the feed
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
