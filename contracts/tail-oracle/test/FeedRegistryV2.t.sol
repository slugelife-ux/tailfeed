// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {FeedRegistryV2} from "../src/FeedRegistryV2.sol";
import {TailFeedProxyV2} from "../src/TailFeedProxyV2.sol";

contract FeedRegistryV2Test is Test {
    FeedRegistryV2 registry;
    address pusher = makeAddr("pusher");
    address stranger = makeAddr("stranger");

    uint256 constant FEED = 1;

    function setUp() public {
        vm.prank(pusher);
        registry = new FeedRegistryV2(pusher);
        vm.prank(pusher);
        registry.register(FEED, "TAIL CRM/USD");
    }

    function _push(int256 answer, uint64 heartbeat) internal {
        uint256[] memory ids = new uint256[](1);
        int256[] memory answers = new int256[](1);
        uint64[] memory hbs = new uint64[](1);
        ids[0] = FEED;
        answers[0] = answer;
        hbs[0] = heartbeat;
        vm.prank(pusher);
        registry.batchPush(ids, answers, hbs);
    }

    function test_getRoundData_returns_exact_history() public {
        TailFeedProxyV2 proxy = TailFeedProxyV2(registry.proxyOf(FEED));

        vm.warp(1000);
        _push(12345000000, 300);
        vm.warp(1100);
        _push(12400000000, 300);
        vm.warp(1200);
        _push(12450000000, 300);

        // latest round (3) through both surfaces
        (uint80 rid, int256 ans, uint256 started, uint256 updated, uint80 air) = proxy.latestRoundData();
        assertEq(rid, 3);
        assertEq(ans, 12450000000);
        assertEq(started, 1200);
        assertEq(updated, 1200);
        assertEq(air, 3);

        // historical rounds bit-for-bit
        (rid, ans, started, updated, air) = proxy.getRoundData(1);
        assertEq(rid, 1);
        assertEq(ans, 12345000000);
        assertEq(started, 1000);
        assertEq(updated, 1000);
        assertEq(air, 1);

        (rid, ans, started, updated, air) = proxy.getRoundData(2);
        assertEq(rid, 2);
        assertEq(ans, 12400000000);
        assertEq(started, 1100);
        assertEq(updated, 1100);
        assertEq(air, 2);
    }

    function test_getRoundData_reverts_on_unknown_round() public {
        TailFeedProxyV2 proxy = TailFeedProxyV2(registry.proxyOf(FEED));
        _push(12345000000, 300);

        vm.expectRevert(abi.encodeWithSelector(FeedRegistryV2.RoundOutOfRange.selector, FEED, 2));
        proxy.getRoundData(2);

        vm.expectRevert(abi.encodeWithSelector(FeedRegistryV2.RoundOutOfRange.selector, FEED, 0));
        proxy.getRoundData(0);
    }

    function test_onlyPusher_canPush() public {
        uint256[] memory ids = new uint256[](1);
        int256[] memory answers = new int256[](1);
        uint64[] memory hbs = new uint64[](1);
        ids[0] = FEED;
        answers[0] = 100;
        hbs[0] = 300;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistryV2.NotPusher.selector, stranger));
        registry.batchPush(ids, answers, hbs);
    }

    function test_onlyPusher_canRegister() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistryV2.NotPusher.selector, stranger));
        registry.register(99, "TAIL X/USD");
    }

    function test_duplicate_register_reverts() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistryV2.FeedAlreadyRegistered.selector, FEED));
        registry.register(FEED, "TAIL CRM/USD");
    }

    function test_oversized_answer_reverts() public {
        uint256[] memory ids = new uint256[](1);
        int256[] memory answers = new int256[](1);
        uint64[] memory hbs = new uint64[](1);
        ids[0] = FEED;
        answers[0] = int256(type(int192).max) + 1;
        hbs[0] = 300;
        vm.prank(pusher);
        vm.expectRevert(
            abi.encodeWithSelector(FeedRegistryV2.InvalidAnswer.selector, int256(type(int192).max) + 1)
        );
        registry.batchPush(ids, answers, hbs);
    }

    function test_history_survives_many_rounds_fuzz(uint8 pushes) public {
        vm.assume(pushes > 0 && pushes < 60);
        TailFeedProxyV2 proxy = TailFeedProxyV2(registry.proxyOf(FEED));
        int256 base = 15000000000;
        for (uint8 i = 0; i < pushes; ++i) {
            vm.warp(1000 + uint256(i) * 60);
            _push(base + int256(uint256(i)) * 100, 300);
        }
        // spot-check first, middle, last
        uint80 last = uint80(pushes);
        (, int256 a1,,,) = proxy.getRoundData(1);
        assertEq(a1, base);
        (, int256 aL,,,) = proxy.getRoundData(last);
        assertEq(aL, base + int256(uint256(pushes - 1)) * 100);
        if (pushes > 2) {
            (, int256 aM,,,) = proxy.getRoundData(last / 2 + 1);
            assertEq(aM, base + int256(uint256(last / 2)) * 100);
        }
    }
}
