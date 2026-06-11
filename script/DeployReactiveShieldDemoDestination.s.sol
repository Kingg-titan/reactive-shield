// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {DemoERC20} from "../src/demo/DemoERC20.sol";
import {ReactiveShieldDemoHook} from "../src/demo/ReactiveShieldDemoHook.sol";

contract DeployReactiveShieldDemoDestination is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (DemoERC20 token, ReactiveShieldDemoHook hook) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address poolManager = vm.envAddress("UNICHAIN_SEPOLIA_POOL_MANAGER");
        address callbackProxy = vm.envAddress("UNICHAIN_SEPOLIA_CALLBACK_PROXY");
        uint256 epochLength = vm.envOr("REACTIVE_SHIELD_EPOCH_LENGTH", uint256(20));

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), callbackProxy, deployer, epochLength);
        (address minedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ReactiveShieldDemoHook).creationCode, constructorArgs);

        console2.log("ReactiveShield demo destination deploy");
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", poolManager);
        console2.log("Callback proxy:", callbackProxy);
        console2.log("Reactive sender:", deployer);
        console2.log("Mined demo hook:", minedHook);
        console2.logBytes32(salt);

        vm.startBroadcast(privateKey);
        token = new DemoERC20("ReactiveShield Demo USDC", "rsUSDC", 18);
        hook = new ReactiveShieldDemoHook{salt: salt}(IPoolManager(poolManager), callbackProxy, deployer, epochLength);
        vm.stopBroadcast();

        require(address(hook) == minedHook, "ReactiveShieldDemo: mined address mismatch");
        console2.log("Demo token:", address(token));
        console2.log("Demo hook:", address(hook));
        console2.log("Token explorer:", string.concat("https://sepolia.uniscan.xyz/address/", vm.toString(address(token))));
        console2.log("Hook explorer:", string.concat("https://sepolia.uniscan.xyz/address/", vm.toString(address(hook))));
    }
}
