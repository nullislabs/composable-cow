# Order discovery specification

Version: 1 (draft)

This document specifies how off-chain consumers discover and interpret
conditional orders without prior knowledge of their handlers. It covers three
surfaces:

1. **Handler descriptors** (`IOrderDescriptor`) — declarative metadata for
   decoding and rendering a handler's orders.
2. **Order modules** (`IOrderModule`) — executable extensions that let an
   off-chain monitoring service support handlers whose orders require
   constructed `offchainInput`, including handler-specific off-chain data.
3. **Proof payload URIs** — merkle-root payload locations expressed in the
   same URI format as every other discovery surface, plus the payload document
   that lets a consumer enumerate every published sub-order of a root.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as
described in RFC 2119.

## Design principles

- **The chain is the sole authority.** Every economically material field of an
  order (tokens, amounts, receiver, kind, validity) is derived from
  `generateOrder` / `tryGenerateOrder` / `IOrderManifest`, never from metadata.
  Descriptors and modules are presentation and tooling hints. A consumer that
  renders or signs from metadata instead of chain-derived data is broken.
- **Polling verdicts are 100 % on-chain.** A monitoring service needs nothing
  in this document to poll correctly with empty `offchainInput`: `poll()`
  verdicts, `getNextPollTimestamp`, `tryGenerateOrder`, and manifest pages are
  self-describing. Modules extend service coverage to handlers that require
  constructed `offchainInput`; they never mediate verdicts, which always come
  from the chain.
- **Executable code is pulled only against an on-chain commitment.** Module
  bytes MUST verify against `moduleCommitment()` before execution. The
  commitment is a root in a named addressing packaging (§0), so verification uses
  that packaging's own primitives rather than a separate hash over the fetched
  bytes. Verified modules MAY be fetched and executed automatically, but only
  inside the sandbox and budget regime of §2.
- **Feature detection, never gating.** Every interface here is a sidecar with
  its own ERC-165 id, detected independently, absent without penalty, and never
  on the settlement path.
- **One commitment format everywhere.** Descriptors and modules are committed
  to identically: a `(digest, kind)` pair under §0, verified by the addressing
  scheme's own primitives. What differs per surface is only the structure the
  commitment resolves to: a descriptor resolves to one JSON document, a module
  to a package. Proof payloads are the exception and verify by recomputing the
  merkle root, since they are authored per root rather than published once.
- **Content addressing locates as well as verifies.** A `BZZ_MANIFEST`
  commitment already names where the bytes live, so a handler publishes no URI
  and no gateway is written into a deployed contract. Retrieval is the host's
  concern. URIs exist for `SHA256`, where the digest locates nothing.
- **Fail closed.** Unknown URI schemes, unsupported or reverting views, and
  unverifiable documents are treated as "no discovery", never as errors to
  retry aggressively and never as data to trust.

## 0. Commitments

Descriptors (§1) and modules (§2) are both committed to on-chain as a
`(bytes32 digest, PackageKind kind)` pair. `kind` names how the digest is
computed, and therefore how it is verified. What the committed bytes *are* is
fixed per surface rather than by the kind: a module commits to a `.tar.zst`
package, a descriptor to its JSON document.

```solidity
enum PackageKind {
    BZZ_MANIFEST, // Swarm BMT root
    SHA256        // sha256 over the published bytes
}
```

The two kinds trade the same two properties against each other, and a
publisher picks which one it wants:

| | `BZZ_MANIFEST` | `SHA256` |
|---|---|---|
| locates itself | yes, the root is the Swarm reference | no, a URI is required |
| verification | per entry, from BMT roots in the manifest | whole archive, in one pass |
| partial fetch | yes, read `nexum.toml` before the component | no |
| mirrors | Swarm only | bzz, ipfs, https, anywhere |

The asymmetry is structural rather than a preference. A mantaray root is a
hash over a *structure*, so only Swarm can recompute it; that is exactly what
buys per-entry verification and costs cross-scheme mirroring. A `SHA256`
digest is a hash over *bytes*, so any transport can be checked by hashing what
it delivered, at the cost of verifying nothing until the whole archive is in
hand.

Neither kind requires a canonical byte serialisation to be specified. Mantaray
already defines a deterministic structure, and an archive is committed to as
the exact bytes published.

### 0.1 Location

