// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ComposableCoW} from "../../ComposableCoW.sol";

import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    BaseConditionalOrder
} from "../../BaseConditionalOrder.sol";
import {IOrderManifest} from "../../interfaces/IOrderManifest.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";
import {TWAPOrderMathLib, AfterTwapFinish} from "./libraries/TWAPOrderMathLib.sol";
import {OrderDescriptor} from "../../OrderDescriptor.sol";

// --- error strings

/// @dev The current time is outside the active part's span
error NotWithinSpan();
/// @dev The TWAP has no start time yet: t0 is 0 and no context value has been written
error OrderNotInitialized();

/**
 * @title TWAP Conditional Order
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @notice TWAP conditional orders allow for splitting an order into a series of orders that are
 * executed at a fixed interval. This is useful for ensuring that a trade is executed at a
 * specific price, even if the price of the token changes during the trade.
 * @dev Designed to be used with the CoW Protocol Conditional Order Framework.
 */
contract TWAP is OrderDescriptor {
    using SafeCast for uint256;

    ComposableCoW public immutable composableCow;

    constructor(ComposableCoW _composableCow, string[] memory descriptorUris, bytes32 descriptorDigest_)
        OrderDescriptor(descriptorUris, descriptorDigest_)
    {
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

    // --- IOrderManifest

    /**
     * @inheritdoc IOrderManifest
     * @dev A TWAP has exactly `n` parts. Degenerate parameters yield an empty
     *      manifest (EXACT, 0) rather than reverting or computing on
     *      unvalidated input.
     */
    function getManifestInfo(address owner, bytes32 ctx, bytes calldata staticInput)
        external
        view
        override
        returns (ManifestInfo memory info)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);

        try this.validateTwapData(twap) {}
        catch {
            return ManifestInfo({cardinality: Cardinality.EXACT, totalOrders: 0});
        }

        info = ManifestInfo({cardinality: Cardinality.EXACT, totalOrders: twap.n});
    }

    /**
     * @inheritdoc IOrderManifest
     * @dev Enumerates part orders with their validity windows. Parameters are
     *      validated before any part math runs.
     */
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata,
        uint256 offset,
        uint256 limit
    ) external view override returns (ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);

        // If t0 is still 0 after resolution, the order has not been initialized
        // (context not yet written)
        if (twap.t0 == 0) {
            return (new ManifestEntry[](0), false, OrderNotInitialized.selector);
        }

        // Validate order parameters before any part math
        try this.validateTwapData(twap) {}
        catch (bytes memory errorData) {
            return (new ManifestEntry[](0), false, _decodeErrorToGeneratorResult(errorData).reasonCode);
        }

        uint256 totalParts = twap.n;
        if (offset >= totalParts || limit == 0) {
            return (new ManifestEntry[](0), false, bytes4(0));
        }

        uint256 remaining = totalParts - offset;
        uint256 count = remaining < limit ? remaining : limit;
        hasMore = offset + count < totalParts;

        entries = new ManifestEntry[](count);
        for (uint256 i = 0; i < count; i++) {
            entries[i] = _manifestEntry(twap, offset + i);
        }
    }

    /// @dev External wrapper for validation (used with try/catch)
    function validateTwapData(TWAPOrder.Data memory twap) external pure {
        TWAPOrder.validate(twap);
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

    /// @dev Calculate validFrom and validTo for any part index (pure, for manifest enumeration)
    function _partTiming(TWAPOrder.Data memory twap, uint256 partIndex)
        internal
        pure
        returns (uint256 validFrom, uint256 validTo)
    {
        validFrom = twap.t0 + (partIndex * twap.t);

        if (twap.span == 0) {
            // Full epoch: valid until the next part starts
            validTo = validFrom + twap.t - 1;
        } else {
            // Partial span within the epoch
            validTo = validFrom + twap.span - 1;
        }
    }

    /**
     * @dev Build the GPv2Order.Data for any part index (pure, for manifest
     *      enumeration). Does NOT check runtime conditions (before/after the
     *      TWAP window) - use only for the manifest.
     */
    function _orderForPartPure(TWAPOrder.Data memory twap, uint256 partIndex)
        internal
        pure
        returns (GPv2Order.Data memory order)
    {
        (, uint256 validTo) = _partTiming(twap, partIndex);

        order = GPv2Order.Data({
            sellToken: twap.sellToken,
            buyToken: twap.buyToken,
            receiver: twap.receiver,
            sellAmount: twap.partSellAmount,
            buyAmount: twap.minPartLimit,
            validTo: validTo.toUint32(),
            appData: twap.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    /// @dev Build a complete ManifestEntry for any part index
    function _manifestEntry(TWAPOrder.Data memory twap, uint256 partIndex)
        internal
        view
        returns (ManifestEntry memory entry)
    {
        (uint256 validFrom, uint256 validTo) = _partTiming(twap, partIndex);

        entry = ManifestEntry({
            index: partIndex,
            order: _orderForPartPure(twap, partIndex),
            validFrom: validFrom,
            isActive: block.timestamp >= validFrom && block.timestamp <= validTo
        });
    }
}
