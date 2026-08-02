// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {PackageKind} from "../interfaces/PackageKind.sol";

/**
 * @title A content commitment and where to fetch it from
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Shared by the descriptor and module surfaces, which differ in what they
 *      commit to and in nothing else. Each holds its own `Data`, so the two
 *      occupy distinct slots and are set independently.
 */
library Commitment {
    /**
     * @dev URIs cannot be published without a commitment to verify them against
     */
    error UncommittedURI();

    /**
     * @dev `SHA256` does not locate the content, so it requires a URI
     */
    error URIRequired();

    /**
     * @dev A `BZZ_MANIFEST` commitment locates its own content; a URI could not
     *      be verified against a structure root anyway
     */
    error URINotUsed();

    struct Data {
        string[] uris;
        bytes32 digest;
        PackageKind kind;
    }

    /**
     * @dev An uncommitted surface. The kind is immaterial while the digest is
     *      zero, so this spells that out rather than leaving an arbitrary
     *      `PackageKind` at each construction site.
     */
    function none() internal pure returns (Data memory) {
        return Data({uris: new string[](0), digest: bytes32(0), kind: PackageKind.BZZ_MANIFEST});
    }

    /// @dev `bytes32(0)` means uncommitted; such a surface is not advertised.
    function advertised(Data storage self) internal view returns (bool) {
        return self.digest != bytes32(0);
    }

    function set(Data storage self, Data memory value) internal {
        validate(value.uris.length, value.digest, value.kind);
        self.uris = value.uris;
        self.digest = value.digest;
        self.kind = value.kind;
    }

    function validate(uint256 uriCount, bytes32 digest, PackageKind kind) internal pure {
        if (digest == bytes32(0)) {
            require(uriCount == 0, UncommittedURI());
        } else if (kind == PackageKind.SHA256) {
            require(uriCount > 0, URIRequired());
        } else {
            require(uriCount == 0, URINotUsed());
        }
    }
}
