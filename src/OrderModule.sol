// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {TwoStepOwnable} from "./TwoStepOwnable.sol";

import {IOrderModule} from "./interfaces/IOrderModule.sol";
import {PackageKind} from "./interfaces/PackageKind.sol";
import {Commitment} from "./libraries/Commitment.sol";

/**
 * @title Order Module mixin - opt-in module commitment for handlers
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Inherits nothing beyond its own interface, so a handler may compose it
 *      with `BaseConditionalOrder` and `OrderModule` without the three meeting
 *      at a common base.
 *
 *      Immutable by omission: no setter, and `ModuleUpdate` is emitted
 *      exactly once, from the constructor. The commitment is what advertises
 *      `IOrderModule`, not the URI list, since a `BZZ_MANIFEST` commitment
 *      locates its own package and publishes no URI. Handlers consult
 *      `_moduleAdvertised` from `supportsInterface`.
 */
abstract contract OrderModule is IOrderModule {
    using Commitment for Commitment.Data;

    /// @dev `internal` so `OwnedOrderModule` writes what these accessors read.
    Commitment.Data internal _module;

    constructor(Commitment.Data memory module) {
        _module.set(module);
        if (module.digest != bytes32(0)) emit ModuleUpdate(module.uris, module.digest, module.kind);
    }

    /**
     * @inheritdoc IOrderModule
     */
    function moduleURI() external view returns (string[] memory uris) {
        return _module.uris;
    }

    /**
     * @inheritdoc IOrderModule
     */
    function moduleCommitment() external view returns (bytes32 digest, PackageKind kind) {
        return (_module.digest, _module.kind);
    }

    function _moduleAdvertised() internal view returns (bool) {
        return _module.advertised();
    }
}

/**
 * @dev Adds rotation. The setter writes the storage the read-only accessors
 *      already read, so nothing has to be overridden, and `ModuleUpdate` is
 *      re-emitted so indexers observe the change without polling.
 *
 *      Ownership is two-step only ({TwoStepOwnable}): the commitment is the
 *      only mutable state here, so a mistyped single-step transfer would
 *      strand it. The recipient must accept; `renounceOwnership` is the
 *      deliberate freeze.
 */
abstract contract OwnedOrderModule is OrderModule, TwoStepOwnable {
    using Commitment for Commitment.Data;

    function setModule(Commitment.Data memory module) external onlyOwner {
        _module.set(module);
        emit ModuleUpdate(module.uris, module.digest, module.kind);
    }
}
