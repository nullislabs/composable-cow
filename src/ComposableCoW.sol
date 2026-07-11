// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {
    ExtensibleFallbackHandler,
    ERC1271,
    ISignatureVerifierMuxer,
    ISafeSignatureVerifier,
    Safe
} from "safe/handler/ExtensibleFallbackHandler.sol";

import {IConditionalOrder, IConditionalOrderGenerator, GPv2Order} from "./interfaces/IConditionalOrder.sol";
import {ISwapGuard} from "./interfaces/ISwapGuard.sol";
import {IValueFactory} from "./interfaces/IValueFactory.sol";
import {CoWSettlement} from "./vendored/CoWSettlement.sol";

/**
 * @title ComposableCoW - A contract that allows users to create multiple conditional orders
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Designed to be used with Safe + ExtensibleFallbackHandler
 */
contract ComposableCoW is ISafeSignatureVerifier {
    // --- errors
    error ProofNotAuthed();
    /// @dev A zero root (explicit clear) must carry an empty proof
    error ProofDataMalformed();
    /// @dev A listed blob versioned hash is not attached to this transaction
    error BlobNotAttached();
    error SingleOrderNotAuthed();
    error SwapGuardRestricted();
    error InvalidHandler();
    error InvalidFallbackHandler();
    error InterfaceNotSupported();

    // --- types

    // A struct to encapsulate order parameters / offchain input
    struct PayloadStruct {
        bytes32[] proof;
        IConditionalOrder.ConditionalOrderParams params;
        bytes offchainInput;
    }

    /**
     * @dev Where to find the merkle payload document (the complete leaf set,
     *      see `docs/discovery.md` §3). Two orthogonal publication channels,
     *      each optional:
     *      - `uris`: mirrors for the payload document; all URIs MUST reference
     *        the same bytes. Never interpreted on-chain.
     *      - `blobVersionedHashes`: EIP-4844 blobs carrying the payload. Every
     *        listed hash is verified attached to THIS transaction, binding
     *        publication to authorization.
     *      Both empty = private: no discovery is expected.
     */
    struct Proof {
        string[] uris;
        bytes32[] blobVersionedHashes;
    }

    /**
     * @dev Observed fill state of a discrete order, derived from
     *      `GPv2Settlement.filledAmount`. Orthogonal to the handler's verdict:
     *      composed here by the registry, never produced by a handler.
     */
    enum FillStatus {
        NONE, // No fill observed
        PARTIALLY_FILLED, // 0 < filledAmount < total
        FILLED, // filledAmount >= total
        INVALIDATED // order was cancelled via invalidateOrder
    }

    /**
     * @dev The public polling result: the handler's verdict plus the observed
     *      fill overlay. A `POST` verdict coexists with `PARTIALLY_FILLED`,
     *      which is what allows a partially filled `partiallyFillable` order
     *      to keep being posted.
     * @param generator the handler's verdict (see `IConditionalOrderGenerator`)
     * @param fill observed fill state; only meaningful when the verdict is `POST`
     * @param filledAmount raw `GPv2Settlement.filledAmount` for the discrete
     *        order (`type(uint256).max` when invalidated)
     */
    /**
     * @dev Registry-level restriction overlay. Like the fill overlay, this is
     *      orthogonal to the handler's verdict and never overwrites it: a
     *      restricted order keeps its true generator verdict (a guarded POST
     *      stays visible) but no signature is built while restricted. With
     *      restriction expressed here, `INVALID` is uniformly terminal - the
     *      swap guard is owner-reversible and its lifecycle is observable via
     *      `SwapGuardSet` (clear = address(0)).
     */
    enum Restriction {
        NONE, // No registry-level restriction
        SWAP_GUARD // The owner's swap guard rejected the order
    }

    struct PollResult {
        IConditionalOrderGenerator.GeneratorResult generator;
        FillStatus fill;
        uint256 filledAmount;
        Restriction restriction;
    }

    // --- events

    /**
     * An event emitted when a user sets their merkle root
     * @param owner the owner of the merkle root
     * @param root the merkle root
     * @param proof where to find the proofs
     * @param context the resolved cabinet value for context-set roots
     *        (abi-encoded bytes32), empty bytes otherwise
     */
    event MerkleRootSet(address indexed owner, bytes32 root, Proof proof, bytes context);
    event ConditionalOrderCreated(
        address indexed owner, IConditionalOrder.ConditionalOrderParams params, bytes context
    );
    event ConditionalOrderRemoved(address indexed owner, bytes32 indexed orderHash);
    event SwapGuardSet(address indexed owner, ISwapGuard swapGuard);

    // --- state
    /// @dev The GPv2 settlement contract, consulted for observed fill state
    CoWSettlement public immutable settlement;
    // Domain separator is only used for generating signatures
    bytes32 public immutable domainSeparator;
    /// @dev Mapping of owner's merkle roots
    mapping(address owner => bytes32 root) public roots;
    /// @dev Mapping of owner's single orders
    mapping(address owner => mapping(bytes32 orderHash => bool authorized)) public singleOrders;
    // @dev Mapping of owner's swap guard
    mapping(address owner => ISwapGuard guard) public swapGuards;
    // @dev Mapping of owner's on-chain storage slots
    mapping(address owner => mapping(bytes32 ctx => bytes32 value)) public cabinet;

    // --- constructor

    /**
     * @param _settlement The GPv2 settlement contract
     */
    constructor(address _settlement) {
        settlement = CoWSettlement(_settlement);
        domainSeparator = settlement.domainSeparator();
    }

    // --- setters

    /**
     * Set the merkle root of the user's conditional orders
     * @notice Set the merkle root of the user's conditional orders
     * @param root The merkle root of the user's conditional orders
     * @param proof Where to find the proofs
     */
    function setRoot(bytes32 root, Proof calldata proof) public {
        _setRoot(root, proof, bytes(""));
    }

    /**
     * Set the merkle root of the user's conditional orders and store a value from on-chain in the cabinet
     * @dev The cabinet is written *before* the event fires, so indexers reacting
     *      to `MerkleRootSet` observe a consistent cabinet, and the resolved
     *      value is carried in the event's `context` field.
     * @param root The merkle root of the user's conditional orders
     * @param proof Where to find the proofs
     * @param factory A factory from which to get a value to store in the cabinet related to the merkle root
     * @param data Implementation specific off-chain data
     */
    function setRootWithContext(bytes32 root, Proof calldata proof, IValueFactory factory, bytes calldata data)
        external
    {
        // Default to the zero slot for a merkle root as this is the most common use case
        // and should save gas on calldata when reading the cabinet.

        // Set the cabinet slot before emitting
        bytes32 value = factory.getValue(data);
        cabinet[msg.sender][bytes32(0)] = value;

        _setRoot(root, proof, abi.encode(value));
    }

    /**
     * Authorise a single conditional order
     * @param params The parameters of the conditional order
     * @param dispatch Whether to dispatch the `ConditionalOrderCreated` event
     */
    function create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch) public {
        _create(params, dispatch, bytes(""));
    }

    /**
     * Authorise a single conditional order and store a value from on-chain in the cabinet
     * @dev The cabinet is written *before* the event fires, so indexers reacting
     *      to `ConditionalOrderCreated` observe a consistent cabinet, and the
     *      resolved value is carried in the event's `context` field.
     * @param params The parameters of the conditional order
     * @param factory A factory from which to get a value to store in the cabinet
     * @param data Implementation specific off-chain data
     * @param dispatch Whether to dispatch the `ConditionalOrderCreated` event
     */
    function createWithContext(
        IConditionalOrder.ConditionalOrderParams calldata params,
        IValueFactory factory,
        bytes calldata data,
        bool dispatch
    ) external {
        // When setting the slot, an opinionated direction is taken to tie the return value of
        // the slot to the conditional order, such that there is a guarantee of data integrity

        // Set the cabinet slot before emitting
        bytes32 value = factory.getValue(data);
        cabinet[msg.sender][hash(params)] = value;

        _create(params, dispatch, abi.encode(value));
    }

    /**
     * Remove the authorisation of a single conditional order
     * @param singleOrderHash The hash of the single conditional order to remove
     */
    function remove(bytes32 singleOrderHash) external {
        singleOrders[msg.sender][singleOrderHash] = false;
        cabinet[msg.sender][singleOrderHash] = bytes32(0);
        emit ConditionalOrderRemoved(msg.sender, singleOrderHash);
    }

    /**
     * Set the swap guard of the user's conditional orders
     * @param swapGuard The address of the swap guard
     */
    function setSwapGuard(ISwapGuard swapGuard) external {
        swapGuards[msg.sender] = swapGuard;
        emit SwapGuardSet(msg.sender, swapGuard);
    }

    // --- ISafeSignatureVerifier

    /**
     * @inheritdoc ISafeSignatureVerifier
     * @dev Gas-sensitive settlement path: calls `handler.verify` directly and
     *      never touches the polling machinery.
     *      This function does not make use of the `typeHash` parameter as CoW Protocol does not
     *      have more than one type.
     * @param encodeData Is the abi encoded `GPv2Order.Data`
     * @param payload Is the abi encoded `PayloadStruct`
     */
    function isValidSafeSignature(
        Safe safe,
        address sender,
        bytes32 _hash,
        bytes32 _domainSeparator,
        bytes32, // typeHash
        bytes calldata encodeData,
        bytes calldata payload
    ) external view override returns (bytes4 magic) {
        // First decode the payload
        PayloadStruct memory _payload = abi.decode(payload, (PayloadStruct));

        // Check if the order is authorised
        bytes32 ctx = _auth(address(safe), _payload.params, _payload.proof);

        // It's an authorised order, validate it.
        GPv2Order.Data memory order = abi.decode(encodeData, (GPv2Order.Data));

        // Check with the swap guard if the order is restricted or not
        require(_guardCheck(address(safe), ctx, _payload.params, _payload.offchainInput, order), SwapGuardRestricted());

        // Proof is valid, guard (if any) is valid, now check the handler
        _payload.params.handler
            .verify(
                address(safe),
                sender,
                _hash,
                _domainSeparator,
                ctx,
                _payload.params.staticInput,
                _payload.offchainInput,
                order
            );

        return ERC1271.isValidSignature.selector;
    }

    // --- getters

    /**
     * Poll for a discrete order with signature and scheduling metadata
     * @dev Does not revert for order conditions: the handler's verdict and the
     *      observed fill state are returned in the structured result. Reverts
     *      only for authorisation (`_auth`) and handler-interface failures.
     * @param owner of the order
     * @param params `ConditionalOrderParams` for the order
     * @param offchainInput any dynamic off-chain input for generating the discrete order
     * @param proof if using merkle-roots that H(handler || salt || staticInput) is in the merkle tree
     * @return result composed polling result (verdict + fill overlay)
     * @return signature for submitting to CoW Protocol API (empty unless the
     *         order is currently postable)
     */
    function getTradeableOrderWithSignature(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof
    ) external view returns (PollResult memory result, bytes memory signature) {
        // Check if the order is authorised and in doing so, get the context
        bytes32 ctx = _auth(owner, params, proof);

        result = _poll(owner, params, ctx, offchainInput);

        // Only a POST verdict can yield a signature
        if (result.generator.code != IConditionalOrderGenerator.GeneratorResultCode.POST) {
            return (result, bytes(""));
        }

        // A fully filled or invalidated order is not postable
        if (result.fill == FillStatus.FILLED || result.fill == FillStatus.INVALIDATED) {
            return (result, bytes(""));
        }

        // A partially filled order is only postable if it is partially fillable;
        // a partial fill on a fill-or-kill order should not be re-posted
        if (result.fill == FillStatus.PARTIALLY_FILLED && !result.generator.order.partiallyFillable) {
            return (result, bytes(""));
        }

        // A restricted order is never signed; the generator verdict is
        // preserved in the result (restriction is an overlay, not a verdict)
        if (result.restriction != Restriction.NONE) {
            return (result, bytes(""));
        }

        signature = _buildSignature(owner, params, offchainInput, proof, result.generator.order);
    }

    /**
     * Check the current polling state of a conditional order
     * @dev Returns the same composed result as `getTradeableOrderWithSignature`,
     *      without building the signature. The swap guard is consulted and
     *      reported via `restriction`; enforcement (signature withheld, revert
     *      at settlement) happens at signature build and during `verify`.
     * @param owner of the order
     * @param params `ConditionalOrderParams` for the order
     * @param offchainInput any dynamic off-chain input for generating the discrete order
     * @param proof if using merkle-roots that H(handler || salt || staticInput) is in the merkle tree
     * @return result composed polling result (verdict + fill overlay)
     */
    function checkOrder(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof
    ) external view returns (PollResult memory result) {
        bytes32 ctx = _auth(owner, params, proof);
        return _poll(owner, params, ctx, offchainInput);
    }

    // --- public functions

    /**
     * Return the hash of the conditional order parameters
     * @param params `ConditionalOrderParams` for the order
     * @return hash of the conditional order parameters
     */
    function hash(IConditionalOrder.ConditionalOrderParams memory params) public pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    // --- internal functions

    /**
     * @dev Write the root and emit, carrying the resolved cabinet context
     */
    function _setRoot(bytes32 root, Proof calldata proof, bytes memory context) internal {
        if (root == bytes32(0)) {
            // Explicit clear: a zero root authorizes no leaf; publishing a
            // payload for it is malformed
            require(proof.uris.length == 0 && proof.blobVersionedHashes.length == 0, ProofDataMalformed());
        }
        // Publication is atomic with authorization: every listed blob must be
        // attached to the transaction setting the root
        for (uint256 i = 0; i < proof.blobVersionedHashes.length; i++) {
            require(_blobAttached(proof.blobVersionedHashes[i]), BlobNotAttached());
        }
        roots[msg.sender] = root;
        emit MerkleRootSet(msg.sender, root, proof, context);
    }

    /**
     * @dev True iff `versionedHash` is among this transaction's blob hashes.
     *      `blobhash(i)` returns zero past the last blob, and a real versioned
     *      hash can never be zero (it always begins with the 0x01 version byte).
     */
    function _blobAttached(bytes32 versionedHash) internal view returns (bool) {
        for (uint256 i;; i++) {
            bytes32 h = blobhash(i);
            if (h == bytes32(0)) return false;
            if (h == versionedHash) return true;
        }
    }

    /**
     * @dev Authorise the order and emit, carrying the resolved cabinet context
     */
    function _create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch, bytes memory context)
        internal
    {
        require(address(params.handler) != address(0), InvalidHandler());

        singleOrders[msg.sender][hash(params)] = true;
        if (dispatch) {
            emit ConditionalOrderCreated(msg.sender, params, context);
        }
    }

    /**
     * @dev Poll the handler through the ERC-165 gate and compose the observed
     *      fill state into the result. Shared by `getTradeableOrderWithSignature`
     *      and `checkOrder` so the gate cannot drift between the two paths.
     */
    function _poll(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes32 ctx,
        bytes calldata offchainInput
    ) internal view returns (PollResult memory result) {
        // Make sure the handler supports `IConditionalOrderGenerator`
        try IConditionalOrderGenerator(address(params.handler))
            .supportsInterface(type(IConditionalOrderGenerator).interfaceId) returns (
            bool supported
        ) {
            if (!supported) {
                revert InterfaceNotSupported();
            }
        } catch {
            revert InterfaceNotSupported();
        }

        result.generator = IConditionalOrderGenerator(address(params.handler))
            .poll(owner, msg.sender, ctx, params.staticInput, offchainInput);

        // The fill and restriction overlays are only meaningful for a postable order
        if (result.generator.code == IConditionalOrderGenerator.GeneratorResultCode.POST) {
            if (!_guardCheck(owner, ctx, params, offchainInput, result.generator.order)) {
                result.restriction = Restriction.SWAP_GUARD;
            }
            uint256 filledAmount = _getFilledAmount(owner, result.generator.order);
            result.filledAmount = filledAmount;
            if (filledAmount == 0) {
                result.fill = FillStatus.NONE;
            } else if (filledAmount == type(uint256).max) {
                // `invalidateOrder` sets filledAmount to uint256.max: the order
                // was cancelled, not filled
                result.fill = FillStatus.INVALIDATED;
            } else {
                uint256 totalAmount = result.generator.order.kind == GPv2Order.KIND_SELL
                    ? result.generator.order.sellAmount
                    : result.generator.order.buyAmount;
                result.fill = filledAmount >= totalAmount ? FillStatus.FILLED : FillStatus.PARTIALLY_FILLED;
            }
        }
    }

    /**
     * @dev `msg.sender` set to `owner` of the conditional order to guard against
     *      unauthorised ordering
     * @param owner of the conditional order
     * @param params that uniquely identify the conditional order
     * @param proof to assert that the conditional order is authorised (if using merkle-roots)
     * @return ctx of the conditional order (bytes32(0) if not using merkle-roots)
     */
    function _auth(address owner, IConditionalOrder.ConditionalOrderParams memory params, bytes32[] memory proof)
        internal
        view
        returns (bytes32 ctx)
    {
        if (proof.length != 0) {
            // The order is part of a merkle tree
            bytes32 leaf = keccak256(bytes.concat(hash(params)));
            require(MerkleProof.verify(proof, roots[owner], leaf), ProofNotAuthed());
        } else {
            // The order is a single order
            ctx = hash(params);
            require(singleOrders[owner][ctx], SingleOrderNotAuthed());
        }
    }

    /**
     * @dev Check with the swap guard (if any) if the order is restricted
     */
    function _guardCheck(
        address owner,
        bytes32 ctx,
        IConditionalOrder.ConditionalOrderParams memory params,
        bytes memory offchainInput,
        GPv2Order.Data memory order
    ) internal view returns (bool) {
        ISwapGuard guard = swapGuards[owner];
        if (address(guard) != address(0)) {
            return guard.verify(order, ctx, params, offchainInput);
        }
        return true;
    }

    /**
     * @dev Build the ERC-1271 signature payload for the discrete order
     */
    function _buildSignature(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof,
        GPv2Order.Data memory order
    ) internal view returns (bytes memory signature) {
        // Get the signature for the order
        try ExtensibleFallbackHandler(owner).supportsInterface(type(ISignatureVerifierMuxer).interfaceId) returns (
            bool supported
        ) {
            if (!supported) {
                revert InvalidFallbackHandler();
            }
            signature = abi.encodeWithSignature(
                "safeSignature(bytes32,bytes32,bytes,bytes)",
                domainSeparator,
                GPv2Order.TYPE_HASH,
                abi.encode(order),
                abi.encode(PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}))
            );
        } catch {
            // Assume a non-Safe wallet (e.g. an `ERC1271Forwarder`)
            signature = abi.encode(order, PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}));
        }
    }

    /**
     * @dev Compute the order UID and look up the observed fill amount
     */
    function _getFilledAmount(address owner, GPv2Order.Data memory order) internal view returns (uint256) {
        bytes memory orderUid = abi.encodePacked(GPv2Order.hash(order, domainSeparator), owner, order.validTo);
        return settlement.filledAmount(orderUid);
    }
}
