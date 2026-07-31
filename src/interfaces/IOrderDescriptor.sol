// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {PackageKind} from "./PackageKind.sol";

/**
 * @title Order Descriptor - declarative handler metadata for discovery
 * @author mfw78 <mfw78@nxm.rs>
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
    event DescriptorUpdate(string[] uris, bytes32 digest, PackageKind kind);

    /**
     * @notice Locations of the handler descriptor document.
     * @dev Empty for `BZZ_MANIFEST`, which the commitment locates. Non-empty
     *      for `SHA256`. Any URI listed is a retrieval hint and MUST resolve
     *      to the same document bytes, never alternative content.
     */
    function descriptorURI() external view returns (string[] memory uris);

    /**
     * @notice Commitment to the descriptor document.
     * @dev `digest` is the document root in `kind`'s addressing. Consumers
     *      MUST verify fetched bytes against it before parsing. `bytes32(0)`
     *      means uncommitted; treat such descriptors as absent.
     */
    function descriptorCommitment() external view returns (bytes32 digest, PackageKind kind);
}
