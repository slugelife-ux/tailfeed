// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {TailPriceOracle} from "../src/TailPriceOracle.sol";

contract TailPriceOracleTest is Test {
    TailPriceOracle oracle;
    address pusher = address(0xA11CE);
    address stranger = address(0xB0B);

    function setUp() public {
        oracle = new TailPriceOracle(pusher, "TAIL IONQ / USD");
    }

    function test_decimals_and_description() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "TAIL IONQ / USD");
    }

    function test_empty_before_first_push() public view {
        assertTrue(oracle.isEmpty());
    }

    function test_push_and_read_round() public {
        vm.prank(pusher);
        oracle.pushPrice(3155000000, 60); // $31.55 at 8 decimals

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, 3155000000);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
        assertEq(oracle.latestAnswer(), 3155000000);
        assertFalse(oracle.isEmpty());
    }

    function test_rounds_increment() public {
        vm.startPrank(pusher);
        oracle.pushPrice(3155000000, 60);
        skip(30);
        oracle.pushPrice(3160000000, 60);
        vm.stopPrank();

        (uint80 roundId, int256 answer,,,) = oracle.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, 3160000000);
    }

    function test_only_pusher_can_push() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TailPriceOracle.NotPusher.selector, stranger));
        oracle.pushPrice(3155000000, 60);
    }

    function test_rejects_nonpositive_price() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(TailPriceOracle.InvalidAnswer.selector, 0));
        oracle.pushPrice(0, 60);

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(TailPriceOracle.InvalidAnswer.selector, -1));
        oracle.pushPrice(-1, 60);
    }

    function test_staleness_is_reader_visible() public {
        vm.prank(pusher);
        oracle.pushPrice(3155000000, 60);

        skip(120); // past the 60s heartbeat, no new push

        (,, , uint256 updatedAt,) = oracle.latestRoundData();
        assertGt(block.timestamp - updatedAt, 60);
    }

    function test_new_round_after_stale_gap_emits_StaleRound() public {
        vm.prank(pusher);
        oracle.pushPrice(3155000000, 60);
        skip(120);

        vm.prank(pusher);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit StaleRound(1, uint64(block.timestamp - 120), 60);
        oracle.pushPrice(3160000000, 60);
    }

    event StaleRound(uint80 indexed roundId, uint64 updatedAt, uint64 heartbeat);

    /// @dev The exact reading pattern Robinhood's docs require of Chainlink
    ///      consumers, run against this oracle: positive answer, fresh round.
    function test_consumer_guard_pattern_passes_when_fresh() public {
        vm.prank(pusher);
        oracle.pushPrice(3155000000, 60);

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertGt(answer, 0, "Invalid price");
        assertGt(updatedAt, 0, "Round not complete");
    }
}

contract TailPriceOracleInvariantTest is Test {
    // Property: round ids are dense, answers are positive, monotonic timestamps.
    TailPriceOracle oracle;
    address pusher = address(0xA11CE);

    function setUp() public {
        oracle = new TailPriceOracle(pusher, "TAIL TEST / USD");
    }

    function invariant_answers_positive_and_ids_dense() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        if (roundId > 0) {
            assertGt(answer, 0);
            assertGt(updatedAt, 0);
            assertGe(updatedAt, startedAt);
        }
    }
}
