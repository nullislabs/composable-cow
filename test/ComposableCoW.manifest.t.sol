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
import {TWAPOrder} from "../src/types/twap/libraries/TWAPOrder.sol";
import {OrderNotInitialized} from "../src/types/twap/TWAP.sol";
import {PerpetualStableSwap, NotFunded} from "../src/types/PerpetualStableSwap.sol";
import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";
import {IValueFactory} from "../src/interfaces/IValueFactory.sol";

/// @dev Test reason errors, as a handler would declare them
error TestNotYetActive();
error TestPermanentlyInvalid();

/// @title Tests for the IOrderManifest default implementation in BaseConditionalOrder
contract ComposableCoWManifestTest is BaseComposableCoWTest {
    uint256 constant SELL_AMOUNT = 24000e18;
    uint256 constant LIMIT_PRICE = 100e18;
    uint32 constant FREQUENCY = 1 hours;
    uint32 constant NUM_PARTS = 24;
    uint32 constant SPAN = 5 minutes;

    PerpetualStableSwap perpetualSwap;
    IValueFactory currentBlockTimestampFactory;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        perpetualSwap = new PerpetualStableSwap(testDescriptorUris(), TEST_DESCRIPTOR_DIGEST);
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
    }

    function _twapTestBundle(uint256 startTime) internal view returns (TWAPOrder.Data memory) {
        return TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            partSellAmount: SELL_AMOUNT / NUM_PARTS,
            minPartLimit: LIMIT_PRICE,
            t0: startTime,
            n: NUM_PARTS,
            t: FREQUENCY,
            span: SPAN,
            appData: keccak256("test.twap")
        });
    }

    function _pssData() internal view returns (PerpetualStableSwap.Data memory) {
        return PerpetualStableSwap.Data({
            tokenA: token0,
            tokenB: token1,
            validityBucketSeconds: 300,
            halfSpreadBps: 50,
            appData: keccak256("perpetual")
        });
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

    // ============ TWAP Manifest Tests ============

    function test_TWAP_getManifestInfo_ReturnsExactCardinality() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(block.timestamp);

        IOrderManifest.ManifestInfo memory info = twap.getManifestInfo(address(safe1), bytes32(0), abi.encode(twapData));

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.EXACT));
        assertEq(info.totalOrders, NUM_PARTS);
    }

    function test_TWAP_getManifestInfo_DegenerateYieldsEmptyManifest() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(block.timestamp);
        twapData.n = 0;

        IOrderManifest.ManifestInfo memory info = twap.getManifestInfo(address(safe1), bytes32(0), abi.encode(twapData));

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.EXACT));
        assertEq(info.totalOrders, 0);
    }

    function test_TWAP_getManifestPage_ReturnsAllParts() public {
        uint256 startTime = block.timestamp;
        TWAPOrder.Data memory twapData = _twapTestBundle(startTime);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, NUM_PARTS);

        assertEq(entries.length, NUM_PARTS);
        assertFalse(hasMore);
        assertEq(reasonCode, bytes4(0));

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].index, i);
            assertEq(entries[i].validFrom, startTime + (i * FREQUENCY));
            assertEq(address(entries[i].order.sellToken), address(token0));
            assertEq(address(entries[i].order.buyToken), address(token1));
            assertEq(entries[i].order.sellAmount, twapData.partSellAmount);
            assertEq(entries[i].order.buyAmount, twapData.minPartLimit);
        }
    }

    function test_TWAP_getManifestPage_Pagination() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(block.timestamp);

        (IOrderManifest.ManifestEntry[] memory page1, bool hasMore1,) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, 10);
        assertEq(page1.length, 10);
        assertTrue(hasMore1);
        assertEq(page1[0].index, 0);
        assertEq(page1[9].index, 9);

        (IOrderManifest.ManifestEntry[] memory page2, bool hasMore2,) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 10, 10);
        assertEq(page2.length, 10);
        assertTrue(hasMore2);
        assertEq(page2[0].index, 10);
        assertEq(page2[9].index, 19);

        (IOrderManifest.ManifestEntry[] memory page3, bool hasMore3,) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 20, 10);
        assertEq(page3.length, 4);
        assertFalse(hasMore3);
        assertEq(page3[0].index, 20);
        assertEq(page3[3].index, 23);
    }

    function test_TWAP_getManifestPage_UninitializedCarriesStatus() public {
        // t0 = 0 and no context set: the order is not initialized
        TWAPOrder.Data memory twapData = _twapTestBundle(0);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, 10);

        assertEq(entries.length, 0);
        assertFalse(hasMore);
        assertEq(reasonCode, OrderNotInitialized.selector);
    }

    function test_TWAP_getManifestPage_WithContext() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(0);
        uint256 contextTime = block.timestamp + 1 days;

        IConditionalOrder.ConditionalOrderParams memory params =
            createOrder(twap, keccak256("twap"), abi.encode(twapData));

        vm.warp(contextTime);
        _createWithContext(address(safe1), params, currentBlockTimestampFactory, bytes(""), false);

        bytes32 ctx = composableCow.hash(params);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore,) =
            twap.getManifestPage(address(safe1), ctx, abi.encode(twapData), bytes(""), 0, 5);

        assertEq(entries.length, 5);
        assertTrue(hasMore);
        // First entry starts at the context time stored in the cabinet
        assertEq(entries[0].validFrom, contextTime);
    }

    function test_TWAP_ManifestEntriesMatchGenerateOrder() public {
        uint256 startTime = block.timestamp;
        TWAPOrder.Data memory twapData = _twapTestBundle(startTime);

        (IOrderManifest.ManifestEntry[] memory entries,,) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, NUM_PARTS);

        for (uint256 i = 0; i < entries.length; i++) {
            vm.warp(entries[i].validFrom);

            GPv2Order.Data memory generatedOrder =
                twap.generateOrder(address(safe1), address(0), bytes32(0), abi.encode(twapData), bytes(""));

            assertEq(address(entries[i].order.sellToken), address(generatedOrder.sellToken));
            assertEq(address(entries[i].order.buyToken), address(generatedOrder.buyToken));
            assertEq(entries[i].order.sellAmount, generatedOrder.sellAmount);
            assertEq(entries[i].order.buyAmount, generatedOrder.buyAmount);
            assertEq(entries[i].order.validTo, generatedOrder.validTo);
        }
    }

    function test_TWAP_IsActive_DuringSpan() public {
        uint256 startTime = block.timestamp;
        TWAPOrder.Data memory twapData = _twapTestBundle(startTime);

        vm.warp(startTime + SPAN / 2);

        (IOrderManifest.ManifestEntry[] memory entries,,) =
            twap.getManifestPage(address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, 3);

        assertTrue(entries[0].isActive); // First part is active
        assertFalse(entries[1].isActive); // Second part not yet active
        assertFalse(entries[2].isActive); // Third part not yet active
    }

    // ============ PerpetualStableSwap Manifest Tests ============

    function test_PSS_ManifestReturnsUnbounded() public {
        IOrderManifest.ManifestInfo memory info =
            perpetualSwap.getManifestInfo(address(safe1), bytes32(0), abi.encode(_pssData()));

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.UNBOUNDED));
        assertEq(info.totalOrders, 0);
    }

    function test_PSS_PaginationAlwaysTerminates() public {
        deal(address(token0), address(safe1), 1000e18);

        // A naive walker: offset += entries.length until hasMore == false
        uint256 offset;
        for (uint256 i = 0; i < 3; i++) {
            (IOrderManifest.ManifestEntry[] memory entries, bool hasMore,) =
                perpetualSwap.getManifestPage(address(safe1), bytes32(0), abi.encode(_pssData()), bytes(""), offset, 10);
            offset += entries.length;
            if (!hasMore) return; // terminated as required
        }
        revert("pagination did not terminate");
    }

    function test_PSS_ManifestPage_NotFundedCarriesStatus() public {
        address unfundedOwner = makeAddr("unfunded");

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) =
            perpetualSwap.getManifestPage(unfundedOwner, bytes32(0), abi.encode(_pssData()), bytes(""), 0, 10);

        assertEq(entries.length, 0);
        assertFalse(hasMore);
        assertEq(reasonCode, NotFunded.selector);
    }

    function test_PSS_ManifestPage_WithBalance() public {
        deal(address(token0), address(safe1), 1000e18);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore,) =
            perpetualSwap.getManifestPage(address(safe1), bytes32(0), abi.encode(_pssData()), bytes(""), 0, 10);

        assertEq(entries.length, 1);
        assertFalse(hasMore);
        assertEq(entries[0].index, 0);
        assertEq(address(entries[0].order.sellToken), address(token0));
        assertEq(entries[0].order.sellAmount, 1000e18);
    }
}
