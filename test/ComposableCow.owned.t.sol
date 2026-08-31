// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Ownable} from "solady/auth/Ownable.sol";

import {Commitment} from "../src/libraries/Commitment.sol";
import "./ComposableCow.base.t.sol";

import {OrderDescriptor} from "../src/OrderDescriptor.sol";
import {IOrderDescriptor} from "../src/interfaces/IOrderDescriptor.sol";
import {IOrderModule} from "../src/interfaces/IOrderModule.sol";
import {PackageKind} from "../src/interfaces/PackageKind.sol";
import {OwnedGoodAfterTime, OwnedStopLoss, OwnedTWAP} from "../src/types/Owned.sol";
import {StopLoss} from "../src/types/StopLoss.sol";
import {TwoStepOwnable} from "../src/TwoStepOwnable.sol";

contract ComposableCowOwnedTest is BaseComposableCowTest {
    OwnedTWAP private ownedTwap;
    OwnedStopLoss private ownedStopLoss;
    OwnedGoodAfterTime private ownedGat;

    address private constant OWNER = address(0xA11CE);
    address private constant STRANGER = address(0xBAD);

    bytes32 private constant DIGEST = keccak256("descriptor");

    function setUp() public virtual override(BaseComposableCowTest) {
        super.setUp();
        ownedTwap = new OwnedTWAP(composableCow, OWNER);
        ownedStopLoss = new OwnedStopLoss(OWNER);
        ownedGat = new OwnedGoodAfterTime(OWNER);
    }

    function _uris(string memory u) private pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = u;
    }

    /// @dev Uncommitted at construction: nothing to advertise until the owner sets it.
    function test_owned_UncommittedOnDeploy() public {
        (bytes32 digest,) = ownedTwap.descriptorCommitment();
        assertEq(digest, bytes32(0));
        assertEq(ownedTwap.descriptorURI().length, 0);
        assertFalse(ownedTwap.supportsInterface(type(IOrderDescriptor).interfaceId));
        assertFalse(ownedTwap.supportsInterface(type(IOrderModule).interfaceId));
        assertEq(ownedTwap.owner(), OWNER, "deployer must not retain ownership");
    }

    function test_owned_SetDescriptorAdvertisesAndRoundTrips() public {
        vm.expectEmit(true, true, true, true);
        emit IOrderDescriptor.DescriptorUpdate(new string[](0), DIGEST, PackageKind.BZZ_MANIFEST);

        vm.prank(OWNER);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST})
        );

        (bytes32 digest, PackageKind kind) = ownedTwap.descriptorCommitment();
        assertEq(digest, DIGEST);
        assertEq(uint256(kind), uint256(PackageKind.BZZ_MANIFEST));
        assertTrue(ownedTwap.supportsInterface(type(IOrderDescriptor).interfaceId));
        assertFalse(ownedTwap.supportsInterface(type(IOrderModule).interfaceId));
    }

    /// @dev The two commitments are independent surfaces under one owner.
    function test_owned_SetModuleIsIndependentOfDescriptor() public {
        vm.prank(OWNER);
        ownedStopLoss.setModule(
            Commitment.Data({
                uris: _uris("https://example.invalid/module.tar.zst"), digest: DIGEST, kind: PackageKind.SHA256
            })
        );

        (bytes32 digest, PackageKind kind) = ownedStopLoss.moduleCommitment();
        assertEq(digest, DIGEST);
        assertEq(uint256(kind), uint256(PackageKind.SHA256));
        assertTrue(ownedStopLoss.supportsInterface(type(IOrderModule).interfaceId));
        assertFalse(ownedStopLoss.supportsInterface(type(IOrderDescriptor).interfaceId));
    }

    /// @dev Rotation is the whole point: a second set must replace the first.
    function test_owned_RotationReplacesCommitment() public {
        vm.startPrank(OWNER);
        ownedGat.setDescriptor(Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST}));
        bytes32 next = keccak256("rotated");
        ownedGat.setDescriptor(
            Commitment.Data({uris: _uris("https://example.invalid/d.json"), digest: next, kind: PackageKind.SHA256})
        );
        vm.stopPrank();

        (bytes32 digest, PackageKind kind) = ownedGat.descriptorCommitment();
        assertEq(digest, next);
        assertEq(uint256(kind), uint256(PackageKind.SHA256));
        assertEq(ownedGat.descriptorURI().length, 1);
    }

    function test_owned_RevertsForStranger() public {
        vm.startPrank(STRANGER);

        vm.expectRevert(Ownable.Unauthorized.selector);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST})
        );

        vm.expectRevert(Ownable.Unauthorized.selector);
        ownedTwap.setModule(Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST}));

        vm.stopPrank();
    }

    /// @dev The constructor invariants of the immutable mixin, enforced on write.
    function test_owned_EnforcesURIInvariants() public {
        vm.startPrank(OWNER);

        vm.expectRevert(Commitment.URIRequired.selector);
        ownedTwap.setDescriptor(Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.SHA256}));

        vm.expectRevert(Commitment.URINotUsed.selector);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: _uris("bzz://x"), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST})
        );

        vm.expectRevert(Commitment.UncommittedURI.selector);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: _uris("bzz://x"), digest: bytes32(0), kind: PackageKind.BZZ_MANIFEST})
        );

        vm.stopPrank();
    }

    /**
     * @dev Two-step handover, in the stronger direction. Solady moves control
     *      only to a recipient that has itself asked for it, so a mistyped
     *      address cannot strand the commitments: it will never have asked.
     */
    function test_owned_TransferIsTwoStep() public {
        // the single-step path is disabled outright: a mistyped direct
        // transfer cannot strand the commitment
        vm.prank(OWNER);
        vm.expectRevert(TwoStepOwnable.TransferDisabled.selector);
        ownedTwap.transferOwnership(STRANGER);
        assertEq(ownedTwap.owner(), OWNER, "ownership moved through the disabled path");

        // ownership cannot be pushed at an address that has not asked for it
        vm.prank(OWNER);
        vm.expectRevert(Ownable.NoHandoverRequest.selector);
        ownedTwap.completeOwnershipHandover(STRANGER);
        assertEq(ownedTwap.owner(), OWNER, "ownership moved without a request");

        vm.prank(STRANGER);
        ownedTwap.requestOwnershipHandover();
        assertEq(ownedTwap.owner(), OWNER, "ownership moved on the request alone");
        assertGt(ownedTwap.ownershipHandoverExpiresAt(STRANGER), block.timestamp);

        vm.prank(OWNER);
        ownedTwap.completeOwnershipHandover(STRANGER);
        assertEq(ownedTwap.owner(), STRANGER);

        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST})
        );
    }

    /// @dev `renounceOwnership` is the deliberate freeze: after it, the
    ///      handler is permanently as-committed - nobody can rotate
    function test_owned_RenounceFreezesCommitment() public {
        vm.prank(OWNER);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: new string[](0), digest: DIGEST, kind: PackageKind.BZZ_MANIFEST})
        );

        vm.prank(OWNER);
        ownedTwap.renounceOwnership();
        assertEq(ownedTwap.owner(), address(0));

        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ownedTwap.setDescriptor(
            Commitment.Data({uris: new string[](0), digest: bytes32(uint256(1)), kind: PackageKind.BZZ_MANIFEST})
        );

        // the frozen commitment still reads back
        (bytes32 digest,) = ownedTwap.descriptorCommitment();
        assertEq(digest, DIGEST);
    }

    /**
     * @dev The variants exist to change the discovery surface and nothing else.
     *      One owner governs both commitments.
     */
    function test_owned_OrderGenerationIsUnchanged() public {
        StopLoss.Data memory o; // zero amounts, rejected before any oracle is consulted

        StopLoss immutableHandler = new StopLoss(Commitment.none());

        bytes memory expected =
            abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, bytes4(keccak256("ZeroAmount()")));

        vm.expectRevert(expected);
        immutableHandler.generateOrder(address(safe1), bytes32(0), abi.encode(o), bytes(""));

        vm.expectRevert(expected);
        ownedStopLoss.generateOrder(address(safe1), bytes32(0), abi.encode(o), bytes(""));
    }
}
