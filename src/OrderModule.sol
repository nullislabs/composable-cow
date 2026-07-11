// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IOrderModule} from "./interfaces/IOrderModule.sol";
import {BaseConditionalOrder} from "./BaseConditionalOrder.sol";

/**
 * @title Order Module mixin - opt-in module commitment for handlers
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Immutable by omission, as for `OrderDescriptor`. A zero digest is
 *      non-conformant (the digest is the module's canonical identity), so
 *      construction with any URIs requires a non-zero digest; constructed
 *      with no URIs the handler does not advertise `IOrderModule`.
 */
abstract contract OrderModule is IOrderModule, BaseConditionalOrder {
    /// @dev A module commitment requires a non-zero digest
    error InvalidModuleDigest();

    string[] private _moduleUris;
    bytes32 private immutable _MODULE_DIGEST;

    constructor(string[] memory uris, bytes32 digest) {
        if (uris.length > 0) {
            require(digest != bytes32(0), InvalidModuleDigest());
            emit ModuleUpdate(uris, digest);
        }
        _moduleUris = uris;
        _MODULE_DIGEST = digest;
    }

    /// @inheritdoc IOrderModule
    function moduleURI() external view returns (string[] memory uris) {
        return _moduleUris;
    }

    /// @inheritdoc IOrderModule
    function moduleDigest() external view returns (bytes32) {
        return _MODULE_DIGEST;
    }

    /// @dev Advertise `IOrderModule` only when a module is committed
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        if (interfaceId == type(IOrderModule).interfaceId) {
            return _moduleUris.length > 0;
        }
        return super.supportsInterface(interfaceId);
    }
}
