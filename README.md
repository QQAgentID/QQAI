# QQAI

**QQ Agentic ID (QQAID)** — an Agent ID-gated NFT collection on BNB Chain, paired with the **$QQAI** token.

Holding a Binance Agent ID is the key: it unlocks the free mint, the paid mint, token claims and mining.

- **Website:** https://getqqai.xyz
- **Mint opens:** December 2, 2026, 08:00 (UTC+8)
- **Chain:** BNB Smart Chain (BSC, chain id 56)

## The NFT — QQ Agentic ID

| | |
|---|---|
| Total supply | 111,111 |
| Tiers | Common 66,667 · Rare 27,778 · Epic 12,222 · Legendary 4,444 |
| Tier weights | 1 / 2 / 3 / 4 |
| Free mint | 1,111 slots, first-come-first-served, 1 per Agent ID (0.0001 BNB network fee) |
| Paid mint | 110,000 at a flat **1.1 USDT** each, max 10 per wallet, plus unlimited referral tickets |
| Market | Built-in non-custodial marketplace, 2.5% fee |

Tier assignment is committed on-chain before the reveal (`sha256` commitment published in `QQAITierData`); the reveal happens when the token goes live.

## The token — $QQAI

- Emission model with a hard cap of **111 trillion $QQAI**. Nothing is pre-minted; supply is created only by the claim, mining, liquidity and team contracts.
- The token **goes live automatically when total mints reach 11,111**.
- 100% of paid-mint proceeds stay in escrow inside `QQAINFT`. At every 11,111-mint milestone anyone can call `releaseEscrow()`: **80% funds liquidity, 15% buy back & burn, 5% team**.
- **Safety net:** if the first milestone (11,111 mints) is not reached within 24 hours of opening, paid minters can burn their NFT for a 90% refund (0.99 USDT).

### One claim per NFT — two doors

Every NFT carries one token allotment: **250,000,000 $QQAI × tier weight**, stepped down at each 11,111-mint milestone.

- **KEEP (35%)** — the NFT survives and keeps mining.
- **COLLAPSE (100%)** — the NFT is burned; 90% pays out immediately and 10% flows into the Collapse Pool, shared pro-rata by tier weight among NFTs still alive when the claim period ends.

Claim fees are charged in USDT, tiered by NFT tier; the first claim per wallet is free.

### Mining with a thermostat

Living NFTs mine **13,770 $QQAI × tier weight per day** from the moment the token goes live. A thermostat adjusts the rate against the recorded reference price (P0) of the official pool:

| Spot price vs P0 | Rate |
|---|---|
| ≥ 2× P0 | ×1.5 |
| ≥ P0 | ×1.0 |
| ≥ 0.5× P0 | ×0.5 |
| < 0.5× P0 | ×0.25 |

### Liquidity, on autopilot

`QQAIPoolManager` is ownerless and has no withdraw function. At each milestone it pairs a fixed $QQAI tranche with the escrowed USDT on PancakeSwap V2 and **burns 100% of the LP tokens**. The first milestone also registers the official pair and records the reference price for the thermostat.

Trades against the official pair carry a 2% buy / 2% sell tax; wallet-to-wallet transfers are untaxed.

## Contracts

| Contract | Role |
|---|---|
| `QQAINFT` | The NFT sale: free + paid mint, escrow, milestone releases, refund safety net |
| `QQAIToken` | $QQAI ERC-20: capped emission, minter lock, pair tax |
| `QQAIClaim` | KEEP / COLLAPSE claims, Collapse Pool, mining accrual + thermostat |
| `QQAIPoolManager` | Automatic liquidity provisioning, LP burn, reference price |
| `QQAIMarket` | Non-custodial NFT marketplace (2.5% fee) |
| `QQAITierData` | On-chain tier-assignment data chunks |
| `External` | Interfaces: Agent ID registry, ERC-20, PancakeSwap V2 |

Solidity 0.8.28, via-IR, optimizer 200 runs, EVM Cancun. OpenZeppelin Contracts v5.

## Build

```bash
npm install
npm run compile
```

Artifacts (ABI + bytecode + the Sourcify standard input) are written to `contracts/build/`.

Deployment parameters live in `contracts/production-config.example.json` — placeholder addresses included; fill in your own before deploying.

## License

MIT — see [LICENSE](LICENSE).
