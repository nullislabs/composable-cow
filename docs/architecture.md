# Composable CoW Architecture

## Overview

Composable CoW is a framework for creating conditional orders on CoW Protocol. It enables any wallet capable of ERC-1271 signatures to define orders that become tradeable when specific conditions are met (price thresholds, time windows, balance triggers, and so forth).

ERC-1271 is the standard for smart contract signature verification, allowing contracts to validate signatures on behalf of their owners. This includes Safe wallets, Argent, Sequence, and other smart contract wallets.

The architecture separates two distinct execution paths:

1. **Settlement Path** — on-chain verification during trade execution (gas-sensitive).
2. **Polling Path** — off-chain queries by watch-towers (gas-irrelevant).

This separation ensures settlement remains gas-efficient while providing rich metadata for off-chain infrastructure.

## Design Principles

1. **Single source of truth**: `generateOrder()` contains all order generation logic.
2. **Lean settlement**: No metadata structs; only constant string errors for debugging.
3. **Rich polling**: Structured results with scheduling hints for watch-towers.
4. **Verdict and fill state are orthogonal**: handlers produce a *verdict* (`GeneratorResult`); observed fill state is composed by the registry, never by a handler.
5. **No code duplication**: Polling wraps the same core logic used by settlement.
6. **Handler purity**: handlers are pure functions of their explicit arguments (`owner`, `sender`, `ctx`, `staticInput`, `offchainInput`) and must not branch on `msg.sender`. Off-chain simulation soundness depends on this.

## Interface Hierarchy

```
IConditionalOrder
├── Errors (bytes4 reasonCode: the selector of a handler-declared error)
│   ├── OrderNotValid(bytes4 reasonCode)
│   ├── PollTryNextBlock(bytes4 reasonCode)
│   ├── PollTryAtTimestamp(uint256 timestamp, bytes4 reasonCode)
│   └── PollTryAtBlock(uint256 blockNumber, bytes4 reasonCode)
├── ConditionalOrderParams struct
├── generateOrder() - core order generation
└── verify() - settlement validation

IConditionalOrderGenerator : IConditionalOrder, IERC165
├── GeneratorResultCode enum (the handler's verdict)
├── GeneratorResult struct
├── poll() - structured, non-reverting polling
├── tryGenerateOrder() - probe returning full revert data
├── getNextPollTimestamp() - scheduling hints
└── describeOrder() - human-readable status

IOrderManifest (sidecar, own ERC-165 id)
├── Cardinality enum (EXACT, CAPPED, UNBOUNDED)
├── ManifestInfo struct (cardinality, totalOrders)
├── ManifestEntry struct (index, order, validFrom, isActive)
├── getManifestInfo() - order cardinality info
└── getManifestPage() - paginated order enumeration
```

The registry-facing polling types live on `ComposableCoW` itself:

```
ComposableCoW
├── FillStatus enum (NONE, PARTIALLY_FILLED, FILLED, INVALIDATED)
└── PollResult struct (GeneratorResult generator, FillStatus fill, uint256 filledAmount)
```

New capabilities are added as sidecar interfaces with their own ERC-165 ids (as `IOrderManifest` is), never by widening `IConditionalOrderGenerator`: its interface id gates the polling path in `ComposableCoW`, and changing it would reject every deployed handler.

## Execution Paths

### Settlement Path (On-Chain)

```
CoW Settlement
    │
    ▼
Wallet.isValidSignature(hash, signature)    ERC-1271 verification
    │
    ▼
[Wallet-specific routing]                   e.g., Safe's ExtensibleFallbackHandler
    │
    ▼
ComposableCoW.isValidSafeSignature(...)     Signature validation
    │
    ├── _auth()                     Verify merkle proof or single order
    ├── _guardCheck()               Optional swap guard
    │
    └── handler.verify(...)         LEAN PATH
              │
              ▼
        generateOrder()             Core logic, reverts if invalid
              │
              └── hash check        Verify order matches
```

**Note**: The function `isValidSafeSignature` works with any ERC-1271-compatible wallet that routes signature verification to ComposableCoW. The name reflects the original Safe integration, but the interface is wallet-agnostic.

