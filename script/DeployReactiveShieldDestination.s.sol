// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {ReactiveShieldHook} from "../src/ReactiveShieldHook.sol";

contract DeployReactiveShieldDestination is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct ChainConfig {
        string name;
        string explorer;
        address poolManager;
        address callbackProxy;
    }

    function run() external returns (ReactiveShieldHook hook) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 epochLength = _envOr("REACTIVE_SHIELD_EPOCH_LENGTH", uint256(20));
        ChainConfig memory cfg = _chainConfig();

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            IPoolManager(cfg.poolManager),
            cfg.callbackProxy,
            deployer,
            epochLength
        );
        (address minedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ReactiveShieldHook).creationCode, constructorArgs);

        console2.log("ReactiveShield destination deploy");
        console2.log("Network:", cfg.name);
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", cfg.poolManager);
        console2.log("Callback proxy:", cfg.callbackProxy);
        console2.log("Reactive sender:", deployer);
        console2.log("Epoch length:", epochLength);
        console2.log("Mined hook:", minedHook);
        console2.logBytes32(salt);

        vm.startBroadcast(privateKey);
        hook = new ReactiveShieldHook{salt: salt}(
            IPoolManager(cfg.poolManager),
            cfg.callbackProxy,
            deployer,
            epochLength
        );
        vm.stopBroadcast();

        require(address(hook) == minedHook, "ReactiveShield: mined address mismatch");
        console2.log("Destination hook deployed:", address(hook));
        console2.log("Explorer:", string.concat(cfg.explorer, "/address/", vm.toString(address(hook))));
    }

    function _chainConfig() internal view returns (ChainConfig memory cfg) {
        if (block.chainid == 11155111) {
            return ChainConfig({
                name: "Ethereum Sepolia",
                explorer: "https://sepolia.etherscan.io",
                poolManager: vm.envAddress("SEPOLIA_POOL_MANAGER"),
                callbackProxy: vm.envAddress("SEPOLIA_CALLBACK_PROXY")
            });
        }
        if (block.chainid == 84532) {
            return ChainConfig({
                name: "Base Sepolia",
                explorer: "https://sepolia.basescan.org",
                poolManager: vm.envAddress("BASE_SEPOLIA_POOL_MANAGER"),
                callbackProxy: vm.envAddress("BASE_SEPOLIA_CALLBACK_PROXY")
            });
        }
        if (block.chainid == 1301) {
            return ChainConfig({
                name: "Unichain Sepolia",
                explorer: "https://sepolia.uniscan.xyz",
                poolManager: vm.envAddress("UNICHAIN_SEPOLIA_POOL_MANAGER"),
                callbackProxy: vm.envAddress("UNICHAIN_SEPOLIA_CALLBACK_PROXY")
            });
        }
        if (block.chainid == 130) {
            return ChainConfig({
                name: "Unichain",
                explorer: "https://uniscan.xyz",
                poolManager: vm.envAddress("UNICHAIN_POOL_MANAGER"),
                callbackProxy: vm.envAddress("UNICHAIN_CALLBACK_PROXY")
            });
        }
        return ChainConfig({
            name: "Custom",
            explorer: vm.envOr("DESTINATION_EXPLORER_URL", string("")),
            poolManager: vm.envAddress("DESTINATION_POOL_MANAGER"),
            callbackProxy: vm.envAddress("DESTINATION_CALLBACK_PROXY")
        });
    }

    function _envOr(string memory key, uint256 fallbackValue) internal view returns (uint256 value) {
        try vm.envUint(key) returns (uint256 envValue) {
            return envValue;
        } catch {
            return fallbackValue;
        }
    }
}
