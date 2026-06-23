// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721Receiver.sol";
import {LuciMarket} from "../../src/LuciMarket.sol";
import {ISanctionsList} from "../../src/interfaces/ISanctionsList.sol";

contract MockERC721 is ERC721 {
    constructor() ERC721("Mock NFT", "MNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockSanctionsList is ISanctionsList {
    mapping(address user => bool sanctioned) public sanctioned;

    function setSanctioned(address user, bool sanctioned_) external {
        sanctioned[user] = sanctioned_;
    }

    function isSanctioned(address user) external view returns (bool) {
        return sanctioned[user];
    }
}

contract RejectEthActor {
    function approveAll(address collection, address operator) external {
        IERC721(collection).setApprovalForAll(operator, true);
    }

    function list(
        LuciMarket market,
        address collection,
        uint256 tokenId,
        uint256 price,
        uint64 expiresAt,
        address buyer
    ) external {
        market.list(collection, tokenId, price, expiresAt, buyer);
    }

    receive() external payable {
        revert("REJECT_ETH");
    }
}

contract ReenteringBuyer is IERC721Receiver {
    LuciMarket public market;
    address public collection;
    uint256 public tokenId;
    bool public attempted;
    bool public reentered;

    function setReentry(LuciMarket market_, address collection_, uint256 tokenId_) external {
        market = market_;
        collection = collection_;
        tokenId = tokenId_;
    }

    function buy(address collection_, uint256 tokenId_) external payable {
        market.buy{value: msg.value}(collection_, tokenId_);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        attempted = true;
        (bool success,) = address(market).call(abi.encodeCall(LuciMarket.buy, (collection, tokenId)));
        reentered = success;
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
