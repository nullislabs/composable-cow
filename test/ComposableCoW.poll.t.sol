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
    PollTryNextBlockHandler,
    PollTryAtTimestampHandler,
    PollTryAtBlockHandler,
    SuccessHandler,
    PanicHandler,
    RequireFailHandler,
    UnknownErrorHandler
} from "./ComposableCoW.base.t.sol";

/// @dev Test reason errors, as a handler would declare them
error TestOrderInvalid();
error TestTryNextBlock();
error TestWaitTimestamp();
error TestWaitBlock();

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
}
