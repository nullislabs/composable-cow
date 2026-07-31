// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IOrderDescriptor} from "./interfaces/IOrderDescriptor.sol";
import {PackageKind} from "./interfaces/PackageKind.sol";
import {BaseConditionalOrder} from "./BaseConditionalOrder.sol";

/**
 * @title Order Descriptor mixin - opt-in descriptor commitment for handlers
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Immutable by omission: there is no setter, and `DescriptorUpdate` is
 *      emitted exactly once, from the constructor. Deployments that support
 *      rotation add their own access-controlled setter and re-emit.
 *
 *      A handler constructed with no URIs does NOT advertise
 *      `IOrderDescriptor` - feature detection stays honest for deployments
 *      that predate their descriptor document; committing requires a
 *      redeployment (the descriptor digest is per-deployment anyway).
 */
abstract contract OrderDescriptor is IOrderDescriptor, BaseConditionalOrder {
    /**
     * @dev URIs cannot be published without a commitment to verify them against
     */
    error UncommittedDescriptorURI();

    /**
     * @dev `TAR_ZST` does not locate the document, so it requires a URI
     */
    error DescriptorURIRequired();

    string[] private _descriptorUris;
    bytes32 private immutable _DESCRIPTOR_DIGEST;
    PackageKind private immutable _DESCRIPTOR_KIND;

    constructor(string[] memory uris, bytes32 digest, PackageKind kind) {
        if (digest != bytes32(0)) {
            require(kind != PackageKind.TAR_ZST || uris.length > 0, DescriptorURIRequired());
            emit DescriptorUpdate(uris, digest, kind);
        } else {
            require(uris.length == 0, UncommittedDescriptorURI());
        }
        _descriptorUris = uris;
        _DESCRIPTOR_DIGEST = digest;
        _DESCRIPTOR_KIND = kind;
    }

    /**
     * @inheritdoc IOrderDescriptor
     */
    function descriptorURI() external view returns (string[] memory uris) {
        return _descriptorUris;
    }

    /**
     * @inheritdoc IOrderDescriptor
     */
    function descriptorCommitment() external view returns (bytes32 digest, PackageKind kind) {
        return (_DESCRIPTOR_DIGEST, _DESCRIPTOR_KIND);
    }

    /**
     * @dev Advertise `IOrderDescriptor` only when a descriptor is committed:
     *      claiming the interface while returning empty values is
     *      non-conformant per the discovery specification. The commitment is
     *      the gate, not the URI list, since a `BZZ_MANIFEST` commitment
     *      locates its own document and publishes no URI.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        if (interfaceId == type(IOrderDescriptor).interfaceId) {
            return _DESCRIPTOR_DIGEST != bytes32(0);
        }
        return super.supportsInterface(interfaceId);
    }
}
