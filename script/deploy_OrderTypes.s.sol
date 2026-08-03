// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Commitment} from "../src/libraries/Commitment.sol";
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

        new TWAP(ComposableCow(composableCow), Commitment.none());
        new GoodAfterTime(Commitment.none());
        new PerpetualStableSwap(Commitment.none());
        new TradeAboveThreshold();

        vm.stopBroadcast();
    }
}
