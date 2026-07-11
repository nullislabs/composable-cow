// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @title Order Module - executable client module for custom handlers
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Sidecar interface with its own ERC-165 id. An order module constructs
 *      `offchainInput` for handlers that signal `NEEDS_INPUT` - the one
 *      aspect of servicing an order that cannot be derived on-chain. Module
 *      output is untrusted input to on-chain verification; the runtime
 *      contract is defined by the reference monitoring service
 *      (see `docs/discovery.md` §2).
 */
interface IOrderModule {
    /**
     * @notice Emitted when the module location or commitment changes.
     * @dev MUST be emitted from the constructor of implementing contracts.
     */
    event ModuleUpdate(string[] uris, bytes32 digest);

    /**
     * @notice Locations of the module. All URIs MUST reference the same bytes.
     */
    function moduleURI() external view returns (string[] memory uris);

    /**
     * @notice keccak256 of the exact module bytes. MUST be non-zero.
     * @dev The module's canonical identity and the final pre-execution gate.
     *      Fetch integrity is per-transport (a Swarm reference, CID, or
     *      RFC 6920 hash verifies the fetch); the digest is what consent
     *      lists, caches, and budgets key by. Consumers MUST verify
     *      keccak256(bytes) == moduleDigest() before execution.
     */
    function moduleDigest() external view returns (bytes32);
}
