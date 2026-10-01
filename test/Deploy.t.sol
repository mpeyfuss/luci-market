// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std-1.14.0/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployTest is Test {
    Deploy internal deploy;

    function setUp() public {
        deploy = new Deploy();
    }

    function test_zeroFlagIgnoresChainId() public {
        address sender = makeAddr("sender");
        bytes32 salt = _salt(sender, hex"00");

        assertEq(deploy.guardedSalt(salt, sender, 1), deploy.guardedSalt(salt, sender, 11_155_111));
    }

    function test_chainFlagChangesGuardedSalt() public {
        address sender = makeAddr("sender");
        bytes32 salt = _salt(sender, hex"01");

        assertNotEq(deploy.guardedSalt(salt, sender, 1), deploy.guardedSalt(salt, sender, 11_155_111));
    }

    function test_rejectsSaltThatDoesNotStartWithSender(address sender) public {
        vm.assume(sender != address(this));
        bytes32 salt = _salt(address(this), hex"00");

        vm.expectRevert(Deploy.InvalidSalt.selector);
        deploy.guardedSalt(salt, sender, 1);
    }

    function test_rejectsUnspecifiedProtectionFlag() public {
        bytes32 salt = _salt(address(this), hex"02");

        vm.expectRevert(Deploy.InvalidSalt.selector);
        deploy.guardedSalt(salt, address(this), 1);
    }

    function _salt(address sender, bytes1 flag) private pure returns (bytes32 salt) {
        salt = bytes32(bytes.concat(bytes20(sender), flag, bytes11(uint88(1))));
    }
}
