// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script} from "forge-std/Script.sol";

// ExtensibleFallbackHandler
import {ExtensibleFallbackHandler} from "safe/handler/ExtensibleFallbackHandler.sol";

// ComposableCow
import {ComposableCow} from "../src/ComposableCow.sol";

// Order types
import {TWAP} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";
import {StopLoss} from "../src/types/StopLoss.sol";

// Value factories
import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";
import {PackageKind} from "../src/interfaces/PackageKind.sol";

contract DeployProdStack is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address settlement = vm.envAddress("SETTLEMENT");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy ExtensibleFallbackHandler
        new ExtensibleFallbackHandler{salt: bytes32(0)}();

        // Deploy ComposableCow
        ComposableCow composableCow = new ComposableCow{salt: bytes32(0)}(settlement);

        // Deploy order types
        new TWAP{salt: bytes32(0)}(composableCow, new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        new GoodAfterTime{salt: bytes32(0)}(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        new PerpetualStableSwap{salt: bytes32(0)}(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        new TradeAboveThreshold{salt: bytes32(0)}();
        new StopLoss{salt: bytes32(0)}(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);

        // Deploy value factories
        new CurrentBlockTimestampFactory{salt: bytes32(0)}();
    }
}