**Gas considerations**:
- Error reasons use constant strings (minimal allocation).
- No polling structs are constructed.
- No polling metadata calls.
- Minimal computation beyond core validation.

### Polling Path (Off-Chain)

```
Watch-Tower
    │
    ▼
ComposableCoW.getTradeableOrderWithSignature(...)
    │
    ├── _auth()                     Verify authorization
    │
    └── _poll()                     ERC-165 gate + handler.poll(...)
              │
              ▼
        try generateOrder()         Same core logic
              │
              ├── Success:
              │   ├── getNextPollTimestamp()
              │   ├── describeOrder()
              │   └── GeneratorResult(POST, order, hints)
              │
              └── Revert:
                  ├── decode error selector
                  └── GeneratorResult(WAIT_* / TRY_NEXT_BLOCK / INVALID, waitUntil, reasonCode)
    │
    ▼ (verdict == POST)
_getFilledAmount()                  Compose the fill overlay from GPv2Settlement
    │
    ├── 0                → fill = NONE
    ├── type(uint).max   → fill = INVALIDATED   (invalidateOrder, not a fill)
    ├── >= totalAmount   → fill = FILLED
    └── otherwise        → fill = PARTIALLY_FILLED
    │
    ▼
signature emitted iff verdict == POST and the order is postable:
    fill == NONE, or
    fill == PARTIALLY_FILLED and order.partiallyFillable
    (after the optional swap guard check)
```

**Characteristics**:
- Returns a structured `PollResult`; never reverts for order conditions (only for authorization and handler-interface failures).
- The handler's verdict and the observed fill state are orthogonal: a `POST` verdict coexists with `PARTIALLY_FILLED`, which is what lets a partially filled `partiallyFillable` order keep being posted until fully filled.
- Includes scheduling hints (`nextPollTimestamp` and `waitUntil`).
- Carries machine-readable reason selectors for debugging; names resolve from the handler ABI.
- If the swap guard restricts the order, the returned verdict is forced to `INVALID` with `reasonCode = SwapGuardRestricted.selector` and no signature is emitted.
- `checkOrder()` returns the same composed `PollResult` through the same `_poll` helper (including the ERC-165 handler gate), without building the signature. The swap guard is not consulted by `checkOrder`; it is enforced at signature build time and during settlement.

## Error Types

There are no stringly errors anywhere on the error surface. The framework errors carry
a `bytes4 reasonCode`: the selector of a custom error the handler declares (e.g.
`error StrikeNotReached();` passed as `StrikeNotReached.selector`). Declared errors are
part of the handler ABI, so any ABI-aware consumer resolves a reasonCode to a name
without a bespoke table, and revert data stays fixed-size:

| Error | Meaning | Watch-tower Action |
|-------|---------|-------------------|
| `OrderNotValid(bytes4)` | Permanent failure | Stop polling |
| `PollTryNextBlock(bytes4)` | Transient, retry soon | Poll next block |
| `PollTryAtTimestamp(uint256, bytes4)` | Wait for time | Schedule at timestamp |
| `PollTryAtBlock(uint256, bytes4)` | Wait for block | Schedule at block |

### Revert Decoding Policy

`BaseConditionalOrder.poll()` decodes reverts from `generateOrder()` into verdicts. Only `OrderNotValid` is terminal; everything unrecognized is treated as transient so a recoverable fault reschedules instead of permanently killing a valid order off-chain:

| Revert | Verdict | reasonCode |
|--------|---------|------------|
| `OrderNotValid(code)` | `INVALID` | decoded code |
| `PollTryNextBlock(code)` | `TRY_NEXT_BLOCK` | decoded code |
| `PollTryAtTimestamp(t, code)` | `WAIT_TIMESTAMP` (`waitUntil = t`) | decoded code |
| `PollTryAtBlock(b, code)` | `WAIT_BLOCK` (`waitUntil = b`) | decoded code |
| `Panic(subcode)` | `TRY_NEXT_BLOCK` | `0x4e487b71` (the `Panic` selector) |
| `Error(string)` (bare `require`) | `TRY_NEXT_BLOCK` | `0x08c379a0` (the `Error` selector) |
| any other custom error | `TRY_NEXT_BLOCK` | the caught selector |
| empty / malformed revert data | `TRY_NEXT_BLOCK` | `bytes4(0)` |

