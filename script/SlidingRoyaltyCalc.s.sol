// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std-1.14.0/Script.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

/// @title Sliding Royalty Rounding Comparison
/// @notice Scratch script comparing rounding behavior across three ways of computing the sliding royalty.
/// @dev Scratch comparison of rounding. The first variant truncates to integer bps before applying them;
///      that is what an earlier revision shipped. `LuciRoyaltyModel` now uses the folded `mulDiv` form
///      (the third variant): the percentage is derived in USD and applied to the sale in its own currency
///      in one step, because the units cancel (ETH × USD / USD).
/// @dev Not a deployment script and not part of the test suite. Run ad hoc:
///      `forge script SlidingRoyaltyCalc --sig "run(uint256,uint256)" <salePrice> <mintPrice>`
contract SlidingRoyaltyCalc is Script {
    uint256 public constant BASIS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 1000;

    /// @param salePrice Sale price
    /// @param mintPrce Mint price, in the same denomination as `salePrice`
    function run(uint256 salePrice, uint256 mintPrce) public pure {
        // two-step form (historical): truncates to 0 while profit < mint / 1000
        uint256 profit = salePrice - mintPrce;
        uint256 royaltyBps = (profit * MAX_ROYALTY_BPS) / mintPrce;
        console.log(royaltyBps);
        uint256 royalty = salePrice * royaltyBps / BASIS;
        console.log(royalty);

        // folded form without mulDiv — same math, overflows on large inputs
        royalty = (salePrice * profit * MAX_ROYALTY_BPS) / (mintPrce * BASIS);
        console.log(royalty);

        // shipped form: one mulDiv, 512-bit intermediate, no bps dead zone
        royalty = Math.mulDiv(salePrice, profit * MAX_ROYALTY_BPS, mintPrce * BASIS);
        console.log(royalty);
    }
}
