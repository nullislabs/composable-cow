// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title Two-step-only ownership
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Disables Solady's single-step `transferOwnership`: the owned commitment
 *      is the only mutable state on the handlers that use this, and a mistyped
 *      direct transfer would strand it. The two-step handover
 *      (`requestOwnershipHandover`/`completeOwnershipHandover`) is the only
 *      transfer path. `renounceOwnership` stays live as the deliberate freeze:
 *      a renounced handler is permanently as-committed.
 */
abstract contract TwoStepOwnable is Ownable {
    /// @dev Single-step ownership transfer is disabled; use the handover
    error TransferDisabled();

    function transferOwnership(address) public payable virtual override onlyOwner {
        revert TransferDisabled();
    }
}
