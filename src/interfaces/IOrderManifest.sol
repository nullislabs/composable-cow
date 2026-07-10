// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

/**
 * @title IOrderManifest - Interface for order enumeration
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @notice Allows enumeration of the discrete orders a conditional order will produce.
 * @dev A sidecar interface with its own ERC-165 id, feature-detected by consumers;
 *      never consulted on the settlement path. Useful for analytics, UI preview,
 *      and order lifecycle tracking. The manifest mirrors the information `poll`
 *      already exposes - it is not a second source of truth.
 */
interface IOrderManifest {
    /**
     * @notice How `ManifestInfo.totalOrders` is to be read.
     */
    enum Cardinality {
        EXACT, // totalOrders is the exact count (e.g. TWAP with n parts)
        CAPPED, // totalOrders is an upper cap; the actual count is dynamic
        UNBOUNDED // no meaningful count (e.g. PerpetualStableSwap); totalOrders is 0
    }

    /**
     * @notice High-level information about the order manifest
     * @param cardinality How to read `totalOrders`
     * @param totalOrders Exact count for EXACT, cap for CAPPED, 0 for UNBOUNDED
     */
    struct ManifestInfo {
        Cardinality cardinality;
        uint256 totalOrders;
    }

    /**
     * @notice A single entry in the manifest representing one discrete order
     * @param index The index of this order (0-indexed)
     * @param order The GPv2Order data for this discrete order
     * @param validFrom When this order becomes valid (since GPv2Order only has validTo)
     * @param isActive Whether this order is currently active (within its validity window)
     */
    struct ManifestEntry {
        uint256 index;
        GPv2Order.Data order;
        uint256 validFrom;
        bool isActive;
    }

    /**
     * @notice Get high-level information about the order manifest
     * @param owner The owner of the conditional order
     * @param ctx Context key (bytes32(0) for merkle, hash(params) for single)
     * @param staticInput The static input parameters for the conditional order
     * @return info The manifest information
     */
    function getManifestInfo(address owner, bytes32 ctx, bytes calldata staticInput)
        external
        view
        returns (ManifestInfo memory info);

    /**
     * @notice Get a paginated list of manifest entries
     * @dev PAGINATION CONTRACT: a page with zero entries and `hasMore == true` MUST
     *      be unreachable, so a consumer advancing `offset += entries.length` and
     *      stopping at `hasMore == false` always terminates. UNBOUNDED handlers
     *      expose only index 0 (the current discrete order) and MUST return
     *      `hasMore == false` on every branch; `offset > 0` yields an empty final
     *      page.
     * @dev When the page is empty because order generation is not currently
     *      possible, `reasonCode` carries the decoded reason selector (mirroring
     *      `poll` semantics) so a not-yet-active order is distinguishable from a
     *      permanently invalid one. `reasonCode` is `bytes4(0)` on ordinary pages.
     * @param owner The owner of the conditional order
     * @param ctx Context key (bytes32(0) for merkle, hash(params) for single)
     * @param staticInput The static input parameters for the conditional order
     * @param offchainInput Dynamic parameters from watch-tower (may be empty)
     * @param offset Starting index for pagination
     * @param limit Maximum number of entries to return
     * @return entries Array of manifest entries
     * @return hasMore Whether more entries exist beyond this page
     * @return reasonCode `bytes4(0)` on ordinary pages; the decoded generation
     *         reason selector when an empty page is caused by the order not being
     *         generatable
     */
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        uint256 offset,
        uint256 limit
    ) external view returns (ManifestEntry[] memory entries, bool hasMore, bytes4 reasonCode);
}
