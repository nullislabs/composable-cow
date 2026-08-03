// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Script.sol";

import {ComposableCow} from "../src/ComposableCow.sol";
import {Commitment} from "../src/libraries/Commitment.sol";
import {PackageKind} from "../src/interfaces/PackageKind.sol";
import {OwnedGoodAfterTime, OwnedStopLoss, OwnedTWAP} from "../src/types/Owned.sol";

/**
 * @title Rotatable-handler deployments
 * @dev Deploys the registry and rotatable handlers at the same addresses on
 *      every chain, via CREATE2 through the canonical factory.
 *
 *      That works here because nothing in the initcode is chain-specific.
 *      `GPv2Settlement` is at one address on every chain CoW deploys to, so the
 *      registry's constructor argument does not vary; the registry's address
 *      therefore does not vary either, which in turn fixes each handler's
 *      constructor argument. The chain-specific part of the registry, the
 *      settlement domain separator, is read in the constructor and held as an
 *      immutable, so it lands in the deployed code without touching the address.
 *
 *      Two preconditions come with that, and neither is enforceable from here:
 *      `SETTLEMENT` must be the same address used on every other chain, and
 *      `ADMIN` must be too, or the handlers diverge while the registry does not.
 *      Run `predict` first and compare against a chain already deployed to.
 *
 *      CREATE2 is available to these handlers precisely because they deploy
 *      uncommitted. On the immutable handlers the descriptor digest is a
 *      constructor argument, so the address would depend on a descriptor that
 *      cannot be built until the address is known. The `Owned*` variants set
 *      their descriptor afterwards with `setDescriptor`, which breaks the cycle.
 *
 *      `ComposableCow` takes no commitment mixin: it has no descriptor.
 *
 *      Requires `SETTLEMENT` and `ADMIN`, plus a signer: either
 *      `PRIVATE_KEY` in the environment or `--account`/`--keystore`.
 */
