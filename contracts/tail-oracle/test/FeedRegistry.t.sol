// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {FeedRegistry} from "../src/FeedRegistry.sol";
import {TailFeedProxy} from "../src/TailFeedProxy.sol";

contract FeedRegistryTest is Test {
    FeedRegistry registry;
    address pusher = address(0xA11CE);
    address stranger = address(0xB0B);

    uint256 constant CRM = 1;
    uint256 constant CIEN = 2;
    uint256 constant WDAY = 3;

    event StaleRound(uint256 indexed feedId, uint80 indexed roundId, uint64 updatedAt, uint64 heartbeat);

    function setUp() public {
        registry = new FeedRegistry(pusher);
        vm.startPrank(pusher);
        registry.register(CRM, "TAIL CRM / USD");
        registry.register(CIEN, "TAIL CIEN / USD");
        registry.register(WDAY, "TAIL WDAY / USD");
        vm.stopPrank();
    }

    function test_register_deploys_proxy_with_description() public view {
        TailFeedProxy proxy = TailFeedProxy(registry.proxyOf(CRM));
        assertEq(proxy.description(), "TAIL CRM / USD");
        assertEq(proxy.decimals(), 8);
        assertEq(address(proxy.registry()), address(registry));
        assertEq(proxy.feedId(), CRM);
    }

    function test_register_is_pusher_only_and_one_time() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.NotPusher.selector, stranger));
        registry.register(4, "TAIL NEW / USD");

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.FeedAlreadyRegistered.selector, CRM));
        registry.register(CRM, "TAIL CRM AGAIN / USD");
    }

    function test_batch_push_then_readback_through_proxies() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = CRM; ids[1] = CIEN; ids[2] = WDAY;
        int256[] memory answers = new int256[](3);
        answers[0] = 21532197553; answers[1] = 3176000000; answers[2] = 2575500000;
        uint64[] memory hbs = new uint64[](3);
        hbs[0] = 60; hbs[1] = 60; hbs[2] = 60;

        vm.prank(pusher);
        registry.batchPush(ids, answers, hbs);

        (uint80 rid, int256 ans, uint256 sat, uint256 uat, uint80 air) =
            TailFeedProxy(registry.proxyOf(CRM)).latestRoundData();
        assertEq(rid, 1);
        assertEq(ans, 21532197553);
        assertEq(air, 1);
        assertEq(uat, sat);

        (, ans,,,) = TailFeedProxy(registry.proxyOf(CIEN)).latestRoundData();
        assertEq(ans, 3176000000);

        ans = TailFeedProxy(registry.proxyOf(WDAY)).latestAnswer();
        assertEq(ans, 2575500000);
    }

    function test_batch_push_rounds_increment_per_feed() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = CRM; ids[1] = WDAY;
        int256[] memory a1 = new int256[](2);
        a1[0] = 100; a1[1] = 200;
        int256[] memory a2 = new int256[](2);
        a2[0] = 101; a2[1] = 201;
        uint64[] memory hbs = new uint64[](2);
        hbs[0] = 60; hbs[1] = 60;

        vm.startPrank(pusher);
        registry.batchPush(ids, a1, hbs);
        skip(30);
        registry.batchPush(ids, a2, hbs);
        vm.stopPrank();

        (uint80 ridCRM, int256 ansCRM,,,) = TailFeedProxy(registry.proxyOf(CRM)).latestRoundData();
        assertEq(ridCRM, 2);
        assertEq(ansCRM, 101);

        (uint80 ridW, int256 ansW,,,) = TailFeedProxy(registry.proxyOf(WDAY)).latestRoundData();
        assertEq(ridW, 2);
        assertEq(ansW, 201);
    }

    function test_gates() public {
        uint256[] memory oneId = new uint256[](1);
        oneId[0] = CRM;
        uint256[] memory badId = new uint256[](1);
        badId[0] = 99;
        uint64[] memory hb = new uint64[](1);
        hb[0] = 60;
        int256[] memory ok = new int256[](1);
        ok[0] = 100;
        int256[] memory zero = new int256[](1);
        zero[0] = 0;
        int256[] memory neg = new int256[](1);
        neg[0] = -1;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.NotPusher.selector, stranger));
        registry.batchPush(oneId, ok, hb);

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.InvalidAnswer.selector, 0));
        registry.batchPush(oneId, zero, hb);

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.InvalidAnswer.selector, -1));
        registry.batchPush(oneId, neg, hb);

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.FeedNotRegistered.selector, 99));
        registry.batchPush(badId, ok, hb);
    }

    function test_length_mismatch_reverts() public {
        uint256[] memory twoIds = new uint256[](2);
        twoIds[0] = CRM; twoIds[1] = CIEN;
        int256[] memory oneAns = new int256[](1);
        oneAns[0] = 100;
        uint64[] memory twoHbs = new uint64[](2);
        twoHbs[0] = 60; twoHbs[1] = 60;

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.LengthMismatch.selector));
        registry.batchPush(twoIds, oneAns, twoHbs);
    }

    function test_stale_round_emitted_after_heartbeat_gap() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = CRM;
        int256[] memory ans = new int256[](1);
        ans[0] = 100;
        uint64[] memory hb = new uint64[](1);
        hb[0] = 60;

        vm.prank(pusher);
        registry.batchPush(ids, ans, hb);

        uint64 pushedAt = uint64(block.timestamp);
        skip(120);

        int256[] memory ans2 = new int256[](1);
        ans2[0] = 101;
        vm.prank(pusher);
        vm.expectEmit(true, true, true, true, address(registry));
        emit StaleRound(CRM, 1, pushedAt, 60);
        registry.batchPush(ids, ans2, hb);
    }

    function test_get_feed_bundle() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = CRM;
        int256[] memory ans = new int256[](1);
        ans[0] = 100;
        uint64[] memory hb = new uint64[](1);
        hb[0] = 60;

        vm.prank(pusher);
        registry.batchPush(ids, ans, hb);

        (uint80 rid, int256 ansOut, uint64 sat, uint64 uat, address proxy) = registry.getFeed(CRM);
        assertEq(rid, 1);
        assertEq(ansOut, 100);
        assertEq(uat, sat);
        assertEq(proxy, registry.proxyOf(CRM));
    }

    function test_proxy_reverts_on_unregistered_feed() public {
        TailFeedProxy orphan = new TailFeedProxy(registry, 99);
        vm.expectRevert(abi.encodeWithSelector(FeedRegistry.FeedNotRegistered.selector, 99));
        orphan.latestRoundData();
    }
}

contract FeedRegistryInvariantTest is Test {
    FeedRegistry registry;
    address pusher = address(0xA11CE);

    function setUp() public {
        registry = new FeedRegistry(pusher);
    }

    function invariant_proxy_readback_equals_registry() public view {
        // before any registration, proxies do not exist; invariant only asserts
        // registry-consistency of rounds that exist
        for (uint256 i = 1; i <= 3; ++i) {
            if (registry.proxyOf(i) == address(0)) continue;
            (uint80 rid, int256 ans,,, ) = TailFeedProxy(registry.proxyOf(i)).latestRoundData();
            assertEq(rid, registry.roundIdOf(i));
            assertEq(ans, registry.answerOf(i));
            if (rid > 0) {
                assertGt(ans, 0);
            }
        }
    }
}
