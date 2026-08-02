// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271} from "solady/accounts/ERC1271.sol";

import {ComposableCow} from "../ComposableCow.sol";
import {ERC1271Forwarder} from "../ERC1271Forwarder.sol";
import {Account7702} from "./Account7702.sol";

/**
 * @title An `Account7702` that can own conditional orders
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Adds the `ComposableCow` order-payload signature shape to the generic
 *      account, so an EOA can own conditional orders without deploying a
 *      `Safe`.
 *
 *      The premise is that `ComposableCow` never calls a `Safe` method:
 *      `isValidSafeSignature` takes one only as a typed address, and `_auth`
 *      reads the registry's own `roots` and `singleOrders`. The owner therefore
 *      needs nothing beyond ERC-1271.
 *
 *      Two signature shapes are tried in order:
 *      1. ERC-7739 nested EIP-712, inherited unchanged. A miss returns
 *         `0xffffffff` without reverting, so dispatch falls through. This is a
 *         direct owner signature: it never reaches `ComposableCow`, so registry
 *         authorisation, handler `verify` and any swap guard are bypassed.
 *      2. The order payload, `abi.encode(GPv2Order.Data, PayloadStruct)`,
 *         exactly as `ERC1271Forwarder` has always decoded it. On a miss this
 *         branch reverts rather than returning `0xffffffff`, as the forwarder
 *         always has, so an integrator probing this account with an arbitrary
 *         ERC-1271 query must treat a revert as a rejection.
 *
 *      Misrouting can only reject, never accept: the order branch requires
 *      registry authorisation plus the `GPv2Order.hash` check, and the ECDSA
 *      branch requires recovery of the nested digest to `address(this)`.
 *
 *      Declares no `supportsInterface`, and inherits no fallback that would
 *      answer one. `ComposableCow._buildSignature` probes the owner with
 *      `supportsInterface` and produces the payload shape 2 decodes only from
 *      its catch branch, so that probe MUST revert. Solady's `Receiver`, which
 *      `ERC7821` brings, answers only the ERC-721 and ERC-1155 receiver
 *      selectors and reverts `FnSelectorNotRecognized` otherwise, which is what
 *      makes this hold.
 */
contract CowAccount7702 is Account7702, ERC1271Forwarder {
    constructor(ComposableCow _composableCow) ERC1271Forwarder(_composableCow) {}

    /// @dev Distinct from the generic account's domain: a signature for one is
    ///      not valid for the other.
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("CowAccount7702", "1");
    }

    function isValidSignature(bytes32 _hash, bytes calldata signature)
        public
        view
        override(ERC1271, ERC1271Forwarder)
        returns (bytes4 result)
    {
        result = ERC1271.isValidSignature(_hash, signature);
        if (result != bytes4(0xffffffff)) return result;
        return ERC1271Forwarder.isValidSignature(_hash, signature);
    }
}
