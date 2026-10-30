// SPDX-License-Identifier: AGPL-3.0-only
// Hooke: compounding interest helpers.
// @author adiii.eth
// Copyright (C) 2018 Rain <rainbreak@riseup.net> and Centrifuge, referencing MakerDAO dss https://github.com/makerdao/dss/blob/master/src/pot.sol
// Adapted from Centrifuge tinlake-math src/interest.sol. See NOTICE.

pragma solidity 0.8.28;

import "./Math.sol";

contract Interest is Math {
    error InvalidTimestamp();
    error ZeroRate();

    // @notice This function provides compounding in seconds
    // @param chi Accumulated interest rate over time
    // @param ratePerSecond Interest rate accumulation per second in RAD(10ˆ27)
    // @param lastUpdated When the interest rate was last updated
    // @param pie Total sum of all amounts accumulating under one interest rate, divided by that rate
    // @return The new accumulated rate, as well as the difference between the debt calculated with the old and new accumulated rates.
    function compounding(uint256 chi, uint256 ratePerSecond, uint256 lastUpdated, uint256 pie)
        public
        view
        returns (uint256, uint256)
    {
        require(block.timestamp >= lastUpdated, InvalidTimestamp());
        require(chi != 0, ZeroRate());
        // instead of a interestBearingAmount we use a accumulated interest rate index (chi)
        uint256 updatedChi = _chargeInterest(chi, ratePerSecond, lastUpdated, block.timestamp);
        return (updatedChi, safeSub(rmul(updatedChi, pie), rmul(chi, pie)));
    }

    // @notice This function charge interest on a interestBearingAmount
    // @param interestBearingAmount is the interest bearing amount
    // @param ratePerSecond Interest rate accumulation per second in RAD(10ˆ27)
    // @param lastUpdated last time the interest has been charged
    // @return interestBearingAmount + interest
    function chargeInterest(uint256 interestBearingAmount, uint256 ratePerSecond, uint256 lastUpdated)
        public
        view
        returns (uint256)
    {
        if (block.timestamp >= lastUpdated) {
            interestBearingAmount = _chargeInterest(interestBearingAmount, ratePerSecond, lastUpdated, block.timestamp);
        }
        return interestBearingAmount;
    }

    function _chargeInterest(uint256 interestBearingAmount, uint256 ratePerSecond, uint256 lastUpdated, uint256 current)
        internal
        pure
        returns (uint256)
    {
        return rmul(rpow(ratePerSecond, current - lastUpdated, ONE), interestBearingAmount);
    }

    // convert pie to debt/savings amount
    function toAmount(uint256 chi, uint256 pie) public pure returns (uint256) {
        return rmul(pie, chi);
    }

    // convert debt/savings amount to pie
    function toPie(uint256 chi, uint256 amount) public pure returns (uint256) {
        return rdivup(amount, chi);
    }

    // @dev rpow is inherited from Math (math.sol); not redefined here to avoid an override clash.
}
