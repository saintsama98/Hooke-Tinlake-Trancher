// SPDX-License-Identifier: AGPL-3.0-only
// Hooke: unit tests for the assessor's accrual, pricing and waterfall.
// @author adiii.eth

pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/lender/Assessor.sol";
import "../mocks/SimpleNAVFeed.sol";

/// @dev Stands in for a tranche (tokenSupply) and the reserve (totalBalance).
contract AssessorStub {
    uint256 public tokenSupply;
    uint256 public totalBalance;

    function setSupply(uint256 v) external {
        tokenSupply = v;
    }

    function setBalance(uint256 v) external {
        totalBalance = v;
    }
}

contract AssessorTest is Test {
    uint256 internal constant ONE = 1e27;
    // about 5% a year, compounding per second
    uint256 internal constant RATE = ONE + 1585489599188229325;

    Assessor internal assessor;
    SimpleNAVFeed internal nav;
    AssessorStub internal reserve;
    AssessorStub internal senior;
    AssessorStub internal junior;

    function setUp() public {
        vm.warp(1_000_000);
        assessor = new Assessor();
        nav = new SimpleNAVFeed();
        reserve = new AssessorStub();
        senior = new AssessorStub();
        junior = new AssessorStub();
        assessor.depend("navFeed", address(nav));
        assessor.depend("reserve", address(reserve));
        assessor.depend("seniorTranche", address(senior));
        assessor.depend("juniorTranche", address(junior));
        nav.file("nav", 100e18);
    }

    // ------------------------------------------------------------ senior interest clock

    /// A pool that carried no senior debt for a year must not charge a year of interest on
    /// the first senior debt it books.
    function test_firstSeniorDebt_accruesFromBooking() public {
        assessor.file("seniorInterestRate", RATE);
        vm.warp(block.timestamp + 365 days);
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        assertEq(assessor.seniorDebt(), 80e18, "no interest for the year with no debt");
        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(assessor.seniorDebt(), 84.1e18, 0.001e18, "one year at about 5%");
    }

    /// Raising the rate from zero must not apply the new rate to the time before the change.
    function test_rateRaisedFromZero_accruesFromChange() public {
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        vm.warp(block.timestamp + 365 days);
        assertEq(assessor.seniorDebt(), 80e18, "zero rate accrues nothing");
        assessor.file("seniorInterestRate", RATE);
        assertEq(assessor.seniorDebt(), 80e18, "new rate not applied to the past year");
    }

    /// Senior debt written off to zero and booked again later accrues only from the rebooking.
    function test_debtRebookedAfterZero_accruesFromRebooking() public {
        assessor.file("seniorInterestRate", RATE);
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        assessor.changeSeniorAsset(0, 0, 80e18); // fully redeemed
        assertEq(assessor.seniorDebt(), 0);
        vm.warp(block.timestamp + 365 days);
        assessor.changeSeniorAsset(0.5e27, 50e18, 0);
        assertEq(assessor.seniorDebt(), 50e18, "no interest for the year at zero debt");
    }

    /// The reason for the drip guard is kept: accrual too small to book each second is not
    /// lost when dripped every second.
    function test_drip_keepsSubWeiAccrual() public {
        assessor.file("seniorInterestRate", RATE);
        nav.file("nav", 100);
        assessor.changeSeniorAsset(ONE, 100, 0); // 100 wei of senior debt
        uint256 start = block.timestamp;
        for (uint256 i = 0; i < 400 days; i += 1 days) {
            vm.warp(start + i);
            assessor.dripSeniorDebt();
        }
        vm.warp(start + 400 days);
        assertEq(assessor.dripSeniorDebt(), 105, "same as a single accrual over the period");
    }
}
