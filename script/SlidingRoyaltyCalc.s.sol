// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std-1.14.0/Script.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

/// @title Sliding Royalty Rounding Comparison
/// @notice Scratch script comparing rounding behavior across three ways of computing the sliding royalty.
/// @dev HISTORICAL. This was written against the original single-currency model, where both `salePrice` and
///      `mintPrice` were ETH wei, which allowed the whole calculation to be folded into one expression.
///      `LuciRoyaltyModel` no longer works that way: the percentage is derived from USD-denominated values and
///      then applied to a sale price in its own currency, so the two are in different denominations and cannot
///      share a single `mulDiv`. The shipped contract uses the two-step form below (`royaltyBps`, then apply),
///      which is the first variant this script prints. The folded variants are kept only to show what the
///      two-step form gives up in precision.
/// @dev Not a deployment script and not part of the test suite. Run ad hoc:
///      `forge script SlidingRoyaltyCalc --sig "run(uint256,uint256)" <salePrice> <mintPrice>`
contract SlidingRoyaltyCalc is Script {
    uint256 public constant BASIS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 1000;

    /// @param salePrice Sale price
    /// @param mintPrce Mint price, in the same denomination as `salePrice`
    function run(uint256 salePrice, uint256 mintPrce) public pure {
        // calculate with intermediate variable - this is the form the contract ships, because the bps must be
        // derived in USD before being applied to the sale price in its own currency
        uint256 profit = salePrice - mintPrce;
        uint256 royaltyBps = (profit * MAX_ROYALTY_BPS) / mintPrce; // truncates to 0 while profit < mintPrce / 1000
        console.log(royaltyBps);
        uint256 royalty = salePrice * royaltyBps / BASIS;
        console.log(royalty);

        // calculate without intermediary variable - loses nothing to the intermediate truncation, but is no
        // longer expressible now that profit and salePrice are denominated differently
        royalty = (salePrice * profit * MAX_ROYALTY_BPS) / (mintPrce * BASIS);
        console.log(royalty);

        // calculate with mulDiv - same as above but with a 512-bit intermediate, so it survives inputs that
        // would overflow the plain multiplication
        royalty = Math.mulDiv(salePrice, profit * MAX_ROYALTY_BPS, mintPrce * BASIS);
        console.log(royalty);

        // ROUNDING DEAD ZONE: the bps step truncates to zero while profit is under 0.1% of the mint price, so a
        // sale just above the mint price pays nothing. Under USD-denominated mint prices that threshold is
        // mintPriceUsd / 1000 - $10 on a $10,000 mint - rather than a handful of wei. Not a wash trading vector:
        // at the boundary the forgone royalty is under 0.01% of the sale price, which is simply the bottom of
        // the sliding scale doing what it is supposed to do. Anyone wanting to dodge royalties at that margin
        // has far easier options than round-tripping a sale on-chain.
    }
}
