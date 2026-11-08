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

    // ------------------------------------------------------------ admin surface

    function test_file_rejectsUnknownParameter() public {
        vm.expectRevert(Assessor.UnknownParameter.selector);
        assessor.file("nope", 1);
    }

    function test_depend_rejectsUnknownContract() public {
        vm.expectRevert(Assessor.UnknownParameter.selector);
        assessor.depend("nope", address(1));
    }

    function test_file_setsBounds() public {
        assessor.file("minSeniorRatio", 0.2e27);
        assessor.file("maxSeniorRatio", 0.8e27);
        assessor.file("maxReserve", 7);
        (Fixed27 memory lo, Fixed27 memory hi) = assessor.seniorRatioBounds();
        assertEq(lo.value, 0.2e27);
        assertEq(hi.value, 0.8e27);
        assertEq(assessor.maxReserve(), 7);
    }

    function test_strangerCannotWrite() public {
        address eve = makeAddr("eve");
        vm.startPrank(eve);
        vm.expectRevert(Auth.NotAuthorized.selector);
        assessor.file("maxReserve", 1);
        vm.expectRevert(Auth.NotAuthorized.selector);
        assessor.depend("navFeed", eve);
        vm.expectRevert(Auth.NotAuthorized.selector);
        assessor.changeSeniorAsset(0, 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ tranche assets and waterfall

    function test_getTrancheAssets_rejectsUnknownTranche() public {
        vm.expectRevert(Assessor.NoSuchTranche.selector);
        assessor.getTrancheAssets(2);
    }

    function test_getTrancheAssets_seniorCappedAtTotal() public {
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        nav.file("nav", 50e18); // the pool lost half its value, below the senior claim
        assertEq(assessor.getTrancheAssets(0), 50e18);
        assertEq(assessor.getTrancheAssets(1), 0);
    }

    function testFuzz_trancher_conservesAndFillsSeniorFirst(uint96 seniorSupply, uint96 assets) public {
        nav.file("nav", uint256(seniorSupply) * 2);
        assessor.changeSeniorAsset(0.5e27, seniorSupply, 0);
        uint256[] memory d = assessor.trancher(assets);
        uint256 entitled = assessor.seniorDebt() + assessor.seniorBalance();
        assertEq(d[0] + d[1], assets, "distribution adds up to the input");
        assertEq(d[0], assets < entitled ? assets : entitled, "senior filled first, up to its entitlement");
    }

    // ------------------------------------------------------------ prices

    function test_prices_parWithNoTokensOut() public view {
        (Fixed27 memory j, Fixed27 memory s) = assessor.calcTokenPrices(0, 0);
        assertEq(j.value, ONE);
        assertEq(s.value, ONE);
    }

    function test_prices_splitAssetsByClaim() public {
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        senior.setSupply(80e18);
        junior.setSupply(10e18);
        (Fixed27 memory j, Fixed27 memory s) = assessor.calcTokenPrices(100e18, 0);
        assertEq(s.value, ONE, "senior worth its 80");
        assertEq(j.value, 2e27, "junior holds the residual 20 over 10 tokens");
    }

    function test_prices_juniorZeroAndSeniorCappedWhenUnderwater() public {
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        senior.setSupply(80e18);
        junior.setSupply(10e18);
        (Fixed27 memory j, Fixed27 memory s) = assessor.calcTokenPrices(40e18, 0);
        assertEq(j.value, 0, "junior wiped out");
        assertEq(s.value, 0.5e27, "senior takes everything left");
    }

    // ------------------------------------------------------------ accrual

    function test_dripIsIdempotentWithinABlock() public {
        assessor.file("seniorInterestRate", RATE);
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        vm.warp(block.timestamp + 30 days);
        uint256 once = assessor.dripSeniorDebt();
        assertEq(assessor.dripSeniorDebt(), once);
        assertEq(assessor.seniorDebt(), once);
    }

    function testFuzz_dripSplitMatchesSingleAccrual(uint32 dt1, uint32 dt2) public {
        dt1 = uint32(bound(dt1, 0, 400 days));
        dt2 = uint32(bound(dt2, 0, 400 days));
        assessor.file("seniorInterestRate", RATE);
        assessor.changeSeniorAsset(0.8e27, 80e18, 0);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + dt1);
        assessor.dripSeniorDebt();
        vm.warp(t0 + uint256(dt1) + dt2);
        uint256 split = assessor.dripSeniorDebt();
        uint256 single = assessor.chargeInterest(80e18, RATE, t0);
        assertApproxEqAbs(split, single, 1e9, "drip schedule does not change accrual beyond rounding");
        assertGe(single + 1e9, split);
    }

    function test_rebalanceSplitsDebtAndBalance() public {
        assessor.changeSeniorAsset(0.5e27, 80e18, 0);
        assertEq(assessor.seniorDebt(), 50e18, "debt is the senior share of nav");
        assertEq(assessor.seniorBalance(), 30e18, "the rest of the senior claim sits idle");
    }
}
