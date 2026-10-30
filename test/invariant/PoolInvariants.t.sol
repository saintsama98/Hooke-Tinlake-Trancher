// SPDX-License-Identifier: AGPL-3.0-only
// Hooke: stateful invariants of a full pool, covering ICascade I1 to I3 and cash and token conservation.
// @author adiii.eth

pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../script/LenderDeployer.s.sol";
import "../mocks/SimpleToken.sol";
import "../mocks/SimpleNAVFeed.sol";
import "./handlers/PoolHandler.sol";

contract PoolInvariantsTest is Test {
    uint256 constant RAY = 1e27;
    uint256 constant MINTED = 1_000 ether;

    SimpleToken currency;
    SimpleToken seniorToken;
    SimpleToken juniorToken;
    SimpleNAVFeed navFeed;
    LenderDeployer d;
    Assessor assessor_;
    Idle reserve;
    PoolHandler handler;
    address[] actors;

    function setUp() public {
        currency = new SimpleToken("USD Coin", "USDC");
        seniorToken = new SimpleToken("Senior", "SEN");
        juniorToken = new SimpleToken("Junior", "JUN");
        navFeed = new SimpleNAVFeed();
        d = new LenderDeployer(address(currency), address(seniorToken), address(juniorToken));
        d.deploy({
            navFeed: address(navFeed),
            challengeTime: 1 hours,
            minSeniorRatio_: 0,
            maxSeniorRatio_: RAY,
            maxReserve_: 1_000_000 ether,
            seniorRate_: RAY
        });
        assessor_ = d.assessor_();
        reserve = d.reserve();

        for (uint256 i = 0; i < 6; i++) {
            address a = makeAddr(string(abi.encodePacked("lender", vm.toString(i))));
            actors.push(a);
            currency.mint(a, MINTED);
            vm.startPrank(a);
            currency.approve(address(d.seniorTranche()), type(uint256).max);
            currency.approve(address(d.juniorTranche()), type(uint256).max);
            seniorToken.approve(address(d.seniorTranche()), type(uint256).max);
            juniorToken.approve(address(d.juniorTranche()), type(uint256).max);
            vm.stopPrank();
        }

        handler = new PoolHandler(d, currency, seniorToken, juniorToken, navFeed, actors);
        targetContract(address(handler));
    }

    function _pool() internal view returns (uint256) {
        return navFeed.currentNAV() + reserve.totalBalance();
    }

    function _seniorEntitlement() internal view returns (uint256) {
        return assessor_.seniorDebt() + assessor_.seniorBalance();
    }

    /// I3: the two tranches account for the whole pool, nothing more and nothing less.
    function invariant_conservation() public view {
        assertEq(assessor_.getTrancheAssets(0) + assessor_.getTrancheAssets(1), _pool());
    }

    /// I1: senior is paid first and never more than its entitlement or the pool.
    function invariant_seniorFirstAndCapped() public view {
        uint256 s = assessor_.getTrancheAssets(0);
        uint256 entitlement = _seniorEntitlement();
        uint256 pool = _pool();
        assertEq(s, entitlement < pool ? entitlement : pool);
    }

    /// I2: while junior holds any value, senior is whole.
    function invariant_juniorTakesLossFirst() public view {
        if (assessor_.getTrancheAssets(1) > 0) {
            assertEq(assessor_.getTrancheAssets(0), _seniorEntitlement());
        }
    }

    /// The waterfall applied to the pool conserves it and matches the reported senior assets.
    /// `trancher` accrues senior interest first, so it runs inside a snapshot that is rolled back.
    function invariant_trancherConservesThePool() public {
        uint256 snap = vm.snapshotState();
        uint256 pool = _pool();
        uint256[] memory split = assessor_.trancher(pool);
        assertEq(split[0] + split[1], pool);
        assertEq(split[0], assessor_.getTrancheAssets(0));
        vm.revertToState(snap);
    }

    /// Currency is never created or destroyed: lenders, escrow and the reserve hold all of it.
    function invariant_cashConservation() public view {
        uint256 held = currency.balanceOf(address(d.seniorTranche())) + currency.balanceOf(address(d.juniorTranche()))
            + currency.balanceOf(address(reserve));
        for (uint256 i = 0; i < actors.length; i++) {
            held += currency.balanceOf(actors[i]);
        }
        assertEq(held, MINTED * actors.length);
        assertEq(currency.totalSupply(), MINTED * actors.length);
    }

    /// The reserve's ledger matches the currency it actually holds.
    function invariant_reserveLedgerMatchesBalance() public view {
        assertEq(currency.balanceOf(address(reserve)), reserve.totalBalance());
    }

    /// Tranche tokens exist only with lenders or in tranche escrow.
    function invariant_tokensOnlyWithLendersOrEscrow() public view {
        _assertTokenHolders(seniorToken, address(d.seniorTranche()));
        _assertTokenHolders(juniorToken, address(d.juniorTranche()));
    }

    function _assertTokenHolders(SimpleToken token, address escrow) internal view {
        uint256 held = token.balanceOf(escrow);
        for (uint256 i = 0; i < actors.length; i++) {
            held += token.balanceOf(actors[i]);
        }
        assertEq(held, token.totalSupply());
    }
}
