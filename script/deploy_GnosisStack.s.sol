// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Script.sol";

import {ComposableCow} from "../src/ComposableCow.sol";
import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";

import {CowAccount7702} from "../src/accounts/CowAccount7702.sol";
import {OwnedGoodAfterTime, OwnedStopLoss, OwnedTWAP} from "../src/types/Owned.sol";

/**
 * @title Gnosis Chain integration deployment
 * @dev Deploys the registry and the three rotatable handlers. Handlers are
 *      deployed uncommitted; descriptors are published and set afterwards with
 *      `setDescriptor`, which is why they are the `Owned*` variants.
 *
 *      Plain CREATE, not CREATE2. The digest is a constructor argument to the
 *      immutable handlers, so a CREATE2 address would depend on a descriptor
 *      that cannot be built until the address is known. The rotatable handlers
 *      sidestep that by deploying uncommitted, but there is no cross-chain
 *      address to preserve for an integration deployment, so determinism buys
 *      nothing here.
 *
 *      `ComposableCow` takes no commitment mixin: it has no descriptor.
 *
 *      Requires `PRIVATE_KEY`, `SETTLEMENT` and `ADMIN`.
 */
contract DeployGnosisStack is Script {
    uint256 private constant GNOSIS = 100;

    error WrongChain(uint256 actual);

    function run() external {
        require(block.chainid == GNOSIS, WrongChain(block.chainid));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address settlement = vm.envAddress("SETTLEMENT");
        address admin = vm.envAddress("ADMIN");

        vm.startBroadcast(deployerPrivateKey);

        ComposableCow composableCow = new ComposableCow(settlement);
        OwnedTWAP twap = new OwnedTWAP(composableCow, admin);
        OwnedStopLoss stopLoss = new OwnedStopLoss(admin);
        OwnedGoodAfterTime goodAfterTime = new OwnedGoodAfterTime(admin);

        // Delegation target for an EOA testing without a Safe. The EOA authorises
        // the proxy once; the implementation behind it can be replaced by `admin`
        // afterwards without a second authorisation.
        CowAccount7702 account = new CowAccount7702(composableCow);
        EIP7702Proxy accountProxy = new EIP7702Proxy(address(account), admin);

        vm.stopBroadcast();

        console.log("chainId          ", block.chainid);
        console.log("owner             ", admin);
        console.log("ComposableCow    ", address(composableCow));
        console.log("OwnedTWAP         ", address(twap));
        console.log("OwnedStopLoss     ", address(stopLoss));
        console.log("OwnedGoodAfterTime", address(goodAfterTime));
        console.log("CowAccount7702    ", address(account));
        console.log("EIP7702Proxy      ", address(accountProxy));
        console.log("");
        console.log("Record these in deployments/networks.json, then publish each");
        console.log("descriptor and call setDescriptor from the owner.");
        console.log("Delegate an EOA with: cast send --auth", address(accountProxy));
    }
}
