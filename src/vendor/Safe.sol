// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.0 <0.9.0;

/**
 * @dev The Safe surface this registry actually uses, vendored from
 *      `safe-contracts` rather than depended upon.
 *
 *      The dependency was a compilation liability: `Safe.sol` uses inline
 *      assembly that is not annotated memory-safe, so the IR pipeline cannot
 *      allocate its stack and `via_ir` fails on the whole project. Nothing here
 *      needs the implementation. `Safe` is only ever a typed address, and the
 *      handler is only ever asked whether it supports an interface.
 *
 *      Declarations match `safe-contracts` exactly, so a contract written
 *      against either compiles against this.
 */

/// @dev Standard ERC-165.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @dev ERC-1271, as `safe-contracts` declares it.
interface ERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/**
 * @dev A Safe, as far as this registry is concerned. Only its address is used:
 *      `isValidSafeSignature` takes one as a typed address and `_auth` reads
 *      the registry's own storage, so no Safe behaviour is invoked.
 */
interface Safe {}

/**
 * @title Safe Signature Verifier Interface
 * @notice Standard for external contracts verifying signatures for a Safe.
 */
interface ISafeSignatureVerifier {
    function isValidSafeSignature(
        Safe safe,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 typeHash,
        bytes calldata encodeData,
        bytes calldata payload
    ) external view returns (bytes4 magic);
}

interface ISignatureVerifierMuxer {
    function domainVerifiers(Safe safe, bytes32 domainSeparator) external view returns (ISafeSignatureVerifier);

    function setDomainVerifier(bytes32 domainSeparator, ISafeSignatureVerifier verifier) external;
}
