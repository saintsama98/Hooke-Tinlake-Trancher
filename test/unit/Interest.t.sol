// SPDX-License-Identifier: AGPL-3.0-only
// Hooke: the compounding guards revert with custom errors.
// @author adiii.eth

pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/math/Interest.sol";

contract InterestTest is Test {
    Interest internal interest;

    function setUp() public {
        interest = new Interest();
        vm.warp(1_000_000);
    }

    function test_compounding_revertsOnFutureTimestamp() public {
        vm.expectRevert(Interest.InvalidTimestamp.selector);
        interest.compounding(1e27, 1e27, block.timestamp + 1, 1e18);
    }

    function test_compounding_revertsOnZeroRate() public {
        vm.expectRevert(Interest.ZeroRate.selector);
        interest.compounding(0, 1e27, block.timestamp, 1e18);
    }

    function test_compounding_atUnitRateChargesNothing() public view {
        (uint256 chi, uint256 delta) = interest.compounding(1e27, 1e27, block.timestamp - 100, 1e18);
        assertEq(chi, 1e27);
        assertEq(delta, 0);
    }
}
