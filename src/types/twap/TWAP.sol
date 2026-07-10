// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCoW} from "../../ComposableCoW.sol";

import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    BaseConditionalOrder
} from "../../BaseConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";
import {TWAPOrderMathLib, AfterTwapFinish} from "./libraries/TWAPOrderMathLib.sol";

// --- error strings

/// @dev The current time is outside the active part's span
error NotWithinSpan();

/**
 * @title TWAP Conditional Order
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @notice TWAP conditional orders allow for splitting an order into a series of orders that are
 * executed at a fixed interval. This is useful for ensuring that a trade is executed at a
 * specific price, even if the price of the token changes during the trade.
 * @dev Designed to be used with the CoW Protocol Conditional Order Framework.
 */
contract TWAP is BaseConditionalOrder {
    ComposableCoW public immutable composableCow;

    constructor(ComposableCoW _composableCow) {
        composableCow = _composableCow;
    }

    /**
     * @inheritdoc IConditionalOrder
     * @dev `owner`, `sender` and `offchainInput` is not used.
     */
    function generateOrder(address owner, address, bytes32 ctx, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        /**
         * @dev Decode the payload into a TWAP bundle and get the order. `orderFor` will revert if
         * there is no current valid order.
         * NOTE: This will return an order even if the part of the TWAP bundle that is currently
         * valid is filled. This is safe as CoW Protocol ensures that each `orderUid` is only
         * settled once.
         */
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);

        order = TWAPOrder.orderFor(twap);

        /**
         * @dev If outside the current part's span, this is a scheduling gap, not a
         * permanent failure: signal when the next part starts, or terminate if
         * there is no next part.
         */
        if (!(block.timestamp <= order.validTo)) {
            uint256 part = _currentPart(twap);
            uint256 nextPartStart = twap.t0 + ((part + 1) * twap.t);
            uint256 endTime = twap.t0 + (twap.n * twap.t);

            require(nextPartStart < endTime, IConditionalOrder.OrderNotValid(AfterTwapFinish.selector));
            revert IConditionalOrder.PollTryAtTimestamp(nextPartStart, NotWithinSpan.selector);
        }
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev The next discrete order becomes available when the next part starts;
     *      after the final part there is nothing left to poll for.
     */
    function getNextPollTimestamp(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory)
        external
        view
        override
        returns (uint256)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);
        uint256 part = _currentPart(twap);

        // Last part - stop polling after this fills. Written as `part + 1 >= n`
        // to stay underflow-safe for degenerate bundles.
        if (part + 1 >= twap.n) {
            return POLL_NEVER;
        }

        // Next part starts at...
        return twap.t0 + ((part + 1) * twap.t);
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     */
    function describeOrder(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory)
        external
        view
        override
        returns (string memory)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);
        uint256 part = _currentPart(twap);

        if (part + 1 >= twap.n) {
            return "final twap part";
        }
        return "twap part ready";
    }

    // --- internal helpers

    /// @dev Decode staticInput and resolve t0 from the cabinet if needed
    function _resolveTwapData(address owner, bytes32 ctx, bytes calldata staticInput)
        internal
        view
        returns (TWAPOrder.Data memory twap)
    {
        twap = abi.decode(staticInput, (TWAPOrder.Data));

        /**
         * @dev If `twap.t0` is set to 0, then get the start time from the context.
         */
        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }
    }

    /// @dev Get the current part index from block.timestamp
    function _currentPart(TWAPOrder.Data memory twap) internal view returns (uint256) {
        return TWAPOrderMathLib.currentPart(twap.t0, twap.t);
    }
}