For full diagnostics - `Panic` sub-codes, `Error(string)` messages, or an unrecognized
error's arguments - call `tryGenerateOrder`, which returns `(success, order, revertData)`
as ordinary return data: the complete ABI-encoded inner error arrives without any RPC
revert-data handling, making it composable in multicalls and batch probes.

## Polling Result Structures

### GeneratorResult (handler-facing)

Handlers can only ever produce a *verdict*; fill state is deliberately not representable on the generator surface:

```solidity
enum GeneratorResultCode {
    POST,             // A discrete order is ready to be posted
    WAIT_TIMESTAMP,   // Wait until waitUntil (unix timestamp)
    WAIT_BLOCK,       // Wait until waitUntil (block number)
    TRY_NEXT_BLOCK,   // Transient condition, retry next block
    INVALID           // Permanently invalid, stop polling
}

struct GeneratorResult {
    GeneratorResultCode code;
    GPv2Order.Data order;        // Valid iff code == POST
    uint256 nextPollTimestamp;   // POST: when to poll for the next order
    uint256 waitUntil;           // WAIT_*: when to retry
    bytes4 reasonCode;           // Selector behind a non-POST verdict; bytes4(0) for POST
}
```

### PollResult (registry-facing)

Composed by `ComposableCoW`, never by a handler:

```solidity
enum FillStatus {
    NONE,             // No fill observed
    PARTIALLY_FILLED, // 0 < filledAmount < total
    FILLED,           // filledAmount >= total
    INVALIDATED       // order was cancelled via invalidateOrder
}

struct PollResult {
    IConditionalOrderGenerator.GeneratorResult generator;
    FillStatus fill;          // Only meaningful when the verdict is POST
    uint256 filledAmount;     // Raw GPv2Settlement.filledAmount (uint256.max when invalidated)
}
```

### Verdict Semantics

| Verdict | Meaning | Watch-tower Action |
|---------|---------|-------------------|
| `POST` | Order ready to post | Submit to CoW Protocol API (if the fill overlay allows) |
| `WAIT_TIMESTAMP` | Wait for specific time | Schedule poll at `waitUntil` |
| `WAIT_BLOCK` | Wait for specific block | Schedule poll at block `waitUntil` |
| `TRY_NEXT_BLOCK` | Transient condition | Poll again next block |
| `INVALID` | Permanently invalid | Stop polling this order |

### Fill Overlay Semantics

| FillStatus | Meaning | Signature emitted? |
|------------|---------|--------------------|
| `NONE` | Untouched | Yes (verdict `POST`) |
| `PARTIALLY_FILLED` | Partially filled | Only if `order.partiallyFillable` |
| `FILLED` | Fully filled | No |
| `INVALIDATED` | Cancelled on-chain (`invalidateOrder`) | No |

`INVALIDATED` is distinct from `FILLED`: `GPv2Settlement.invalidateOrder` sets `filledAmount` to `type(uint256).max`, which is a cancellation, not a fill.

### nextPollTimestamp Semantics

| Value | Meaning |
|-------|---------|
| `0` | Use `order.validTo + 1` as default (`POLL_AT_VALIDTO`) |
| `> 0` | Poll at this specific timestamp |
| `type(uint256).max` | Final order, stop polling after fill (`POLL_NEVER`) |

## Order Type Patterns

### Single-Shot Orders (StopLoss, GoodAfterTime)

```solidity
function generateOrder(...) public view returns (GPv2Order.Data memory) {
    // Validate conditions - use require with custom errors (Solidity 0.8.30+)
    require(!expired, OrderNotValid(OrderExpired.selector));
    require(conditionMet, PollTryNextBlock(ConditionNotMet.selector));

    // Build and return order
    return GPv2Order.Data(...);
}

function getNextPollTimestamp(...) external pure returns (uint256) {
    return POLL_NEVER;  // single shot
}
```

Handlers must reject degenerate zero-amount orders (`OrderNotValid(ZeroAmount.selector)`): a fill-or-kill order with `sellAmount == 0` settles without ever incrementing `filledAmount`, so the native replay guard never trips and the order would be indefinitely replayable.

