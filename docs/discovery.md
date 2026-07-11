# Order discovery specification

Version: 1 (draft)

This document specifies how off-chain consumers discover and interpret
conditional orders without prior knowledge of their handlers. It covers three
surfaces:

1. **Handler descriptors** (`IOrderDescriptor`) — declarative metadata for
   decoding and rendering a handler's orders.
2. **Order modules** (`IOrderModule`) — executable extensions that let an
   off-chain monitoring service (the polling agent historically called a
   watch-tower; "monitoring service" hereafter) service handlers whose orders
   require constructed `offchainInput`, including handler-specific off-chain
   data.
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
- **Executable code is pulled only against an on-chain content hash.** Module
  bytes MUST verify against `moduleDigest()` before execution, regardless of
  transport. Digest-verified modules MAY be fetched and executed
  automatically, but only inside the sandbox and budget regime of §2.
- **Feature detection, never gating.** Every interface here is a sidecar with
  its own ERC-165 id, detected independently, absent without penalty, and never
  on the settlement path.
- **One URI format everywhere.** Descriptors, modules, and proof payloads all
  reference off-chain bytes as URIs under a single scheme policy and a single
  hardened fetcher. What differs per surface is only the integrity source:
  descriptor and module bytes verify against an on-chain digest; proof payload
  bytes verify by recomputing the merkle root.
- **Fail closed.** Unknown URI schemes, unsupported or reverting views, and
  unverifiable documents are treated as "no discovery", never as errors to
  retry aggressively and never as data to trust.

## 1. Handler descriptors

### 1.1 Interface

```solidity
interface IOrderDescriptor {
    /**
     * @notice Emitted when the descriptor location or commitment changes.
     * @dev MUST be emitted from the constructor of implementing contracts so
     *      indexers discover the descriptor without polling.
     */
    event DescriptorUpdate(string[] uris, bytes32 digest);

    /**
     * @notice Locations of the handler descriptor document.
     * @dev All URIs MUST reference the same document bytes (redundant
     *      mirrors), never alternative content.
     */
    function descriptorURI() external view returns (string[] memory uris);

    /**
     * @notice keccak256 of the exact descriptor document bytes as published.
     * @dev Consumers MUST verify fetched bytes against this digest before
     *      parsing when the URI is not content-addressed. bytes32(0) means
     *      uncommitted; consumers MUST treat such descriptors as untrusted.
     */
    function descriptorDigest() external view returns (bytes32);
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

Descriptor URIs MUST be one of:

| Scheme | Integrity source |
|---|---|
| `bzz://` | content address |
| `ipfs://` | content address |
| `data:` | in-band |
| `ni:` (RFC 6920) | hash embedded in the URI; `.well-known/ni/` HTTPS mapping applies |
| `https:` | permitted ONLY when `descriptorDigest()` is non-zero |

`http:`, `file:`, and any URI resolving to loopback, link-local, or private
address ranges are prohibited. Fetchers SHOULD disable redirects (or re-validate
every hop against this policy), enforce a size cap (256 KiB RECOMMENDED), and
enforce a total timeout.

### 1.3 Document

The descriptor document is JSON, validated against the published descriptor-v1
JSON Schema (draft 2020-12, content-addressed `$id`; published separately).
Producers MUST serialize with RFC 8785 (JSON Canonicalization Scheme); the
digest commits to the exact published bytes, and consumers verify bytes before
parsing.

```json
{
  "version": "1",
  "name": "TWAP",
  "description": "Sells a fixed amount in n equal parts at a fixed interval.",
  "handler": { "chainId": 100, "address": "0x…" },
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
- `display` templates are data (mustache-style with a small filter set),
  never code.
- `handler.{chainId,address}` MUST match the contract the descriptor was
  resolved from; a mismatch invalidates the document.

Consumers SHOULD run a divergence check before presenting descriptor-derived
summaries: derive the actual order via `tryGenerateOrder`, compare material
fields, and surface any mismatch prominently. A descriptor that contradicts
observed behavior is a red flag, not a reconciliation problem.

### 1.4 Generation

Descriptors are derived, not hand-written:

- `staticInput.components` from the build artifact AST (the struct never
  crosses an external ABI boundary);
- `errors` from the handler ABI (every reason error is a declared error);
- a small author overlay supplies `name`, `description`, `display`, and
  `links`;
- `handler` is stamped at deployment, making the digest per-deployment;
  deploy tooling canonicalizes, hashes, publishes, and passes
  `(uris, digest)` to the constructor.

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
    event ModuleUpdate(string[] uris, bytes32 digest);

    /**
     * @notice Locations of the module. All URIs MUST reference the same bytes.
     */
    function moduleURI() external view returns (string[] memory uris);

    /**
     * @notice keccak256 of the exact module bytes. MUST be non-zero.
     * @dev The module's canonical identity and the final pre-execution gate.
     *      Fetch integrity is per-transport (a Swarm reference, CID, or
     *      RFC 6920 hash verifies the fetch); the digest is what consent
     *      lists, caches, and budgets key by, so mirror rotation never
     *      invalidates operator trust in byte-identical code. Consumers MUST
     *      verify keccak256(bytes) == moduleDigest() before execution and
     *      MUST NOT serve cached bytes against any other key.
     */
    function moduleDigest() external view returns (bytes32);
}
```

