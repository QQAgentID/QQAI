# QQAI

**QQAI** — an Agent ID-gated token on BNB Chain with a fixed supply of 1 trillion. Holding a Binance Agent ID is the key to the sale: it unlocks the free mint and the paid mint.

- **Website:** https://qqai-bnb.pages.dev
- **X:** https://x.com/QQAgent_BNB
- **Sale opens:** November 26, 2026, 18:00 (UTC+8)
- **Chain:** BNB Smart Chain (BSC, chain id 56)

## The token

- **1,000,000,000,000 QQAI, fixed supply.** Tokens are minted on demand by the sale contract — nothing is pre-minted to any wallet.
- Allocation: **675B** public sale · **225B** liquidity reserve · **50B** team (locked in a vesting contract) · **50B** project reserve.
- Trade tax applies only on the official pair; wallet-to-wallet transfers are untaxed. Buys pay **2%**. Sells start at **10%** when the pool opens and step down to **2%** permanently. All collected tax is converted to BNB and funds the project.

## The sale

### Free mint

- **555 slots × 16,500,000 QQAI**, first-come-first-served, max **2 per Agent ID**.
- A 0.0001 BNB gate fee applies per free mint.

### Paid mint — batches 1–4

- **1,111 mints per batch**, max **10 per Agent ID**. Every paid mint includes a **+5% Agent ID bonus** in QQAI.

| Batch | Price | QQAI per mint |
|---|---|---|
| 1 | 0.003 BNB | 50,000,000 |
| 2 | 0.00315 BNB | 47,500,000 |
| 3 | 0.0033075 BNB | 45,125,000 |
| 4 | 0.003472875 BNB | 42,868,750 |

### Escrow and the pool

- Paid-mint BNB is escrowed on-chain. **80%** is reserved for the liquidity pool. The remaining 20% is split as **10% buy back & burn, 5% liquidity, 5% team**.
- The moment paid mint **#4,444** lands, the sale contract itself creates the PancakeSwap pair, deposits the escrowed BNB together with the 225B QQAI liquidity reserve, and **burns 100% of the LP tokens**.
- After the pool opens, paid minting continues as a buy-through with a bonus on top: **+5%** in batches 5–8, **+3%** in batches 9–12, **+1%** in batches 13–16, then the standard amount.

### Refund safety net

- If the pool has not opened within **7 days** of the sale start, paid minters can return all of their paid QQAI (it is burned) and receive **80% of their BNB back**; the remainder is split **15% to liquidity + 5% team**.
- The refund window closes forever the moment the pool opens. Free mints are not refundable.

## Contracts

Deployed on BNB Smart Chain (chain id 56). All four deployed contracts are verified on Sourcify with an **exact match**; the sources under `contracts/` are byte-for-byte the verified sources returned by Sourcify.

| Contract | Address | Sourcify |
|---|---|---|
| `QQAIToken` | `0x69b8cA186337701262310079C14a715387338888` | [exact_match](https://sourcify.dev/#/lookup/0x69b8cA186337701262310079C14a715387338888) |
| `QQAIMint` | `0x313eedfBb409A886F55203AEEb7270CF77B65DfF` | [exact_match](https://sourcify.dev/#/lookup/0x313eedfBb409A886F55203AEEb7270CF77B65DfF) |
| `QQAIVesting` | `0xd46313C4A48902108743eD74B5C700909Dc7d35F` | [exact_match](https://sourcify.dev/#/lookup/0xd46313C4A48902108743eD74B5C700909Dc7d35F) |
| `QQAIDeployer` | `0x8D60DB09a9F52E9b9B60fA2DD9B4303936B06C3c` | [exact_match](https://sourcify.dev/#/lookup/0x8D60DB09a9F52E9b9B60fA2DD9B4303936B06C3c) |
| `External` | Interfaces: Agent ID registry, ERC-20, PancakeSwap V2 (compiled into the contracts above) | — |

Solidity 0.8.28, via-IR, optimizer 200 runs, EVM Cancun. OpenZeppelin Contracts v5.

## Build

```bash
npm install
npm run compile
```

Artifacts (ABI + bytecode + the Sourcify standard input) are written to `contracts/build/`.

## License

MIT — see [LICENSE](LICENSE).
