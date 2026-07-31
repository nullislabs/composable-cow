// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @dev The addressing scheme an on-chain commitment digest is expressed in.
 *      Verification uses that scheme's own primitives, so no canonical byte
 *      serialisation is defined (see `docs/discovery.md` §0).
 *
 *      `BZZ` and `IPFS` are content-addressed: the digest locates the bytes as
 *      well as verifying them, so no URI is required. `SHA256` locates
 *      nothing and requires at least one URI.
 */
enum DigestKind {
    BZZ, // Swarm BMT root
    IPFS, // sha2-256 multihash digest of the root CID
    SHA256 // sha256 over the published bytes
}