- Sidecar with its own ERC-165 id, detected independently of
  `IOrderDescriptor`: a module without presentation metadata is valid, and
  vice versa.
- A zero `moduleDigest` is non-conformant; consumers MUST refuse to execute
  unverifiable bytes. This is the content-hash gate: no module runs whose
  bytes do not match the on-chain commitment.
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

- **Sandbox, no ambient authority**: no filesystem, no environment, no keys,
  no arbitrary network. I/O is limited to
  - a read-only EIP-1193 provider (`eth_call`, `eth_getStorageAt`,
    `eth_blockNumber`), and
  - fetch scoped to the origins the module declares (§2.3), with SSRF policy
    applied (public addresses only, no redirects leaving the declared set,
    size and time caps).
- **Budgets**: hard CPU/wall-clock/memory limits per invocation; a module that
  exceeds them is parked per handler under the same bounded-retry policy as
  unavailable payloads, never hot-retried.
- **Output distrust**: the host treats returned `offchainInput` as opaque
  candidate bytes for on-chain calls — never as truth about the order.

Frontends executing modules additionally broker all signature requests through
the host UI, which displays the chain-derived order, never the module's
claims.

### 2.3 Module contract (v1)

This specification normatively defines only the **portability core** below —
the minimum every module MUST satisfy regardless of which host loads it. The
full runtime interface — host API semantics (provider method set, scoped-fetch
behavior), packaging and loading, concrete resource budgets, optional exports
(e.g. frontend rendering), and the evolution of the module manifest — is
delegated to **shepherd**, the reference off-chain monitoring service, whose
module-interface specification is authoritative and independently versioned.
Modules SHOULD target the shepherd module interface; other hosts implementing
the same interface inherit module compatibility.

The portability core: a single-file ES module, dependencies bundled, no
runtime imports:

```js
export const version = "1";
export const capabilities = { origins: ["https://api.example.com"] };

export async function buildOffchainInput({ chainId, provider, fetch, owner, params, ctx }) {
  // provider: read-only EIP-1193 (eth_call, eth_getStorageAt, eth_blockNumber)
  // fetch: host-supplied, restricted to `capabilities.origins`
  return "0x…"; // offchainInput bytes
}
```

- `capabilities.origins` declares every external origin the module may
  contact; the host grants fetch to exactly that set and nothing else. An
  empty list means chain-state-only.
- `buildOffchainInput` SHOULD be deterministic given a block and the external
  data it fetches; output is best-effort by construction, since verification
  is on-chain.
- Constructed `offchainInput` is used exclusively as input to on-chain calls
  (`poll` / `getTradeableOrderWithSignature`) — never for display, never for
  scheduling beyond the returned verdict.
- Optional exports (e.g. `renderSummary` for frontend rendering) and other
  module types (e.g. wasm) are defined by the shepherd module-interface
  specification, not here.

## 3. Proof payload URIs and the merkle payload

### 3.1 Location as URIs

`ComposableCoW.setRoot` takes the payload location as URI mirrors, replacing
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
  `_auth`: `leaf = keccak256(abi.encode(ConditionalOrderParams))`; the tree is
  built bottom-up over the ascending-sorted leaf array; each internal node is
  `keccak256(sorted-pair(a, b))` (OpenZeppelin `MerkleProof` convention); an
  odd trailing node at any level is promoted unchanged to the next level.
  Sorted-pair hashing alone does not determine tree shape — implementations
  MUST follow this construction (note: OpenZeppelin's `StandardMerkleTree`
  double-hashes leaves and yields different roots; it is NOT this encoding).
  Reference test vectors are published alongside the contracts.
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
   for modules they have audited.
2. **Discovered, digest-verified** — on-chain commitments check out
   (`moduleDigest` for modules, `descriptorDigest`/content address for
   descriptors): poll, post, display, and automatic module execution under
   the full §2.2 sandbox and budget regime.
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
