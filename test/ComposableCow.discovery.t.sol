// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

import {IConditionalOrder, IConditionalOrderGenerator, BaseComposableCowTest} from "./ComposableCow.base.t.sol";
import {IOrderManifest} from "../src/interfaces/IOrderManifest.sol";
import {IOrderDescriptor} from "../src/interfaces/IOrderDescriptor.sol";
import {IOrderModule} from "../src/interfaces/IOrderModule.sol";
import {OrderDescriptor} from "../src/OrderDescriptor.sol";
import {OrderModule} from "../src/OrderModule.sol";
import {StopLoss} from "../src/types/StopLoss.sol";
import {PackageKind} from "../src/interfaces/PackageKind.sol";

error TestNoOrder();

/**
 * @dev Minimal handler committing a module: the OrderModule mixin under test
 */
contract ModuleHandler is OrderModule {
    constructor(string[] memory uris, bytes32 digest, PackageKind kind) OrderModule(uris, digest, kind) {}

    function generateOrder(address, bytes32, bytes calldata, bytes calldata)
        public
        pure
        override
        returns (GPv2Order.Data memory)
    {
        revert IConditionalOrderGenerator.PollNeedsOffchainInput(TestNoOrder.selector);
    }
}

/**
 * @title Tests for the discovery sidecars: feature detection, commitment
 *        gating, and constructor events
 */
contract ComposableCowDiscoveryTest is BaseComposableCowTest {
    function moduleUris() internal pure returns (string[] memory uris) {
        uris = new string[](1);
        uris[0] = "https://example.com/twap-oracle.tar.zst";
    }

    // --- descriptor ---

    /**
     * @dev A committed descriptor advertises the sidecar and round-trips
     *      its commitment; the base interfaces keep advertising through the
     *      super chain
     */
    function test_descriptor_CommittedAdvertisesAndRoundTrips() public {
        StopLoss handler = new StopLoss(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST, PackageKind.SHA256);

        assertTrue(handler.supportsInterface(type(IOrderDescriptor).interfaceId));
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
        assertTrue(handler.supportsInterface(type(IOrderManifest).interfaceId));
        assertTrue(handler.supportsInterface(type(IERC165).interfaceId));
        assertFalse(handler.supportsInterface(type(IOrderModule).interfaceId));

        assertEq(handler.descriptorURI()[0], testDescriptorUris()[0]);
        (bytes32 digest, PackageKind kind) = handler.descriptorCommitment();
        assertEq(digest, TEST_DESCRIPTOR_DIGEST);
        assertEq(uint256(kind), uint256(PackageKind.SHA256));
    }

    /**
     * @dev Uncommitted (no URIs): the handler does NOT advertise the
     *      sidecar - feature detection never lies about empty metadata
     */
    function test_descriptor_UncommittedDoesNotAdvertise() public {
        StopLoss handler = new StopLoss(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);

        assertFalse(handler.supportsInterface(type(IOrderDescriptor).interfaceId));
        // the handler remains a fully functional generator
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
    }

    /**
     * @dev DescriptorUpdate fires exactly once, from the constructor, so
     *      indexers discover descriptors without polling
     */
    function test_descriptor_ConstructorEmitsUpdate() public {
        vm.expectEmit(true, true, true, true);
        emit IOrderDescriptor.DescriptorUpdate(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST, PackageKind.SHA256);
        new StopLoss(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST, PackageKind.SHA256);
    }

    // --- module ---

    /**
     * @dev A committed module advertises the sidecar with its identity digest
     */
    function test_module_CommittedAdvertisesAndRoundTrips() public {
        bytes32 digest = keccak256("module component bytes");

        vm.expectEmit(true, true, true, true);
        emit IOrderModule.ModuleUpdate(moduleUris(), digest, PackageKind.SHA256);
        ModuleHandler handler = new ModuleHandler(moduleUris(), digest, PackageKind.SHA256);

        assertTrue(handler.supportsInterface(type(IOrderModule).interfaceId));
        assertFalse(handler.supportsInterface(type(IOrderDescriptor).interfaceId));
        assertEq(handler.moduleURI()[0], moduleUris()[0]);
        (bytes32 got, PackageKind kind) = handler.moduleCommitment();
        assertEq(got, digest);
        assertEq(uint256(kind), uint256(PackageKind.SHA256));
    }

    /**
     * @dev URIs without a commitment are unverifiable, so publishing them is
     *      non-conformant
     */
    function test_module_RevertsUncommittedURI() public {
        vm.expectRevert(OrderModule.UncommittedModuleURI.selector);
        new ModuleHandler(moduleUris(), bytes32(0), PackageKind.BZZ_MANIFEST);
    }

    /**
     * @dev A `BZZ_MANIFEST` commitment locates its own package, so a URI is
     *      not merely redundant: it could not be verified against a structure
     *      root, and publishing one would write a gateway into the contract
     */
    function test_module_RevertsContentAddressedWithURI() public {
        vm.expectRevert(OrderModule.ModuleURINotUsed.selector);
        new ModuleHandler(moduleUris(), keccak256("pkg"), PackageKind.BZZ_MANIFEST);
    }

    /**
     * @dev `SHA256` does not locate the package, so it requires a URI
     */
    function test_module_RevertsSha256WithoutURI() public {
        vm.expectRevert(OrderModule.ModuleURIRequired.selector);
        new ModuleHandler(new string[](0), keccak256("pkg"), PackageKind.SHA256);
    }

    /**
     * @dev A content-addressed commitment locates its own package, so it
     *      advertises with no URI published at all
     */
    function test_module_ContentAddressedNeedsNoURI() public {
        ModuleHandler handler = new ModuleHandler(new string[](0), keccak256("pkg"), PackageKind.BZZ_MANIFEST);
        assertTrue(handler.supportsInterface(type(IOrderModule).interfaceId));
        assertEq(handler.moduleURI().length, 0);
    }

    /**
     * @dev No module committed: no advertising, handler still functions
     */
    function test_module_UncommittedDoesNotAdvertise() public {
        ModuleHandler handler = new ModuleHandler(new string[](0), bytes32(0), PackageKind.BZZ_MANIFEST);
        assertFalse(handler.supportsInterface(type(IOrderModule).interfaceId));
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
    }

    /**
     * @dev The module-requiring handler signals NEEDS_INPUT when polled
     *      empty - the discovery trigger end to end
     */
    function test_module_NeedsInputSignal() public {
        ModuleHandler handler = new ModuleHandler(new string[](0), keccak256("module"), PackageKind.BZZ_MANIFEST);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.NEEDS_INPUT));
        assertEq(result.reasonCode, TestNoOrder.selector);
    }
}