`BZZ_MANIFEST` is content-addressed: the commitment names the bytes, so it also
locates them. Its URI list MUST be empty, and implementations reject a
commitment that carries one. A URI here would not merely be redundant: a
gateway serves resolved file content rather than chunks, so bytes fetched from
one cannot be checked against a structure root at all. Publishing one would
write a gateway into a deployed contract in exchange for nothing.

`SHA256` is not self-locating. Its URI list MUST be non-empty. Any scheme may
appear there, including `ipfs://`, which verifies its own content in transit
but whose CID is not the commitment: a UnixFS CID depends on chunker and DAG
layout, which are publisher settings rather than properties of the content, so
it cannot be recomputed from bytes fetched elsewhere.

A `bytes32(0)` digest is uncommitted. Consumers MUST treat the surface as
absent rather than fetching anything.

### 0.2 Verification

`BZZ_MANIFEST`: resolve the root, then verify each entry against the BMT root
the manifest carries for it. A single document (a descriptor) is committed to
as a leaf rather than a manifest.

`SHA256`: fetch the bytes from any URI and verify their `sha256` equals the
digest. For a descriptor those bytes are the document and verification ends
there. For a module they are the `.tar.zst` package, which is then extracted;
verifying the archive authenticates every byte in it, so
no per-entry digest is declared anywhere. Restating entry digests inside the
package would create a second source of truth and a disagreement to specify
around, without adding a check.

Extraction is the attack surface an archive brings and a manifest does not.
Consumers MUST, before writing anything:

- reject duplicate entry paths, which is where archive parsers disagree;
- reject absolute paths, `..` traversal, and symlinks;
- cap entry count and total decompressed size, refusing the package rather
  than expanding it.

### 0.3 Compression

This concerns module packages; a descriptor is a single document and is
published as-is. Each container compresses at the level it can, so the
component is stored differently in each while `nexum.toml` stays
byte-identical across both:

- `SHA256`: entries are stored uncompressed; the archive compresses them.
- `BZZ_MANIFEST`: mantaray has no archive-level compression, so the component
  is stored zstd-compressed at `<component>.zst`, which is worth doing on a
  network that charges per chunk. `nexum.toml` is stored uncompressed: it is
  small, and a consumer reads and verifies it before deciding whether to fetch
  the component at all.

The decompressed-size cap of §0.2 applies to both.

## 1. Handler descriptors

### 1.1 Interface

```solidity
interface IOrderDescriptor {
    /**
     * @notice Emitted when the descriptor location or commitment changes.
     * @dev MUST be emitted from the constructor of implementing contracts so
     *      indexers discover the descriptor without polling.
     */
    event DescriptorUpdate(string[] uris, bytes32 digest, PackageKind kind);

    /**
     * @notice Locations of the handler descriptor document.
     * @dev Empty for `BZZ_MANIFEST`, which the commitment locates. Required
     *      for `SHA256`. Any URI listed is a hint: all MUST resolve to the
     *      same document bytes, never alternative content.
     */
    function descriptorURI() external view returns (string[] memory uris);

    /**
     * @notice Commitment to the descriptor document.
     * @dev `digest` is the document root in `kind`'s addressing. Consumers
     *      MUST verify fetched bytes against it before parsing.
     *      `bytes32(0)` means uncommitted; treat the descriptor as absent.
     */
    function descriptorCommitment()
        external
        view
        returns (bytes32 digest, PackageKind kind);
}
```

- The interface is intentionally read-only. Implementations that support
  rotation expose their own access-controlled setter and MUST emit
  `DescriptorUpdate` on every change. Immutable implementations have no setter
  and emit exactly once, from the constructor. Consumers detect mutability
  behaviorally: any `DescriptorUpdate` after the constructor event SHOULD be
  treated as a trust downgrade.
- The descriptor is contract-level. A handler is a type; individual orders are
  rendered client-side from the descriptor's `staticInput` schema, ABI
  decoding, and `describeOrder`.
- `BaseConditionalOrder` does not implement this interface; concrete handlers
  opt in. Advertising the interface while returning empty values is
  non-conformant.

### 1.2 URI policy

Integrity comes from the commitment (§0), never from the URI, so this policy
governs retrieval only. Where a URI is used it MUST be one of:

| Scheme | Used with |
|---|---|
| `bzz://` | `BZZ_MANIFEST`, as a hint; the commitment already locates the document |
| `ipfs://` | `SHA256`, as a location; the CID is not the commitment |
| `data:` | either kind, for a document published in-band |
| `https:` | `SHA256`, the common case |

