// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @dev How a committed package is put together, and therefore how its digest
 *      is computed and verified (see `docs/discovery.md` §0).
 *
 *      `BZZ_MANIFEST` hashes a structure, so only Swarm can recompute it: it
 *      locates itself and verifies per entry, but cannot be mirrored on
 *      another scheme. `TAR_ZST` hashes bytes, so any transport can be checked
 *      by hashing what it delivered, at the cost of a URI and whole-archive
 *      verification.
 */
enum PackageKind {
    BZZ_MANIFEST, // mantaray manifest root
    TAR_ZST // sha256 of a .tar.zst archive
}