### Multi-Part Orders (TWAP)

```solidity
function generateOrder(...) public view returns (GPv2Order.Data memory) {
    // Before the start is a WAIT, not a permanent failure
    require(block.timestamp >= startTime, PollTryAtTimestamp(startTime, BeforeTwapStart.selector));
    require(block.timestamp < endTime, OrderNotValid(AfterTwapFinish.selector));

    // Between parts (outside the span) is a scheduling gap:
    // PollTryAtTimestamp(nextPartStart, NotWithinSpan.selector), or
    // OrderNotValid(AfterTwapFinish.selector) when no part remains.
    return buildPartOrder(currentPart);
}

function getNextPollTimestamp(...) external view returns (uint256) {
    uint256 part = calculateCurrentPart();
    if (part + 1 >= numParts) return POLL_NEVER;   // underflow-safe form
    return startTime + ((part + 1) * frequency);
}
```

### Perpetual Orders (PerpetualStableSwap)

```solidity
function generateOrder(...) public view returns (GPv2Order.Data memory) {
    require(funded, OrderNotValid(NotFunded.selector));
    return GPv2Order.Data(...);
}

function getNextPollTimestamp(...) external pure returns (uint256) {
    return POLL_AT_VALIDTO;  // Use validTo + 1, perpetually repeating
}
```

### Multi-Order Generation per Poll

One poll yields one discrete order, but a conditional order is not limited to one *simultaneously postable* order. `generateOrder` may key the discrete order off `offchainInput` (e.g. `abi.encode(index)`), and `verify()` re-derives from the same `offchainInput` carried in each order's signature payload — so N simultaneously-postable orders per `(handler, salt, staticInput)` are sound, settle independently, and need no interface change. `IOrderManifest.getManifestPage` provides the enumeration.

Worked example — a multi-currency DCA buying N tokens per window:

```solidity
function generateOrder(address owner, address, bytes32 ctx, bytes calldata staticInput, bytes calldata offchainInput)
    public view returns (GPv2Order.Data memory)
{
    Data memory data = abi.decode(staticInput, (Data)); // data.legs: token/amount pairs
    uint256 leg = abi.decode(offchainInput, (uint256)); // which leg to cut
    require(leg < data.legs.length, OrderNotValid(NoSuchLeg.selector));
    return buildLegOrder(data, leg);                    // window logic as usual
}
```

A watch-tower enumerates the currently active entries via the manifest and polls once per leg with the leg index as `offchainInput`. The same pattern covers a simplified AMM (index 0 = buy, 1 = sell) and sequenced strategies (the follow-up entry appears in the manifest once the first leg fills).

## Order Manifest Interface

The `IOrderManifest` interface enables enumeration of the discrete orders a conditional order will produce. This is useful for analytics, UI previews, and order lifecycle tracking. It is a sidecar interface with its own ERC-165 id, feature-detected by consumers and never consulted on the settlement path. The manifest mirrors the information `poll` already exposes — it is not a second source of truth.

### Cardinality Types

`Cardinality` names how `totalOrders` is to be read:

| Cardinality | Description | Example |
|-------------|-------------|---------|
| `EXACT` | `totalOrders` is the exact count | TWAP with n parts |
| `CAPPED` | `totalOrders` is an upper cap; actual count is dynamic | Future order types |
| `UNBOUNDED` | No meaningful count (`totalOrders` is 0) | PerpetualStableSwap |

### ManifestInfo Structure

```solidity
struct ManifestInfo {
    Cardinality cardinality;
    uint256 totalOrders;  // Exact for EXACT, cap for CAPPED, 0 for UNBOUNDED
}
```

### ManifestEntry Structure

```solidity
struct ManifestEntry {
    uint256 index;           // Order index (0-indexed)
    GPv2Order.Data order;    // The discrete order
    uint256 validFrom;       // When this order becomes valid
    bool isActive;           // Whether currently within validity window
}
```

The `validFrom` field is needed because `GPv2Order.Data` only contains `validTo`.

### Pagination Contract

`getManifestPage` returns `(entries, hasMore, reasonCode)` and guarantees that an empty page with `hasMore == true` is unreachable: a consumer advancing `offset += entries.length` and stopping at `hasMore == false` always terminates.

