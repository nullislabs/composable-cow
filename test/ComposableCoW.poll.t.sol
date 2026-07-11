// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    ComposableCoW,
    BaseComposableCoWTest,
    InvalidHash,
    OrderNotValidHandler,
    NeedsOffchainInputHandler,
    PollTryNextBlockHandler,
    PollTryAtTimestampHandler,
    PollTryAtBlockHandler,
    SuccessHandler,
    PanicHandler,
    RequireFailHandler,
    UnknownErrorHandler
} from "./ComposableCoW.base.t.sol";
import {OffchainInputRequired} from "../src/interfaces/IConditionalOrder.sol";

/// @dev Test reason errors, as a handler would declare them
error TestOrderInvalid();
error TestTryNextBlock();
error TestWaitTimestamp();
error TestWaitBlock();
error TestTriggerPriceRequired();

/// @title Tests for poll() verdicts and error decoding in BaseConditionalOrder
contract ComposableCoWPollTest is BaseComposableCoWTest {
    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();
    }

    /// @dev OrderNotValid is the only error decoding to the terminal INVALID verdict
    function test_poll_DecodesOrderNotValid() public {
        bytes4 expectedReason = TestOrderInvalid.selector;
        OrderNotValidHandler handler = new OrderNotValidHandler(expectedReason);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.INVALID));
        assertEq(result.reasonCode, expectedReason);
        assertEq(result.waitUntil, 0);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev PollNeedsOffchainInput decodes to the NEEDS_INPUT verdict: not a
    ///      timed retry - the caller must acquire input or park
    function test_poll_DecodesPollNeedsOffchainInput() public {
        bytes4 expectedReason = TestTriggerPriceRequired.selector;
        NeedsOffchainInputHandler handler = new NeedsOffchainInputHandler(expectedReason);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.NEEDS_INPUT));
        assertEq(result.reasonCode, expectedReason);
        assertEq(result.waitUntil, 0);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev The same handler generates once offchainInput is supplied - the
    ///      NEEDS_INPUT verdict is about the missing input, not the order
    function test_poll_NeedsInputHandlerPostsWithInput() public {
        NeedsOffchainInputHandler handler = new NeedsOffchainInputHandler(TestTriggerPriceRequired.selector);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes("trigger"));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.POST));
        assertEq(result.reasonCode, bytes4(0));
    }

    /// @dev The canonical OffchainInputRequired reason round-trips the probe:
    ///      tryGenerateOrder surfaces the full PollNeedsOffchainInput revert
    function test_tryGenerateOrder_NeedsInputRevertData() public {
        NeedsOffchainInputHandler handler = new NeedsOffchainInputHandler(OffchainInputRequired.selector);

        (bool success,, bytes memory revertData) =
            handler.tryGenerateOrder(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertFalse(success);
        assertEq(
            revertData,
            abi.encodeWithSelector(IConditionalOrder.PollNeedsOffchainInput.selector, OffchainInputRequired.selector)
        );
    }

    /// @dev PollTryNextBlock decodes to the TRY_NEXT_BLOCK verdict
    function test_poll_DecodesPollTryNextBlock() public {
        bytes4 expectedReason = TestTryNextBlock.selector;
        PollTryNextBlockHandler handler = new PollTryNextBlockHandler(expectedReason);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK));
        assertEq(result.reasonCode, expectedReason);
        assertEq(result.waitUntil, 0);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev PollTryAtTimestamp decodes to the WAIT_TIMESTAMP verdict
    function test_poll_DecodesPollTryAtTimestamp() public {
        uint256 expectedTimestamp = 1234567890;
        bytes4 expectedReason = TestWaitTimestamp.selector;
        PollTryAtTimestampHandler handler = new PollTryAtTimestampHandler(expectedTimestamp, expectedReason);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.WAIT_TIMESTAMP));
        assertEq(result.reasonCode, expectedReason);
        assertEq(result.waitUntil, expectedTimestamp);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev PollTryAtBlock decodes to the WAIT_BLOCK verdict
    function test_poll_DecodesPollTryAtBlock() public {
        uint256 expectedBlock = 999999;
        bytes4 expectedReason = TestWaitBlock.selector;
        PollTryAtBlockHandler handler = new PollTryAtBlockHandler(expectedBlock, expectedReason);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.WAIT_BLOCK));
        assertEq(result.reasonCode, expectedReason);
        assertEq(result.waitUntil, expectedBlock);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev A successful generateOrder yields the POST verdict with the order
    function test_poll_ReturnsPostOnValidOrder() public {
        SuccessHandler handler = new SuccessHandler();

        GPv2Order.Data memory expectedOrder = GPv2Order.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: keccak256("test"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        handler.setOrder(expectedOrder);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.POST));
        assertEq(result.reasonCode, bytes4(0));
        assertEq(address(result.order.sellToken), address(expectedOrder.sellToken));
        assertEq(address(result.order.buyToken), address(expectedOrder.buyToken));
        assertEq(result.order.sellAmount, expectedOrder.sellAmount);
        assertEq(result.order.buyAmount, expectedOrder.buyAmount);
    }

    /// @dev An arithmetic Panic maps to TRY_NEXT_BLOCK with a diagnosable reason,
    ///      never to the terminal INVALID verdict
    function test_poll_PanicMapsToTryNextBlock() public {
        PanicHandler handler = new PanicHandler();

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK));
        // Panic(uint256) selector; the 0x12 sub-code is retrievable via tryGenerateOrder
        assertEq(result.reasonCode, bytes4(0x4e487b71));
    }

    /// @dev A bare require reason maps to TRY_NEXT_BLOCK, preserving the reason
    function test_poll_BareRequireMapsToTryNextBlock() public {
        RequireFailHandler handler = new RequireFailHandler();

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK));
        // Error(string) selector; the message is retrievable via tryGenerateOrder
        assertEq(result.reasonCode, bytes4(0x08c379a0));
    }

    /// @dev An unrecognized custom error maps to TRY_NEXT_BLOCK, not INVALID
    function test_poll_UnknownErrorMapsToTryNextBlock() public {
        UnknownErrorHandler handler = new UnknownErrorHandler();

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK));
        // The unrecognized error's own selector is carried through
        assertEq(result.reasonCode, UnknownErrorHandler.SomethingUnexpected.selector);
    }

    /// @dev Fuzz OrderNotValid decoding
    function test_poll_FuzzOrderNotValid(bytes4 reasonCode) public {
        OrderNotValidHandler handler = new OrderNotValidHandler(reasonCode);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.INVALID));
        assertEq(result.reasonCode, reasonCode);
    }

    /// @dev Fuzz PollTryAtTimestamp decoding
    function test_poll_FuzzPollTryAtTimestamp(uint256 timestamp, bytes4 reasonCode) public {
        PollTryAtTimestampHandler handler = new PollTryAtTimestampHandler(timestamp, reasonCode);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.WAIT_TIMESTAMP));
        assertEq(result.waitUntil, timestamp);
        assertEq(result.reasonCode, reasonCode);
    }

    /// @dev Fuzz PollTryAtBlock decoding
    function test_poll_FuzzPollTryAtBlock(uint256 blockNum, bytes4 reasonCode) public {
        PollTryAtBlockHandler handler = new PollTryAtBlockHandler(blockNum, reasonCode);

        IConditionalOrderGenerator.GeneratorResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.WAIT_BLOCK));
        assertEq(result.waitUntil, blockNum);
        assertEq(result.reasonCode, reasonCode);
    }

    /// @dev verify() derives from generateOrder() and accepts a matching hash
    function test_verify_UsesGenerateOrder() public {
        SuccessHandler handler = new SuccessHandler();

        GPv2Order.Data memory expectedOrder = GPv2Order.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: keccak256("test"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        handler.setOrder(expectedOrder);

        bytes32 domainSeparator = composableCow.domainSeparator();
        bytes32 orderHash = GPv2Order.hash(expectedOrder, domainSeparator);

        // Should not revert - hash matches
        handler.verify(
            address(safe1), address(this), orderHash, domainSeparator, bytes32(0), bytes(""), bytes(""), expectedOrder
        );
    }

    /// @dev verify() reverts on hash mismatch
    function test_verify_RevertsOnHashMismatch() public {
        SuccessHandler handler = new SuccessHandler();

        GPv2Order.Data memory expectedOrder = GPv2Order.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: keccak256("test"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        handler.setOrder(expectedOrder);

        bytes32 domainSeparator = composableCow.domainSeparator();
        bytes32 wrongHash = keccak256("wrong hash");

        // Should revert - hash doesn't match
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, InvalidHash.selector));
        handler.verify(
            address(safe1), address(this), wrongHash, domainSeparator, bytes32(0), bytes(""), bytes(""), expectedOrder
        );
    }

    // --- tryGenerateOrder: full revert data diagnostics ---

    /// @dev A Panic's complete revert data - including the sub-code - is returned
    function test_tryGenerateOrder_ReturnsFullPanicData() public {
        PanicHandler handler = new PanicHandler();

        (bool success,, bytes memory revertData) =
            handler.tryGenerateOrder(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertFalse(success);
        // Panic(0x12): division by zero
        assertEq(revertData, abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x12)));
    }

    /// @dev A bare require's Error(string) message is fully retrievable
    function test_tryGenerateOrder_ReturnsFullErrorString() public {
        RequireFailHandler handler = new RequireFailHandler();

        (bool success,, bytes memory revertData) =
            handler.tryGenerateOrder(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertFalse(success);
        assertEq(revertData, abi.encodeWithSignature("Error(string)", "plain require failure"));
    }

    /// @dev An unrecognized custom error's arguments are fully retrievable
    function test_tryGenerateOrder_ReturnsFullCustomErrorData() public {
        UnknownErrorHandler handler = new UnknownErrorHandler();

        (bool success,, bytes memory revertData) =
            handler.tryGenerateOrder(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertFalse(success);
        assertEq(revertData, abi.encodeWithSelector(UnknownErrorHandler.SomethingUnexpected.selector, uint256(42)));
    }

    /// @dev Success returns the order and empty revert data
    function test_tryGenerateOrder_SuccessReturnsOrder() public {
        SuccessHandler handler = new SuccessHandler();
        GPv2Order.Data memory expectedOrder = getBlankOrder();
        expectedOrder.sellAmount = 42e18;
        handler.setOrder(expectedOrder);

        (bool success, GPv2Order.Data memory order, bytes memory revertData) =
            handler.tryGenerateOrder(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertTrue(success);
        assertEq(order.sellAmount, 42e18);
        assertEq(revertData.length, 0);
    }

    // --- registry-level composition tests ---

    /// @dev getTradeableOrderWithSignature surfaces the handler verdict unchanged
    function test_getTradeableOrderWithSignature_UsesPollInternally() public {
        uint256 expectedTimestamp = block.timestamp + 1 days;
        bytes4 expectedReason = TestWaitTimestamp.selector;
        PollTryAtTimestampHandler handler = new PollTryAtTimestampHandler(expectedTimestamp, expectedReason);

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(handler)), salt: keccak256("test"), staticInput: bytes("")
        });

        _create(address(safe1), params, false);

        (ComposableCoW.PollResult memory result, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.generator.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.WAIT_TIMESTAMP));
        assertEq(result.generator.waitUntil, expectedTimestamp);
        assertEq(result.generator.reasonCode, expectedReason);
        assertEq(signature.length, 0);
        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.NONE));
    }

    /// @dev Helper: register a SuccessHandler order and return its params
    function _successOrder(bool partiallyFillable)
        internal
        returns (IConditionalOrder.ConditionalOrderParams memory params, SuccessHandler handler)
    {
        handler = new SuccessHandler();
        handler.setOrder(
            GPv2Order.Data({
                sellToken: token0,
                buyToken: token1,
                receiver: address(0),
                sellAmount: 100e18,
                buyAmount: 50e18,
                validTo: uint32(block.timestamp + 1 hours),
                appData: keccak256("fill-overlay"),
                feeAmount: 0,
                kind: GPv2Order.KIND_SELL,
                partiallyFillable: partiallyFillable,
                sellTokenBalance: GPv2Order.BALANCE_ERC20,
                buyTokenBalance: GPv2Order.BALANCE_ERC20
            })
        );
        params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(handler)), salt: keccak256("fill-overlay"), staticInput: bytes("")
        });
        _create(address(safe1), params, false);
    }

    /// @dev Mock the observed fill amount for every filledAmount(bytes) call
    function _mockFilledAmount(uint256 amount) internal {
        vm.mockCall(
            address(composableCow.settlement()), abi.encodeWithSignature("filledAmount(bytes)"), abi.encode(amount)
        );
    }

    /// @dev No fill observed: NONE overlay, signature returned
    function test_fillOverlay_NoneReturnsSignature() public {
        (IConditionalOrder.ConditionalOrderParams memory params,) = _successOrder(true);
        _mockFilledAmount(0);

        (ComposableCoW.PollResult memory result, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.generator.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.POST));
        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.NONE));
        assertEq(result.filledAmount, 0);
        assertGt(signature.length, 0);
    }

    /// @dev A partially filled partiallyFillable order keeps returning its signature
    function test_fillOverlay_PartialFillKeepsPosting() public {
        (IConditionalOrder.ConditionalOrderParams memory params,) = _successOrder(true);
        _mockFilledAmount(40e18);

        (ComposableCoW.PollResult memory result, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.generator.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.POST));
        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.PARTIALLY_FILLED));
        assertEq(result.filledAmount, 40e18);
        assertGt(signature.length, 0);
    }

    /// @dev A partial fill on a fill-or-kill order does not return a signature
    function test_fillOverlay_PartialFillOnFillOrKillWithholdsSignature() public {
        (IConditionalOrder.ConditionalOrderParams memory params,) = _successOrder(false);
        _mockFilledAmount(40e18);

        (ComposableCoW.PollResult memory result, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.generator.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.POST));
        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.PARTIALLY_FILLED));
        assertEq(signature.length, 0);
    }

    /// @dev A fully filled order does not return a signature
    function test_fillOverlay_FilledWithholdsSignature() public {
        (IConditionalOrder.ConditionalOrderParams memory params,) = _successOrder(true);
        _mockFilledAmount(100e18);

        (ComposableCoW.PollResult memory result, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.FILLED));
        assertEq(result.filledAmount, 100e18);
        assertEq(signature.length, 0);
    }

    /// @dev An invalidated order is INVALIDATED, not FILLED, and not postable
    function test_fillOverlay_InvalidatedIsDistinctFromFilled() public {
        (IConditionalOrder.ConditionalOrderParams memory params,) = _successOrder(true);
        _mockFilledAmount(type(uint256).max);

        (ComposableCoW.PollResult memory result, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.INVALIDATED));
        assertEq(result.filledAmount, type(uint256).max);
        assertEq(signature.length, 0);
    }

    /// @dev checkOrder returns the same composed overlay as the signature path
    function test_checkOrder_ComposesFillOverlay() public {
        (IConditionalOrder.ConditionalOrderParams memory params,) = _successOrder(true);
        _mockFilledAmount(100e18);

        ComposableCoW.PollResult memory result =
            composableCow.checkOrder(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.generator.code), uint256(IConditionalOrderGenerator.GeneratorResultCode.POST));
        assertEq(uint256(result.fill), uint256(ComposableCoW.FillStatus.FILLED));
    }

    /// @dev checkOrder applies the ERC-165 handler gate
    function test_checkOrder_RevertInterfaceNotSupported() public {
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(token0)), // a contract without ERC-165
            salt: keccak256("no-interface"),
            staticInput: bytes("")
        });
        _create(address(safe1), params, false);

        vm.expectRevert(ComposableCoW.InterfaceNotSupported.selector);
        composableCow.checkOrder(address(safe1), params, bytes(""), new bytes32[](0));
    }
}
