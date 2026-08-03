// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {ComposableCow} from "../src/ComposableCow.sol";
import {Commitment} from "../src/libraries/Commitment.sol";
import {PackageKind} from "../src/interfaces/PackageKind.sol";
import {OwnedTWAP} from "../src/types/Owned.sol";
import {DeployOwnedStack} from "../script/deploy_OwnedStack.s.sol";

contract ValidateHarness is DeployOwnedStack {
    function validate(uint256 expectedChain, address settlement, address admin) external view {
        _validate(expectedChain, settlement, admin);
    }

    function descriptorFor(string calldata uri, address deployer, address admin)
        external
        view
        returns (bool, Commitment.Data memory)
    {
        return _descriptorFor(uri, deployer, admin);
    }

    function isHttps(string calldata uri) external pure returns (bool) {
        return _isHttps(uri);
    }
}

/**
 * @dev The descriptor is committed as a sha256 over published bytes, so the
 *      digest going on chain has to be the digest of the document that is
 *      actually served. The script computes it from the repository rather than
 *      taking it on trust, and these check that it does.
 */
contract DescriptorPublishTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    string internal constant URI = "https://example.invalid/twap.json";

    ValidateHarness internal harness;

    function setUp() public {
        harness = new ValidateHarness();
    }

    /**
     * @dev The digest is sha256 over the document as it sits in the repo,
     *      checked twice on purpose. The pinned literal proves the digest
     *      matches what `sha256sum descriptors/TWAP.json` prints - agreement
     *      with the tool anyone verifying the published document will reach
     *      for. The `sha256(vm.readFile(...))` comparison proves the script's
     *      digest derives from that exact file, byte for byte: the document
     *      ends in a newline, and dropping it would silently change every
     *      digest ever published. Only the pair rules out both drift modes.
     *
     *      Update the constant deliberately if the document changes.
     */
    function test_descriptor_DigestIsTheDocumentsSha256() public view {
        (bool set, Commitment.Data memory d) = harness.descriptorFor(URI, ADMIN, ADMIN);

        assertTrue(set);
        assertEq(
            d.digest,
            0xb499b04e292a7fe808b982113e7e931446261bbc5d702517ba89a8403536ce1a,
            "digest does not match sha256sum of the document"
        );
        assertEq(bytes(vm.readFile("descriptors/TWAP.json")).length, 1825, "readFile did not return the file exactly");
        assertEq(d.digest, sha256(bytes(vm.readFile("descriptors/TWAP.json"))), "digest is not the document's");
        assertEq(uint256(d.kind), uint256(PackageKind.SHA256));
        assertEq(d.uris.length, 1);
        assertEq(d.uris[0], URI);
    }

    /// @dev `setDescriptor` is `onlyOwner`, so publishing in the same run needs
    ///      the owner's key. Failing loudly beats a reverting broadcast.
    function test_descriptor_RequiresTheOwnerKey() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployOwnedStack.DescriptorNeedsOwnerKey.selector, address(0xB0B), ADMIN)
        );
        harness.descriptorFor(URI, address(0xB0B), ADMIN);
    }

    function test_descriptor_RejectsANonHttpsUri() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployOwnedStack.DescriptorUriNotHttps.selector, "http://example.invalid/twap.json")
        );
        harness.descriptorFor("http://example.invalid/twap.json", ADMIN, ADMIN);
    }

    /// @dev Unset, the handler deploys uncommitted exactly as before.
    function test_descriptor_OptionalWhenUriUnset() public view {
        (bool set,) = harness.descriptorFor("", ADMIN, ADMIN);
        assertFalse(set, "an unset URI still published");
    }

    function test_isHttps() public view {
        assertTrue(harness.isHttps("https://a"));
        assertFalse(harness.isHttps("http://a"));
        assertFalse(harness.isHttps("https://"), "scheme alone is not a URI");
        assertFalse(harness.isHttps("bzz://a"));
        assertFalse(harness.isHttps(""));
    }
}

