// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

import {IConditionalOrder, ComposableCow, BaseComposableCowTest} from "./ComposableCow.base.t.sol";
import {ComposableCowLib} from "./libraries/ComposableCowLib.t.sol";

/**
 * @title Tests for the URI-based Proof struct: blob publication verification,
 *        zero-root hygiene, and the normative payload tree construction
 */
contract ComposableCowProofTest is BaseComposableCowTest {
    using ComposableCowLib for IConditionalOrder.ConditionalOrderParams[];

    /**
     * @dev A plausible EIP-4844 versioned hash: 0x01 version byte prefix
     */
    function _versionedHash(bytes32 seed) internal pure returns (bytes32) {
        return bytes32((uint256(keccak256(abi.encode(seed))) >> 8) | (uint256(0x01) << 248));
    }

    /**
     * @dev Set the transaction's blob hashes via the cheatcode address
     *      directly - the pinned forge-std Vm interface predates it
     */
    function _setTxBlobs(bytes32[] memory hashes) internal {
        (bool ok,) = address(vm).call(abi.encodeWithSignature("blobhashes(bytes32[])", hashes));
        require(ok, "vm.blobhashes unavailable");
    }

    function _emptyProof() internal pure returns (ComposableCow.Proof memory) {
        return ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: new bytes32[](0)});
    }

    // --- URI mirrors ---

    /**
     * @dev URIs are opaque to the contract: any mirror set round-trips
     *      through the event unmodified
     */
    function test_setRoot_EmitsUriMirrors() public {
        string[] memory uris = new string[](2);
        uris[0] = "bzz://c0ffee";
        uris[1] = "ipfs://bafybeigdyrzt5example";
        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: uris, blobVersionedHashes: new bytes32[](0)});

        vm.expectEmit(true, true, true, true);
        emit ComposableCow.MerkleRootSet(address(safe1), keccak256("root"), proof, bytes(""));

        vm.prank(address(safe1));
        composableCow.setRoot(keccak256("root"), proof);
    }

    // --- blob publication verification ---

    /**
     * @dev Every listed blob hash attached to the transaction: accepted
     */
    function test_setRoot_BlobsAttached() public {
        bytes32[] memory txBlobs = new bytes32[](2);
        txBlobs[0] = _versionedHash("blob0");
        txBlobs[1] = _versionedHash("blob1");
        _setTxBlobs(txBlobs);

        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: txBlobs});

        vm.prank(address(safe1));
        composableCow.setRoot(keccak256("root"), proof);
        assertEq(composableCow.roots(address(safe1)), keccak256("root"));
    }

    /**
     * @dev A subset of the transaction's blobs is fine - the payload need
     *      not occupy every blob in the transaction
     */
    function test_setRoot_BlobSubsetAttached() public {
        bytes32[] memory txBlobs = new bytes32[](3);
        txBlobs[0] = _versionedHash("blob0");
        txBlobs[1] = _versionedHash("blob1");
        txBlobs[2] = _versionedHash("blob2");
        _setTxBlobs(txBlobs);

        bytes32[] memory listed = new bytes32[](1);
        listed[0] = txBlobs[1];
        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: listed});

        vm.prank(address(safe1));
        composableCow.setRoot(keccak256("root"), proof);
    }

    /**
     * @dev A listed hash missing from the transaction: publication is not
     *      atomic with authorization, so the root cannot be set
     */
    function test_setRoot_RevertsBlobNotAttached() public {
        bytes32[] memory txBlobs = new bytes32[](1);
        txBlobs[0] = _versionedHash("blob0");
        _setTxBlobs(txBlobs);

        bytes32[] memory listed = new bytes32[](2);
        listed[0] = txBlobs[0];
        listed[1] = _versionedHash("not attached");
        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: listed});

        vm.prank(address(safe1));
        vm.expectRevert(ComposableCow.BlobNotAttached.selector);
        composableCow.setRoot(keccak256("root"), proof);
    }

    /**
     * @dev No blobs on the transaction at all: any listed hash reverts
     */
    function test_setRoot_RevertsBlobNotAttachedNoBlobs() public {
        bytes32[] memory listed = new bytes32[](1);
        listed[0] = _versionedHash("blob0");
        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: listed});

        vm.prank(address(safe1));
        vm.expectRevert(ComposableCow.BlobNotAttached.selector);
        composableCow.setRoot(keccak256("root"), proof);
    }

    // --- zero-root clear hygiene ---

    /**
     * @dev Zero root with an empty proof is an explicit clear
     */
    function test_setRoot_ZeroRootClears() public {
        vm.startPrank(address(safe1));
        composableCow.setRoot(keccak256("root"), _emptyProof());
        composableCow.setRoot(bytes32(0), _emptyProof());
        vm.stopPrank();
        assertEq(composableCow.roots(address(safe1)), bytes32(0));
    }

    /**
     * @dev Publishing a payload for a root that authorizes nothing is
     *      malformed: clears must carry an empty proof
     */
    function test_setRoot_RevertsZeroRootWithUris() public {
        string[] memory uris = new string[](1);
        uris[0] = "bzz://c0ffee";
        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: uris, blobVersionedHashes: new bytes32[](0)});

        vm.prank(address(safe1));
        vm.expectRevert(ComposableCow.ProofDataMalformed.selector);
        composableCow.setRoot(bytes32(0), proof);
    }

    function test_setRoot_RevertsZeroRootWithBlobs() public {
        bytes32[] memory txBlobs = new bytes32[](1);
        txBlobs[0] = _versionedHash("blob0");
        _setTxBlobs(txBlobs);
        ComposableCow.Proof memory proof = ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: txBlobs});

        vm.prank(address(safe1));
        vm.expectRevert(ComposableCow.ProofDataMalformed.selector);
        composableCow.setRoot(bytes32(0), proof);
    }

    // --- normative tree construction (leafEncoding "v1" vectors) ---

    /**
     * @dev The payload standard's tree construction, implemented
     *      independently of solady's `MerkleTreeLib`: ascending-sorted leaf
     *      hashes, bottom-up sorted-pair keccak, odd trailing node promoted
     *      unchanged. Mutates `hashes` in place.
     */
    function _normativeRoot(bytes32[] memory hashes) internal pure returns (bytes32) {
        _sortAscending(hashes);
        uint256 n = hashes.length;
        while (n > 1) {
            uint256 half = n / 2;
            for (uint256 i = 0; i < half; i++) {
                hashes[i] = _hashSortedPair(hashes[2 * i], hashes[2 * i + 1]);
            }
            if (n % 2 == 1) {
                // odd trailing node promoted unchanged
                hashes[half] = hashes[n - 1];
                n = half + 1;
            } else {
                n = half;
            }
        }
        return hashes[0];
    }

    function _hashSortedPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _sortAscending(bytes32[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; i++) {
            bytes32 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
    }

    /**
     * @dev Derive the inclusion proof for `target` under the normative
     *      construction. A node promoted from an odd level contributes no
     *      sibling for that level.
     */
    function _normativeProof(bytes32[] memory hashes, bytes32 target) internal pure returns (bytes32[] memory proof) {
        _sortAscending(hashes);
        bytes32[] memory scratch = new bytes32[](hashes.length);
        bytes32[] memory acc = new bytes32[](64);
        uint256 depth;
        bytes32 tracked = target;
        uint256 n = hashes.length;
        for (uint256 i = 0; i < n; i++) {
            scratch[i] = hashes[i];
        }
        while (n > 1) {
            uint256 half = n / 2;
            for (uint256 i = 0; i < half; i++) {
                bytes32 a = scratch[2 * i];
                bytes32 b = scratch[2 * i + 1];
                bytes32 parent = _hashSortedPair(a, b);
                if (a == tracked || b == tracked) {
                    acc[depth++] = a == tracked ? b : a;
                    tracked = parent;
                }
                scratch[i] = parent;
            }
            if (n % 2 == 1) {
                // promoted unchanged: no sibling at this level
                scratch[half] = scratch[n - 1];
                n = half + 1;
            } else {
                n = half;
            }
        }
        proof = new bytes32[](depth);
        for (uint256 i = 0; i < depth; i++) {
            proof[i] = acc[i];
        }
    }

    /// @dev The leaf `_auth` computes: the params hash, hashed again. Hashing
    ///      twice keeps a leaf preimage from ever being 64 bytes, which is what
    ///      would let an internal node be passed off as a leaf.
    function _authLeaf(IConditionalOrder.ConditionalOrderParams memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(params))));
    }

    /**
     * @dev The normative construction (`leafEncoding: "v1"`) is accepted by
     *      `_auth` itself, for every leaf across minimal, even and odd tree
     *      sizes, including the odd-promotion levels.
     *
     *      This goes through `getTradeableOrderWithSignature` rather than
     *      calling `MerkleProofLib.verify` directly. Verifying a tree against
     *      its own root only proves the tree is self-consistent, which a tree
     *      built with the wrong leaf encoding also is: the earlier version of
     *      this test passed while using a leaf `_auth` never computes.
     */
    function test_payloadTree_NormativeConstructionVerifiesLikeAuth() public {
        uint256[5] memory sizes = [uint256(2), 3, 4, 5, 7];
        for (uint256 s = 0; s < sizes.length; s++) {
            IConditionalOrder.ConditionalOrderParams[] memory bundle = getBundle(safe1, sizes[s]);

            bytes32[] memory hashes = new bytes32[](bundle.length);
            for (uint256 i = 0; i < bundle.length; i++) {
                hashes[i] = _authLeaf(bundle[i]);
            }

            bytes32[] memory forRoot = new bytes32[](hashes.length);
            for (uint256 i = 0; i < hashes.length; i++) {
                forRoot[i] = hashes[i];
            }
            bytes32 root = _normativeRoot(forRoot);

            _setRoot(
                address(safe1),
                root,
                ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: new bytes32[](0)})
            );

            for (uint256 i = 0; i < bundle.length; i++) {
                bytes32[] memory forProof = new bytes32[](hashes.length);
                for (uint256 j = 0; j < hashes.length; j++) {
                    forProof[j] = hashes[j];
                }
                bytes32[] memory proof = _normativeProof(forProof, _authLeaf(bundle[i]));

                // reverts `ProofNotAuthed` if the construction is not what `_auth` accepts
                composableCow.getTradeableOrderWithSignature(address(safe1), bundle[i], bytes(""), proof);
            }
        }
    }

    /// @dev The encoding the payload standard used to document, a single hash,
    ///      is rejected. Pins that the two are not interchangeable, so the spec
    ///      cannot drift back without this failing.
    function test_payloadTree_SingleHashedLeafIsRejected() public {
        IConditionalOrder.ConditionalOrderParams[] memory bundle = getBundle(safe1, 2);

        bytes32 a = keccak256(abi.encode(bundle[0]));
        bytes32 b = keccak256(abi.encode(bundle[1]));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;

        _setRoot(
            address(safe1),
            _hashSortedPair(a, b),
            ComposableCow.Proof({uris: new string[](0), blobVersionedHashes: new bytes32[](0)})
        );

        vm.expectRevert(ComposableCow.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), bundle[0], bytes(""), proof);
    }
}
