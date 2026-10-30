// SPDX-License-Identifier: AGPL-3.0-only
// Hooke: drives a deployed pool through random orders, epochs and NAV moves for the invariant suite.
// @author adiii.eth

pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../../script/LenderDeployer.s.sol";
import "../../mocks/SimpleToken.sol";
import "../../mocks/SimpleNAVFeed.sol";

contract PoolHandler is Test {
    SimpleToken public currency;
    SimpleToken public seniorToken;
    SimpleToken public juniorToken;
    SimpleNAVFeed public navFeed;
    EpochCoordinator public coordinator;
    Tranche public seniorTranche;
    Tranche public juniorTranche;
    Operator public seniorOp;
    Operator public juniorOp;

    address[] public actors;

    uint256 public epochsExecuted;
    uint256 public navMoves;

    constructor(LenderDeployer d, SimpleToken c, SimpleToken s, SimpleToken j, SimpleNAVFeed n, address[] memory a) {
        currency = c;
        seniorToken = s;
        juniorToken = j;
        navFeed = n;
        coordinator = d.coordinator();
        seniorTranche = d.seniorTranche();
        juniorTranche = d.juniorTranche();
        seniorOp = d.seniorOperator();
        juniorOp = d.juniorOperator();
        actors = a;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function supply(uint256 seed, uint256 amount, bool senior) external {
        address who = _actor(seed);
        amount = bound(amount, 0, currency.balanceOf(who));
        vm.prank(who);
        try (senior ? seniorOp : juniorOp).supplyOrder(amount) {} catch {}
    }

    function redeem(uint256 seed, uint256 amount, bool senior) external {
        address who = _actor(seed);
        amount = bound(amount, 0, (senior ? seniorToken : juniorToken).balanceOf(who));
        vm.prank(who);
        try (senior ? seniorOp : juniorOp).redeemOrder(amount) {} catch {}
    }

    function release(uint256 seed, bool senior) external {
        vm.prank(_actor(seed));
        try (senior ? seniorOp : juniorOp).deservedRelease() {} catch {}
    }

    /// Closes an epoch. If the orders do not fit, a submission period opens; a solution that
    /// fills no orders is submitted and executed after the challenge period.
    function closeEpoch() external {
        vm.warp(block.timestamp + 1 days + 1);
        if (!coordinator.submissionPeriod()) {
            try coordinator.closeEpoch() {} catch {}
        }
        if (coordinator.submissionPeriod()) {
            try coordinator.submitSolution(0, 0, 0, 0) {} catch {}
            vm.warp(block.timestamp + 1 hours + 1);
            try coordinator.executeEpoch() {} catch {}
        }
        epochsExecuted = coordinator.lastEpochExecuted();
    }

    /// Moves the value of the loan book up or down. Cash in the reserve is never touched.
    function moveNav(uint256 nav) external {
        navFeed.file("nav", bound(nav, 0, 2_000 ether));
        navMoves++;
    }
}
