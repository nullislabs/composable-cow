// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCow} from "../ComposableCow.sol";
import {OwnedOrderDescriptor} from "../OrderDescriptor.sol";
import {OrderModule, OwnedOrderModule} from "../OrderModule.sol";
import {IOrderDescriptor} from "../interfaces/IOrderDescriptor.sol";
import {IOrderModule} from "../interfaces/IOrderModule.sol";
import {Commitment} from "../libraries/Commitment.sol";
import {GoodAfterTime} from "./GoodAfterTime.sol";
import {StopLoss} from "./StopLoss.sol";
import {TWAP} from "./twap/TWAP.sol";

/**
 * @dev The handlers with rotatable commitments. Each extends the handler it is
 *      named for, so order generation is the same code and only the discovery
 *      surface differs. One owner governs both commitments.
 *
 *      Constructed uncommitted, then committed by the owner. That ordering is
 *      forced rather than convenient: on the immutable handlers the digest is a
 *      constructor argument, so under CREATE2 the address would depend on a
 *      descriptor that cannot be built until the address is known.
 */
contract OwnedTWAP is TWAP, OwnedOrderDescriptor, OwnedOrderModule {
    constructor(ComposableCow composableCow_, address owner_)
        TWAP(composableCow_, Commitment.none())
        OrderModule(Commitment.none())
    {
        _initializeOwner(owner_);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        if (interfaceId == type(IOrderModule).interfaceId) return _moduleAdvertised();
        return super.supportsInterface(interfaceId);
    }
}

/// @dev See {OwnedTWAP}.
contract OwnedStopLoss is StopLoss, OwnedOrderDescriptor, OwnedOrderModule {
    constructor(address owner_) StopLoss(Commitment.none()) OrderModule(Commitment.none()) {
        _initializeOwner(owner_);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        if (interfaceId == type(IOrderModule).interfaceId) return _moduleAdvertised();
        return super.supportsInterface(interfaceId);
    }
}

/// @dev See {OwnedTWAP}.
contract OwnedGoodAfterTime is GoodAfterTime, OwnedOrderDescriptor, OwnedOrderModule {
    constructor(address owner_) GoodAfterTime(Commitment.none()) OrderModule(Commitment.none()) {
        _initializeOwner(owner_);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        if (interfaceId == type(IOrderModule).interfaceId) return _moduleAdvertised();
        return super.supportsInterface(interfaceId);
    }
}
