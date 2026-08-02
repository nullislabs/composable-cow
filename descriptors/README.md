# Handler descriptors

Descriptor documents for the conditional order types in `src/types/`, specified
in [`docs/discovery.md`](../docs/discovery.md) §1.

Descriptors are presentation metadata: hints, never authority. Every
economically material fact is derived from the chain.

## Layout

| Path | Written by | Contents |
|------|------------|----------|
| `overlays/<Handler>.json` | authors | `name`, `description`, `display`, `links`, error `labels`, and the generator's pointers (`source`, `staticInputStruct`) |
| `<Handler>.json` | `dev/gen-descriptors.py` | the descriptor document, canonical bytes |
| `schema/descriptor-v1.json` | authors | the descriptor-v1 JSON Schema (draft 2020-12) |

The overlay is the only hand-written input. Everything else is derived from
compiler output.

## Generation

```sh
forge build --ast
dev/gen-descriptors.py
```

`--ast` is required. Two facts are unavailable from the ABI:

- `staticInput.components`: the struct never crosses an external ABI boundary,
  so no contract ABI describes its shape.
- `errors`: reason errors are declared at file scope, which solc omits from the
  contract ABI. Only the framework wrappers (`OrderNotValid`, `PollTry*`) reach
  it, and those are not reason codes. Reason errors are those referenced as
  `X.selector` across the handler's transitive import closure, which covers
  errors raised inside libraries such as `TWAPOrder`.

`offchainInput.required` is derived from whether `generateOrder` reads its
`offchainInput` parameter, not from whether the handler declares
`PollNeedsOffchainInput`; a handler may consume the input without declaring it.

## No handler identity

The document carries neither address nor chain id.

The digest is a constructor argument, so it is part of the initcode that fixes a
CREATE2 address; a document naming its own address would depend on a digest that
depends on the address. Chain id is cycle-free but every field here is
chain-independent, so requiring it would force one publication per chain for
byte-identical content.

Binding comes from resolution: a document is a contract's descriptor when it
hashes to the digest that contract's `descriptorCommitment()` returns.

One digest per handler version, valid for every deployment on every chain. There
are no deployments yet (see [`../deployments/`](../deployments)), so none has
been published or committed to on-chain.

## Verification

```sh
dev/gen-descriptors.py --check    # committed bytes match what the pipeline emits
forge test --match-contract DescriptorDoc
nix-shell -p check-jsonschema --run \
  "check-jsonschema --schemafile descriptors/schema/descriptor-v1.json descriptors/*.json"
```

Any draft 2020-12 validator works; CI uses `check-jsonschema`, which also checks
the schema against the metaschema. The schema rejects a document carrying
`handler`.

The Solidity test asserts, against the contracts themselves:

- every `errors` key equals `bytes4(keccak256("<name>()"))`;
- selectors are distinct;
- the component count matches the width of the ABI-encoded struct;
- a provoked verdict's `reasonCode` is present in the descriptor, which is the
  divergence check §1.3 asks consumers to run.

Each assertion was checked against a deliberately corrupted document.

## Canonicalization

Documents are serialized with sorted keys and no insignificant whitespace: RFC
8785 for the subset used here, which is ASCII with no floating point. The
generator rejects anything outside that subset.
