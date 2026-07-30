# Solidity style

Conventions that are not already enforced by `forge fmt`.

## NatSpec

Use the block form for every declaration-level doc comment:

```solidity
/**
 * @title Order Descriptor
 * @author mfw78 <mfw78@nxm.rs>
 * @dev Sidecar interface with its own ERC-165 id, feature-detected
 *      independently and never on the settlement path.
 */
interface IOrderDescriptor {
    /**
     * @notice Locations of the handler descriptor document.
     */
    function descriptorURI() external view returns (string[] memory uris);
}
```

Rules:

- `/** */` for anything solc treats as NatSpec: contracts, interfaces,
  libraries, functions, events, errors, structs, enums, and public or external
  state variables. This holds even when the comment carries a single tag.
- `///` is not used. Mixing the two forms, sometimes within one file, was the
  inconsistency this rule removes.
- Wrapped tag text is indented to align under the tag it continues.
- Comments inside a function body are not NatSpec: solc ignores doc tags there.
  Write them as `//` or `/* */` and do not tag them.

## Naming

- Contracts, interfaces, and libraries use CapWords without internal
  capitalisation carried over from branding, so `ComposableCow`, not
  `ComposableCoW`. The `CoW Protocol` spelling is retained in prose and in
  vendored upstream identifiers such as `GPv2Settlement` and `CoWSettlement`.
