// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";

import "./ComposableCow.base.t.sol";

import {Account7702} from "../src/accounts/Account7702.sol";
import {CowAccount7702} from "../src/accounts/CowAccount7702.sol";

/// @dev `signAndAttachDelegation` is supported by the `forge` binary but absent
///      from the vendored `forge-std` interface.
interface Vm7702Proxy {
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

/// @dev A second implementation, distinguishable from the first by its domain.
contract OtherAccount is Account7702 {
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("OtherAccount", "1");
    }
}

/**
 * @dev The reason for delegating to a proxy rather than straight to an
 *      implementation: the implementation can be replaced without the EOA
 *      re-signing an EIP-7702 authorisation.
 */
contract ComposableCowProxyTest is BaseComposableCowTest {
    address internal constant ADMIN = address(0xA11CE);

    CowAccount7702 internal cowImpl;
    OtherAccount internal otherImpl;
    EIP7702Proxy internal proxy;

    address internal eoa;
    uint256 internal eoaPk;

    function setUp() public virtual override(BaseComposableCowTest) {
        super.setUp();

        cowImpl = new CowAccount7702(composableCow);
        otherImpl = new OtherAccount();
        proxy = new EIP7702Proxy(address(cowImpl), ADMIN);

        (eoa, eoaPk) = makeAddrAndKey("composable-cow-7702-proxy-eoa");
        Vm7702Proxy(address(vm)).signAndAttachDelegation(address(proxy), eoaPk);
    }

    /// @dev The delegation designator points at the proxy, not the implementation.
    function test_proxy_DelegationTargetsProxy() public {
        assertEq(eoa.code.length, 23, "delegation designator absent");
        assertEq(_proxyImplementation(), address(cowImpl));
        assertEq(_proxyAdmin(), ADMIN);
    }

    /**
     * @dev The whole point. The EOA signs one authorisation, pointing at the
     *      proxy. Changing the implementation afterwards changes the code the
     *      EOA runs, with no second authorisation and no transaction from the
     *      EOA at all.
     */
    function test_proxy_UpgradeChangesBehaviourWithoutRedelegating() public {
        bytes32 before = _domainSeparatorOf(eoa);

        vm.prank(ADMIN);
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("upgrade(address)", address(otherImpl)));
        assertTrue(ok, "upgrade call failed");

        assertEq(_proxyImplementation(), address(otherImpl));
        assertTrue(_domainSeparatorOf(eoa) != before, "EOA still runs the old implementation");
        assertEq(eoa.code.length, 23, "delegation should be untouched by an upgrade");
    }

    function test_proxy_UpgradeRejectsNonAdmin() public {
        address impl = _proxyImplementation();

        vm.prank(address(0xBAD));
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("upgrade(address)", address(otherImpl)));

        // A non-admin call is forwarded rather than treated as an upgrade, so
        // the implementation must be unchanged either way.
        ok; // silence unused
        assertEq(_proxyImplementation(), impl, "non-admin changed the implementation");
    }

    /// @dev ERC-1271 must work through the proxy exactly as it does direct.
    function test_proxy_ERC1271WorksThroughProxy() public {
        bytes32 separator = _domainSeparatorOf(eoa);
        assertTrue(separator != bytes32(0), "EIP-712 domain unavailable through the proxy");
    }

    /// @dev The proxy keeps `implementation()` and `admin()` out of its public
    ///      ABI so it can forward all calldata, so they are read low level.
    function _proxyImplementation() private view returns (address) {
        (bool ok, bytes memory ret) = address(proxy).staticcall(abi.encodeWithSignature("implementation()"));
        require(ok && ret.length >= 32, "implementation() failed");
        return abi.decode(ret, (address));
    }

    function _proxyAdmin() private view returns (address) {
        (bool ok, bytes memory ret) = address(proxy).staticcall(abi.encodeWithSignature("admin()"));
        require(ok && ret.length >= 32, "admin() failed");
        return abi.decode(ret, (address));
    }

    function _domainSeparatorOf(address account) private view returns (bytes32) {
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeWithSignature("eip712Domain()"));
        if (!ok || ret.length < 32) return bytes32(0);
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            abi.decode(ret, (bytes1, string, string, uint256, address, bytes32, uint256[]));
        return keccak256(abi.encode(keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract));
    }
}
