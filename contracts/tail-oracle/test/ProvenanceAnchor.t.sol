// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProvenanceAnchor} from "../src/ProvenanceAnchor.sol";

contract ProvenanceAnchorTest is Test {
    ProvenanceAnchor anchor;

    function setUp() public {
        anchor = new ProvenanceAnchor();
    }

    function test_OnlyDeployerCanAnchor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ProvenanceAnchor.NotPusher.selector);
        anchor.anchor(1, bytes32(uint256(1)), bytes32(uint256(2)), 60);
    }

    function test_AnchorStoresAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit ProvenanceAnchor.Anchored(1794994448, bytes32(uint256(0x91)), bytes32(uint256(0xc1)), 60);
        anchor.anchor(1794994448, bytes32(uint256(0x91)), bytes32(uint256(0xc1)), 60);

        (bytes32 merkle, bytes32 batch, uint96 count, uint64 ts) = anchor.anchors(1794994448);
        assertEq(merkle, bytes32(uint256(0x91)));
        assertEq(batch, bytes32(uint256(0xc1)));
        assertEqUint(count, 60);
        assertGt(ts, 0);
        assertEqUint(anchor.anchorCount(), 1);
        assertEqUint(anchor.anchorTimestamps(0), 1794994448);
    }

    function test_DoubleAnchorRejected() public {
        anchor.anchor(42, bytes32(uint256(1)), bytes32(uint256(2)), 5);
        vm.expectRevert();
        anchor.anchor(42, bytes32(uint256(3)), bytes32(uint256(4)), 5);
    }

    function test_ZeroRootNotOverwritten() public {
        // a different timestamp is a new anchor
        anchor.anchor(1, bytes32(uint256(1)), bytes32(uint256(2)), 5);
        anchor.anchor(2, bytes32(uint256(3)), bytes32(uint256(4)), 6);
        assertEqUint(anchor.anchorCount(), 2);
    }

    function test_AllTimestamps() public {
        anchor.anchor(5, bytes32(uint256(1)), bytes32(uint256(2)), 5);
        anchor.anchor(9, bytes32(uint256(3)), bytes32(uint256(4)), 6);
        uint256[] memory ts = anchor.allTimestamps();
        assertEqUint(ts.length, 2);
        assertEqUint(ts[0], 5);
        assertEqUint(ts[1], 9);
    }
}
