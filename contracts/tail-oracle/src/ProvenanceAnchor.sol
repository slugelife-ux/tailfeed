// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ProvenanceAnchor
/// @notice Anchors TLS-notary attestation batches onchain. Each push cycle's
///         receipts are committed by two roots:
///         - merkleRoot over leaves keccak256(symbol ++ answer(u256) ++ genAt(u256))
///         - batchRoot  = keccak256(concat of sorted attestation sha256 digests)
///         Anyone can download the presentation files, verify them against
///         api.robinhood.com's real TLS session, recompute both roots, and
///         check them against the onchain anchor.
contract ProvenanceAnchor {
    address public immutable pusher;

    struct Anchor {
        bytes32 merkleRoot;
        bytes32 batchRoot;
        uint96 feedCount;
        uint64 blockTimestamp;
    }

    mapping(uint256 => Anchor) public anchors;
    uint256[] public anchorTimestamps;
    uint256 public anchorCount;

    event Anchored(
        uint256 indexed batchTimestamp,
        bytes32 merkleRoot,
        bytes32 batchRoot,
        uint256 feedCount
    );

    error NotPusher();

    constructor() {
        pusher = msg.sender;
    }

    /// @param batchTimestamp the attest_batch run timestamp (manifest key)
    function anchor(
        uint256 batchTimestamp,
        bytes32 merkleRoot,
        bytes32 batchRoot,
        uint256 feedCount
    ) external {
        if (msg.sender != pusher) revert NotPusher();
        require(anchors[batchTimestamp].merkleRoot == bytes32(0), "already anchored");
        anchors[batchTimestamp] =
            Anchor(merkleRoot, batchRoot, uint96(feedCount), uint64(block.timestamp));
        anchorTimestamps.push(batchTimestamp);
        anchorCount++;
        emit Anchored(batchTimestamp, merkleRoot, batchRoot, feedCount);
    }

    function allTimestamps() external view returns (uint256[] memory) {
        return anchorTimestamps;
    }
}
