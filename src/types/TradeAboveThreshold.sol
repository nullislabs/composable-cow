// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {
    IERC20,
    GPv2Order,
    IConditionalOrder,
    IConditionalOrderGenerator,
    BaseConditionalOrder
} from "../BaseConditionalOrder.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

// --- error strings

/// @dev The sell token balance is below the required minimum or zero
error BalanceInsufficient();

/**
 * @title A smart contract that trades whenever its balance of a certain token exceeds a target threshold
 */
contract TradeAboveThreshold is BaseConditionalOrder {
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint32 validityBucketSeconds;
        uint256 threshold;
        bytes32 appData;
    }

    /**
     * @inheritdoc IConditionalOrder
     * @dev If the `owner`'s balance of `sellToken` is above the specified threshold, sell its entire balance
     * for `buyToken` at the current market price (no limit!).
     */
    function generateOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        /// @dev Decode the payload into the trade above threshold parameters.
        TradeAboveThreshold.Data memory data = abi.decode(staticInput, (Data));

        uint256 balance = data.sellToken.balanceOf(owner);
        // Don't allow the order to be placed if the balance is less than the threshold,
        // or zero: a zero sell amount never trips the settlement replay guard.
        require(
            balance >= data.threshold && balance > 0, IConditionalOrder.PollTryNextBlock(BalanceInsufficient.selector)
        );
        // ensures that orders queried shortly after one another result in the same hash (to avoid spamming the orderbook)
        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            balance,
            1, // 0 buy amount is not allowed
            Utils.validToBucket(data.validityBucketSeconds),
            data.appData,
            0,
            GPv2Order.KIND_SELL,
            false,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}
