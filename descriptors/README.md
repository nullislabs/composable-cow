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
| `schema/descriptor-v1.json` | authors | the descriptor-v1 JSON Schema (draft 2020-12) |

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

## These documents carry no handler identity

Neither address nor chain, and that is not a gap waiting on a deployment.

The digest is a constructor argument to `OrderDescriptor`, so it is part of the
initcode that fixes a CREATE2 address. A document naming its own handler address
could never be committed to: the address would depend on a digest that depends on
the address. Chain id is cycle-free but carries nothing, since every field here
is chain-independent, and requiring it would force one publication per chain for
byte-identical content.

Binding comes from resolution instead. A consumer reads `descriptorCommitment()`
from a specific contract and verifies the fetched bytes against that digest, so a
document is that contract's descriptor exactly when it hashes to what the
contract returns. An identity field would restate what the commitment proves.

The upshot is that these documents are complete: one digest per handler version,
publishable now, valid for every deployment on every chain. There are no
deployments yet (see [`../deployments/`](../deployments)), so none has been
published or committed to on-chain.

## Verification

Two layers, neither requiring a JavaScript toolchain.

```sh
dev/gen-descriptors.py --check    # committed bytes match what the pipeline emits
forge test --match-contract DescriptorDoc
nix-shell -p check-jsonschema --run \
  "check-jsonschema --schemafile descriptors/schema/descriptor-v1.json descriptors/*.json"
```

Any draft 2020-12 validator will do; CI uses `check-jsonschema` because it is a
single pipx install and validates the schema against the metaschema too. The
schema is the artefact a third-party consumer needs, since it is what lets them
reject a malformed document without reimplementing the rules in prose.

It also makes one design decision enforceable rather than merely documented: a
document carrying `handler` is rejected outright, so the CREATE2 cycle described
below cannot be reintroduced by accident.

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