/// @dev CREATE2 buys one address per contract across every chain. That only
///      holds while the initcode carries nothing chain-specific, so these pin
///      what does and does not reach an address.
contract DeployAddressTest is Test {
    ValidateHarness internal harness;

    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant ADMIN = address(0xA11CE);

    function setUp() public {
        harness = new ValidateHarness();
    }

    /// @dev The reason for CREATE2 at all: same inputs, different chain, same
    ///      addresses. `predict` is `pure`, so no chain state can reach it.
    function test_predict_IsTheSameOnEveryChain() public {
        vm.chainId(1);
        (address a1, address b1, address c1, address d1) = harness.predict(SETTLEMENT, ADMIN);

        vm.chainId(100);
        (address a2, address b2, address c2, address d2) = harness.predict(SETTLEMENT, ADMIN);

        vm.chainId(8453);
        (address a3, address b3, address c3, address d3) = harness.predict(SETTLEMENT, ADMIN);

        assertEq(a1, a2, "registry moved");
        assertEq(a1, a3, "registry moved");
        assertEq(b1, b2, "twap moved");
        assertEq(b1, b3, "twap moved");
        assertEq(c1, c2, "stopLoss moved");
        assertEq(d1, d2, "goodAfterTime moved");
    }

    /// @dev The TWAP address is derived from the registry's, not computed
    ///      beside it: a different registry has to move the handler too, or
    ///      the second deployment would point at the wrong one.
    function test_predict_TwapFollowsTheRegistry() public view {
        (address regA, address twapA,,) = harness.predict(SETTLEMENT, ADMIN);
        (address regB, address twapB,,) = harness.predict(address(0xBEEF), ADMIN);

        assertTrue(regA != regB, "settlement does not reach the registry address");
        assertTrue(twapA != twapB, "registry does not reach the twap address");
    }

    /// @dev The precondition worth stating loudly: a different owner is a
    ///      different handler address, while the registry is unaffected.
    function test_predict_AdminMovesHandlersOnly() public view {
        (address regA, address twapA, address slA, address gatA) = harness.predict(SETTLEMENT, ADMIN);
        (address regB, address twapB, address slB, address gatB) = harness.predict(SETTLEMENT, address(0xB0B));

        assertEq(regA, regB, "admin should not reach the registry address");
        assertTrue(twapA != twapB, "admin does not reach the twap address");
        assertTrue(slA != slB, "admin does not reach the stopLoss address");
        assertTrue(gatA != gatB, "admin does not reach the goodAfterTime address");
    }

    /**
     * @dev The chaining itself: the handler's initcode must carry the registry
     *      address, not the settlement one. Moving the settlement moves both, so
     *      a test that only varies the settlement cannot tell the two apart, and
     *      a mutation swapping them survives it. This pins the encoding.
     */
    function test_predict_TwapEncodesTheRegistryNotTheSettlement() public view {
        (address registry, address twap,,) = harness.predict(SETTLEMENT, ADMIN);

        assertEq(
            twap,
            vm.computeCreate2Address(
                bytes32(0), keccak256(abi.encodePacked(type(OwnedTWAP).creationCode, abi.encode(registry, ADMIN)))
            ),
            "twap initcode does not carry the registry"
        );

        assertTrue(
            twap
                != vm.computeCreate2Address(
                    bytes32(0), keccak256(abi.encodePacked(type(OwnedTWAP).creationCode, abi.encode(SETTLEMENT, ADMIN)))
                ),
            "twap initcode carries the settlement"
        );
    }

    /// @dev Checked against the cheatcode rather than a second copy of the
    ///      same derivation.
    function test_predict_MatchesCreate2() public view {
        (address registry,,,) = harness.predict(SETTLEMENT, ADMIN);
        assertEq(
            registry,
            vm.computeCreate2Address(
                bytes32(0), keccak256(abi.encodePacked(type(ComposableCow).creationCode, abi.encode(SETTLEMENT)))
            )
        );
    }
}

/**
 * @dev The preflight checks run once, on a live network, with real funds behind
 *      them. Each is asserted to fire rather than assumed to.
 */
contract DeployStackTest is Test {
    uint256 internal constant MAINNET = 1;

    ValidateHarness internal harness;
    address internal settlement;
    address internal admin = address(0xA11CE);

    function setUp() public {
        harness = new ValidateHarness();
        // the check is only that the address has code, so any contract serves
        settlement = address(new Bytecode());
        vm.chainId(MAINNET);
    }

    function test_validate_AcceptsAValidConfig() public view {
        harness.validate(MAINNET, settlement, admin);
    }

    /// @dev The check that catches a stale `ETH_RPC_URL`.
    function test_validate_RejectsWrongChain() public {
        vm.chainId(100);
        vm.expectRevert(abi.encodeWithSelector(DeployOwnedStack.WrongChain.selector, MAINNET, uint256(100)));
        harness.validate(MAINNET, settlement, admin);
    }

    /// @dev A settlement address with no code means the wrong address or the
    ///      wrong chain, and every order would be unsettleable.
    function test_validate_RejectsCodelessSettlement() public {
        vm.expectRevert(abi.encodeWithSelector(DeployOwnedStack.SettlementHasNoCode.selector, address(0xBEEF)));
        harness.validate(MAINNET, address(0xBEEF), admin);
    }

    /// @dev A zero owner strands both commitments: the handler deploys
    ///      uncommitted and no key can ever call `setDescriptor`.
    function test_validate_RejectsZeroOwner() public {
        vm.expectRevert(DeployOwnedStack.OwnerIsZero.selector);
        harness.validate(MAINNET, settlement, address(0));
    }
}

/// @dev Something with a non-empty code size, and nothing else.
contract Bytecode {}
