// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleTreeLib} from "solady/utils/MerkleTreeLib.sol";
import {IConditionalOrder} from "../../src/interfaces/IConditionalOrder.sol";

library ComposableCowLib {
    function hash(IConditionalOrder.ConditionalOrderParams memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(params))));
    }

    function sort(bytes32[] memory array) internal pure returns (bytes32[] memory) {
        for (uint256 i = 0; i < array.length; i++) {
            for (uint256 j = i + 1; j < array.length; j++) {
                if (array[i] > array[j]) {
                    bytes32 temp = array[i];
                    array[i] = array[j];
                    array[j] = temp;
                }
            }
        }
        return array;
    }

    /**
     * Generate a Merkle root and proof for a leaf in a tree
     * @param leaves to be inserted into the tree
     * @param n th leaf to generate the proof for
     * @param m a mapping of hashes to leaves to be populated (storage)
     * @return the root of the tree
     * @return a proof for the n'th leaf
     * @return the n'th leaf
     */
    function getRootAndProof(
        IConditionalOrder.ConditionalOrderParams[] memory leaves,
        uint256 n,
        mapping(bytes32 => IConditionalOrder.ConditionalOrderParams) storage m
    ) internal returns (bytes32, bytes32[] memory, IConditionalOrder.ConditionalOrderParams memory) {
        // 1. Create a mapping of hashes to leaves
        for (uint256 i = 0; i < leaves.length; i++) {
            m[hash(leaves[i])] = leaves[i];
        }

        // 2. Create keccak256 hashes of the leaves
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i = 0; i < leaves.length; i++) {
            hashes[i] = hash(leaves[i]);
        }

        // 3. Sort the hashes
        bytes32[] memory sortedHashes = sort(hashes);

        // 4. Build the tree, then take the root and the n'th leaf's proof.
        //    `MerkleTreeLib` pairs with `MerkleProofLib`, which is what
        //    `ComposableCow` verifies with, so construction and verification
        //    come from the same family.
        bytes32[] memory tree = MerkleTreeLib.build(sortedHashes);
        bytes32 root = MerkleTreeLib.root(tree);
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, n);

        // 6. Get the leaf that was used to create the proof
        IConditionalOrder.ConditionalOrderParams memory leaf = m[sortedHashes[n]];

        return (root, proof, leaf);
    }
}
