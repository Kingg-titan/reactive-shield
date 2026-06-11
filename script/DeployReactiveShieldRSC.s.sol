// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ReactiveShieldRSC} from "../src/rsc/ReactiveShieldRSC.sol";

contract DeployReactiveShieldRSC is Script {
    function run() external returns (ReactiveShieldRSC rsc) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 originChainId = vm.envUint("REACTIVE_SHIELD_ORIGIN_CHAIN_ID");
        uint256 destinationChainId = vm.envUint("REACTIVE_SHIELD_DESTINATION_CHAIN_ID");
        address hook = vm.envAddress("REACTIVE_SHIELD_HOOK_ADDRESS");

        console2.log("ReactiveShield RSC deploy");
        console2.log("Reactive sender/deployer:", vm.addr(privateKey));
        console2.log("Origin chain id:", originChainId);
        console2.log("Destination chain id:", destinationChainId);
        console2.log("Hook:", hook);

        vm.startBroadcast(privateKey);
        rsc = new ReactiveShieldRSC(originChainId, destinationChainId, hook);
        vm.stopBroadcast();

        console2.log("RSC deployed:", address(rsc));
        console2.log("Explorer:", string.concat("https://lasna.reactscan.net/address/", vm.toString(address(rsc))));
        console2.log("subscriptionConfigured:", rsc.subscriptionConfigured());
    }
}