- UNBOUNDED handlers expose only index 0 (the current discrete order) and return `hasMore == false` on every branch; `offset > 0` yields an empty final page.
- When a page is empty because the order cannot currently be generated, `reasonCode` carries the decoded reason selector (mirroring `poll` semantics), so a not-yet-active order (`BeforeTwapStart.selector`) is distinguishable from a permanently invalid one. `reasonCode` is `bytes4(0)` on ordinary pages.

### Manifest Implementation by Order Type

| Order Type | Cardinality | totalOrders | Behavior |
|------------|-------------|-------------|----------|
| TWAP | EXACT | n (number of parts) | All n parts with timing; degenerate parameters yield an empty manifest |
| StopLoss | EXACT | 1 | Single order from generateOrder() |
| GoodAfterTime | EXACT | 1 | Single order from generateOrder() |
| TradeAboveThreshold | EXACT | 1 | Single order from generateOrder() |
| PerpetualStableSwap | UNBOUNDED | 0 | Current order at index 0; pagination always terminates |

### Default Implementation

`BaseConditionalOrder` provides a default manifest implementation for single-shot orders:
- `getManifestInfo()` returns `EXACT` with `totalOrders: 1`.
- `getManifestPage()` wraps `generateOrder()` for a single entry, surfacing the decoded reason selector when generation is not currently possible.

## ComposableCoW Contract

### Events

| Event | Description |
|-------|-------------|
| `MerkleRootSet(address indexed owner, bytes32 root, Proof proof, bytes context)` | Merkle root updated |
| `ConditionalOrderCreated(address indexed owner, ConditionalOrderParams params, bytes context)` | Order created with dispatch=true |
| `ConditionalOrderRemoved(address indexed owner, bytes32 indexed orderHash)` | Order deauthorized |
| `SwapGuardSet(address indexed owner, ISwapGuard swapGuard)` | Swap guard updated |

On the `*WithContext` paths, the cabinet is written **before** the event fires and `context` carries the resolved cabinet value (`abi.encode(bytes32 value)`), so an indexer reacting to the event observes a consistent cabinet without an extra read. On the plain paths `context` is empty bytes.

### Key Functions

| Function | Path | Returns |
|----------|------|---------|
| `isValidSafeSignature()` | Settlement | `bytes4` magic value |
| `getTradeableOrderWithSignature()` | Polling | `(PollResult, bytes signature)` |
| `checkOrder()` | Polling | `PollResult` |

### Authorization

Orders are authorized via:
- **Single orders**: `singleOrders[owner][hash(params)] = true`
- **Merkle roots**: `roots[owner] = merkleRoot`

The `_auth()` function verifies authorization and returns the context key as follows:
- Merkle orders: `ctx = bytes32(0)`.
- Single orders: `ctx = hash(params)`.

### Context Storage (Cabinet)

The `cabinet` mapping stores per-order context:
```solidity
mapping(address owner => mapping(bytes32 ctx => bytes32 value)) public cabinet;
```

This is used by TWAP to store dynamic start times set at order creation.

## ERC-1271 Integration

ComposableCoW is designed to work with any smart contract wallet that implements ERC-1271 (`isValidSignature`). The integration requires the wallet to route signature verification requests to ComposableCoW.

### How It Works

1. **Order Creation**: The wallet owner authorizes conditional orders via `create()` or `setRoot()`.
2. **Signature Verification**: When CoW Protocol settlement calls `isValidSignature(hash, signature)` on the wallet, it routes the call to ComposableCoW.
3. **Validation**: ComposableCoW verifies authorization and validates the order via `generateOrder()`.

### Supported Wallets

| Wallet Type | Integration Method |
|-------------|-------------------|
| Safe | ExtensibleFallbackHandler with domain verifier |
| Other ERC-1271 | Extend `ERC1271Forwarder` abstract contract |

### ERC1271Forwarder

The `ERC1271Forwarder` abstract contract provides a ready-made integration for any ERC-1271 wallet. Extend this contract to add ComposableCoW support:

```solidity
import {ERC1271Forwarder} from "./ERC1271Forwarder.sol";

contract MyWallet is ERC1271Forwarder {
    constructor(ComposableCoW _composableCoW) ERC1271Forwarder(_composableCoW) {}
    // ... wallet implementation
}
```