`http:`, `file:`, and any URI resolving to loopback, link-local, or private
address ranges are prohibited. Fetchers SHOULD disable redirects (or re-validate
every hop against this policy), enforce a size cap (256 KiB RECOMMENDED), and
enforce a total timeout.

An `https:` URI is never trusted on its own: bytes fetched from one are used
only after they verify against the commitment, which for `SHA256` is the whole
of the integrity argument.

### 1.3 Document

The descriptor document is JSON, validated against the descriptor-v1 JSON
Schema (draft 2020-12), which lives at `descriptors/schema/descriptor-v1.json`.
Producers MUST serialize with RFC 8785 (JSON Canonicalization Scheme); the
digest commits to the exact published bytes, and consumers verify bytes before
parsing.

The schema's `$id` is a stable identifier, not a content address: a digest over
the schema cannot be embedded in the schema it describes. Publishing at a
content-addressed location is fine; the address is carried by whatever
references the schema, never inside it.

```json
{
  "version": "1",
  "name": "TWAP",
  "description": "Sells a fixed amount in n equal parts at a fixed interval.",
  "staticInput": { "components": [ { "name": "sellToken", "type": "address" } ] },
  "offchainInput": { "required": false },
  "display": { "summary": "TWAP: sell {{partSellAmount|amount(sellToken)}} × {{n}} every {{t|duration}}" },
  "errors": { "0x…": { "name": "BeforeTwapStart", "label": "Not started yet" } },
  "links": { "source": "…" },
  "extensions": {}
}
```

Field notes (normative semantics; full schema separate):

- `staticInput.components` is a JSON-ABI components fragment — the decoded
  shape of the handler's `staticInput` bytes, with field names.
- `offchainInput.required`: when `true`, orders need constructed
  `offchainInput`. Module discovery is on-chain (`IOrderModule` via ERC-165,
  §2), independent of this field; `required == true` without a module means
  only operator-specific tooling can service the handler.
- `errors` maps reason selectors (`bytes4`, as carried in `reasonCode`) to
  names and optional human labels. Names for open-source handlers are
  derivable from the verified ABI; this map serves closed-source handlers and
  display labels.

  Reason errors MUST be nullary. A handler raises one by passing `X.selector`
  to a framework wrapper whose payload is `bytes4`, so the error is a tag and
  is never constructed; parameters would be dropped at the raise site and
  could not be recovered from `poll`, `getManifestPage` or `tryGenerateOrder`.
  Structured data travels in the wrapper instead, as `waitUntil` does.
- `display` templates are data (mustache-style with a small filter set),
  never code.
- The document carries no handler identity, neither address nor chain. Binding
  comes from resolution: a document is a contract's descriptor when it hashes
  to the digest that contract's `descriptorCommitment()` returns.

  The digest is a constructor argument, so under CREATE2 it is part of the
  initcode that determines the address; a document naming its own address would
  depend on a digest that depends on the address. Every field above is
  chain-independent, so one publication serves every deployment on every chain.

Consumers SHOULD run a divergence check before presenting descriptor-derived
summaries: derive the actual order via `tryGenerateOrder`, compare material
fields, and surface any mismatch prominently. A descriptor that contradicts
observed behavior is a red flag, not a reconciliation problem.

### 1.4 Generation

Descriptors are derived, not hand-written:

- `staticInput.components` from the build artifact AST (the struct never
  crosses an external ABI boundary);
- `errors` from the build artifact AST as well, not the ABI: a reason error
  declared at file scope is omitted from the contract ABI, and only the
  framework wrappers (`OrderNotValid`, `PollTry*`) appear there. Reason errors
  are those referenced as `X.selector` across the handler's transitive import
  closure, which also captures errors raised inside libraries;
- `offchainInput.required` from whether `generateOrder` reads its
  `offchainInput` parameter, not from whether the handler declares
  `PollNeedsOffchainInput`: a handler may consume the input without declaring
  that error;
- a small author overlay supplies `name`, `description`, `display`, `links`,
  and optional error labels;
- nothing is stamped at deployment; the document is a pure function of the
  handler's source and its overlay. Tooling canonicalizes, hashes, publishes,
  and passes `(uris, digest)` to the constructor, and may do so before
  selecting a chain or computing an address.

## 2. Order modules

