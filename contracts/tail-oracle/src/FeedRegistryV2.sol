// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {TailFeedProxyV2} from "./TailFeedProxyV2.sol";

/// @title FeedRegistryV2
/// @notice V1.1 of the TailFeed registry: identical publish model to V1 with
///         the addition of per-round history. Every pushed round is stored,
///         so consumers can call getRoundData(roundId) on the proxy to read
///         any past round, and build TWAPs or sparklines onchain.
/// @dev Admin power, stated plainly: exactly one pusher address may register
///      feeds and publish rounds. Set at construction, immutable, no owner
///      functions, no upgrade path. At mainnet the pusher key moves to a
///      timelock or multisig in a new deployment, by the owner, in the open.
///      History is append-only (3 extra SSTOREs per feed per push). A later
///      mainnet revision may ring-buffer the tail to cut gas; the read
///      surface will not change.
contract FeedRegistryV2 {
    uint8 public constant DECIMALS = 8;

    address public immutable pusher;

    // Flat per-feed storage; feedId is a stable small integer chosen offchain.
    mapping(uint256 => string) public descriptionOf;
    mapping(uint256 => uint80) public roundIdOf;
    mapping(uint256 => int256) public answerOf;
    mapping(uint256 => uint64) public startedAtOf;
    mapping(uint256 => uint64) public updatedAtOf;
    mapping(uint256 => address) public proxyOf;

    // v1.1: append-only round history. historyOf[feedId][roundId] exists for
    // every round from 1 to roundIdOf[feedId]. Round 0 is never written.
    struct Round {
        int192 answer;
        uint32 startedAt;
        uint32 updatedAt;
    }
    mapping(uint256 => mapping(uint80 => Round)) public historyOf;

    event FeedRegistered(uint256 indexed feedId, address indexed proxy, string description);
    event RoundPushed(uint256 indexed feedId, uint80 roundId, int256 answer, uint64 updatedAt, uint64 heartbeat);
    event StaleRound(uint256 indexed feedId, uint80 indexed roundId, uint64 updatedAt, uint64 heartbeat);

    error NotPusher(address caller);
    error LengthMismatch();
    error InvalidAnswer(int256 answer);
    error FeedNotRegistered(uint256 feedId);
    error FeedAlreadyRegistered(uint256 feedId);

    constructor(address pusher_) {
        pusher = pusher_;
    }

    /// @notice Register a feed and deploy its proxy. Pusher only, one-time per feedId.
    function register(uint256 feedId, string calldata description) external returns (address proxy) {
        if (msg.sender != pusher) revert NotPusher(msg.sender);
        if (proxyOf[feedId] != address(0)) revert FeedAlreadyRegistered(feedId);

        proxy = address(new TailFeedProxyV2(this, feedId));
        proxyOf[feedId] = proxy;
        descriptionOf[feedId] = description;

        emit FeedRegistered(feedId, proxy, description);
    }

    /// @notice Publish one round for many feeds in one transaction. Pusher only.
    ///         Readers run their own staleness check on updatedAt, exactly as
    ///         Robinhood's docs instruct for Chainlink feeds.
    function batchPush(
        uint256[] calldata feedIds,
        int256[] calldata answers,
        uint64[] calldata heartbeats
    ) external {
        if (msg.sender != pusher) revert NotPusher(msg.sender);
        uint256 n = feedIds.length;
        if (n != answers.length || n != heartbeats.length) revert LengthMismatch();

        uint64 now_ = uint64(block.timestamp);
        for (uint256 i = 0; i < n; ++i) {
            uint256 feedId = feedIds[i];
            int256 answer = answers[i];
            if (answer <= 0 || answer > type(int192).max) revert InvalidAnswer(answer);
            if (proxyOf[feedId] == address(0)) revert FeedNotRegistered(feedId);

            uint80 prevId = roundIdOf[feedId];
            if (prevId != 0) {
                uint64 prevUpdatedAt = updatedAtOf[feedId];
                uint64 hb = heartbeats[i];
                if (now_ > prevUpdatedAt + hb) {
                    emit StaleRound(feedId, prevId, prevUpdatedAt, hb);
                }
            }

            uint80 roundId = prevId + 1;
            roundIdOf[feedId] = roundId;
            answerOf[feedId] = answer;
            startedAtOf[feedId] = now_;
            updatedAtOf[feedId] = now_;

            // v1.1: store the round for getRoundData. int192/uint32 pack the
            // struct into one storage slot per round.
            historyOf[feedId][roundId] = Round(int192(answer), uint32(now_), uint32(now_));

            emit RoundPushed(feedId, roundId, answer, now_, heartbeats[i]);
        }
    }

    /// @notice Whole-feed read for consumers that prefer one call.
    function getFeed(uint256 feedId)
        external
        view
        returns (uint80 roundId, int256 answer, uint64 startedAt, uint64 updatedAt, address proxy)
    {
        if (proxyOf[feedId] == address(0)) revert FeedNotRegistered(feedId);
        return (roundIdOf[feedId], answerOf[feedId], startedAtOf[feedId], updatedAtOf[feedId], proxyOf[feedId]);
    }

    /// @notice Historical round read (v1.1). Round 0 does not exist.
    function getRound(uint256 feedId, uint80 roundId)
        external
        view
        returns (int256 answer, uint64 startedAt, uint64 updatedAt)
    {
        if (roundId == 0 || roundId > roundIdOf[feedId]) revert RoundOutOfRange(feedId, roundId);
        Round storage r = historyOf[feedId][roundId];
        return (int256(r.answer), uint64(r.startedAt), uint64(r.updatedAt));
    }

    error RoundOutOfRange(uint256 feedId, uint80 roundId);
}
