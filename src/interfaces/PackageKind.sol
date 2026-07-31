// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @dev How a commitment digest is computed, and therefore how it is verified
 *      (see `docs/discovery.md` §0). What the committed bytes are is fixed per
 *      surface: a module commits to a `.tar.zst` package, a descriptor to its
 *      JSON document.
 *
 *      `BZZ_MANIFEST` hashes a structure, so only Swarm can recompute it: it
 *      locates itself and verifies per entry, and publishes no URI. `SHA256`
 *      hashes bytes, so any transport can be checked by hashing what it
 *      delivered, at the cost of requiring a URI to locate them.
 */
enum PackageKind {
    BZZ_MANIFEST, // Swarm BMT root of a mantaray manifest, or of the document
    SHA256 // sha256 over the published bytes
}