A handler MAY ship an executable module for consumers that service its orders.
Modules exist to construct `offchainInput` — the only aspect of servicing an
order that cannot be derived on-chain — including when construction requires
handler-specific off-chain data (external APIs, signed quotes, orderbook
state). Responsibility for such data sits solely with the handler/module pair;
a monitoring service never needs handler-specific knowledge beyond what the
module encapsulates.

A handler that cannot generate without `offchainInput` signals it at the
verdict layer: it reverts `PollNeedsOffchainInput(bytes4 reasonCode)`, which
decodes to the `NEEDS_INPUT` verdict — semantically "empty-input polling is
futile; acquire input or park", never a timed retry. This is the module
discovery trigger: consumers seeing `NEEDS_INPUT` probe `IOrderModule` via
ERC-165. Consumers MUST NOT schedule empty-input re-polls of a `NEEDS_INPUT`
order.

### 2.1 Interface

```solidity
interface IOrderModule {
    /**
     * @notice Emitted when the module location or commitment changes.
     * @dev MUST be emitted from the constructor of implementing contracts.
     */
    event ModuleUpdate(string[] uris, bytes32 digest, PackageKind kind);

    /**
     * @notice Locations of the module package.
     * @dev Empty for `BZZ_MANIFEST`, which the commitment locates. Required
     *      for `SHA256`. Any URI listed is a hint.
     */
    function moduleURI() external view returns (string[] memory uris);

    /**
     * @notice Commitment to the module package. `digest` MUST be non-zero.
     * @dev The package root in `kind`'s addressing, and the module's
     *      canonical identity: consent lists, caches, and budgets key by it,
     *      so changing where a package is mirrored never invalidates operator
     *      trust in the same code. Consumers MUST verify the package against
     *      it before execution and MUST NOT serve cached bytes against any
     *      other key.
     */
    function moduleCommitment()
        external
        view
        returns (bytes32 digest, PackageKind kind);
}
```

- Sidecar with its own ERC-165 id, detected independently of
  `IOrderDescriptor`: a module without presentation metadata is valid, and
  vice versa.
- A zero digest is non-conformant; consumers MUST refuse to execute
  unverifiable bytes. This is the gate: no module runs whose package does not
  resolve from the on-chain commitment.
- Mutability by omission, as for descriptors: no setter in the interface;
  immutable implementations emit `ModuleUpdate` once from the constructor;
  post-constructor updates are a trust signal consumers MAY act on.

### 2.2 Execution model

Monitoring services MAY fetch and execute digest-verified modules
automatically. The safety argument is structural: **module output is untrusted
input to on-chain verification.** Constructed `offchainInput` feeds
`generateOrder`/`poll`, and the settlement path re-verifies everything a
module could influence — a lying module can only fail to produce serviceable
orders, never cause an unauthorized order to validate. The residual risks are
host compromise and resource burn, addressed by the following requirements,
which are MUSTs for any automatic execution:

- **No ambient authority**: a module is a WebAssembly component and reaches
  the outside world only through what its world imports (§2.3). No filesystem,
  no environment, no keys, no arbitrary network — not as a host promise, but
  because those interfaces are absent from the world it is instantiated in.
  What remains is chain access, an outbound HTTP client the host restricts to
  the origins the package declares, and logging.
- **Authenticated capability grant**: the origin allowlist lives inside the
  package, and the package root is the on-chain commitment (§0). A host
  therefore cannot be handed a wider grant than the handler author committed
  to, and an operator can audit the grant from chain state alone.
- **Budgets**: hard CPU/wall-clock/memory limits per invocation; a module that
  exceeds them is parked per handler under the same bounded-retry policy as
  unavailable payloads, never hot-retried.
- **Idempotence, not determinism**: a module MAY fetch, so repeated calls with
  identical input MAY return different bytes. What is required is that
  `build-offchain-input` has no observable side effects and is safe to call
  any number of times with results discarded. Determinism is neither achievable
  nor needed, because output is verified on-chain rather than trusted.
- **Output distrust**: the host treats returned `offchainInput` as opaque
  candidate bytes for on-chain calls — never as truth about the order.

Frontends executing modules additionally broker all signature requests through
the host UI, which displays the chain-derived order, never the module's
claims.

### 2.3 Module contract (v1)

