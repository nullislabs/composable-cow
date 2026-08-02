// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IOrderDescriptor} from "./interfaces/IOrderDescriptor.sol";
import {PackageKind} from "./interfaces/PackageKind.sol";
import {Commitment} from "./libraries/Commitment.sol";

/**
 * @title Order Descriptor mixin - opt-in descriptor commitment for handlers
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Inherits nothing beyond its own interface, so a handler may compose it
 *      with `BaseConditionalOrder` and `OrderModule` without the three meeting
 *      at a common base.
 *
 *      Immutable by omission: no setter, and `DescriptorUpdate` is emitted
 *      exactly once, from the constructor. The commitment is what advertises
 *      `IOrderDescriptor`, not the URI list, since a `BZZ_MANIFEST` commitment
 *      locates its own document and publishes no URI. Handlers consult
 *      `_descriptorAdvertised` from `supportsInterface`.
 */
abstract contract OrderDescriptor is IOrderDescriptor {
    using Commitment for Commitment.Data;

    /// @dev `internal` so `OwnedOrderDescriptor` writes what these accessors read.
    Commitment.Data internal _descriptor;

    constructor(Commitment.Data memory descriptor) {
        _descriptor.set(descriptor);
        if (descriptor.digest != bytes32(0)) {
            emit DescriptorUpdate(descriptor.uris, descriptor.digest, descriptor.kind);
        }
    }

    /**
     * @inheritdoc IOrderDescriptor
     */
    function descriptorURI() external view returns (string[] memory uris) {
        return _descriptor.uris;
    }

    /**
     * @inheritdoc IOrderDescriptor
     */
    function descriptorCommitment() external view returns (bytes32 digest, PackageKind kind) {
        return (_descriptor.digest, _descriptor.kind);
    }

    function _descriptorAdvertised() internal view returns (bool) {
        return _descriptor.advertised();
    }
}

/**
 * @dev Adds rotation. The setter writes the storage the read-only accessors
 *      already read, so nothing has to be overridden, and `DescriptorUpdate` is
 *      re-emitted so indexers observe the change without polling.
 *
 *      Ownership is `Ownable2Step`: the commitment is the only mutable state
 *      here, so a mistyped transfer would strand it. The recipient must accept.
 */
abstract contract OwnedOrderDescriptor is OrderDescriptor, Ownable2Step {
    using Commitment for Commitment.Data;

    function setDescriptor(Commitment.Data memory descriptor) external onlyOwner {
        _descriptor.set(descriptor);
        emit DescriptorUpdate(descriptor.uris, descriptor.digest, descriptor.kind);
    }
}
