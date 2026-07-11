// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order, IERC20} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {IERC165, IConditionalOrder, IConditionalOrderGenerator} from "./interfaces/IConditionalOrder.sol";
import {IOrderManifest} from "./interfaces/IOrderManifest.sol";

/// @dev The generated order hash does not match the hash passed to `verify`
error InvalidHash();

/**
 * @title Base logic for conditional orders.
 * @dev Provides the dual-path plumbing: a lean `verify` for the settlement path and a
 *      structured, non-reverting `poll` for watch-towers, both derived from one
 *      `generateOrder` implementation.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract BaseConditionalOrder is IConditionalOrderGenerator, IOrderManifest {
    /// @dev Signals to poll at `order.validTo + 1` for the next discrete order.
    uint256 internal constant POLL_AT_VALIDTO = 0;
    /// @dev Signals that this is the final discrete order; stop polling after it fills.
    uint256 internal constant POLL_NEVER = type(uint256).max;

    /**
     * @inheritdoc IConditionalOrder
     * @dev As an order generator, the `GPv2Order.Data` passed as a parameter is ignored / not validated.
     */
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata
    ) external view override {
        GPv2Order.Data memory generatedOrder = generateOrder(owner, sender, ctx, staticInput, offchainInput);

        /// @dev Verify that the *generated* order is valid and matches the payload.
        require(
            _hash == GPv2Order.hash(generatedOrder, domainSeparator),
            IConditionalOrder.OrderNotValid(InvalidHash.selector)
        );
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev Wraps `generateOrder` in a try/catch, decoding conditional-order errors
     *      into a structured verdict.
     */
    function poll(address owner, address sender, bytes32 ctx, bytes calldata staticInput, bytes calldata offchainInput)
        external
        view
        override
        returns (IConditionalOrderGenerator.GeneratorResult memory result)
    {
        try this.generateOrder(owner, sender, ctx, staticInput, offchainInput) returns (GPv2Order.Data memory order) {
            uint256 nextPoll = this.getNextPollTimestamp(owner, ctx, staticInput, order);
            return IConditionalOrderGenerator.GeneratorResult({
                code: IConditionalOrderGenerator.GeneratorResultCode.POST,
                order: order,
                nextPollTimestamp: nextPoll,
                waitUntil: 0,
                reasonCode: bytes4(0)
            });
        } catch (bytes memory errorData) {
            return _decodeErrorToGeneratorResult(errorData);
        }
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev The complete revert data is returned as ordinary return data so a
     *      consumer can inspect `Panic` sub-codes or unrecognized inner errors
     *      with their arguments, without any RPC revert-data handling.
     */
    function tryGenerateOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) external view override returns (bool success, GPv2Order.Data memory order, bytes memory revertData) {
        try this.generateOrder(owner, sender, ctx, staticInput, offchainInput) returns (GPv2Order.Data memory o) {
            return (true, o, bytes(""));
        } catch (bytes memory errorData) {
            return (false, _emptyOrder(), errorData);
        }
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev Default: poll at `order.validTo + 1`. Override for multi-part orders.
     */
    function getNextPollTimestamp(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        view
        virtual
        override
        returns (uint256)
    {
        return POLL_AT_VALIDTO;
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev Default: generic message. Override for better UX.
     */
    function describeOrder(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        view
        virtual
        override
        returns (string memory)
    {
        return "order ready";
    }

    /**
     * @dev Set the visibility of this function to `public` to allow `verify` to call it.
     * @inheritdoc IConditionalOrder
     */
    function generateOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) public view virtual override returns (GPv2Order.Data memory);

    // --- IOrderManifest defaults

    /**
     * @inheritdoc IOrderManifest
     * @dev Default: a single-shot order (EXACT with 1 order). Override for
     *      multi-part orders.
     */
    function getManifestInfo(address, bytes32, bytes calldata)
        external
        view
        virtual
        override
        returns (ManifestInfo memory info)
    {
        info = ManifestInfo({cardinality: Cardinality.EXACT, totalOrders: 1});
    }

    /**
     * @inheritdoc IOrderManifest
     * @dev Default: wraps `generateOrder` for a single entry at index 0. When the
     *      order cannot currently be generated, the page is empty and `reasonCode`
     *      carries the decoded reason selector, mirroring `poll` semantics.
     */
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        uint256 offset,
        uint256 limit
    ) external view virtual override returns (ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode) {
        // Single-shot: only index 0 exists
        if (offset > 0 || limit == 0) {
            return (new ManifestEntry[](0), false, bytes4(0));
        }

        try this.generateOrder(owner, address(0), ctx, staticInput, offchainInput) returns (
            GPv2Order.Data memory order
        ) {
            entries = new ManifestEntry[](1);
            entries[0] = ManifestEntry({
                index: 0,
                order: order,
                validFrom: 0, // Single-shot orders are valid immediately (no explicit validFrom)
                isActive: block.timestamp <= order.validTo
            });
            return (entries, false, bytes4(0));
        } catch (bytes memory errorData) {
            // Surface why the order is not generatable so a not-yet-active order
            // is distinguishable from a permanently invalid one
            return (new ManifestEntry[](0), false, _decodeErrorToGeneratorResult(errorData).reasonCode);
        }
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return interfaceId == type(IConditionalOrderGenerator).interfaceId
            || interfaceId == type(IOrderManifest).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /**
     * @dev Decode revert data from `generateOrder` into a `GeneratorResult`.
     *
     *      Only `OrderNotValid` maps to the terminal `INVALID` verdict.
     *      `PollNeedsOffchainInput` maps to `NEEDS_INPUT` (acquire input or park,
     *      never a timed retry). Unrecognized
     *      reverts - including `Panic` and `Error(string)` - map to `TRY_NEXT_BLOCK`
     *      so a transient or recoverable fault reschedules rather than permanently
     *      killing the order off-chain. The `reasonCode` carries the selector of
     *      whatever was caught; the complete revert data is retrievable via
     *      `tryGenerateOrder`.
     */
    function _decodeErrorToGeneratorResult(bytes memory errorData)
        internal
        pure
        returns (IConditionalOrderGenerator.GeneratorResult memory)
    {
        if (errorData.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(errorData, 32))
            }

            // OrderNotValid(bytes4): the only permanently terminal verdict
            if (selector == IConditionalOrder.OrderNotValid.selector) {
                return
                    _verdict(IConditionalOrderGenerator.GeneratorResultCode.INVALID, 0, _decodeBytes4Error(errorData));
            }

            // PollTryNextBlock(bytes4)
            if (selector == IConditionalOrder.PollTryNextBlock.selector) {
                return _verdict(
                    IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK, 0, _decodeBytes4Error(errorData)
                );
            }

            // PollTryAtTimestamp(uint256, bytes4)
            if (selector == IConditionalOrder.PollTryAtTimestamp.selector) {
                (uint256 timestamp, bytes4 reasonCode) = _decodeUintBytes4Error(errorData);
                return _verdict(IConditionalOrderGenerator.GeneratorResultCode.WAIT_TIMESTAMP, timestamp, reasonCode);
            }

            // PollTryAtBlock(uint256, bytes4)
            if (selector == IConditionalOrder.PollTryAtBlock.selector) {
                (uint256 blockNum, bytes4 reasonCode) = _decodeUintBytes4Error(errorData);
                return _verdict(IConditionalOrderGenerator.GeneratorResultCode.WAIT_BLOCK, blockNum, reasonCode);
            }

            // PollNeedsOffchainInput(bytes4): not a timed retry - the caller
            // must acquire non-empty offchainInput or park the order
            if (selector == IConditionalOrder.PollNeedsOffchainInput.selector) {
                return
                    _verdict(
                        IConditionalOrderGenerator.GeneratorResultCode.NEEDS_INPUT, 0, _decodeBytes4Error(errorData)
                    );
            }

            // Anything else - Panic, Error(string), or an unrecognized custom
            // error - is a transient verdict carrying the caught selector
            return _verdict(IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK, 0, selector);
        }

        // Empty or malformed revert data: transient, no reason available
        return _verdict(IConditionalOrderGenerator.GeneratorResultCode.TRY_NEXT_BLOCK, 0, bytes4(0));
    }

    /// @dev Build a non-POST verdict with an empty order.
    function _verdict(IConditionalOrderGenerator.GeneratorResultCode code, uint256 waitUntil, bytes4 reasonCode)
        private
        pure
        returns (IConditionalOrderGenerator.GeneratorResult memory)
    {
        return IConditionalOrderGenerator.GeneratorResult({
            code: code, order: _emptyOrder(), nextPollTimestamp: 0, waitUntil: waitUntil, reasonCode: reasonCode
        });
    }

    /// @dev Decode an error with signature `(bytes4)`.
    function _decodeBytes4Error(bytes memory errorData) internal pure returns (bytes4 reasonCode) {
        if (errorData.length >= 36) {
            assembly {
                errorData := add(errorData, 4)
            }
            reasonCode = abi.decode(errorData, (bytes4));
        }
    }

    /// @dev Decode an error with signature `(uint256, bytes4)`.
    function _decodeUintBytes4Error(bytes memory errorData) internal pure returns (uint256 value, bytes4 reasonCode) {
        if (errorData.length >= 68) {
            assembly {
                errorData := add(errorData, 4)
            }
            (value, reasonCode) = abi.decode(errorData, (uint256, bytes4));
        }
    }

    /// @dev An all-zero order for non-POST verdicts.
    function _emptyOrder() internal pure returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: IERC20(address(0)),
            buyToken: IERC20(address(0)),
            receiver: address(0),
            sellAmount: 0,
            buyAmount: 0,
            validTo: 0,
            appData: bytes32(0),
            feeAmount: 0,
            kind: bytes32(0),
            partiallyFillable: false,
            sellTokenBalance: bytes32(0),
            buyTokenBalance: bytes32(0)
        });
    }
}
