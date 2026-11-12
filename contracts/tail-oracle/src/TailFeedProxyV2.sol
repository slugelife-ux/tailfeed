// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FeedRegistryV2} from "./FeedRegistryV2.sol";

/// @title TailFeedProxyV2
/// @notice v1.1 per-feed AggregatorV3-compatible read surface over
///         FeedRegistryV2: full getRoundData(uint80) for any past round, on
///         top of the usual latest reads. Deployed by the registry at
///         register() time. Developers who already read Chainlink feeds swap
///         this address in and change nothing else.
contract TailFeedProxyV2 {
    FeedRegistryV2 public immutable registry;
    uint256 public immutable feedId;

    constructor(FeedRegistryV2 registry_, uint256 feedId_) {
        registry = registry_;
        feedId = feedId_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (registry.proxyOf(feedId) == address(0)) revert FeedRegistryV2.FeedNotRegistered(feedId);
        roundId = registry.roundIdOf(feedId);
        answer = registry.answerOf(feedId);
        startedAt = registry.startedAtOf(feedId);
        updatedAt = registry.updatedAtOf(feedId);
        answeredInRound = roundId;
    }

    /// @notice Full AggregatorV3 historical round read (v1.1).
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (int256 a, uint64 s, uint64 u) = registry.getRound(feedId, _roundId);
        roundId = _roundId;
        answer = a;
        startedAt = s;
        updatedAt = u;
        answeredInRound = _roundId;
    }

    function latestAnswer() external view returns (int256) {
        return registry.answerOf(feedId);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return registry.descriptionOf(feedId);
    }
}
