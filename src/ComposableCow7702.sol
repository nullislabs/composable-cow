// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271 as SoladyERC1271} from "solady/accounts/ERC1271.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

import {ComposableCow} from "./ComposableCow.sol";
import {ERC1271Forwarder} from "./ERC1271Forwarder.sol";

/**
 * @title EIP-7702 delegate routing ERC-1271 to ComposableCow
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Lets an EOA place conditional orders without deploying a `Safe`.
 *      `ComposableCow` never calls a `Safe` method: `isValidSafeSignature`
 *      takes one only as a typed address, and `_auth` reads the registry's own
 *      `roots` and `singleOrders`. The owner therefore needs nothing beyond
 *      ERC-1271, which `ERC1271Forwarder` already implements.
 *
 *      Stateless by construction. The only member is the immutable
 *      `composableCow`, which lives in code, so there is no initializer to
 *      front-run and no storage to collide with a later delegate.
 *
 *      Batching is `ERC7821` at its defaults: an empty `opData` requires
 *      `msg.sender == address(this)`, which under EIP-7702 is satisfied only by
 *      a transaction the EOA sends to itself, and a non-empty `opData` reverts,
 *      so there is no relayed path and no nonce to maintain. The EOA's own
 *      account nonce sequences the batch.
 *
 *      Signature validation accepts exactly two shapes, tried in order:
 *      1. ERC-7739 defensive nested EIP-712 (Solady's `ERC1271`): TypedDataSign
 *         or PersonalSign rehashing, recovered to the EOA itself. A miss
 *         returns `0xffffffff` without reverting, so dispatch falls through.
 *         This is a direct owner signature: it never touches `ComposableCow`,
 *         so registry authorization, any swap guard installed via
 *         `ComposableCow.setSwapGuard`, and handler `verify` are all bypassed.
 *         Only shape 2 is guard-mediated. The nested-EIP712 shortcut for
 *         "safe" callers (Solady's `MulticallerWithSigner` carve-out) is
 *         disabled, so no caller can present a raw, un-nested ECDSA signature.
 *      2. The `ComposableCow` order payload, `abi.encode(GPv2Order.Data,
 *         PayloadStruct)`, exactly as `ERC1271Forwarder` has always decoded it.
 *         On a miss this branch REVERTS (malformed payload, `InvalidHash`, or
 *         unauthorized order) instead of returning `0xffffffff`, as the
 *         forwarder always has. Integrators probing this account with
 *         arbitrary ERC-1271 queries must treat a revert as a rejection.
 */
contract ComposableCow7702 is ERC1271Forwarder, SoladyERC1271, ERC7821 {
    constructor(ComposableCow _composableCow) ERC1271Forwarder(_composableCow) {}

    /// @dev ERC-7739 account domain. `verifyingContract` binds to the EOA at
    ///      runtime: Solady's `EIP712` rebuilds the separator whenever
    ///      `address(this)` differs from the cached deploy address.
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("ComposableCow7702", "1");
    }

    /// @dev The EOA itself is the signer under EIP-7702.
    function _erc1271Signer() internal view override returns (address) {
        return address(this);
    }

    /// @dev No safe-caller carve-out: Solady's default skips the ERC-7739
    ///      nesting entirely for `MulticallerWithSigner`, which would make any
    ///      raw ECDSA signature the EOA ever produced over any 32-byte value a
    ///      valid ERC-1271 signature for that caller. This account has no
    ///      multicaller integration, so the branch is pure attack surface.
    function _erc1271CallerIsSafe() internal pure override returns (bool) {
        return false;
    }

    /// @dev Plain ecrecover to self, restricted to the canonical encoding:
    ///      exactly 65 bytes with low `s`. Rejecting the EIP-2098 compact form
    ///      and the high-`s` twin gives each accepted digest a unique signature
    ///      byte string, so consumers keying replay guards on signature bytes
    ///      are not bypassable. The `SignatureCheckerLib` default would
    ///      staticcall `isValidSignature` on this account (the 7702 delegation
    ///      designator gives `address(this)` nonzero code) and re-enter instead
    ///      of recovering. `tryRecoverCalldata` returns `address(0)` on any
    ///      malformed signature, and `address(this)` is never zero.
    function _erc1271IsValidSignatureNowCalldata(bytes32 _hash, bytes calldata signature)
        internal
        view
        override
        returns (bool)
    {
        if (signature.length != 65) return false;
        // secp256k1 half-order: reject the malleable high-s counterpart
        if (uint256(bytes32(signature[32:64])) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return false;
        }
        return ECDSA.tryRecoverCalldata(_hash, signature) == address(this);
    }

    /// @dev Disabled: the default burns the entire gas budget on a failed
    ///      validation whenever `tx.gasprice == 0` (foundry tests and typical
    ///      `eth_call` simulations). It must always return false on-chain
    ///      anyway, so returning false is behavior-preserving in production.
    function _erc1271IsValidSignatureViaRPC(bytes32, bytes calldata) internal pure override returns (bool) {
        return false;
    }

    /// @dev ERC-7739 first (returns `0xffffffff` on a miss, never reverts with
    ///      the RPC path disabled), then the ComposableCow forwarder (reverts
    ///      on anything that is not a well-formed authorized order payload).
    ///      Misrouting can only reject, never accept: the order branch requires
    ///      registry authorization by the EOA plus the `GPv2Order.hash` check,
    ///      and the ECDSA branch requires recovery of the nested digest to
    ///      `address(this)` (nesting is unconditional: the safe-caller shortcut
    ///      is disabled above). The `0x77390001` detection sentinel
    ///      short-circuits because it differs from `0xffffffff`.
    function isValidSignature(bytes32 _hash, bytes calldata signature)
        public
        view
        override(ERC1271Forwarder, SoladyERC1271)
        returns (bytes4 result)
    {
        result = SoladyERC1271.isValidSignature(_hash, signature);
        if (result != bytes4(0xffffffff)) return result;
        return ERC1271Forwarder.isValidSignature(_hash, signature);
    }
}
