// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IOrderDescriptor} from "./interfaces/IOrderDescriptor.sol";
import {BaseConditionalOrder} from "./BaseConditionalOrder.sol";

/**
 * @title Order Descriptor mixin - opt-in descriptor commitment for handlers
 * @author mfw78 <mfw78@rndlabs.xyz>
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
    string[] private _descriptorUris;
    bytes32 private immutable _DESCRIPTOR_DIGEST;

    constructor(string[] memory uris, bytes32 digest) {
        _descriptorUris = uris;
        _DESCRIPTOR_DIGEST = digest;
        if (uris.length > 0) {
            emit DescriptorUpdate(uris, digest);
        }
    }

    /// @inheritdoc IOrderDescriptor
    function descriptorURI() external view returns (string[] memory uris) {
        return _descriptorUris;
    }

    /// @inheritdoc IOrderDescriptor
    function descriptorDigest() external view returns (bytes32) {
        return _DESCRIPTOR_DIGEST;
    }

    /**
     * @dev Advertise `IOrderDescriptor` only when a descriptor is committed:
     *      claiming the interface while returning empty values is
     *      non-conformant per the discovery specification.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        if (interfaceId == type(IOrderDescriptor).interfaceId) {
            return _descriptorUris.length > 0;
        }
        return super.supportsInterface(interfaceId);
    }
}
