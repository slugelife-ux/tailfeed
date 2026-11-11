// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title TailPriceOracle
/// @notice AggregatorV3-compatible price feed for Stock Tokens that have no
///         Chainlink feed on Robinhood Chain (chain 4663).
/// @dev Written to match the read surface Chainlink consumers already code
///      against, so a protocol can swap a Chainlink proxy address for one of
///      these without touching integration code.
///
///      Admin power, stated plainly: exactly one pusher address may publish
///      rounds. The deployer sets it at construction. It is not hidden, not
///      upgradeable, and there is no owner function that changes pricing rules
///      after deploy. If this ever holds value, the pusher key moves to a
///      timelock or multisig in a new deployment, by the owner, in the open.
///
///      Prices are for the tail of Stock Tokens with no existing feed. Feeds
///      for the 33 already-priced tokens stay on Chainlink; this does not
///      compete with them.
contract TailPriceOracle {
    uint8 public constant DECIMALS = 8;

    address public immutable pusher;
    string public description;

    struct Round {
        int256 answer;
        uint64 startedAt;
        uint64 updatedAt;
        uint80 answeredInRound;
    }

    uint80 private latestRoundId;
    mapping(uint80 => Round) private rounds;

    event NewRound(uint80 indexed roundId, int256 answer, uint64 updatedAt);
    event StaleRound(uint80 indexed roundId, uint64 updatedAt, uint64 heartbeat);

    error NotPusher(address caller);
    error InvalidAnswer(int256 answer);

    constructor(address pusher_, string memory description_) {
        pusher = pusher_;
        description = description_;
    }

    /// @notice Publish a round. Reverts from any address except the pusher.
    function pushPrice(int256 answer, uint64 heartbeat) external {
        if (msg.sender != pusher) revert NotPusher(msg.sender);
        if (answer <= 0) revert InvalidAnswer(answer);

        latestRoundId += 1;
        uint80 id = latestRoundId;
        uint64 now_ = uint64(block.timestamp);

        rounds[id] = Round({
            answer: answer,
            startedAt: now_,
            updatedAt: now_,
            answeredInRound: id
        });

        emit NewRound(id, answer, now_);

        // Flag a previous round that went past its heartbeat before this push
        // landed. Advisory only: readers are expected to check staleness too,
        // exactly as Robinhood's own docs instruct for Chainlink feeds.
        if (id > 1) {
            Round storage prev = rounds[uint80(id - 1)];
            if (now_ > prev.updatedAt + heartbeat) {
                emit StaleRound(id - 1, prev.updatedAt, heartbeat);
            }
        }
    }

    /// @notice Chainlink-compatible read. Consumers run their own staleness
    ///         check on `updatedAt`, same as they must for any feed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round storage r = rounds[latestRoundId];
        return (latestRoundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    /// @dev Convenience view mirroring the older Aggregator interface some
    ///      tooling still calls.
    function latestAnswer() external view returns (int256) {
        return rounds[latestRoundId].answer;
    }

    /// @dev True when no round has ever been published.
    function isEmpty() external view returns (bool) {
        return latestRoundId == 0;
    }
}
