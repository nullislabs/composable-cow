// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script} from "forge-std/Script.sol";

import {ComposableCow} from "../src/ComposableCow.sol";

import {TWAP} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";
import {PackageKind} from "../src/interfaces/PackageKind.sol";

contract DeployOrderTypes is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address composableCow = vm.envAddress("COMPOSABLE_COW");
        vm.startBroadcast(deployerPrivateKey);

        new TWAP(ComposableCow(composableCow), new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        new GoodAfterTime(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        new PerpetualStableSwap(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        new TradeAboveThreshold();

        vm.stopBroadcast();
    }
}