A module is a WebAssembly component (WASI Preview 2). This specification
normatively defines the **portability core**: what a module MUST export,
below. What a module MAY import — the host surface, capability grants, and
resource budgets — is the *environment*, defined by `videre:ccow` and
delegated to the host that implements it. **shepherd** is the reference
monitoring service; other hosts implementing the same world inherit module
compatibility.

The split is deliberate. The export contract is versioned alongside
`IOrderModule`, because `moduleCommitment()` and the WIT are two halves of one
agreement: the chain says a module exists, and the WIT says what a module is.
The import surface versions with the runtime instead.

#### Portability core

```wit
package ccow:module@1.0.0;

interface order-module {
  /// 20 bytes.
  type address = list<u8>;
  /// 32 bytes.
  type word = list<u8>;

  record params { handler: address, salt: word, static-input: list<u8> }

  /// The order, plus the block the host will evaluate the resulting
  /// `offchainInput` against.
  record poll {
    chain-id: u64,
    block-number: u64,
    owner: address,
    /// Zero word when the order is authorised by merkle root.
    ctx: word,
    params: params,
  }

  record not-ready {
    reason: string,
    /// Suggested wait before retrying. Absent leaves cadence to the host.
    retry-after-ms: option<u64>,
  }

  variant outcome {
    /// The `offchainInput` bytes. Empty is valid and common.
    ready(list<u8>),
    /// No input at this block; the order stays live.
    not-ready(not-ready),
    /// This module can never service this order. The host stops asking.
    unserviceable(string),
  }

  build-offchain-input: func(req: poll) -> result<outcome, string>;
}
```

`outcome` mirrors the on-chain verdict trichotomy — postable, wait, terminal —
so a handler author meets no new vocabulary. Not being ready is an outcome
rather than an error, exactly as a `WAIT` verdict is not a revert. The error
case is a log string: every host-actionable state is already in `outcome`, and
every structured host failure (rate limiting, a denied origin, a timeout) is
observed first-hand by the host at the call it mediated, so a module echoing
one back adds nothing.

#### Environment

```wit
package videre:ccow@0.1.0;

world order-module {
  use nexum:host/types@0.2.0.{config, host-error};

  import nexum:host/chain@0.2.0;
  import nexum:host/http@0.2.0;
  import nexum:host/logging@0.2.0;

  export init: func(config: config) -> result<_, host-error>;
  export ccow:module/order-module@1.0.0;
}
```

Deliberately absent: `local-store`, `messaging`, `identity`, `remote-store`.
Persistent state would let two invocations with identical input diverge, which
is the idempotence requirement of §2.2; leaving the interface out makes that
structural instead of a rule to enforce.

#### Package

The commitment resolves to a package with the same logical layout under either
kind, differing only in how the component is stored (§0.3):

```
nexum.toml        # uncompressed under both kinds
component.wasm    # stored as component.wasm.zst under BZZ_MANIFEST
```

```toml
[module]
name = "twap-oracle"
version = "1.0.0"
world = "videre:ccow/order-module@0.1.0"
component = "component.wasm"

[capabilities]
required = ["chain", "http", "logging"]

[capabilities.http]
allow = ["https://api.example.com"]

[config]
pair = "WETH/USDC"
```

- `[capabilities.http].allow` is the complete set of origins the module may
  contact; the host grants exactly that and nothing else. Absent or empty
  means chain-state only.
- `world` lets a host reject a component built against the wrong world before
  linking, rather than failing on a missing import.
- `[config]` is passed verbatim to `init`. A module that cannot run with the
  configuration it is given MUST fail there, not per poll.
- `component` names the logical artifact, not the stored entry, so this file
  is byte-identical whichever kind a publisher chooses.
- No file digests are declared. §0.2 covers why: the commitment already
  authenticates every entry.

#### Execution

1. Resolve the commitment (§0.1) and verify it (§0.2), applying the extraction
   rules for `SHA256`.
2. Read `nexum.toml`. Under `BZZ_MANIFEST` this is one entry, verified and
   parsed before the component is fetched at all; under `SHA256` the whole
   archive is already in hand.
3. Fetch the component, decompressing it under `BZZ_MANIFEST` (§0.3), and
   instantiate it in the `videre:ccow/order-module` world with HTTP restricted
   to `[capabilities.http].allow`.
4. `init` with `[config]`. A failure here parks the handler; it is a
   packaging fault, not a transient one.
5. `build-offchain-input` per poll, dispatching on `outcome`: `ready` supplies
   `offchainInput` to `getTradeableOrderWithSignature`; `not-ready` parks the
   order for `retry-after-ms`; `unserviceable` stops polling that handler.

