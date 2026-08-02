// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271, ISignatureVerifierMuxer} from "safe/handler/extensible/SignatureVerifierMuxer.sol";
import {IERC165} from "safe/Safe.sol";

import {ERC7821} from "solady/accounts/ERC7821.sol";

import {
    IERC20,
    IConditionalOrder,
    GPv2Order,
    ComposableCow,
    BaseComposableCowTest,
    TestSwapGuard
} from "./ComposableCow.base.t.sol";

import {TWAPOrder} from "../src/types/twap/libraries/TWAPOrder.sol";
import {CowAccount7702} from "../src/accounts/CowAccount7702.sol";

/**
 * @dev EIP-7702 delegation cheatcodes are supported by the `forge` binary
 *      (1.7.1) but absent from the vendored `forge-std` Vm interface, so they
 *      are declared locally (see the `VmJson` precedent in
 *      ComposableCow.descriptorDoc.t.sol).
 */
interface Vm7702 {
    struct SignedDelegation {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint64 nonce;
        address implementation;
    }

    function signAndAttachDelegation(address implementation, uint256 privateKey)
        external
        returns (SignedDelegation memory);
}

contract ComposableCow7702Test is BaseComposableCowTest {
    /// @dev The exact GPv2 `Order(...)` EIP-712 type string; `contentsType`
    ///      for the ERC-7739 TypedDataSign workflow (implicit mode).
    string internal constant ORDER_TYPE =
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)";

    /// @dev ERC-7821 mode: single batch, no `opData` support.
    bytes32 internal constant MODE_SINGLE_BATCH = bytes32(uint256(0x01) << 248);

    /// @dev ERC-7821 mode: single batch with optional `opData` support.
    bytes32 internal constant MODE_SINGLE_BATCH_OPDATA = bytes32(uint256(0x01000000000078210001) << 176);

    /// @dev ERC-7739 detection sentinel (see EIP-7739).
    bytes32 internal constant SENTINEL_7739 = 0x7739773977397739773977397739773977397739773977397739773977397739;

    /// @dev The canonical `MulticallerWithSigner`, Solady's default "safe" caller.
    address internal constant MULTICALLER_WITH_SIGNER = 0x000000000000D9ECebf3C23529de49815Dac1c4c;

    /// @dev secp256k1 group order.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    CowAccount7702 internal impl;
    address internal eoa;
    uint256 internal eoaPk;

    function setUp() public virtual override(BaseComposableCowTest) {
        super.setUp();

        // deploy the shared delegate implementation
        impl = new CowAccount7702(composableCow);

        // create the delegating EOA and attach the EIP-7702 delegation
        // (real cheatcode: writes the 0xef0100 ++ impl designator)
        (eoa, eoaPk) = makeAddrAndKey("composable-cow-7702-eoa");
        Vm7702(address(vm)).signAndAttachDelegation(address(impl), eoaPk);
        assertEq(eoa.code.length, 23);
    }

    // --- helpers ---

    function _twapBundle() internal view returns (TWAPOrder.Data memory) {
        return TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            partSellAmount: 1e18,
            minPartLimit: 1,
            t0: block.timestamp,
            n: 2,
            t: 3600,
            span: 0,
            appData: keccak256("twap.7702")
        });
    }

    function _createTwapOrder() internal returns (IConditionalOrder.ConditionalOrderParams memory params) {
        TWAPOrder.Data memory twapData = _twapBundle();
        params = createOrder(twap, keccak256("twap.7702"), abi.encode(twapData));

        // register the single order in ComposableCow as the EOA
        _create(eoa, params, false);

        // fund the EOA and authorize the vault relayer
        deal(address(token0), eoa, twapData.partSellAmount * twapData.n);
        vm.prank(eoa);
        token0.approve(address(relayer), twapData.partSellAmount * twapData.n);
    }

    /// @dev Builds the ERC-7739 TypedDataSign wire signature over the GPv2
    ///      order digest, signed by `pk`.
    function _typedDataSign(GPv2Order.Data memory order, uint256 pk) internal view returns (bytes memory) {
        (bytes32 finalDigest, bytes memory suffix) = _typedDataSignParts(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, finalDigest);
        return abi.encodePacked(r, s, v, suffix);
    }

    /// @dev The ERC-7739 TypedDataSign nested digest to sign, and the wire
    ///      suffix appended after the raw ECDSA bytes.
    function _typedDataSignParts(GPv2Order.Data memory order)
        internal
        view
        returns (bytes32 finalDigest, bytes memory suffix)
    {
        bytes32 appDomain = settlement.domainSeparator();
        bytes32 contents = _orderStructHash(order);
        bytes32 typedDataSignTypehash = keccak256(
            abi.encodePacked(
                "TypedDataSign(Order contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)",
                ORDER_TYPE
            )
        );
        // CowAccount7702's account domain: verifyingContract is the EOA
        bytes32 structHash = keccak256(
            abi.encode(
                typedDataSignTypehash,
                contents,
                keccak256("CowAccount7702"),
                keccak256("1"),
                block.chainid,
                eoa,
                bytes32(0)
            )
        );
        finalDigest = keccak256(abi.encodePacked(hex"1901", appDomain, structHash));
        suffix = abi.encodePacked(appDomain, contents, bytes(ORDER_TYPE), uint16(bytes(ORDER_TYPE).length));
    }

    function _orderStructHash(GPv2Order.Data memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                GPv2Order.TYPE_HASH,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                order.kind,
                order.partiallyFillable,
                order.sellTokenBalance,
                order.buyTokenBalance
            )
        );
    }

    /// @dev Low-level probe asserting a signature is never accepted, whether
    ///      it reverts or returns a non-magic value.
    function _assertNotAccepted(bytes32 hash, bytes memory signature) internal {
        (bool success, bytes memory ret) =
            eoa.staticcall(abi.encodeWithSelector(ERC1271.isValidSignature.selector, hash, signature));
        assertFalse(success && ret.length >= 4 && bytes4(ret) == ERC1271.isValidSignature.selector);
    }

    // --- ComposableCow order-payload path ---

    /**
     * @dev The ComposableCow order payload still validates through the
     *      delegated EOA, and `_buildSignature` takes the catch branch (the
     *      returned signature decodes as `abi.encode(order, PayloadStruct)`).
     */
    function test_orderPayload_ReturnsMagicValue() public {
        IConditionalOrder.ConditionalOrderParams memory params = _createTwapOrder();

        (ComposableCow.PollResult memory orderRes, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(eoa, params, bytes(""), new bytes32[](0));
        GPv2Order.Data memory order = orderRes.generator.order;

        // the signature is the non-Safe (catch branch) encoding
        (GPv2Order.Data memory sigOrder, ComposableCow.PayloadStruct memory payload) =
            abi.decode(signature, (GPv2Order.Data, ComposableCow.PayloadStruct));
        assertEq(
            GPv2Order.hash(sigOrder, composableCow.domainSeparator()),
            GPv2Order.hash(order, composableCow.domainSeparator())
        );
        assertEq(keccak256(abi.encode(payload.params)), keccak256(abi.encode(params)));

        // the delegated EOA validates it
        assertEq(
            ERC1271(eoa).isValidSignature(GPv2Order.hash(order, composableCow.domainSeparator()), signature),
            ERC1271.isValidSignature.selector
        );
    }

    /**
     * @dev The `supportsInterface` probe in `ComposableCow._buildSignature`
     *      still reverts on the delegated EOA (Solady's `Receiver` fallback
     *      answers only token callbacks), forcing the catch branch.
     */
    function test_supportsInterface_ProbeReverts() public {
        vm.expectRevert();
        IERC165(eoa).supportsInterface(type(ISignatureVerifierMuxer).interfaceId);
    }

    // --- ERC-7739 ECDSA path ---

    /**
     * @dev An ECDSA signature by the delegated EOA over the ERC-7739
     *      TypedDataSign nested digest of a GPv2 order is accepted.
     */
    function test_erc7739_TypedDataSign_ReturnsMagicValue() public {
        GPv2Order.Data memory order = getBlankOrder();
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());

        bytes memory signature = _typedDataSign(order, eoaPk);
        assertEq(ERC1271(eoa).isValidSignature(orderDigest, signature), ERC1271.isValidSignature.selector);
    }

    /**
     * @dev The same nested digest signed by a different key is rejected.
     */
    function test_erc7739_WrongSigner_NotAccepted() public {
        GPv2Order.Data memory order = getBlankOrder();
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());

        bytes memory signature = _typedDataSign(order, bob.pk);
        _assertNotAccepted(orderDigest, signature);
    }

    /**
     * @dev Garbage and malformed signatures are never accepted (they either
     *      return a non-magic value or revert in the forwarder fallthrough).
     */
    function test_garbageSignature_NeverAccepted() public {
        bytes32 hash = keccak256("some hash");

        // 65 bytes of garbage (raw-ECDSA shaped)
        _assertNotAccepted(hash, abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27)));
        // empty signature (and a non-sentinel hash)
        _assertNotAccepted(hash, bytes(""));
        // 704 zero bytes (order-payload shaped)
        _assertNotAccepted(hash, new bytes(704));
        // a well-formed but UNREGISTERED order payload
        GPv2Order.Data memory order = getBlankOrder();
        ComposableCow.PayloadStruct memory payload = ComposableCow.PayloadStruct({
            proof: new bytes32[](0), params: getPassthroughOrder(), offchainInput: bytes("")
        });
        _assertNotAccepted(GPv2Order.hash(order, composableCow.domainSeparator()), abi.encode(order, payload));
    }

    /**
     * @dev Solady's default treats `MulticallerWithSigner` as a "safe" caller
     *      and skips the ERC-7739 nesting for it, accepting raw ECDSA
     *      signatures over arbitrary hashes. The `_erc1271CallerIsSafe`
     *      override closes that branch: nesting is unconditional.
     */
    function test_multicallerCaller_RawSignature_NotAccepted() public {
        bytes32 arbitrary = keccak256("any 32-byte value the EOA key ever signed");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPk, arbitrary);

        vm.prank(MULTICALLER_WITH_SIGNER);
        _assertNotAccepted(arbitrary, abi.encodePacked(r, s, v));
    }

    /**
     * @dev The ECDSA leaf accepts only the canonical 65-byte low-s encoding,
     *      so each accepted digest has a unique signature byte string. The
     *      high-s twin and the EIP-2098 compact form of an otherwise valid
     *      signature are rejected.
     */
    function test_erc7739_MalleatedEncodings_NotAccepted() public {
        GPv2Order.Data memory order = getBlankOrder();
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        (bytes32 finalDigest, bytes memory suffix) = _typedDataSignParts(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPk, finalDigest);

        // sanity: the canonical encoding is accepted
        assertEq(
            ERC1271(eoa).isValidSignature(orderDigest, abi.encodePacked(r, s, v, suffix)),
            ERC1271.isValidSignature.selector
        );

        // the high-s twin recovers to the same signer but is rejected
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        _assertNotAccepted(orderDigest, abi.encodePacked(r, sHigh, vFlipped, suffix));

        // the 64-byte EIP-2098 compact form is rejected
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        _assertNotAccepted(orderDigest, abi.encodePacked(r, vs, suffix));
    }

    /**
     * @dev Pins the documented behavior: shape 1 (ERC-7739) is a direct owner
     *      signature that never touches `ComposableCow`, so an installed swap
     *      guard does not mediate it. Only the order-payload branch is
     *      guard-checked.
     */
    function test_erc7739_BypassesSwapGuard() public {
        // a guard that rejects odd sell amounts, installed for the EOA
        TestSwapGuard oddRejectingGuard = new TestSwapGuard(2);
        _setSwapGuard(eoa, oddRejectingGuard);

        GPv2Order.Data memory order = getBlankOrder();
        order.sellAmount = 1;
        assertFalse(oddRejectingGuard.verify(order, bytes32(0), getPassthroughOrder(), bytes("")));

        // the guard-violating order is still accepted via ERC-7739
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory signature = _typedDataSign(order, eoaPk);
        assertEq(ERC1271(eoa).isValidSignature(orderDigest, signature), ERC1271.isValidSignature.selector);
    }

    /**
     * @dev The ERC-7739 detection sentinel is preserved by the dispatch.
     */
    function test_erc7739_DetectionSentinel() public {
        (bool success, bytes memory ret) =
            eoa.staticcall(abi.encodeWithSelector(ERC1271.isValidSignature.selector, SENTINEL_7739, bytes("")));
        assertTrue(success);
        assertEq(bytes4(ret), bytes4(0x77390001));
    }

    // --- ERC-7821 batching ---

    /**
     * @dev A self-call batch (the EOA sending a transaction to itself)
     *      executes: here creating a TWAP order and setting the relayer
     *      allowance in one batch.
     */
    function test_execute_SelfBatch_Succeeds() public {
        TWAPOrder.Data memory twapData = _twapBundle();
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrder(twap, keccak256("twap.7702.batch"), abi.encode(twapData));
        uint256 sellAmount = twapData.partSellAmount * twapData.n;
        deal(address(token0), eoa, sellAmount);

        ERC7821.Call[] memory calls = new ERC7821.Call[](2);
        calls[0] = ERC7821.Call({
            to: address(composableCow),
            value: 0,
            data: abi.encodeWithSelector(ComposableCow.create.selector, params, false)
        });
        calls[1] = ERC7821.Call({
            to: address(token0),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(relayer), sellAmount)
        });

        // under EIP-7702, msg.sender == address(this) is a self-sent tx
        vm.prank(eoa);
        CowAccount7702(payable(eoa)).execute(MODE_SINGLE_BATCH, abi.encode(calls));

        assertTrue(composableCow.singleOrders(eoa, keccak256(abi.encode(params))));
        assertEq(token0.allowance(eoa, address(relayer)), sellAmount);
    }

    /**
     * @dev `execute` from any sender other than the account itself reverts.
     */
    function test_execute_NotSelf_Reverts() public {
        ERC7821.Call[] memory calls = new ERC7821.Call[](0);

        vm.prank(alice.addr);
        vm.expectRevert();
        CowAccount7702(payable(eoa)).execute(MODE_SINGLE_BATCH, abi.encode(calls));
    }

    /**
     * @dev A non-empty `opData` reverts (ERC-7821 defaults: no relayed path).
     */
    function test_execute_NonEmptyOpData_Reverts() public {
        ERC7821.Call[] memory calls = new ERC7821.Call[](0);

        vm.prank(eoa);
        vm.expectRevert();
        CowAccount7702(payable(eoa)).execute(MODE_SINGLE_BATCH_OPDATA, abi.encode(calls, bytes("op")));
    }

    /**
     * @dev Sanity: the local `ORDER_TYPE` string matches GPv2's TYPE_HASH.
     */
    function test_orderTypeString_MatchesTypeHash() public {
        assertEq(keccak256(bytes(ORDER_TYPE)), GPv2Order.TYPE_HASH);
    }
}
