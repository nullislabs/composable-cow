// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @title Order Descriptor - declarative handler metadata for discovery
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Sidecar interface with its own ERC-165 id, feature-detected
 *      independently and never on the settlement path. The descriptor
 *      document is presentation metadata - hints, never authority: every
 *      economically material fact is derived from the chain
 *      (see `docs/discovery.md` §1).
 */
interface IOrderDescriptor {
    /**
     * @notice Emitted when the descriptor location or commitment changes.
     * @dev MUST be emitted from the constructor of implementing contracts so
     *      indexers discover the descriptor without polling.
     */
    event DescriptorUpdate(string[] uris, bytes32 digest);

    /**
     * @notice Locations of the handler descriptor document.
     * @dev All URIs MUST reference the same document bytes (redundant
     *      mirrors), never alternative content.
     */
    function descriptorURI() external view returns (string[] memory uris);

    /**
     * @notice keccak256 of the exact descriptor document bytes as published.
     * @dev Consumers MUST verify fetched bytes against this digest before
     *      parsing when the URI is not content-addressed. bytes32(0) means
     *      uncommitted; consumers MUST treat such descriptors as untrusted.
     */
    function descriptorDigest() external view returns (bytes32);
}