The forwarder:
1. Receives `isValidSignature(bytes32 _hash, bytes signature)` calls.
2. Decodes the signature as `(GPv2Order.Data, ComposableCoW.PayloadStruct)`.
3. Verifies that the order hash matches the provided hash.
4. Forwards the request to `ComposableCoW.isValidSafeSignature()` for order validation.

### Custom Integration

For wallets that cannot extend `ERC1271Forwarder`, implement the forwarding manually:

1. Decode the signature to extract `GPv2Order.Data` and `ComposableCoW.PayloadStruct`.
2. Verify that `GPv2Order.hash(order, domainSeparator) == _hash`.
3. Call `composableCoW.isValidSafeSignature(owner, sender, hash, domainSeparator, typeHash, encodedOrder, encodedPayload)`.

## Implementation Checklist for New Order Types

1. Extend `BaseConditionalOrder`.
2. Implement `generateOrder()`:
   - Validate conditions using `require(condition, CustomError(reason))`.
   - Declare reason errors at file level (e.g., `error MyCondition();`) and pass
     their selectors: `require(ok, PollTryNextBlock(MyCondition.selector))`.
   - Reject degenerate zero-amount orders with `OrderNotValid(ZeroAmount.selector)`.
   - Build and return `GPv2Order.Data`.
3. Override `getNextPollTimestamp()` if not using the default:
   - Return `POLL_AT_VALIDTO` (0) for 'use validTo + 1'.
   - Return `POLL_NEVER` (`type(uint256).max`) for single-shot orders.
   - Return a specific timestamp for multi-part orders.
4. Optionally override `describeOrder()` for better UX.
5. Override manifest functions if not single-shot:
   - `getManifestInfo()` — return the appropriate cardinality; validate parameters before computing counts.
   - `getManifestPage()` — implement pagination for multi-part orders; respect the pagination contract (an empty page with `hasMore == true` must be unreachable).
   - For UNBOUNDED orders, expose only index 0 and return `hasMore == false` on every branch.

## Gas Comparison

| Operation | Settlement Path | Polling Path |
|-----------|----------------|--------------|
| `generateOrder()` | Yes | Yes |
| Hash verification | Yes | No |
| `getNextPollTimestamp()` | No | Yes |
| `describeOrder()` | No | Yes |
| Error reason selectors | Yes (bytes4 constants) | Yes (bytes4 constants) |
| Result struct construction | No | Yes |

The settlement path executes only what is necessary for validation. Error reason strings use compile-time constants to minimize gas overhead while providing useful debugging information.

## Breaking Changes from Upstream

