// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

import {IConditionalOrder, IConditionalOrderGenerator, BaseComposableCoWTest} from "./ComposableCoW.base.t.sol";
import {IOrderManifest} from "../src/interfaces/IOrderManifest.sol";
import {IOrderDescriptor} from "../src/interfaces/IOrderDescriptor.sol";
import {IOrderModule} from "../src/interfaces/IOrderModule.sol";
import {OrderDescriptor} from "../src/OrderDescriptor.sol";
import {OrderModule} from "../src/OrderModule.sol";
import {StopLoss} from "../src/types/StopLoss.sol";

error TestNoOrder();

/// @dev Minimal handler committing a module: the OrderModule mixin under test
contract ModuleHandler is OrderModule {
    constructor(string[] memory uris, bytes32 digest) OrderModule(uris, digest) {}

    function generateOrder(address, address, bytes32, bytes calldata, bytes calldata)
        public
        pure
        override
        returns (GPv2Order.Data memory)
    {
        revert IConditionalOrder.PollNeedsOffchainInput(TestNoOrder.selector);
    }
}

/// @title Tests for the discovery sidecars: feature detection, commitment
///        gating, and constructor events
contract ComposableCoWDiscoveryTest is BaseComposableCoWTest {
    function moduleUris() internal pure returns (string[] memory uris) {
        uris = new string[](1);
        uris[0] = "bzz://c0ffee";
    }

    // --- descriptor ---

    /// @dev A committed descriptor advertises the sidecar and round-trips
    ///      its commitment; the base interfaces keep advertising through the
    ///      super chain
    function test_descriptor_CommittedAdvertisesAndRoundTrips() public {
        StopLoss handler = new StopLoss(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST);

        assertTrue(handler.supportsInterface(type(IOrderDescriptor).interfaceId));
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
        assertTrue(handler.supportsInterface(type(IOrderManifest).interfaceId));
        assertTrue(handler.supportsInterface(type(IERC165).interfaceId));
        assertFalse(handler.supportsInterface(type(IOrderModule).interfaceId));

        assertEq(handler.descriptorURI()[0], testDescriptorUris()[0]);
        assertEq(handler.descriptorDigest(), TEST_DESCRIPTOR_DIGEST);
    }

    /// @dev Uncommitted (no URIs): the handler does NOT advertise the
    ///      sidecar - feature detection never lies about empty metadata
    function test_descriptor_UncommittedDoesNotAdvertise() public {
        StopLoss handler = new StopLoss(new string[](0), bytes32(0));

        assertFalse(handler.supportsInterface(type(IOrderDescriptor).interfaceId));
        // the handler remains a fully functional generator
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
    }

    /// @dev DescriptorUpdate fires exactly once, from the constructor, so
    ///      indexers discover descriptors without polling
    function test_descriptor_ConstructorEmitsUpdate() public {
        vm.expectEmit(true, true, true, true);
        emit IOrderDescriptor.DescriptorUpdate(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST);
        new StopLoss(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST);
    }

    // --- module ---

    /// @dev A committed module advertises the sidecar with its identity digest
    function test_module_CommittedAdvertisesAndRoundTrips() public {
        bytes32 digest = keccak256("module component bytes");

        vm.expectEmit(true, true, true, true);
        emit IOrderModule.ModuleUpdate(moduleUris(), digest);
        ModuleHandler handler = new ModuleHandler(moduleUris(), digest);

        assertTrue(handler.supportsInterface(type(IOrderModule).interfaceId));
        assertFalse(handler.supportsInterface(type(IOrderDescriptor).interfaceId));
        assertEq(handler.moduleURI()[0], moduleUris()[0]);
        assertEq(handler.moduleDigest(), digest);
    }

    /// @dev A zero digest is non-conformant: the digest is the module's
    ///      canonical identity and the final pre-execution gate
    function test_module_RevertsZeroDigest() public {
        vm.expectRevert(OrderModule.InvalidModuleDigest.selector);
        new ModuleHandler(moduleUris(), bytes32(0));
    }

    /// @dev No module committed: no advertising, handler still functions
    function test_module_UncommittedDoesNotAdvertise() public {
        ModuleHandler handler = new ModuleHandler(new string[](0), bytes32(0));
        assertFalse(handler.supportsInterface(type(IOrderModule).interfaceId));
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
    }

    /// @dev The module-requiring handler signals NEEDS_INPUT when polled
    ///      empty - the discovery trigger end to end
    function test_module_NeedsInputSignal() public {
        ModuleHandler handler = new ModuleHandler(moduleUris(), keccak256("module"));

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.NEEDS_INPUT));
        assertEq(result.reasonCode, TestNoOrder.selector);
    }
}
