// SPDX-License-Identifier: AGPL-3.0-only
// Hooke: unit tests for the ward-based authorization mixin.
// @author adiii.eth

pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/auth/Auth.sol";

contract AuthHarness is Auth {
    uint256 public hits;

    function guarded() external auth {
        hits++;
    }
}

contract AuthTest is Test {
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    AuthHarness internal a;
    address internal alice = makeAddr("alice");

    function setUp() public {
        a = new AuthHarness();
    }

    function test_deployerIsWard() public view {
        assertEq(a.wards(address(this)), 1);
    }

    function test_constructorEmitsRely() public {
        vm.expectEmit(true, false, false, false);
        emit Rely(address(this));
        new AuthHarness();
    }

    function test_relyGrantsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(a));
        emit Rely(alice);
        a.rely(alice);
        assertEq(a.wards(alice), 1);
        vm.prank(alice);
        a.guarded();
        assertEq(a.hits(), 1);
    }

    function test_denyRevokesAndEmits() public {
        a.rely(alice);
        vm.expectEmit(true, false, false, false, address(a));
        emit Deny(alice);
        a.deny(alice);
        assertEq(a.wards(alice), 0);
        vm.prank(alice);
        vm.expectRevert(Auth.NotAuthorized.selector);
        a.guarded();
    }

    function test_wardCanDenyItself() public {
        a.deny(address(this));
        vm.expectRevert(Auth.NotAuthorized.selector);
        a.rely(alice);
    }

    function testFuzz_strangerCannotCallAuth(address who) public {
        vm.assume(who != address(this));
        vm.startPrank(who);
        vm.expectRevert(Auth.NotAuthorized.selector);
        a.guarded();
        vm.expectRevert(Auth.NotAuthorized.selector);
        a.rely(who);
        vm.expectRevert(Auth.NotAuthorized.selector);
        a.deny(address(this));
        vm.stopPrank();
    }
}