This fork introduces significant architectural changes from [cowprotocol/composable-cow](https://github.com/cowprotocol/composable-cow). The following sections document all breaking changes for migration purposes.

### IConditionalOrder Interface

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Error renamed and retyped | `PollTryAtEpoch(uint256, string)` | `PollTryAtTimestamp(uint256, bytes4)` |
| Error removed | `PollNever(string)` | Was unused; use `OrderNotValid` for permanent conditions |
| Errors retyped | `string reason` payloads | `bytes4 reasonCode` (selector of a handler-declared error) |
| Function added | - | `generateOrder()` (moved from IConditionalOrderGenerator) |
| Event changed | `ConditionalOrderCreated(address indexed, ConditionalOrderParams)` | gains a `bytes context` parameter (topic0 changes) |

**Migration**: Replace `PollTryAtEpoch` with `PollTryAtTimestamp`, and replace `revert PollNever(reason)` with `revert OrderNotValid(reason)`.

### IConditionalOrderGenerator Interface

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Function removed | `getTradeableOrder()` | Use `generateOrder()` (in base interface) |
| Enum added | - | `GeneratorResultCode` |
| Struct added | - | `GeneratorResult` |
| Function added | - | `poll()` returning `GeneratorResult` |
| Function added | - | `getNextPollTimestamp()` |
| Function added | - | `describeOrder()` |
| Function added | - | `tryGenerateOrder()` returning full revert data |

The ERC-165 interface id of `IConditionalOrderGenerator` therefore changes: handlers deployed against the upstream interface will not satisfy the new id and are rejected by the polling path of a registry compiled against this fork.

**Migration**: Rename `getTradeableOrder()` to `generateOrder()`, and implement `getNextPollTimestamp()` and `describeOrder()` (or use the defaults from `BaseConditionalOrder`).

### ComposableCoW Contract

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Return type changed | `getTradeableOrderWithSignature() returns (GPv2Order.Data, bytes)` | `returns (PollResult, bytes)` |
| Function added | - | `checkOrder() returns (PollResult)` |
| Types added | - | `FillStatus`, `PollResult` |
| Event added | - | `ConditionalOrderRemoved(address indexed, bytes32 indexed)` |
| Events changed | `MerkleRootSet`, `ConditionalOrderCreated` | gain a `bytes context` parameter (topic0 changes); cabinet written before emit |
| State added | - | `settlement` (CoWSettlement immutable) |
| Feature added | - | Fill overlay via `GPv2Settlement.filledAmount()` (incl. `INVALIDATED` detection) |
| Behavior changed | swap-guard restriction reverts on the polling path | returned as an `INVALID` verdict with reason `"swap guard restricted"` (settlement path still reverts) |
| Behavior changed | conditional-order errors revert through `getTradeableOrderWithSignature` | decoded into the returned verdict; only authorization / interface failures revert |

**Migration**: Update callers of `getTradeableOrderWithSignature()` to handle the `PollResult` struct:

```solidity
// Upstream
(GPv2Order.Data memory order, bytes memory sig) = composableCow.getTradeableOrderWithSignature(...);

// This fork
(ComposableCoW.PollResult memory result, bytes memory sig) = composableCow.getTradeableOrderWithSignature(...);
if (
    result.generator.code == IConditionalOrderGenerator.GeneratorResultCode.POST
        && sig.length > 0
) {
    GPv2Order.Data memory order = result.generator.order;
    // ... submit order
}
```

### BaseConditionalOrder

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Function renamed | `getTradeableOrder()` (abstract) | `generateOrder()` (abstract) |
| Function added | - | `poll()` (concrete implementation) |
| Function added | - | `getNextPollTimestamp()` (virtual, default: `POLL_AT_VALIDTO`) |
| Function added | - | `describeOrder()` (virtual, default: "order ready") |
| Interface added | - | Implements `IOrderManifest` |
| Function added | - | `getManifestInfo()` (virtual, default: EXACT/1) |
| Function added | - | `getManifestPage()` (virtual, default: single entry with status) |
| Constant added | - | `POLL_AT_VALIDTO = 0` |
| Constant added | - | `POLL_NEVER = type(uint256).max` |

**Migration**: Rename `getTradeableOrder()` to `generateOrder()`. The base class now provides a `poll()` implementation that wraps `generateOrder()` with try/catch.

### New Interface: IOrderManifest

```solidity
interface IOrderManifest {
    enum Cardinality { EXACT, CAPPED, UNBOUNDED }
    struct ManifestInfo { Cardinality cardinality; uint256 totalOrders; }
    struct ManifestEntry { uint256 index; GPv2Order.Data order; uint256 validFrom; bool isActive; }

    function getManifestInfo(...) external view returns (ManifestInfo memory);
    function getManifestPage(...) external view returns (ManifestEntry[] memory, bool hasMore, string memory status);
}
```

**Migration**: No action is required for existing order types if extending `BaseConditionalOrder` (which provides a default single-shot implementation). Override for multi-part orders such as TWAP.

### Vendored CoWSettlement Interface

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Function added | - | `filledAmount(bytes orderUid) returns (uint256)` |

This addition enables the fill overlay (`FillStatus`) in the registry poll path.

### Summary of Function Renames

| Upstream | This Fork |
|----------|-----------|
| `getTradeableOrder()` | `generateOrder()` |
| `PollTryAtEpoch` | `PollTryAtTimestamp` |

### Summary of Removed Items

| Item | Replacement |
|------|-------------|
| `PollNever` error | `OrderNotValid` error (permanent conditions) |
| `GPv2Interaction` re-export from `IConditionalOrder.sol` | Import from `GPv2Settlement.sol` directly (was unused here) |