Constructed `offchainInput` is used exclusively as input to on-chain calls
(`poll` / `getTradeableOrderWithSignature`) — never for display, never for
scheduling beyond the returned verdict.

## 3. Proof payload URIs and the merkle payload

### 3.1 Location as URIs

`ComposableCow.setRoot` takes the payload location as URI mirrors, replacing
the numeric location registry of the upstream design:

```solidity
struct Proof {
    /// @dev Mirrors for the payload document; all URIs MUST reference the
    ///      same bytes. URIs are never interpreted on-chain.
    string[] uris;
    /// @dev EIP-4844 versioned hashes of the blobs carrying the payload
    ///      document (split convention in §3.2). For every listed hash,
    ///      `setRoot` verifies via `blobhash()` that the blob is attached to
    ///      this transaction. Empty: no blob publication.
    bytes32[] blobVersionedHashes;
}
```

Private (no discovery expected, consumers MUST NOT retry) is expressed as
empty `uris` and empty `blobVersionedHashes`.

- All mirrors carry identical payload bytes; a consumer MAY fetch from any of
  them and MUST verify by recomputing the root (§3.3) regardless of source.
  Because the payload is self-verifying against the on-chain root, no digest
  accompanies these URIs — transport integrity is immaterial.
- Unknown schemes are skipped (fail closed per mirror); a root whose mirrors
  are all unknown or unavailable is parked under the bounded-retry policy.
- Scheme guidance:

| Scheme | Notes | Availability |
|---|---|---|
| `bzz://` | 64-hex reference (or 128-hex encrypted) | best-effort |
| `ipfs://` | CIDv1 | best-effort |
| `ni:` (RFC 6920) | `.well-known/ni/` HTTPS mapping applies | best-effort |
| `https:` | safe here without a digest — the root is the integrity anchor; SSRF policy of §1.2 applies | best-effort |
| `data:` | in-band payload (the successor of the upstream `EMITTED` location); SHOULD only be used for small trees — calldata and log cost make it self-limiting | on-chain |

- Publishers SHOULD pair a guaranteed-publication channel (blobs or `data:`)
  with a content-addressed mirror (`bzz://`, `ipfs://`) for late consumers —
  a combination the upstream single-location design could not express.

### 3.2 Blob publication

A non-empty `blobVersionedHashes` binds publication to authorization:
`setRoot` requires (via the `BLOBHASH` opcode, typed error `BlobNotAttached`)
that **every** listed blob is attached to the transaction setting the root.
The root cannot be set without the payload being published in the same
transaction. The hashes are dedicated `bytes32` values — never URIs — so
verification involves no on-chain string interpretation; `uris` are opaque to
the contract.

Multi-blob split convention: the payload document's field-element streams are
decoded per blob (31 bytes per field element) and concatenated in array
order; a single byte-length prefix lives in the first field element of the
first blob. One blob carries ~126.9 KiB usable (≈ 800 leaves); the array
lifts the guaranteed channel to multi-blob transactions (≈ 4,800 leaves at
six blobs).

Retention advisory: blobs guarantee *publication*, not permanent retrieval
(consensus retention ≈ 4096 epochs / 18 days). Whether any order under a
root can outlive the window is not mechanically checkable, so this is
guidance, not prohibition: publishers of trees that may outlive retention
SHOULD pair a retention-independent mirror; consumers surface
blob-expired-and-unmirrored roots as an operator alert, never a silent
failure.

- `blobhash()` observes the transaction's blobs from any call depth, so an
  inner Safe call conforms when the executing EOA sends a type-3 transaction
  carrying the blob.
- Blob payload packing: canonical document bytes at 31 bytes per field
  element, zero-padded, with the byte length in the first field element.
- Blobs guarantee publication, not permanent retrieval: consensus-layer
  retention is bounded (~4096 epochs). Indexers SHOULD capture within the
  window; publishers SHOULD mirror as in §3.1.

### 3.3 Payload document

The payload is the complete leaf set — no proofs. Once all leaves are held,
every inclusion proof is recomputable locally, and completeness is checked by
recomputing the root.

```json
{
  "version": "1",
  "chainId": 100,
  "root": "0x…",
  "leafEncoding": "v1",
  "leaves": [
    { "handler": "0x…", "salt": "0x…", "staticInput": "0x…" }
  ]
}
```

