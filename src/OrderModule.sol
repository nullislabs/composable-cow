// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IOrderModule} from "./interfaces/IOrderModule.sol";
import {PackageKind} from "./interfaces/PackageKind.sol";
import {BaseConditionalOrder} from "./BaseConditionalOrder.sol";

/**
 * @title Order Module mixin - opt-in module commitment for handlers
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Immutable by omission, as for `OrderDescriptor`. The commitment is what
 *      advertises `IOrderModule`, not the URI list: a `BZZ_MANIFEST`
 *      commitment locates its own package and so publishes no URI. Constructed
 *      with a zero digest, the handler does not advertise the interface.
 */
abstract contract OrderModule is IOrderModule, BaseConditionalOrder {
    /**
     * @dev URIs cannot be published without a commitment to verify them against
     */
    error UncommittedModuleURI();

    /**
     * @dev `TAR_ZST` does not locate the package, so it requires a URI
     */
    error ModuleURIRequired();

    string[] private _moduleUris;
    bytes32 private immutable _MODULE_DIGEST;
    PackageKind private immutable _MODULE_KIND;

    constructor(string[] memory uris, bytes32 digest, PackageKind kind) {
        if (digest != bytes32(0)) {
            require(kind != PackageKind.TAR_ZST || uris.length > 0, ModuleURIRequired());
            emit ModuleUpdate(uris, digest, kind);
        } else {
            require(uris.length == 0, UncommittedModuleURI());
        }
        _moduleUris = uris;
        _MODULE_DIGEST = digest;
        _MODULE_KIND = kind;
    }

    /**
     * @inheritdoc IOrderModule
     */
    function moduleURI() external view returns (string[] memory uris) {
        return _moduleUris;
    }

    /**
     * @inheritdoc IOrderModule
     */
    function moduleCommitment() external view returns (bytes32 digest, PackageKind kind) {
        return (_MODULE_DIGEST, _MODULE_KIND);
    }

    /**
     * @dev Advertise `IOrderModule` only when a module is committed
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        if (interfaceId == type(IOrderModule).interfaceId) {
            return _MODULE_DIGEST != bytes32(0);
        }
        return super.supportsInterface(interfaceId);
    }
}
