// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271, Safe} from "safe/handler/extensible/SignatureVerifierMuxer.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {ComposableCow} from "./ComposableCow.sol";

/**
 * @title ERC1271 Forwarder - An abstract contract that implements ERC1271 forwarding to ComposableCow
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Designed to be extended from by a contract that wants to use ComposableCow
 */
abstract contract ERC1271Forwarder is ERC1271 {
    ComposableCow public immutable composableCow;

    constructor(ComposableCow _composableCow) {
        composableCow = _composableCow;
    }

    // When the pre-image doesn't match the hash, revert with this error.
    error InvalidHash();

    /**
     * Re-arrange the request into something that ComposableCow can understand
     * @param _hash GPv2Order.Data digest
     * @param signature The abi.encoded tuple of (GPv2Order.Data, ComposableCow.PayloadStruct)
     */
    function isValidSignature(bytes32 _hash, bytes memory signature) public view override returns (bytes4) {
        (GPv2Order.Data memory order, ComposableCow.PayloadStruct memory payload) =
            abi.decode(signature, (GPv2Order.Data, ComposableCow.PayloadStruct));
        bytes32 domainSeparator = composableCow.domainSeparator();
        require(GPv2Order.hash(order, domainSeparator) == _hash, InvalidHash());

        return composableCow.isValidSafeSignature(
            Safe(payable(address(this))), // owner
            msg.sender, // sender
            _hash, // GPv2Order digest
            domainSeparator, // GPv2Settlement domain separator
            bytes32(0), // typeHash (not used by ComposableCow)
            abi.encode(order), // GPv2Order
            abi.encode(payload) // ComposableCow.PayloadStruct
        );
    }
}
