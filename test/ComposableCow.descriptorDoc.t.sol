// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "./ComposableCow.base.t.sol";

import "../src/types/TradeAboveThreshold.sol";
import {TWAPOrder} from "../src/types/twap/libraries/TWAPOrder.sol";

/**
 * @dev `parseJsonKeys` is supported by the `forge` binary but absent from the
 *      vendored `forge-std` interface, so it is declared here rather than
 *      bumping the submodule for one cheatcode.
 */
interface VmJson {
    function parseJsonKeys(string calldata json, string calldata key) external pure returns (string[] memory);
}

/**
 * @dev Checks the generated descriptor documents against the contracts they
 *      describe. Solidity rather than a JS toolchain: the facts worth
 *      asserting are on-chain facts, and `forge` already reads JSON.
 *
 *      Byte-for-byte freshness is not checked here; that is
 *      `dev/gen-descriptors.py --check`, which regenerates and diffs.
 */
contract ComposableCowDescriptorDocTest is BaseComposableCowTest {
    string private constant DIR = "descriptors/";

    TradeAboveThreshold private tat;
    string[] private handlers;

    function setUp() public virtual override(BaseComposableCowTest) {
        super.setUp();
        tat = new TradeAboveThreshold();

        handlers.push("TWAP");
        handlers.push("StopLoss");
        handlers.push("GoodAfterTime");
        handlers.push("TradeAboveThreshold");
        handlers.push("PerpetualStableSwap");
    }

    function _doc(string memory handler) private view returns (string memory) {
        return vm.readFile(string.concat(DIR, handler, ".json"));
    }

    function _errorKeys(string memory doc) private pure returns (string[] memory) {
        return VmJson(address(vm)).parseJsonKeys(doc, "$.errors");
    }

    function _hex4(bytes4 sel) private pure returns (string memory) {
        return vm.toString(abi.encodePacked(sel));
    }

    /**
     * @dev Every reason error in this codebase is nullary, so the selector is
     *      determined entirely by the name. A key and name that disagree would
     *      mislabel a live verdict: consumers key on the selector and display
     *      the name.
     */
    function test_descriptor_SelectorMatchesDeclaredName() public {
        uint256 checked;
        for (uint256 h = 0; h < handlers.length; h++) {
            string memory doc = _doc(handlers[h]);
            string[] memory keys = _errorKeys(doc);
            assertGt(keys.length, 0, "descriptor declares no errors");

            for (uint256 i = 0; i < keys.length; i++) {
                string memory name = vm.parseJsonString(doc, string.concat("$.errors[\"", keys[i], "\"].name"));
                bytes4 derived = bytes4(keccak256(bytes(string.concat(name, "()"))));
                assertEq(_hex4(derived), keys[i], string.concat(handlers[h], ": selector does not match ", name));
                checked++;
            }
        }
        assertGt(checked, 20, "suspiciously few errors checked");
    }

    /// @dev A duplicate key silently drops an error from the map.
    function test_descriptor_SelectorsAreDistinct() public {
        for (uint256 h = 0; h < handlers.length; h++) {
            string[] memory keys = _errorKeys(_doc(handlers[h]));
            for (uint256 i = 0; i < keys.length; i++) {
                for (uint256 j = i + 1; j < keys.length; j++) {
                    assertTrue(
                        keccak256(bytes(keys[i])) != keccak256(bytes(keys[j])),
                        string.concat(handlers[h], ": duplicate selector")
                    );
                }
            }
        }
    }

    /**
     * @dev `staticInput.components` describes the tuple a consumer decodes
     *      `staticInput` into. Every member of these structs is a static
     *      32-byte word, so the component count must match the encoded width.
     *      Catches a components list that has drifted from the struct.
     */
    function test_descriptor_ComponentCountMatchesEncodedWidth() public {
        TradeAboveThreshold.Data memory tatData;
        _assertComponentWidth("TradeAboveThreshold", abi.encode(tatData).length);

        TWAPOrder.Data memory twapData;
        _assertComponentWidth("TWAP", abi.encode(twapData).length);
    }

    function _assertComponentWidth(string memory handler, uint256 encodedLength) private {
        uint256 n = _componentCount(_doc(handler));
        assertGt(n, 0, "no components declared");
        assertEq(n * 32, encodedLength, string.concat(handler, ": component count vs encoded width"));
    }

    /**
     * @dev Counted by probing indices: this `forge` rejects the `[*]` wildcard,
     *      and the component objects cannot be decoded into a struct because
     *      `type` is a reserved word in Solidity. Probing also asserts, in
     *      passing, that every component carries a `name`.
     */
    function _componentCount(string memory doc) private returns (uint256 n) {
        for (uint256 i = 0; i < 64; i++) {
            string memory path = string.concat("$.staticInput.components[", vm.toString(i), "].name");
            try vm.parseJsonString(doc, path) returns (string memory) {
                n++;
            } catch {
                return n;
            }
        }
        revert("component count exceeded probe bound");
    }

    /**
     * @dev The divergence check `docs/discovery.md` 1.3 asks consumers to run,
     *      applied to ourselves: provoke a real verdict and require that the
     *      selector it carries is documented. A descriptor missing an error the
     *      handler actually returns leaves a consumer with an unlabelled code
     *      at exactly the moment it needs one.
     */
    function test_descriptor_ObservedReasonCodeIsDocumented() public {
        TradeAboveThreshold.Data memory o = TradeAboveThreshold.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            validityBucketSeconds: 15 minutes,
            threshold: 200e18,
            appData: keccak256("TradeAboveThreshold")
        });
        deal(address(o.sellToken), address(safe1), o.threshold - 1);

        IConditionalOrderGenerator.GeneratorResult memory result =
            tat.poll(address(safe1), bytes32(0), abi.encode(o), bytes(""));

        assertTrue(result.reasonCode != bytes4(0), "expected a reason code");

        string[] memory keys = _errorKeys(_doc("TradeAboveThreshold"));
        bool documented;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(_hex4(result.reasonCode)))) documented = true;
        }
        assertTrue(documented, "observed reason code is absent from the descriptor");
    }
}
