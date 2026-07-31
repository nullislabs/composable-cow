// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DigestKind} from "./DigestKind.sol";

/**
 * @title Order Module - executable client module for custom handlers
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Sidecar interface with its own ERC-165 id. An order module constructs
 *      `offchainInput` for handlers that signal `NEEDS_INPUT` - the one
 *      aspect of servicing an order that cannot be derived on-chain. Module
 *      output is untrusted input to on-chain verification. The module is a
 *      WebAssembly component; its export contract is `ccow:module` and the
 *      host surface is `videre:ccow` (see `docs/discovery.md` §2).
 */
interface IOrderModule {
    /**
     * @notice Emitted when the module location or commitment changes.
     * @dev MUST be emitted from the constructor of implementing contracts.
     */
    event ModuleUpdate(string[] uris, bytes32 digest, DigestKind kind);

    /**
     * @notice Locations of the module package.
     * @dev Empty for content-addressed kinds, which the commitment locates.
     *      Non-empty for `SHA256`. Any URI listed is a retrieval hint and MUST
     *      resolve to the same package.
     */
    function moduleURI() external view returns (string[] memory uris);

    /**
     * @notice Commitment to the module package. `digest` MUST be non-zero.
     * @dev The package root in `kind`'s addressing, and the module's canonical
     *      identity: consent lists, caches, and budgets key by it, so changing
     *      where a package is mirrored never invalidates operator trust in the
     *      same code. Consumers MUST verify the package against it before
     *      execution and MUST NOT serve cached bytes against any other key.
     */
    function moduleCommitment() external view returns (bytes32 digest, DigestKind kind);
}
