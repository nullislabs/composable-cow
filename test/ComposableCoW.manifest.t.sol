// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    ComposableCoW,
    BaseComposableCoWTest,
    OrderNotValidHandler,
    PollTryAtTimestampHandler,
    SuccessHandler
} from "./ComposableCoW.base.t.sol";
import {IOrderManifest} from "../src/interfaces/IOrderManifest.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

/// @dev Test reason errors, as a handler would declare them
error TestNotYetActive();
error TestPermanentlyInvalid();

/// @title Tests for the IOrderManifest default implementation in BaseConditionalOrder
contract ComposableCoWManifestTest is BaseComposableCoWTest {
    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();
    }

    /// @dev The manifest interface is feature-detected via its own ERC-165 id
    function test_manifest_SupportsInterface() public {
        SuccessHandler handler = new SuccessHandler();

        assertTrue(handler.supportsInterface(type(IOrderManifest).interfaceId));
        assertTrue(handler.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
        assertTrue(handler.supportsInterface(type(IERC165).interfaceId));
    }

    /// @dev Default manifest info: single-shot EXACT with 1 order
    function test_manifestInfo_DefaultSingleShot() public {
        SuccessHandler handler = new SuccessHandler();

        IOrderManifest.ManifestInfo memory info = handler.getManifestInfo(address(safe1), bytes32(0), bytes(""));

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.EXACT));
        assertEq(info.totalOrders, 1);
    }

    /// @dev Default page: index 0 carries the generated order
    function test_manifestPage_DefaultSingleEntry() public {
        SuccessHandler handler = new SuccessHandler();
        GPv2Order.Data memory order = getBlankOrder();
        order.sellAmount = 100e18;
        order.validTo = uint32(block.timestamp + 1 hours);
        handler.setOrder(order);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) =
            handler.getManifestPage(address(safe1), bytes32(0), bytes(""), bytes(""), 0, 10);

        assertEq(entries.length, 1);
        assertEq(entries[0].index, 0);
        assertEq(entries[0].order.sellAmount, 100e18);
        assertTrue(entries[0].isActive);
        assertFalse(hasMore);
        assertEq(reasonCode, bytes4(0));
    }

    /// @dev Pagination contract: out-of-range pages are empty and terminal
    function test_manifestPage_OutOfRangeTerminates() public {
        SuccessHandler handler = new SuccessHandler();

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore,) =
            handler.getManifestPage(address(safe1), bytes32(0), bytes(""), bytes(""), 1, 10);
        assertEq(entries.length, 0);
        assertFalse(hasMore);

        (entries, hasMore,) = handler.getManifestPage(address(safe1), bytes32(0), bytes(""), bytes(""), 0, 0);
        assertEq(entries.length, 0);
        assertFalse(hasMore);
    }

    /// @dev An empty page caused by a WAIT condition carries the decoded reason,
    ///      so it is distinguishable from a permanently invalid order
    function test_manifestPage_EmptyPageCarriesWaitReason() public {
        PollTryAtTimestampHandler handler =
            new PollTryAtTimestampHandler(block.timestamp + 1 days, TestNotYetActive.selector);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) =
            handler.getManifestPage(address(safe1), bytes32(0), bytes(""), bytes(""), 0, 10);

        assertEq(entries.length, 0);
        assertFalse(hasMore);
        assertEq(reasonCode, TestNotYetActive.selector);
    }

    /// @dev An empty page caused by a permanently invalid order carries its reason
    function test_manifestPage_EmptyPageCarriesInvalidReason() public {
        OrderNotValidHandler handler = new OrderNotValidHandler(TestPermanentlyInvalid.selector);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) =
            handler.getManifestPage(address(safe1), bytes32(0), bytes(""), bytes(""), 0, 10);

        assertEq(entries.length, 0);
        assertFalse(hasMore);
        assertEq(reasonCode, TestPermanentlyInvalid.selector);
    }

    /// @dev The interfaceId of IConditionalOrderGenerator is unaffected by the
    ///      manifest sidecar (regression pin for the polling gate)
    function test_manifest_DoesNotPerturbGeneratorInterfaceId() public {
        assertTrue(type(IOrderManifest).interfaceId != type(IConditionalOrderGenerator).interfaceId);
        assertTrue(type(IOrderManifest).interfaceId != bytes4(0));
    }
}
