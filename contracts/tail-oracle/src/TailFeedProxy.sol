// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FeedRegistry} from "./FeedRegistry.sol";

/// @title TailFeedProxy
/// @notice Per-feed AggregatorV3-compatible read surface over FeedRegistry.
///         Deployed by the registry at register() time. Developers who already
///         read Chainlink feeds swap this address in and change nothing else.
contract TailFeedProxy {
    FeedRegistry public immutable registry;
    uint256 public immutable feedId;

    constructor(FeedRegistry registry_, uint256 feedId_) {
        registry = registry_;
        feedId = feedId_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (registry.proxyOf(feedId) == address(0)) revert FeedRegistry.FeedNotRegistered(feedId);
        roundId = registry.roundIdOf(feedId);
        answer = registry.answerOf(feedId);
        startedAt = registry.startedAtOf(feedId);
        updatedAt = registry.updatedAtOf(feedId);
        answeredInRound = roundId;
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
