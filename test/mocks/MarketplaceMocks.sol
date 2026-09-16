// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin-contracts-5.6.1/token/ERC721/IERC721Receiver.sol";
import {LuciMarket} from "../../src/LuciMarket.sol";
import {ISanctionsList} from "../../src/interfaces/ISanctionsList.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

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

contract MockRoyaltyModel {
    address public recipient;
    uint256 public amount;

    constructor(address recipient_, uint256 amount_) {
        recipient = recipient_;
        amount = amount_;
    }

    function setAmount(uint256 amount_) external {
        amount = amount_;
    }

    function calculateRoyalty(address, uint256, uint256, address)
        external
        view
        returns (address royaltyRecipient, uint256 royaltyAmount)
    {
        return (recipient, amount);
    }
}

contract MockAggregatorV3 is IAggregatorV3 {
    uint8 internal _decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public shouldRevert;
    bool public shouldRevertDecimals;

    error MockAggregatorRevert();

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        if (shouldRevertDecimals) revert MockAggregatorRevert();
        return _decimals;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function setShouldRevertDecimals(bool shouldRevertDecimals_) external {
        shouldRevertDecimals = shouldRevertDecimals_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer_, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        if (shouldRevert) {
            revert MockAggregatorRevert();
        }
        return (1, answer, updatedAt, updatedAt, 1);
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
