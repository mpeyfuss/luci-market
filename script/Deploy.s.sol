// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std-1.14.0/Script.sol";
import {Strings} from "@openzeppelin-contracts-5.6.1/utils/Strings.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computedAddress);
}

/// @notice Deploys one Luci contract through the canonical CreateX CREATE3 factory.
/// @dev The address depends on the sender and salt, not on the init code, so constructor
///      arguments may differ by chain. `SALT` must start with the sender address. Its 21st
///      byte is `0x00` for one address on every chain, or `0x01` to mix in the chain id.
///      Because CREATE3 ignores the init code, compiler metadata (CBOR) does not affect the address.
contract Deploy is Script {
    using Strings for address;

    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    error InvalidSalt();
    error WrongChain(uint256 expected, uint256 actual);
    error AlreadyDeployed(address deployedContract);
    error DeploymentFailed(address expected);

    /// @param bytecodePath Artifact path, e.g. `LuciMarket.sol:LuciMarket`
    /// @param rpcAlias Name of an entry in `[rpc_endpoints]` in `foundry.toml`
    /// @param expectedChainId Chain id the RPC must report, so a misconfigured endpoint cannot deploy elsewhere
    function run(string memory bytecodePath, string memory rpcAlias, uint256 expectedChainId) public {
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS");
        bytes32 salt = vm.envBytes32("SALT");
        bytes memory bytecode = abi.encodePacked(vm.getCode(bytecodePath), constructorArgs);

        vm.createSelectFork(rpcAlias);
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);

        bytes32 guarded = guardedSalt(salt, msg.sender, block.chainid);
        address deployedContract = ICreateX(CREATEX).computeCreate3Address(guarded, CREATEX);
        console.logAddress(deployedContract);
        if (deployedContract.code.length != 0) revert AlreadyDeployed(deployedContract);

        vm.broadcast();
        address created = ICreateX(CREATEX).deployCreate3(salt, bytecode);
        if (created != deployedContract || created.code.length == 0) revert DeploymentFailed(deployedContract);

        // overwrite rather than append so a stale out.txt from an aborted run cannot corrupt the address
        vm.writeFile("out.txt", deployedContract.toHexString());
    }

    /// @notice Apply the CreateX salt guard for a permissioned salt.
    /// @dev Mirrors `CreateX._guard` for the sender-prefixed cases. `0x00` hashes the sender
    ///      and salt. `0x01` also hashes the chain id, so the address differs by chain.
    function guardedSalt(bytes32 salt, address sender, uint256 chainId) public pure returns (bytes32) {
        if (address(bytes20(salt)) != sender) revert InvalidSalt();
        if (bytes1(salt[20]) == hex"00") {
            return keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt));
        }
        if (bytes1(salt[20]) == hex"01") {
            return keccak256(abi.encode(sender, chainId, salt));
        }
        revert InvalidSalt();
    }
}
