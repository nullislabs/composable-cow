# Handler descriptors

Descriptor documents for the conditional order types in `src/types/`, as
specified in [`docs/discovery.md`](../docs/discovery.md) §1.

A descriptor is presentation metadata: hints, never authority. Every
economically material fact is derived from the chain. A consumer that trusts a
descriptor over observed behaviour has misread the spec.

## Layout

| Path | Written by | Contents |
|------|------------|----------|
| `overlays/<Handler>.json` | authors | `name`, `description`, `display`, `links`, error `labels`, and the pointers the generator needs (`source`, `staticInputStruct`) |
| `<Handler>.json` | `dev/gen-descriptors.py` | the descriptor document, canonical bytes |

The overlay is the only hand-written part. Everything a consumer relies on for
decoding is derived from the compiler output, so it cannot drift from the
contract without the build noticing.

## Generation

```sh
forge build --ast
dev/gen-descriptors.py
```

`--ast` is required: two of the derived facts are not available from the ABI.

- **`staticInput.components`** comes from the AST because the struct never
  crosses an external ABI boundary. `generateOrder` takes `bytes calldata
  staticInput`, so no contract ABI describes its shape.
- **`errors`** comes from the AST because every reason error in this codebase is
  declared at file scope, where solc omits it from the contract ABI. The only
  errors that do reach the ABI are the framework wrappers (`OrderNotValid`,
  `PollTry*`), and those are not reason codes. Reason errors are identified as
  those referenced as `X.selector`, across the handler's transitive import
  closure, which is what picks up errors raised inside libraries such as
  `TWAPOrder`.

`offchainInput.required` is derived from whether `generateOrder` actually reads
its `offchainInput` parameter, not from whether the handler declares
`PollNeedsOffchainInput`. A handler can consume the input without declaring that
error, and one here does.

## These documents are not publishable as-is

`handler.{chainId,address}` is absent. It is stamped at deployment, which is what
makes the digest per-deployment (§1.4). Deploy tooling stamps it, canonicalizes,
hashes, publishes, and passes `(uris, digest)` to the constructor. Until then
these are the deployment-independent portion, and a consumer that fetched one
would correctly reject it: §1.3 requires `handler` to match the contract the
descriptor was resolved from.

There are no deployments (see [`../deployments/`](../deployments)), so no
descriptor in this repository has been published or committed to on-chain.

## Verification

Two layers, neither requiring a JavaScript toolchain.

```sh
dev/gen-descriptors.py --check    # committed bytes match what the pipeline emits
forge test --match-contract DescriptorDoc
```

The `--check` mode catches hand-edits and staleness. The Solidity test checks the
documents against the contracts they describe:

- every `errors` key equals `bytes4(keccak256("<name>()"))`, so a key and its
  name cannot disagree;
- selectors are distinct, since a duplicate silently drops an entry;
- the component count matches the width of the ABI-encoded struct;
- a provoked verdict's `reasonCode` is present in the descriptor. This is the
  divergence check §1.3 asks consumers to run, applied to ourselves.

Each assertion has been checked against a deliberately corrupted document, so
the suite fails when the descriptors are wrong rather than passing either way.

## Canonicalization

Documents are serialized with sorted keys and no insignificant whitespace, which
is RFC 8785 for the subset used here: ASCII, no floating point. The generator
refuses anything outside that subset rather than emitting bytes it cannot
canonicalize. There is no published descriptor-v1 JSON Schema to validate
against yet; §1.3 expects one separately.
