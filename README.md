# `ComposableCow`: Composable Conditional orders

> [!WARNING]
>
> **This fork is unaudited and is not deployed.**
>
> It has diverged substantially from upstream [`cowprotocol/composable-cow`](https://github.com/cowprotocol/composable-cow): the order generation entry point, error signalling, polling interface, proof payload location and handler discovery surface have all changed, and several of those changes are breaking. The audits below cover the upstream contracts as they stood before this work and do not carry over to this tree.
>
> Do not use in production. See [Divergence from upstream](#divergence-from-upstream).

This repository is the next in evolution of the [`conditional-smart-orders`](https://github.com/cowprotocol/conditional-smart-orders), providing a unified interface for stateless, composable conditional orders. `ComposableCow` is designed to be used with the [`ExtensibleFallbackHandler`](https://github.com/rndlabs/safe-contracts/tree/merged-efh-sigmuxer), a powerful _extensible_ fallback handler that allows for significant customisation of a `Safe`, while preserving strong security guarantees.

## Divergence from upstream

This fork is not a drop-in replacement for [`cowprotocol/composable-cow`](https://github.com/cowprotocol/composable-cow). The settlement path is shape-compatible; the changes concentrate on what an off-chain monitoring service can learn from the contracts, and on making that answer machine-readable rather than something to be parsed out of a revert.

- **Order generation.** `getTradeableOrder` is now `generateOrder`, declared on `IConditionalOrderGenerator`.
- **Typed errors.** `string reason` is replaced by `bytes4` error selectors throughout, so a consumer can classify a failure without reading prose.
- **Structured polling.** Polling returns a verdict rather than reverting for the caller to decode: a result code (`POST`, `WAIT_TIMESTAMP`, `WAIT_BLOCK`, `TRY_NEXT_BLOCK`, `INVALID`, `NEEDS_INPUT`), the block or timestamp to retry at, and the handler's reason selector. A missing `offchainInput` is reported as `NEEDS_INPUT` rather than a timed retry, and a swap-guard restriction is reported separately from the handler's own verdict.
- **Fill state.** The registry composes `GPv2Settlement.filledAmount` into the poll result, so a partially filled order reports its fill rather than appearing tradeable at full size. The overlay is orthogonal to the verdict.
- **Order manifest.** `IOrderManifest.getManifestPage` enumerates the discrete orders a conditional order will produce, paginated, with a `ManifestStatus` carrying the same verdict polling would return. An empty page therefore distinguishes "not yet" from "never".
- **Handler discovery.** `IOrderDescriptor` and `IOrderModule` describe a handler and its off-chain extension, each committing to content by digest (`PackageKind`: Swarm BMT manifest or sha256).
- **Proof payload locations.** `Proof` is now `{uris, blobVersionedHashes}` rather than an opaque `{location, data}`. Blob hashes are verified attached to the setting transaction, binding publication to authorisation.
- **Handler validation.** Degenerate zero-amount orders are rejected at validation rather than being emitted for settlement to refuse.
- **Housekeeping.** Solidity 0.8.30 with a pinned toolchain, require-with-custom-error style, build artifacts untracked, `ComposableCoW` renamed to `ComposableCow`, and all deployment state cleared as nothing in this tree is deployed.

Upstream has since added `ComposableCowPoller`, a registry for on-chain polling schedules and just-in-time order funding. That work is not present here.

## Architecture

- [`docs/architecture.md`](./docs/architecture.md) covers the dual-path design: the gas-sensitive settlement path and the gas-irrelevant polling path.
- [`docs/discovery.md`](./docs/discovery.md) specifies the discovery surface, including commitments, handler descriptors, order modules and merkle payload documents.
- [`docs/design/`](./docs/design) holds the design notes behind individual decisions.

### Methodology

For the purposes of outlining the methodologies, it is assumed that:

1. The `Safe` has already had its fallback handler set to `ExtensibleFallbackHandler`.
2. The `Safe` has set the `domainVerifier` for the `GPv2Settlement.domainSeparator()` to `ComposableCow`

#### Conditional order creation

A conditional order is a struct `ConditionalOrderParams`, consisting of:

1. The address of handler, ie. type of conditional order (such as `TWAP`).
2. A unique salt.
3. Implementation specific `staticInput` - data that is known at the creation time of the conditional order.

##### Single Order

1. From the context of the Safe that is placing the order, call `ComposableCow.create` with the `ConditionalOrderParams` struct. Optionally set `dispatch = true` to have events emitted that are picked up by an off-chain monitoring service.

##### Merkle Root

1. Collect all the conditional orders, which are multiple structs of `ConditionalOrderParams`.
2. Populate a merkle tree with the leaves from (1), where each leaf is a double hashed of the ABI-encoded struct.
3. Determine the merkle root of the tree and set this as the root, calling `ComposableCow.setRoot`. The `proof` declares where the payload document (the complete leaf set) is published. Both channels are optional and orthogonal:
   a. `uris`: mirrors for the payload document, all referencing the same bytes. Never interpreted on-chain.
   b. `blobVersionedHashes`: EIP-4844 blobs carrying the payload, each verified to be attached to the transaction setting the root.
   c. Both empty: the root is private and no discovery is expected.

#### Get Tradeable Order With Signature

Conditional orders may generate one or many discrete orders depending on their implementation. To retrieve a discrete order that is valid at the current block:

1. Call `ComposableCow.getTradeableOrderWithSignature(address owner, ConditionalOrderParams params, bytes offchainInput, bytes32[] proof)` where:
   - `owner`: smart contract / `Safe`
   - `params`: mentioned above.
   - `offchainInput` is any implementation specific offchain input for discrete order generation / validation.
   - `proof`: a zero length array if a single order, otherwise the merkle proof for the merkle root that's set for `owner`.
2. The call returns a `PollResult` and a signature. When `result.generator.code` is `POST`, use `result.generator.order` to populate a `POST` to the CoW Protocol API to create an order. Set the `signingScheme` to `eip1271` and the `signature` to that returned from the call in (1). Any other verdict returns an empty signature.
3. Review the order on [CoW Explorer](https://explorer.cow.fi/).
4. The call does not revert for order conditions. `result.generator` carries the verdict, the block or timestamp to retry at, and the handler's error selector; `result.fill` carries the observed fill state. This provides feedback for monitoring services to modify their internal state. It reverts only for authorisation and handler-interface failures.

#### Conditional order cancellation

##### Single Order

1. Determine the digest for the conditional order, ie.`H(Params)`.
2. Call `ComposableCow.remove(H(Params))`

##### Merkle Root

1. Prune the leaf from the merkle tree.
2. Determine the new root.
3. Call `ComposableCow.setRoot` with the new root, which will invalidate any orders that have been pruned from the tree.

## Time-weighted average price (TWAP)

A simple _time-weighted average price_ trade may be thought of as `n` smaller trades happening every `t` time interval, commencing at time `t0`. Additionally, it is possible to limit a part's validity of the order to a certain `span` of time interval `t`.

### Data Structure

```solidity
struct Data {
    IERC20 sellToken;
    IERC20 buyToken;
    address receiver; // address(0) if the safe
    uint256 partSellAmount; // amount to sell in each part
    uint256 minPartLimit; // minimum buy amount in each part (limit)
    uint256 t0;
    uint256 n;
    uint256 t;
    uint256 span;
    bytes32 appData;
}
```

**NOTE:** No direction of trade is specified, as for TWAP it is assumed to be a _sell_ order

Example: Alice wants to sell 12,000,000 DAI for at least 7500 WETH. She wants to do this using a TWAP, executing a part each day over a period of 30 days.

- `sellToken` = DAI
- `buyToken` = WETH
- `receiver` = `address(0)`
- `partSellAmount` = 12000000 / 30 = 400000 DAI
- `minPartLimit` = 7500 / 30 = 250 WETH
- `t0` = Nominated start time (unix epoch seconds)
- `n` = 30 (number of parts)
- `t` = 86400 (duration of each part, in seconds)
- `span` = 0 (duration of `span`, in seconds, or `0` for entire interval)
- `appData` = the CoW Protocol app data hash applied to every part

If Alice also wanted to restrict the duration in which each part traded in each day, she may set `span` to a non-zero duration. For example, if Alice wanted to execute the TWAP, each day for 30 days, however only wanted to trade for the first 12 hours of each day, she would set `span` to `43200` (i.e. `60 * 60 * 12`).

Using `span` allows for use cases such as weekend or week-day only trading.

### Methodology

To create a TWAP order:

1. ABI-Encode the `IConditionalOrder.ConditionalOrderParams` struct with:
   - `handler`: set to the `TWAP` smart contract deployment.
   - `salt`: set to a unique value.
   - `staticInput`: the ABI-encoded `TWAP.Data` struct.
2. Use the `struct` from (1) as either a Merkle leaf, or with `ComposableCow.create` to create a single conditional order.
3. Approve `GPv2VaultRelayer` to trade `n x partSellAmount` of the safe's `sellToken` tokens (in the example above, `GPv2VaultRelayer` would receive approval for spending 12,000,000 DAI tokens).

**NOTE**: When calling `ComposableCow.create`, setting `dispatch = true` will cause `ComposableCow` to emit event logs that are indexed by monitoring services automatically. If you wish to maintain a private order (and will submit to the CoW Protocol API through your own infrastructure, you may set `dispatch` to `false`).

When using Safe, it is possible to batch together all the above calls to perform this step atomically, and optimise gas consumption / UX.

**NOTE:** For cancelling a TWAP order, follow the instructions at [Conditional order cancellation](#conditional-order-cancellation).

## Developers

### Requirements

- `forge` ([Foundry](https://github.com/foundry-rs/foundry))

### Deployments

None. This fork has no deployments on any network.

The legacy `networks.json` recorded upstream's addresses, which belong to contracts this tree no longer matches, so it has been removed rather than left to be mistaken for the fork's own deployments. When this fork does deploy, the canonical machine-readable record is [`deployments/networks.json`](./deployments/networks.json).

The `broadcast/` directory holds upstream's deployment records and verification inputs. They describe contracts this tree no longer matches and are retained only as history.

### Audits

The following audits cover the **upstream** contracts before the changes in this fork. They do not cover the current tree:

- Ackee Blockchain: [CoW Protocol - `ComposableCow` and `ExtensibleFallbackHandler`](./audits/ackee-blockchain-cow-protocol-composablecow-extensiblefallbackhandler-report-1.2.pdf)
- Gnosis internal audit: [ComposableCow - May/July 2023](./audits/gnosis-ComposableCoWMayJul2023.pdf)
- Gnosis internal audit (August 2024): [ComposableCow - Diff between May/July 2023 and August 2024](./audits/Composable_CoW_Diff.pdf)

### Environment setup

Copy `.env.example` to `.env`. Every script reads `PRIVATE_KEY`; `SETTLEMENT` is needed to deploy `ComposableCow`, `COMPOSABLE_COW` to deploy order types against it, and `SAFE` plus `TWAP` to submit a single order. Contract verification reads `ETHERSCAN_API_KEY`. The RPC endpoint is passed per command with `--rpc-url`.

### Testing

Effort has been made to adhere as close as possible to [best practices](https://book.getfoundry.sh/guides/best-practices), with _unit_ and _fuzzing_ tests being implemented. The fuzz tests include `test_simulate_fuzz`, which runs end-to-end integration testing including settlement of conditional orders.

```bash
forge test -vvv --no-match-test "[fF]uzz" # Unit tests only
forge test -vvv                           # Unit and fuzz tests
```

Fuzz tests are seeded in CI (`--fuzz-seed`) so that a run is reproducible.

### Coverage

```bash
forge coverage -vvv --report summary
```

### Script-based deployment

Deployment is handled by solidity scripts in `forge`. The network being deployed to is determined by the `--rpc-url` passed to each command.

To deploy all contracts in a single run:

```bash
source .env
forge script script/deploy_ProdStack.s.sol:DeployProdStack --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
```

To deploy individual contracts:

```bash
# Deploy ComposableCow
forge script script/deploy_ComposableCow.s.sol:DeployComposableCow --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
# Deploy order types
forge script script/deploy_OrderTypes.s.sol:DeployOrderTypes --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
```

`script/` also carries `deploy_ExtensibleFallbackHandler.s.sol` and `deploy_ValueFactories.s.sol` for the supporting contracts.

Each run writes its record under `broadcast/`, keyed by script and chain id.

#### Contract verification on block explorer

There's a dedicated script to verify all contracts at the same time once they have been deployed on a new chain:

```sh
export ETHERSCAN_API_KEY="your API key here"
chain_id=1337
dev/verify-contracts.sh "$chain_id"
```

If this doesn't work, check out [broadcast/StandardJsonInput/README.md](./broadcast/StandardJsonInput/README.md).

#### Local deployment

For local integration testing, including running an off-chain monitoring service against the deployment, it may be useful deploying to a _forked_ mainnet environment. This can be done with `anvil`.

1. Open a terminal and run `anvil`:

   ```bash
   anvil --code-size-limit 50000 --block-time 5
   ```

   **NOTE**: When deploying the full stack on `anvil`, the balancer vault may exceed contract code size limits necessitating the use of `--code-size-limit`.

2. Follow the previous deployment directions, with this time specifying `anvil` as the RPC-URL:

   ```bash
   source .env
   forge script script/deploy_AnvilStack.s.sol:DeployAnvilStack --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
   ```

   **NOTE**: Within the output of the above command, there will be an address for a `Safe` that was deployed to `anvil`. This is needed for the next step.

   **NOTE:** `--verify` is omitted as with local deployments, these should not be submitted to Etherscan for verification.

3. To then simulate the creation of a single order:

   ```bash
   source .env
   SAFE="address here" forge script script/submit_SingleOrder.s.sol:SubmitSingleOrder --rpc-url http://127.0.0.1:8545 --broadcast
   ```
