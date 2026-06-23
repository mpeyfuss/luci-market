// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std-1.14.0/Script.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

contract SlidingRoyaltyCalc is Script {
    uint256 public constant BASIS = 10_000;
    uint256 public constant MAX_ROYALTY_BPS = 1000;

    function run(uint256 salePrice, uint256 mintPrce) public pure {
        // calculate with intermediate variable
        uint256 profit = salePrice - mintPrce;
        uint256 royaltyBps = (profit * MAX_ROYALTY_BPS) / mintPrce; // truncates to 0 when profit is < 0.1% of last price
        console.log(royaltyBps);
        uint256 royalty = salePrice * royaltyBps / BASIS;
        console.log(royalty);

        // calculate without intermediary variable
        royalty = (salePrice * profit * MAX_ROYALTY_BPS) / (mintPrce * BASIS);
        console.log(royalty);

        // calculate with mulDiv
        royalty = Math.mulDiv(salePrice, profit * MAX_ROYALTY_BPS, mintPrce * BASIS);
        console.log(royalty);

        // THIS SHOULD SHOW THAT WASH TRADING CAN ONLY HAPPEN AT A PROFIT OF 9 WEI OR LOWER
        // PROPS IF YOU DO THAT I GUESS BUT HOLY SHIT OTC IS EASIER BRO
    }
}