abstract contract DeployOwnedStack is Script {
    bytes32 internal constant SALT = bytes32(0);

    /// @dev A stale `ETH_RPC_URL` pointing at the wrong network.
    error WrongChain(uint256 expected, uint256 actual);

    /// @dev `SETTLEMENT` has no code here, so it is the wrong address or the
    ///      wrong chain. Every order would be unsettleable.
    error SettlementHasNoCode(address settlement);

    /// @dev A zero owner would strand both commitments permanently: the handler
    ///      would deploy uncommitted with no key able to call `setDescriptor`.
    error OwnerIsZero();

    /// @dev A deployment did not land where it was predicted to.
    error AddressMismatch(address predicted, address actual);

    /// @dev `setDescriptor` is `onlyOwner`, so the deploying key must be the
    ///      owner to publish in the same run. Otherwise deploy uncommitted and
    ///      call `setDescriptor` separately from the owner.
    error DescriptorNeedsOwnerKey(address deployer, address admin);

    /// @dev The descriptor is committed as `SHA256` over the published bytes,
    ///      so the URI has to be the thing serving those bytes over https.
    error DescriptorUriNotHttps(string uri);

    /// @dev With `VERIFY_URI=1` the advertised URI was fetched and its bytes
    ///      do not hash to the committed digest: the URI is stale, mistyped,
    ///      or serving something else.
    error UriServesDifferentBytes(string uri);

    /// @dev Split from `_preflight` so the checks are reachable without the
    ///      environment: `vm.setEnv` writes the host process environment, which
    ///      foundry's per-test isolation does not roll back, so a test that went
    ///      through the env would race every other test in the run.
    function _validate(uint256 expectedChain, address settlement, address admin) internal view {
        require(block.chainid == expectedChain, WrongChain(expectedChain, block.chainid));
        require(settlement.code.length != 0, SettlementHasNoCode(settlement));
        require(admin != address(0), OwnerIsZero());
    }

    function _preflight(uint256 expectedChain) internal view returns (address settlement, address admin) {
        settlement = vm.envAddress("SETTLEMENT");
        admin = vm.envAddress("ADMIN");
        _validate(expectedChain, settlement, admin);
    }

    /// @dev The TWAP descriptor document in this repository. The digest is
    ///      computed from it rather than supplied, so what is committed on
    ///      chain cannot drift from the document that was generated.
    string internal constant TWAP_DESCRIPTOR = "descriptors/TWAP.json";

    /// @dev `TWAP_DESCRIPTOR_URI` is optional. Unset, the handler deploys
    ///      uncommitted exactly as before and the descriptor is published
    ///      later with `setDescriptor`.
    function _twapDescriptor(address deployer, address admin) internal view returns (bool, Commitment.Data memory) {
        return _descriptorFor(vm.envOr("TWAP_DESCRIPTOR_URI", string("")), deployer, admin);
    }

    /// @dev Split from the environment read for the same reason `_validate` is:
    ///      `vm.setEnv` writes the host process environment, which foundry does
    ///      not roll back between tests.
    function _descriptorFor(string memory uri, address deployer, address admin)
        internal
        view
        returns (bool set, Commitment.Data memory descriptor)
    {
        if (bytes(uri).length == 0) return (false, descriptor);

        require(deployer == admin, DescriptorNeedsOwnerKey(deployer, admin));
        require(_isHttps(uri), DescriptorUriNotHttps(uri));

        string[] memory uris = new string[](1);
        uris[0] = uri;

        set = true;
        descriptor = Commitment.Data({
            uris: uris, digest: sha256(bytes(vm.readFile(TWAP_DESCRIPTOR))), kind: PackageKind.SHA256
        });
    }

    function _isHttps(string memory uri) internal pure returns (bool) {
        bytes memory b = bytes(uri);
        bytes memory prefix = "https://";
        if (b.length <= prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (b[i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev The digest is computed from the local document; whether the
    ///      advertised URI actually serves those bytes is a property of a web
    ///      server, so it can only be checked by fetching. `VERIFY_URI=1` does
    ///      that through `vm.ffi` (add `--ffi` to the invocation); otherwise
    ///      the URI is advertised unverified and says so loudly.
    function _verifyOrWarn(Commitment.Data memory descriptor) internal {
        string memory uri = descriptor.uris[0];
        if (vm.envOr("VERIFY_URI", false)) {
            string[] memory cmd = new string[](3);
            cmd[0] = "curl";
            cmd[1] = "-fsSL";
            cmd[2] = uri;
            require(sha256(vm.ffi(cmd)) == descriptor.digest, UriServesDifferentBytes(uri));
            console.log("verified         ", uri);
        } else {
            console.log("WARNING: advertised URI is NOT verified to serve the committed bytes");
            console.log("  %s", uri);
            console.log("  rerun with VERIFY_URI=1 and --ffi, or check by hand:");
            console.log("  curl -fsSL <uri> | sha256sum");
        }
    }

    /// @dev Skips a redundant transaction only when the chain already carries
    ///      this exact commitment - digest, kind, and URIs. Comparing the
    ///      digest alone would make a URI-only change (moving hosting, same
    ///      document) a silent no-op that leaves a dead URI advertised.
    function _publish(OwnedTWAP twap, Commitment.Data memory descriptor) internal {
        (bytes32 currentDigest, PackageKind currentKind) = twap.descriptorCommitment();
        bool same = currentDigest == descriptor.digest && currentKind == descriptor.kind
            && keccak256(abi.encode(twap.descriptorURI())) == keccak256(abi.encode(descriptor.uris));
        if (!same) twap.setDescriptor(descriptor);
    }

    /// @dev `PRIVATE_KEY` if set, otherwise whatever `--account`, `--keystore`
    ///      or `--ledger` supplies on the command line. A raw key in the
    ///      environment is the worse of the two, so it is not the only option.
    function _broadcaster() internal view returns (address deployer, uint256 pk) {
        pk = vm.envOr("PRIVATE_KEY", uint256(0));
        deployer = pk == 0 ? msg.sender : vm.addr(pk);
    }

    function _begin(uint256 pk) internal {
        if (pk == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(pk);
        }
    }

    function _at(bytes memory initCode) internal pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(initCode));
    }

    /// @dev Every address this script can produce, without deploying anything.
    ///      The TWAP address depends on the registry's, which is why it is
    ///      derived here rather than computed independently.
    function predict(address settlement, address admin)
        public
        pure
        returns (address composableCow, address twap, address stopLoss, address goodAfterTime)
    {
        composableCow = _at(abi.encodePacked(type(ComposableCow).creationCode, abi.encode(settlement)));
        twap = _at(abi.encodePacked(type(OwnedTWAP).creationCode, abi.encode(composableCow, admin)));
        stopLoss = _at(abi.encodePacked(type(OwnedStopLoss).creationCode, abi.encode(admin)));
        goodAfterTime = _at(abi.encodePacked(type(OwnedGoodAfterTime).creationCode, abi.encode(admin)));
    }

    /// @dev The registry and the one handler every deployment wants. Returns
    ///      what is already there rather than reverting, so re-running across a
    ///      set of chains converges instead of failing on the second attempt.
    function _core(address settlement, address admin) internal returns (ComposableCow composableCow, OwnedTWAP twap) {
        (address at, address twapAt,,) = predict(settlement, admin);

        composableCow = at.code.length != 0 ? ComposableCow(at) : new ComposableCow{salt: SALT}(settlement);
        require(address(composableCow) == at, AddressMismatch(at, address(composableCow)));

        twap = twapAt.code.length != 0 ? OwnedTWAP(twapAt) : new OwnedTWAP{salt: SALT}(composableCow, admin);
        require(address(twap) == twapAt, AddressMismatch(twapAt, address(twap)));
    }

    function _report(address admin, ComposableCow composableCow, OwnedTWAP twap) internal view {
        console.log("chainId          ", block.chainid);
        console.log("owner            ", admin);
        console.log("ComposableCow    ", address(composableCow));
        console.log("OwnedTWAP        ", address(twap));
    }

    function _next() internal pure {
        console.log("");
        console.log("Record these in deployments/networks.json, then publish each");
        console.log("descriptor and call setDescriptor from the owner.");
    }
}

/**
 * @title Ethereum mainnet deployment
 * @dev The registry and TWAP only. `StopLoss` and `GoodAfterTime` are not
 *      deployed here: `GoodAfterTime` still has the open `TRY_NEXT_BLOCK`
 *      defect in #58, and neither is wanted on mainnet yet. Deploying them
 *      later against this same registry moves no address, since neither is an
 *      input to anything else.
 */
contract DeployMainnetStack is DeployOwnedStack {
    uint256 private constant MAINNET = 1;

    function run() external {
        (address settlement, address admin) = _preflight(MAINNET);

        (address deployer, uint256 pk) = _broadcaster();
        (bool set, Commitment.Data memory descriptor) = _twapDescriptor(deployer, admin);
        if (set) _verifyOrWarn(descriptor);

        _begin(pk);
        (ComposableCow composableCow, OwnedTWAP twap) = _core(settlement, admin);
        if (set) _publish(twap, descriptor);
        vm.stopBroadcast();

        _report(admin, composableCow, twap);
        if (set) {
            console.log("TWAP descriptor  ", descriptor.uris[0]);
            console.logBytes32(descriptor.digest);
        }
        _next();
    }
}

/**
 * @title Gnosis Chain integration deployment
 * @dev The registry and all three rotatable handlers.
 */
contract DeployGnosisStack is DeployOwnedStack {
    uint256 private constant GNOSIS = 100;

    function run() external {
        (address settlement, address admin) = _preflight(GNOSIS);
        (,, address stopLossAt, address gatAt) = predict(settlement, admin);

        (address deployer, uint256 pk) = _broadcaster();
        (bool set, Commitment.Data memory descriptor) = _twapDescriptor(deployer, admin);
        if (set) _verifyOrWarn(descriptor);

        _begin(pk);

        (ComposableCow composableCow, OwnedTWAP twap) = _core(settlement, admin);
        if (set) _publish(twap, descriptor);

        OwnedStopLoss stopLoss =
            stopLossAt.code.length != 0 ? OwnedStopLoss(stopLossAt) : new OwnedStopLoss{salt: SALT}(admin);
        OwnedGoodAfterTime goodAfterTime =
            gatAt.code.length != 0 ? OwnedGoodAfterTime(gatAt) : new OwnedGoodAfterTime{salt: SALT}(admin);

        vm.stopBroadcast();

        require(address(stopLoss) == stopLossAt, AddressMismatch(stopLossAt, address(stopLoss)));
        require(address(goodAfterTime) == gatAt, AddressMismatch(gatAt, address(goodAfterTime)));

        _report(admin, composableCow, twap);
        console.log("OwnedStopLoss    ", address(stopLoss));
        console.log("OwnedGoodAfterTime", address(goodAfterTime));
        _next();
    }
}