- `leafEncoding: "v1"` pins the full tree construction, byte-exact against
  `_auth`: the leaf is hashed **twice**,
  `leaf = keccak256(keccak256(abi.encode(ConditionalOrderParams)))`, matching
  `keccak256(bytes.concat(hash(params)))` in `_auth`. The second hash is what
  keeps a leaf preimage from ever being 64 bytes, which is what would otherwise
  let an internal node be presented as a leaf. The tree is then built bottom-up
  over the ascending-sorted leaf array; each internal node is
  `keccak256(sorted-pair(a, b))`; an odd trailing node at any level is promoted
  unchanged to the next level.
- Sorted-pair hashing alone does not determine tree shape, so implementations
  MUST follow this construction. OpenZeppelin's `StandardMerkleTree` hashes
  leaves twice as this does, but still does not produce this tree, and Solady's
  `MerkleTreeLib` builds a complete `2n-1` node tree that diverges wherever the
  odd-promotion rule fires, such as at 5, 7 or 9 leaves. The mismatch is silent
  under verification: `MerkleProofLib.verify` is sorted-pair and therefore
  shape-agnostic, so a non-conforming tree still verifies against its own root,
  and the divergence surfaces only when a consumer recomputes `root` from
  `leaves`. A wrong leaf encoding fails harder and sooner, with `_auth`
  rejecting every proof outright. Reference test vectors are published
  alongside the contracts.
- `leaves` MUST be sorted ascending by leaf hash and deduplicated; consumers
  MUST reject on the first out-of-order or duplicate leaf.
- Producers MUST serialize with RFC 8785; content addresses and digests commit
  to exact bytes.
- Consumers MUST verify `root` recomputes from `leaves` before use; a mismatch
  rejects the whole payload. Consumers SHOULD enforce a leaf-count/byte cap
  and abort oversized payloads before hashing.
- **Soundness is trustless; completeness is cooperative.** Recomputation proves
  every published leaf is under the root; it cannot prove no leaf was
  withheld. Consumers MUST present enumeration results as "orders published
  for this root", never as the complete set.
- The `ctx` for merkle-authorized orders derives from the root slot written by
  `_setRoot` (zero slot by default; the `setRootWithContext` value otherwise),
  identically for every leaf under the root.
- `setRoot(bytes32(0), …)` is an explicit clear — supersede-to-nothing: a
  zero root can authorize no leaf, so consumers tombstone every order under
  the prior root. The proof MUST be empty on a clear (`ProofDataMalformed`
  otherwise); no distinct event exists — `MerkleRootSet` with a zero root is
  the clear signal.
- Availability failures (no mirror resolvable) are handled with bounded
  retries and negative caching; a payload unavailable after the retry budget
  parks the root.

Per-leaf discovery composes with the manifest: root → payload → each leaf is a
full `ConditionalOrderParams` → `IOrderManifest` pages enumerate that leaf's
discrete orders.

Handlers whose manifests expose multiple concurrently postable orders either
accept the module-less convention `offchainInput = abi.encode(uint256
manifestIndex)` or are module-requiring (`NEEDS_INPUT`); a manifest page
alone does not tell a consumer how to select among concurrent orders.

## 4. Consumer trust tiers

Monitoring-service policy is a gradient, not a binary:

1. **Curated allowlist** — full service; operators MAY relax sandbox budgets
   for modules they have audited. Allowlists key by the commitment digest,
   which is why it is a single canonical value rather than one per mirror: an
   audit of a module covers it wherever it is fetched from.
2. **Discovered, commitment-verified** — `moduleCommitment()` and
   `descriptorCommitment()` resolve and verify per §0.2: poll, post, display,
   and automatic module execution under the full §2.2 sandbox and budget
   regime.
3. **Bare probe** — ERC-165 advertises the generator interface;
   `tryGenerateOrder(owner, params, "")` is the black-box serviceability
   test. Typed verdicts with real reason selectors: poll at low priority with
   rate limits. Garbage reverts, zero reason codes, or gas-bomb behavior:
   park. No module (or an unverifiable one) means empty-`offchainInput`
   probing only. This tier is what makes permissionless handler deployment
   serviceable.

Discovery views MUST be gas-bounded (paginated where unbounded); consumers set
an `eth_call` gas cap and treat reverts and out-of-gas as "unsupported", never
as fatal.
