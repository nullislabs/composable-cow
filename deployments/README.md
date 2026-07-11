# Deployments manifest

`networks.json` is the canonical machine-readable record of framework
deployments, consumed by off-chain monitoring services and indexers as the
single source for where and what to index.

## Schema

```jsonc
{
  "version": 1,              // manifest schema version
  "abiVersion": "2.0.0-dev", // contract ABI version the entries conform to
  "networks": {
    "<chainId>": {
      "composableCow": "0x…",   // registry address
      "deployBlock": 12345678,  // first block to index from
      "topic0": {
        "conditionalOrderCreated": "0x…",
        "merkleRootSet": "0x…",
        "conditionalOrderRemoved": "0x…",
        "swapGuardSet": "0x…"
      }
    }
  }
}
```

Rules:

- Entries are appended by the deployment pipeline; hand edits are reviewed
  like code.
- `topic0` values are recomputed from the ABI at deploy time and MUST match
  the compiled event signatures (consumers guard on these at startup).
- A chain absent from `networks` is not serviced.
