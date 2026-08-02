// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271} from "solady/accounts/ERC1271.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

/**
 * @title Minimal EIP-7702 account
 * @author mfw78 <mfw78@nxm.rs>
 * @dev A delegation target for an EOA: batched execution and ERC-1271, and
 *      nothing else. Carries no protocol integration, so it is usable as the
 *      implementation behind an `EIP7702Proxy` for any purpose.
 *
 *      Stateless. There is no owner and no initializer: under EIP-7702 the
 *      EOA's key is the authority, so introducing either would add a second one.
 *
 *      Batching is `ERC7821` at its defaults. An empty `opData` requires
 *      `msg.sender == address(this)`, which only a transaction the EOA sends to
 *      itself satisfies, and a non-empty `opData` reverts. There is no relayed
 *      path and so no nonce to maintain; the EOA's account nonce sequences the
 *      batch.
 *
 *      Signatures are ERC-7739 nested EIP-712, recovered to the EOA itself. The
 *      nesting is what makes an owner signature replay-safe across accounts and
 *      chains, and is why a raw digest does not validate here.
 */
contract Account7702 is ERC1271, ERC7821 {
    /// @dev `verifyingContract` binds to the EOA at runtime: Solady's `EIP712`
    ///      rebuilds the separator whenever `address(this)` differs from the
    ///      address cached at deployment.
    function _domainNameAndVersion() internal pure virtual override returns (string memory, string memory) {
        return ("Account7702", "1");
    }

    /// @dev The EOA itself is the signer under EIP-7702.
    function _erc1271Signer() internal view virtual override returns (address) {
        return address(this);
    }

    /**
     * @dev No safe-caller carve-out. Solady's default skips the ERC-7739
     *      nesting entirely for `MulticallerWithSigner`, which would make any
     *      raw signature the EOA ever produced over any 32-byte value a valid
     *      ERC-1271 signature for that caller. This account has no multicaller
     *      integration, so the branch is pure attack surface.
     */
    function _erc1271CallerIsSafe() internal pure virtual override returns (bool) {
        return false;
    }

    /**
     * @dev Plain ecrecover to self, restricted to the canonical encoding:
     *      exactly 65 bytes with low `s`. Rejecting the EIP-2098 compact form
     *      and the high-`s` twin gives each accepted digest a unique signature
     *      byte string, so a consumer keying a replay guard on signature bytes
     *      is not bypassable.
     *
     *      The `SignatureCheckerLib` default would staticcall `isValidSignature`
     *      on this account, since the delegation designator gives
     *      `address(this)` nonzero code, and re-enter instead of recovering.
     *      `tryRecoverCalldata` returns `address(0)` on a malformed signature,
     *      and `address(this)` is never zero.
     */
    function _erc1271IsValidSignatureNowCalldata(bytes32 _hash, bytes calldata signature)
        internal
        view
        virtual
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

    /**
     * @dev Disabled: the default burns the entire gas budget on a failed
     *      validation whenever `tx.gasprice == 0`, which is every foundry test
     *      and most `eth_call` simulation. It must always return false on-chain
     *      anyway, so returning false is behaviour-preserving in production.
     */
    function _erc1271IsValidSignatureViaRPC(bytes32, bytes calldata) internal pure virtual override returns (bool) {
        return false;
    }
}
