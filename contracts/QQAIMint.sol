// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentRegistry, IPancakeFactory, IPancakePair, IPancakeRouter} from "./External.sol";
import {QQAIToken} from "./QQAIToken.sol";

/// @notice QQAIMint — the QQAI token sale: direct free + paid minting of
///         $QQAI, gated by the Binance Agent ID registry (owner decision
///         25 Nov 2026, PARAMS §0ab — this contract replaces the NFT sale,
///         the claim contract and the abandoned bonding-curve design).
///
///         PUBLIC BUCKET: the free and paid mints share one public bucket
///         (PUBLIC_CAP, 675B of the 1T cap in production). Every free or
///         paid mint draws from it; minting stops for good once it is
///         exhausted. The free tranche is carved out of the same bucket.
///
///         FREE MINT (the token is free; joining carries a fixed
///         ENTRY GATE FEE, owner decision 25 Nov 2026, §0ab.11):
///           - FREE_GATE_FEE_WEI = 0.0001 BNB exactly per free mint
///             (msg.value must equal it to the wei — less or more
///             reverts FreeGateFee). The fee is forwarded to TREASURY
///             inside the mint; if that send fails the mint still
///             succeeds and the fee accrues in freeGateFeePending
///             until payFreeGateFees() retries it — the same
///             anti-brick pattern as the dev share. If all 555 free
///             mints are taken, the gate collects 0.0555 BNB total;
///           - FREE_PER_MINT = 16,500,000 QQAI per mint;
///           - at most FREE_MAX_PER_AGENT = 2 free mints per Agent ID;
///           - at most FREE_QUOTA_AGENTS = 1,111 unique Agent IDs may ever
///             free-mint;
///           - a hard GLOBAL cap of FREE_TOTAL_CAP = 555 free mints in
///             total, whoever mints them (owner decision 25 Nov 2026,
///             §0ab.4). One Agent ID may still use both of its mints
///             inside the cap; the free tranche is therefore at most
///             555 x 16.5M = 9.1575B.
///
///         PAID MINT — BATCHES OF 1,111 + LADDER + AUTOMATIC POOL
///         (owner decisions 25 Nov 2026, §0ab.3/§0ab.4/§0ab.5): the paid
///         sale runs in sequential batches of PAID_BATCH_SIZE mints
///         (production: 1,111). There is NO time gate between batches:
///         batch N+1 opens the moment batch N is full, and batches keep
///         running as counting units until the paid bucket (PAID_BUCKET
///         = PUBLIC_CAP minus the free tranche's maximum, production
///         675B - 9.1575B = 665.8425B) is exhausted — pre-pool by full
///         deliveries, post-pool by top-ups (§0ab.10; the final mint
///         may therefore be partial). At most
///         PAID_MAX_PER_AGENT mints per Agent ID (a mint-count cap in
///         BOTH phases — post-pool sales are still per-mint batch-unit
///         sales, so no conversion to a BNB-value cap is needed).
///
///         TOKEN PER MINT (both phases): the ladder leg falls 5% per
///         batch from PAID_BASE_PER_MINT (production: 50,000,000 QQAI),
///         floored at PAID_AMOUNT_FLOOR (production: 10,000,000 QQAI) —
///         amount of batch n = max(ladder, floor). The floor would
///         first bind at batch 33 in a direct-draw sale; under the
///         §0ab.10 top-up drain the sale can run far longer, so the
///         floor is a live guard: the per-mint package can never decay
///         toward zero. What the buyer actually RECEIVES is the
///         package plus the Agent ID bonus — amount x 1.05 in both
///         phases (§0ab.10, AGENT_ID_BONUS_BPS).
///
///         PRICE — PRE-POOL (batches 1..POOL_OPEN_BATCH): the ladder leg
///         rises 5% per batch from PAID_BASE_PRICE_WEI (production:
///         0.003 BNB) — price of batch n as in batchPriceWei.
///
///         DEV SHARE — 20% OF EVERY PAID MINT'S GROSS (owner decision
///         25 Nov 2026, §0ab.7; basis restated for the buy-through
///         model, §0ab.10). PRE-POOL: paid-mint BNB is never forwarded
///         per mint; it accrues against the running batch
///         (batchAccruedBnb) and SETTLES in the mint that fills the
///         batch — 20% of the batch's gross is the dev share
///         (production pre-pool total 2.873129325 BNB) and the
///         remaining 80% becomes heldBnb, the pool seed (production:
///         11.4925173 BNB, seeding 141,862,246,986.83 QQAI at the
///         unchanged batch-4 price, so the opening price does NOT
///         move). Since §0ab.13 the pre-pool phase is a FULL ESCROW
///         HOLD: the dev share is not sent at settlement — nothing is
///         released pre-pool at all, neither per mint nor per batch.
///         The 20% accrues inside this contract (pendingDevShareBnb)
///         and is released once, in the pool opening — split
///         §0ab.15: 15% of gross to BUYBACK_RECEIVER, 5% to TREASURY
///         (a failed send there is absorbed into the leg's pending
///         bucket, retried by payBuybackShare() / payDevShare()).
///         Every pre-pool payment
///         therefore stays fully backed in-contract while the refund
///         window can still open (see REFUND below). Settlement
///         itself is pure accounting pre-pool and cannot brick a
///         mint. POST-POOL (§0ab.10, release restated §0ab.13): the
///         80% is spent by this contract through the pool inside the
///         mint (see BUY-THROUGH below), while the mint's 20% share
///         only ACCRUES in pendingDevShareBnb and is released
///         once per batch completion (split §0ab.15); a failed swap reverts
///         the whole mint, so no state changes and no funds are ever
///         left hanging. devSharePaid is the reconciliation
///         counter across both phases: at all times, contract BNB =
///         heldBnb + reserveBnb + batchAccruedBnb + devSharePending
///         + freeGateFeePending (the §0ab.11 gate-fee bucket)
///         + pendingDevShareBnb (§0ab.13: the accrued dev share
///         awaiting its release — the pool opening pre-pool, the
///         next batch completion post-pool) + liquidityReserveBnb
///         (§0ab.13: the refund liquidity share)
///         + buybackSharePending (§0ab.15: a split buyback leg whose
///         send failed at its release, awaiting payBuybackShare())
///         (reserveBnb is legacy §0ab.7 state: under §0ab.10 no new
///         post-pool BNB is held — the 80% goes into the swap — but
///         the bucket, its withdrawReserveBnb() path and the
///         recoverPublicBucket() sweep are unchanged).
///
///         AUTOMATIC POOL OPENING: the moment batch POOL_OPEN_BATCH
///         (production: 4) sells out — paid mint number
///         POOL_OPEN_BATCH x PAID_BATCH_SIZE (production: 4,444) — the
///         PancakeSwap V2 QQAI/WBNB pool opens: ALL held BNB (heldBnb
///         plus the §0ab.13 refund liquidity reserve,
///         liquidityReserveBnb) is seeded
///         with QQAI from the liquidity reserve in the amount
///         heldBnb x batchPerMint(4) / batchPriceWei(4), so the opening
///         spot price equals the batch-4 per-token price exactly. The
///         LP tokens go straight to the burn address (locked forever).
///         The opening is attempted inside the mint transaction that
///         fills batch 4 (through a self-call whose failure is caught);
///         if that attempt fails for any reason, anyone can complete it
///         by calling the permissionless openPool() — the sale itself
///         never bricks on the opening. openPool() is also callable
///         once the paid sale has finished, so a sale that ends before
///         batch 4 (impossible at production geometry) still pools its
///         proceeds. Wiring: this contract must be registered as the
///         token's pool manager (QQAIToken.setPoolManager) so it can
///         flip the pair (setPair) in the same flow — which also makes
///         its seeding transfers tax-exempt, keeping the seeded amounts
///         (and therefore the opening price) exact.
///
///         REFUND SAFETY NET (owner decisions 25 Nov 2026 03:22 WIB,
///         split corrected 03:23 WIB, §0ab.13): if the pool has still
///         not opened REFUND_DELAY (7 days) after START_TIME, the
///         refund window opens (refundOpen()) and stays open until
///         the pool opens — the opening closes it PERMANENTLY.
///         refund() is all-or-nothing per wallet and covers PRE-POOL
///         paid mints only (post-pool mints are never recorded, and
///         the window is shut by then anyway): the wallet's records
///         (paidBnbPaid / paidTokensReceived — the BNB it paid and
///         the full delivery it received, Agent ID bonus included)
///         are zeroed, the full delivery is burned back out of
///         circulation (the bucket counters rewind by the same
///         amount, so the tokens return to the paid bucket; the
///         batch counting — paidMintTotal and the per-agent mint
///         counts — does NOT rewind), and the payment splits 80%
///         back to the wallet, 15% into liquidityReserveBnb (which
///         joins the pool seed if the pool ever opens; if it never
///         does, that BNB simply stays in this contract as a
///         liquidity reserve — there is deliberately NO owner
///         withdrawal path for it, and the bucket recovery below
///         does not sweep it) and 5% to TREASURY, sent inside the
///         refund (a failed send accrues into devSharePending like
///         every other treasury-bound share). The refund is funded
///         out of the pre-pool proceeds buckets in aggregate —
///         batchAccruedBnb, then heldBnb, then
///         pendingDevShareBnb — possible because pre-pool is a full
///         escrow hold (see DEV SHARE above): while the window can
///         open, every pre-pool payment is still fully backed here.
///         Free mints carry no payment and can never be refunded.
///
///         SELL TAX — GRADUATED, TWO HIGH BATCHES ONLY (owner
///         decisions 25 Nov 2026, §0ab.6): the DEX sell tax is 10%
///         while the first SELL_TAX_HIGH_BATCHES post-pool batches run
///         (production: batches 5 and 6) and returns DIRECTLY to the
///         flat permanent 2% when the next batch opens (production:
///         batch 7) — there are no intermediate 8/6/4 steps (a stepped
///         ladder chosen at 01:40 WIB was simplified by the owner at
///         01:42 WIB). QQAIToken.setPair raises the sell tax to 10% at
///         the pool opening; this contract steps it down inside the
///         mint transaction that opens the first normal batch, through
///         a self-call whose failure is caught (the mint never bricks
///         on the tax step), and anyone can repair a missed step by
///         calling the permissionless syncSellTax(). The buy tax stays
///         a flat 2% in every phase; all trade tax goes to TREASURY.
///
///         BUY-THROUGH MINT — POST-POOL (batch 5 onwards; owner
///         decision 25 Nov 2026, §0ab.10 — supersedes the §0ab.9
///         direct spot-price mint before it ever finalised, and the
///         §0ab.8 batch-8 window closure before it): a post-pool paid
///         mint does NOT issue the package straight from the bucket.
///         Instead the buyer's BNB buys real tokens through the pool,
///         so every mint is genuine buy pressure and pushes the price
///         up. Mechanics, all inside one atomic transaction:
///           1. The buyer pays bnbGross = package x spot / (1 + price
///              bonus), where spot is the pool's live BNB-per-token
///              price and the price bonus FADES per batch group
///              (§0ab.9 schedule): batches 5-8 +5%, batches 9-12 +3%,
///              batches 13-16 +1%, batch 17 onwards 0% (bnbGross is
///              then exactly the package's spot value). bnbGross is
///              what currentMintPriceWei() returns; the price is
///              computed on the BASE package amount.
///           2. 20% of bnbGross is the dev share — it only accrues
///              in pendingDevShareBnb inside this contract and is
///              released once, when the running batch
///              completes (§0ab.13 timing, §0ab.15 split; see DEV SHARE above).
///           3. The remaining 80% is swapped by this contract through
///              the PancakeSwap router (swapExactETHForTokensSupporting
///              FeeOnTransferTokens, WBNB -> QQAI, output to this
///              contract) with a min-out of the spot quote minus
///              SWAP_TOLERANCE_BPS. This contract is the token's pool
///              manager and therefore tax-exempt, so the swap output
///              arrives UN-taxed (no double cut) and equals the quote
///              exactly. A failed swap reverts the whole mint.
///           4. The buyer receives EXACTLY the batch package plus the
///              Agent ID bonus (§0ab.10): amount x 1.05 in total —
///              the swap output, topped up from the paid bucket by
///              topUp = amount x 1.05 - swapReceived, minted fresh.
///         BUCKET DRAIN: the bucket is therefore drained ONLY by the
///         top-up (plus the full deliveries pre-pool), so its drain
///         rate depends on the market price — the higher the price,
///         the more of each package the swap covers and the slower
///         the bucket drains; there is no fixed sell-out mint count.
///         The sale runs until the bucket can no longer cover the next
///         top-up: the final mint may then be PARTIAL, delivering the
///         remaining bucket plus its swap output, after which the
///         bucket is empty and paidFinished() is permanently true;
///         any remainder left untaken counts as the LP dust
///         (lpDustAmount) exactly like the pre-pool sell-out pattern.
///         Batches remain pure counting units throughout (1,111 mints
///         per batch, ladder amounts with the 10M floor); the ladder
///         BNB price no longer applies post-pool.
///
///         LADDER ARITHMETIC — DOCUMENTED DEVIATION (§0ab.5): the
///         ladder is applied ITERATIVELY (one multiply/divide per batch
///         step, floor per step), not in the §0ab.3 closed form
///         (base x step^exp / den^exp with a single final floor). The
///         closed form's powers overflow uint256 at batch indices
///         beyond roughly 40 (100^40 is about 10^80, past the 2^256
///         bound), so it cannot be evaluated on-chain as a general
///         view. The iterative values agree with the closed
///         form exactly at batches 1-4 (the pre-pool phase) and differ
///         by at most a few wei of token/price afterwards (batch 18:
///         5 wei of price, 2 wei of token) — economically zero, and the
///         production config + test simulation use the identical
///         iterative rule, so contract, config and tests agree exactly.
///         Production anchors that stay exact under §0ab.10: the
///         pre-pool phase is untouched — batches 1-4 deliver
///         216,387,734,062.5 QQAI (the ladder packages x 1.05 Agent ID
///         bonus) for a gross of 14.365646625 BNB, settling 20/80
///         (§0ab.7): the 80% hold of 11.4925173 BNB seeds the pool
///         with 141,862,246,986.83 QQAI at the batch-4 price (leaving
///         about 83.14B of the LP base un-seeded, held for later).
///         Post-pool there are no fixed totals: the bucket drains by
///         top-ups at a price-dependent rate (see BUY-THROUGH above).
///
///         WINDOW: nothing can be minted before START_TIME (production
///         default 1796169600 = 2 Dec 2026 08:00 UTC+8). The owner can
///         move the start (dev control, PARAMS §0r).
///
///         NON-PUBLIC ALLOCATIONS (each counted against the token's
///         MAX_SUPPLY, never issued twice):
///           - reserve & marketing: RESERVE_ALLOCATION (50B) minted to
///             TREASURY by releaseReserve(), exactly once;
///           - liquidity reserve: LP_ALLOCATION (225B base) PLUS the
///             paid sale's leftover dust once it finishes. The reserve
///             is minted to this contract in pieces as needed, tracked
///             by lpBaseMinted / lpTopUpMinted: the pool opening mints
///             any un-minted base shortfall itself before seeding;
///             releaseLpReserve() (owner) mints whatever entitlement is
///             still outstanding (base remainder + dust once finished)
///             and reverts when nothing is outstanding. The seeded part
///             (lpSeededTokens) sits in the pair; the un-seeded rest
///             stays held here until the owner moves it out with
///             transferLpReserve(). Sold maximum + effective LP +
///             reserve + team sum exactly to the 1T cap.
///         The team allocation is NOT handled here: it vests through
///         QQAIVesting.
///
///         BUCKET RECOVERY (owner escape hatch, §0r): the un-minted
///         remainder of the public bucket can never be stranded in this
///         contract — recoverPublicBucket() lets the owner mint the
///         entire remainder straight to an address of his choice and
///         close the bucket for good; it also sweeps any BNB still held
///         for the pool (pool not yet open) to TREASURY, so pre-pool
///         proceeds can never be stranded either. One deliberate
///         exception (§0ab.13): the refund liquidity reserve
///         (liquidityReserveBnb) is NOT swept — it has no owner
///         withdrawal path by design and stays in this contract. It is deliberately
///         NOT gated by the pause flag or the start time, so the
///         recovery path stays callable exactly when everything else
///         is stopped. Recovery and the LP dust top-up are kept
///         mutually consistent via lpTopUpMinted, exactly as before.
///
///         DEV CONTROL (§0r): ownership is transferable (deliberately no
///         renounce), the owner can pause/unpause both mints in an
///         emergency, adjust the paid per-agent max and move the start
///         time. The free-mint geometry, the ladder bases/steps/floor
///         and the bucket/allocation sizes are constructor-fixed.
///
///         This contract must be registered as a minter on QQAIToken,
///         and as its pool manager for the automatic pool opening.
contract QQAIMint {
    /// @notice Liquidity reserve BASE (225 billion, 22.5% of the 1T
    ///         cap): minted to this contract (by releaseLpReserve() or
    ///         by the pool opening itself), part of it seeds the pool at
    ///         batch 4 and the rest is held for later use. The
    ///         EFFECTIVE liquidity reserve also includes the paid sale's
    ///         leftover dust once the sale is finished (production:
    ///         +15,220,907.86 QQAI) — see lpReserveAmount().
    uint256 public constant LP_ALLOCATION = 225_000_000_000 ether;
    /// @notice Ladder steps (owner decision 25 Nov 2026, §0ab.3): the
    ///         paid price rises 5% per batch, the paid amount falls 5%
    ///         per batch — applied iteratively, one step per batch (see
    ///         the header for the documented deviation from the closed
    ///         form).
    uint256 public constant PRICE_STEP_NUM = 105;
    uint256 public constant PRICE_STEP_DEN = 100;
    uint256 public constant AMOUNT_STEP_NUM = 95;
    uint256 public constant AMOUNT_STEP_DEN = 100;
    /// @notice Post-pool mint bonus schedule (owner decision 25 Nov
    ///         2026, §0ab.9, carried into the buy-through model of
    ///         §0ab.10 — replaces the §0ab.8 batch-8 window closure):
    ///         the BNB price of a post-pool mint is the package's spot
    ///         value divided by (1 + bonus), where the bonus FADES per
    ///         post-pool batch group: BONUS_HIGH_BPS (5%) for batches
    ///         POOL_OPEN_BATCH+1 .. +BONUS_TIER_BATCHES (production:
    ///         batches 5-8), then BONUS_MID_BPS (3%) for the next group
    ///         (batches 9-12), BONUS_LOW_BPS (1%) for the next (batches
    ///         13-16), and 0 from batch 17 onwards — the mint then
    ///         costs exactly the package's spot value.
    uint256 public constant BONUS_HIGH_BPS = 500;
    uint256 public constant BONUS_MID_BPS = 300;
    uint256 public constant BONUS_LOW_BPS = 100;
    uint256 public constant BONUS_TIER_BATCHES = 4;
    /// @notice Agent ID bonus (owner decision 25 Nov 2026 02:06 WIB,
    ///         §0ab.10): EVERY paid mint — pre-pool and post-pool —
    ///         delivers AGENT_ID_BONUS_BPS (5%) MORE tokens than the
    ///         batch package: the buyer receives amount x 1.05. This
    ///         is an identity bonus on the TOKEN side, stacking on top
    ///         of the fading PRICE bonus above (which discounts the
    ///         BNB side). The extra 5% is drawn from the paid bucket
    ///         like the rest of the delivery: pre-pool the full
    ///         amount x 1.05 is minted from the bucket; post-pool the
    ///         pool swap plus the bucket top-up deliver amount x 1.05
    ///         in total. The BNB price is always computed on the base
    ///         package amount — the extra tokens are free to the buyer.
    uint256 public constant AGENT_ID_BONUS_BPS = 500;
    /// @notice Free-mint entry gate fee (owner decision 25 Nov 2026,
    ///         §0ab.11): every freeMint must carry EXACTLY this much
    ///         BNB (0.0001 BNB — the same entry-gate pattern as the
    ///         owner's other projects: the token is free, joining is
    ///         not). Forwarded to TREASURY inside the mint; a failed
    ///         send accrues in freeGateFeePending instead of bricking
    ///         the mint (payFreeGateFees() retries it).
    uint256 public constant FREE_GATE_FEE_WEI = 100_000_000_000_000;
    /// @notice Slippage tolerance for the buy-through swap's min-out
    ///         (1% under the spot quote). The quote is taken from the
    ///         same reserves the swap executes against inside the same
    ///         transaction, so the executed output equals the quote;
    ///         the tolerance only absorbs pathological rounding.
    uint256 public constant SWAP_TOLERANCE_BPS = 100;
    /// @notice Dev share of every paid mint's proceeds (owner decision
    ///         25 Nov 2026, §0ab.7; release model restated 25 Nov 2026
    ///         03:26–03:27 WIB, §0ab.13): DEV_SHARE_BPS (20%) of each
    ///         paid mint's gross is the dev share — calculated per
    ///         mint (so the amounts are exactly the §0ab.7 ones) but
    ///         NEVER transferred per mint. PRE-POOL the sale is a full
    ///         escrow hold: NOTHING is released — no per-mint and no
    ///         per-batch release; the whole gross stays in this
    ///         contract (the 20% share accrues in pendingDevShareBnb)
    ///         and the split runs ONCE at the pool opening: 80%
    ///         (heldBnb) seeds the LP and the accumulated 20% is
    ///         released in that same moment — split §0ab.15 (15% of
    ///         gross to BUYBACK_RECEIVER, 5% to TREASURY). Because
    ///         nothing leaves pre-pool, every pre-pool payment stays
    ///         fully backed in-contract — which is also exactly what
    ///         keeps the §0ab.13 refund split (80/15/5) solvent for
    ///         any pre-pool buyer. POST-POOL: each mint's 20% accrues
    ///         in pendingDevShareBnb and is released ONCE
    ///         per batch completion (each multiple of PAID_BATCH_SIZE
    ///         paid mints), covering exactly that batch's
    ///         accumulation — split §0ab.15 (15% of gross to
    ///         BUYBACK_RECEIVER, 5% to TREASURY); the other 80% is
    ///         swapped through the pool inside the mint (§0ab.10). A
    ///         release whose send fails is absorbed into the leg's
    ///         pending bucket (payDevShare() / payBuybackShare()
    ///         retry it) — a release can never brick a mint either.
    uint256 public constant DEV_SHARE_BPS = 2000;
    /// @notice Split of the dev share at its release points (owner
    ///         decision 25 Nov 2026, §0ab.15 — the RELEASE ITSELF is
    ///         unchanged from §0ab.13: once at the pool opening for the
    ///         pre-pool accumulation, then once per batch completion
    ///         post-pool; only the DESTINATION of the released BNB is
    ///         split). BUYBACK_SHARE_BPS (75%) of every released amount
    ///         is the buy back & burn share — exactly 15% of the mint
    ///         gross — sent in BNB to BUYBACK_RECEIVER; the remaining
    ///         25% — exactly 5% of the gross — is the team share, sent
    ///         in BNB to TREASURY. The buy back & burn itself is
    ///         executed off-contract from BUYBACK_RECEIVER (this
    ///         contract never holds or swaps the share), so a release
    ///         stays a pair of plain BNB sends with the same anti-brick
    ///         absorption as before: a failed send accrues into the
    ///         leg's own pending bucket (devSharePending for the
    ///         TREASURY leg, buybackSharePending for the buyback leg)
    ///         and is retried by payDevShare() / payBuybackShare().
    ///         NOT to be confused with the §0ab.13 refund split: a
    ///         refund's 15% still goes to liquidityReserveBnb and its
    ///         5% to TREASURY — a different flow entirely.
    uint256 public constant BUYBACK_SHARE_BPS = 7500;
    /// @notice Receiver of the buy back & burn share (15% of every paid
    ///         mint's gross, in BNB): the dev operations wallet (zech),
    ///         fixed in code (§0ab.15). It receives NOTHING else from
    ///         this contract — the 5% team share, the free-mint gate
    ///         fees and every other TREASURY-bound flow keep going to
    ///         TREASURY exactly as before.
    address public constant BUYBACK_RECEIVER = 0xF7769F7Ad815d8D425AFD6F3Ec2E9800f11766bA;
    /// @notice Refund safety net (owner decisions 25 Nov 2026 03:22 and
    ///         03:23 WIB, §0ab.13): if the pool has still not opened
    ///         REFUND_DELAY (7 days) after the start, pre-pool paid
    ///         buyers can refund() — they return their full paid-mint
    ///         delivery (burned back into the bucket) and their payment
    ///         splits REFUND_BPS (80%) back to the buyer,
    ///         REFUND_LIQUIDITY_BPS (15%) into the liquidity reserve
    ///         (liquidityReserveBnb, which joins the pool seed if the
    ///         pool ever opens) and REFUND_TREASURY_BPS (5%) to
    ///         TREASURY, sent inside the refund. The three shares sum
    ///         to exactly 100% (the treasury share takes the rounding
    ///         remainder).
    uint256 public constant REFUND_DELAY = 604_800;
    uint256 public constant REFUND_BPS = 8000;
    uint256 public constant REFUND_LIQUIDITY_BPS = 1500;
    uint256 public constant REFUND_TREASURY_BPS = 500;
    /// @notice Graduated sell tax (owner decisions 25 Nov 2026,
    ///         §0ab.6): the DEX sell tax is SELL_TAX_HIGH_BPS for the
    ///         first SELL_TAX_HIGH_BATCHES post-pool batches, then
    ///         SELL_TAX_NORMAL_BPS flat for good — a single step down,
    ///         no intermediate ladder.
    uint256 public constant SELL_TAX_HIGH_BPS = 1000;
    uint256 public constant SELL_TAX_NORMAL_BPS = 200;
    uint256 public constant SELL_TAX_HIGH_BATCHES = 2;
    /// @notice The pool opens automatically when this batch sells out
    ///         (owner decision 25 Nov 2026, §0ab.5).
    uint256 public constant POOL_OPEN_BATCH = 4;
    /// @notice LP tokens from the pool seeding are sent here — locked
    ///         forever (the project's standing LP-burn policy, §0).
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Reserve & marketing allocation (50 billion, 5% of the cap):
    ///         minted to TREASURY by releaseReserve(). Mirrors
    ///         QQAIToken.RESERVE_ALLOCATION.
    uint256 public constant RESERVE_ALLOCATION = 50_000_000_000 ether;

    QQAIToken public immutable TOKEN;
    IAgentRegistry public immutable REGISTRY;
    /// @notice Receives the 5% team leg of the per-batch dev share of
    ///         paid-mint BNB (§0ab.15 split — the 15% buy back & burn
    ///         leg goes to BUYBACK_RECEIVER), any BNB swept by a bucket
    ///         recovery, and the reserve allocation.
    address public immutable TREASURY;
    /// @notice PancakeSwap V2 router used for the pool seeding
    ///         (production: 0x10ED43C718714eb63d5aA57B78B54704E256024E).
    ///         The factory is read from it (production factory:
    ///         0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73).
    address public immutable ROUTER;
    /// @notice WBNB (production: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) —
    ///         the pool's quote token.
    address public immutable WBNB;

    /// @notice Contract owner (dev control, §0r): transferable, never
    ///         renounced by design (no renounce function exists).
    address public owner;

    /// @notice Total size of the shared free+paid public bucket.
    uint256 public immutable PUBLIC_CAP;
    /// @notice QQAI minted so far against PUBLIC_CAP (free + paid).
    uint256 public publicMinted;
    /// @notice Maximum the free tranche can ever take from PUBLIC_CAP:
    ///         FREE_TOTAL_CAP x FREE_PER_MINT (production: 9.1575B).
    ///         The paid sale may never touch this reserve, so paid
    ///         minting can never starve the free tranche.
    uint256 public immutable FREE_BUCKET_MAX;
    /// @notice The paid sale's bucket: PUBLIC_CAP - FREE_BUCKET_MAX
    ///         (production: 665.8425B; floored at 0 for toy geometries
    ///         whose free maximum overshoots the bucket). The ladder
    ///         sale runs until this bucket cannot cover the next mint.
    uint256 public immutable PAID_BUCKET;
    /// @notice Set once the public bucket has been recovered by the
    ///         owner; releaseLpReserve() then mints only what is still
    ///         outstanding of the base (the dust already left via
    ///         recovery).
    bool public publicBucketRecovered;
    /// @notice Of the LP_ALLOCATION base, how much has been minted to
    ///         this contract so far (by releaseLpReserve() and/or by
    ///         the pool opening).
    uint256 public lpBaseMinted;
    /// @notice Dust component actually minted into the LP reserve
    ///         (0 until releaseLpReserve() runs after the paid sale
    ///         finished). recoverPublicBucket subtracts it so the dust
    ///         is never issued twice.
    uint256 public lpTopUpMinted;
    /// @notice QQAI of the liquidity reserve that the pool seeding put
    ///         into the pair (0 until the pool opens).
    uint256 public lpSeededTokens;

    /// @notice QQAI per free mint (production: 16,500,000).
    uint256 public immutable FREE_PER_MINT;
    /// @notice Max free mints per Agent ID (production: 2).
    uint256 public immutable FREE_MAX_PER_AGENT;
    /// @notice Max unique Agent IDs that may ever free-mint
    ///         (production: 1,111).
    uint256 public immutable FREE_QUOTA_AGENTS;
    /// @notice Hard global cap on the TOTAL number of free mints, whoever
    ///         mints them (production: 555 — so the free tranche is at
    ///         most 555 x FREE_PER_MINT = 9.1575B, even though a single
    ///         Agent ID may mint twice inside the cap).
    uint256 public immutable FREE_TOTAL_CAP;
    /// @notice Unique Agent IDs that have free-minted at least once.
    uint256 public freeAgentCount;
    /// @notice Total free mints performed so far, across all Agent IDs.
    uint256 public freeMintTotal;
    mapping(uint256 => uint256) public freeMintCountOf;
    mapping(uint256 => uint256) public paidMintCountOf;

    /// @notice Batch-1 BNB price of one paid mint (production:
    ///         0.003 BNB). Pre-pool, the running batch's price is derived
    ///         from it by the +5% ladder (batchPriceWei). Constructor-fixed.
    uint256 public immutable PAID_BASE_PRICE_WEI;
    /// @notice Batch-1 QQAI per paid mint (production: 50,000,000).
    ///         The running batch's amount is derived from it by the
    ///         -5% ladder (batchPerMint), in both phases.
    ///         Constructor-fixed.
    uint256 public immutable PAID_BASE_PER_MINT;
    /// @notice Floor under the per-mint ladder amount (production:
    ///         10,000,000 QQAI): amount of batch n =
    ///         max(ladder amount, PAID_AMOUNT_FLOOR), so the shrinking
    ///         ladder can still drain the whole paid bucket.
    ///         Constructor-fixed (0 disables the floor).
    uint256 public immutable PAID_AMOUNT_FLOOR;
    /// @notice Max paid mints per Agent ID (production default: 10).
    ///         The only paid parameter that stays owner-configurable.
    uint256 public paidMaxPerAgent;

    /// @notice Paid mints per batch (production: 1,111). Batches run
    ///         back-to-back with no time gate: the next batch starts the
    ///         moment the running one is full, until the paid bucket
    ///         runs dry (see PAID_BUCKET).
    uint256 public immutable PAID_BATCH_SIZE;
    /// @notice Total paid mints performed so far, across all Agent IDs.
    uint256 public paidMintTotal;
    /// @notice Total QQAI minted so far through the paid sale, drawn
    ///         against PAID_BUCKET.
    uint256 public paidMintedTokens;

    /// @notice The settled 80% share of pre-pool batches, held for the
    ///         pool seeding (the 20% dev share of each batch has
    ///         already been paid out at settlement). Zeroed by the
    ///         opening (or by a bucket recovery sweeping it to
    ///         TREASURY).
    uint256 public heldBnb;
    /// @notice Gross BNB accrued by the RUNNING batch's paid mints, not
    ///         yet settled. Settled (split 20/80) in the mint that
    ///         fills the batch; a bucket recovery sweeps it whole.
    uint256 public batchAccruedBnb;
    /// @notice The settled 80% share of post-pool batches, held by this
    ///         contract as a BNB reserve (§0ab.7 interpretation:
    ///         post-pool proceeds beyond the dev share stay with the
    ///         dev, in the contract). Owner-withdrawable via
    ///         withdrawReserveBnb(); also swept by recoverPublicBucket.
    uint256 public reserveBnb;
    /// @notice Cumulative dev share (20% of paid-mint gross) actually
    ///         RELEASED to its destinations — the reconciliation
    ///         counter (§0ab.7 amounts, §0ab.13 release model: at the
    ///         pool opening for the pre-pool accumulation, then once
    ///         per batch completion post-pool; §0ab.15 split: the sum
    ///         of treasurySharePaid + buybackSharePaid, plus any
    ///         unsplit amount a bucket-recovery sweep sent to
    ///         TREASURY, which is attributed here only). The 5%
    ///         treasury share of an executed refund (§0ab.13) is
    ///         counted here too, once actually sent — the same
    ///         accounting its devSharePending detour would produce.
    uint256 public devSharePaid;
    /// @notice Of devSharePaid, the part delivered to TREASURY as the
    ///         5% team leg of a release (§0ab.15), plus the 5%
    ///         treasury share of executed refunds (§0ab.13) once sent.
    uint256 public treasurySharePaid;
    /// @notice Of devSharePaid, the part delivered to BUYBACK_RECEIVER
    ///         as the 15% buy back & burn leg of a release (§0ab.15).
    uint256 public buybackSharePaid;
    /// @notice TREASURY-bound BNB whose send failed at its release
    ///         (a batch-completion release, the pool-opening release,
    ///         or a refund's 5% treasury share, §0ab.13); held here
    ///         (never lost, never mixed into another bucket) until
    ///         payDevShare() retries the send.
    uint256 public devSharePending;
    /// @notice Buyback-leg BNB (to BUYBACK_RECEIVER, §0ab.15) whose
    ///         send failed at its release; held here (never lost,
    ///         never mixed into another bucket) until
    ///         payBuybackShare() retries the send.
    uint256 public buybackSharePending;
    /// @notice Dev share accrued in-contract and NOT yet released
    ///         (§0ab.13): pre-pool this is the whole 20% accumulation
    ///         of every settled batch (released in the pool opening);
    ///         post-pool it is the running accumulation (released at
    ///         each batch completion). Includes devShareBatchAccrued
    ///         as its running-batch part — the two are never added
    ///         together in the balance invariant.
    uint256 public pendingDevShareBnb;
    /// @notice Of pendingDevShareBnb, the part accrued by the RUNNING
    ///         batch's post-pool buy-through mints (per-mint 20%
    ///         accruals, §0ab.13) — released (split §0ab.15) in the mint
    ///         that fills the batch, then reset to zero. Always zero
    ///         pre-pool (pre-pool accrual is computed at settlement
    ///         from batchAccruedBnb instead).
    uint256 public devShareBatchAccrued;
    /// @notice Refund accounting (§0ab.13), PRE-POOL paid mints only:
    ///         total BNB gross a wallet has paid, and total QQAI it
    ///         was delivered (package + Agent ID bonus), recorded per
    ///         mint. refund() settles exactly these records; post-pool
    ///         mints are never recorded (the refund window is shut by
    ///         then anyway).
    mapping(address => uint256) public paidBnbPaid;
    mapping(address => uint256) public paidTokensReceived;
    /// @notice BNB earmarked as liquidity by refunds (§0ab.13): the
    ///         15% liquidity share of every refunded payment. Joins
    ///         the pool seed if the pool ever opens (see _openPool);
    ///         if it never does, it stays in this contract as a
    ///         liquidity reserve — deliberately NO owner withdrawal
    ///         path exists for it (withdrawReserveBnb does not touch
    ///         it and recoverPublicBucket does not sweep it).
    uint256 public liquidityReserveBnb;
    /// @notice Cumulative free-mint gate fees (§0ab.11) actually sent
    ///         to TREASURY — the reconciliation counter.
    uint256 public freeGateFeePaid;
    /// @notice Gate fees whose TREASURY send failed at mint time;
    ///         held here (never lost, never mixed into any other
    ///         bucket) until payFreeGateFees() retries the send.
    uint256 public freeGateFeePending;
    /// @notice True once the PancakeSwap pool has been opened.
    bool public poolOpen;
    /// @notice The QQAI/WBNB pair created at the pool opening (zero
    ///         until then). Mirrors QQAIToken.PAIR once flipped.
    address public pair;

    /// @notice Minting opens at this unix time (production default:
    ///         1796169600 = 2 Dec 2026 08:00 UTC+8). Owner-adjustable.
    uint256 public startTime;
    /// @notice Emergency pause for both mints (owner only).
    bool public paused;

    bool public reserveReleased;
    bool public lpReserveReleased;

    error NotOwner();
    error NotAgent();
    error NotStarted();
    error IsPaused();
    error FreeMaxed();
    error FreeQuotaFull();
    error FreeTotalCapFull();
    error FreeGateFee();
    error BucketEmpty();
    error NothingToRecover();
    error PaidValue();
    error PaidMaxed();
    error PaidSoldOut();
    error AlreadyReleased();
    error TransferFailed();
    error PoolAlreadyOpen();
    error PoolNotReady();
    error PoolUnavailable();
    error PoolSeedBalance();
    error PoolPriceZero();
    error NotSelf();
    error RefundClosed();
    error NothingToRefund();

    event FreeMint(address indexed buyer, uint256 indexed agentId, uint256 amount, uint256 mintNumber, uint256 feeWei);
    event PaidMint(address indexed buyer, uint256 indexed agentId, uint256 amount, uint256 mintNumber, uint256 paidWei, uint256 batch);
    /// @notice Post-pool buy-through breakdown (§0ab.10): the mint's
    ///         gross BNB, the dev share accrued for it (§0ab.13:
    ///         released at the batch completion, split §0ab.15), the BNB
    ///         swapped through the pool, the QQAI the swap delivered
    ///         to this contract, and the bucket top-up that completed
    ///         the buyer's package.
    event PaidSwap(uint256 indexed batch, uint256 grossWei, uint256 devShareWei, uint256 swapBnbWei, uint256 swapReceived, uint256 topUp);
    event PaidBatchFilled(uint256 indexed batch);
    event PoolOpened(address indexed pair, uint256 bnbSeeded, uint256 tokenSeeded, uint256 liquidity);
    event SellTaxSynced(uint256 bps);
    event BatchSettled(uint256 indexed batch, uint256 grossWei, uint256 devShareWei, uint256 restWei);
    /// @notice A §0ab.13 refund: the wallet's recorded pre-pool
    ///         payment (bnbPaid) split 80% back to the wallet
    ///         (bnbRefunded), 15% into the liquidity reserve
    ///         (bnbToLiquidity) and 5% to TREASURY (bnbToTreasury),
    ///         against tokensReturned QQAI burned back into the paid
    ///         bucket.
    event RefundPaid(
        address indexed wallet,
        uint256 bnbPaid,
        uint256 bnbRefunded,
        uint256 bnbToLiquidity,
        uint256 bnbToTreasury,
        uint256 tokensReturned
    );
    event DevShareSent(address indexed treasury, uint256 amount);
    /// @notice The 15% buy back & burn leg of a dev-share release
    ///         (§0ab.15) landed at BUYBACK_RECEIVER (indexed) — the
    ///         off-contract buy back & burn watcher keys on this
    ///         event (and on buybackSharePaid) to execute the buy.
    event BuybackShareSent(address indexed receiver, uint256 amount);
    event FreeGateFeeSent(address indexed treasury, uint256 amount);
    event ReserveBnbWithdrawn(address indexed to, uint256 amount);
    event PaidMaxPerAgentSet(uint256 max);
    event StartTimeSet(uint256 startTime);
    event PausedSet(bool paused);
    event ReserveReleased(address indexed treasury, uint256 amount);
    event LpReserveReleased(uint256 amount);
    event LpReserveTransferred(address indexed to, uint256 amount);
    event PublicBucketRecovered(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    struct Config {
        address token;
        address registry;
        address treasury;
        address router;
        address wbnb;
        uint256 publicCap;
        uint256 freePerMint;
        uint256 freeMaxPerAgent;
        uint256 freeQuotaAgents;
        uint256 freeTotalCap;
        uint256 paidBasePriceWei;
        uint256 paidBasePerMint;
        uint256 paidAmountFloor;
        uint256 paidMaxPerAgent;
        uint256 paidBatchSize;
        uint256 startTime;
    }

    constructor(Config memory c) {
        require(
            c.token != address(0) && c.registry != address(0) && c.treasury != address(0) && c.router != address(0)
                && c.wbnb != address(0),
            "address"
        );
        require(c.publicCap != 0 && c.freePerMint != 0 && c.paidBasePerMint != 0 && c.paidBasePriceWei != 0, "amount");
        require(c.freeMaxPerAgent != 0 && c.freeQuotaAgents != 0 && c.freeTotalCap != 0 && c.paidMaxPerAgent != 0, "max");
        require(c.paidBatchSize != 0, "batch");
        require(c.publicCap + LP_ALLOCATION + RESERVE_ALLOCATION <= 1_000_000_000_000 ether, "cap overflow");
        TOKEN = QQAIToken(c.token);
        REGISTRY = IAgentRegistry(c.registry);
        TREASURY = c.treasury;
        ROUTER = c.router;
        WBNB = c.wbnb;
        owner = msg.sender;
        PUBLIC_CAP = c.publicCap;
        FREE_PER_MINT = c.freePerMint;
        FREE_MAX_PER_AGENT = c.freeMaxPerAgent;
        FREE_QUOTA_AGENTS = c.freeQuotaAgents;
        FREE_TOTAL_CAP = c.freeTotalCap;
        PAID_BASE_PRICE_WEI = c.paidBasePriceWei;
        PAID_BASE_PER_MINT = c.paidBasePerMint;
        PAID_AMOUNT_FLOOR = c.paidAmountFloor;
        paidMaxPerAgent = c.paidMaxPerAgent;
        PAID_BATCH_SIZE = c.paidBatchSize;
        FREE_BUCKET_MAX = c.freeTotalCap * c.freePerMint;
        PAID_BUCKET = c.publicCap > FREE_BUCKET_MAX ? c.publicCap - FREE_BUCKET_MAX : 0;
        startTime = c.startTime;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Agent ID check — the exact pattern QQAINFT uses: handle
    ///      non-empty and the handle's token owned by `a`.
    function agentOf(address a) public view returns (uint256 id, bool ok_) {
        try REGISTRY.handleOf(a) returns (string memory handle) {
            if (bytes(handle).length == 0) return (0, false);
            id = uint256(keccak256(bytes(handle)));
            try REGISTRY.ownerOf(id) returns (address holder) {
                ok_ = holder == a;
            } catch {
                ok_ = false;
            }
        } catch {
            ok_ = false;
        }
        if (!ok_) id = 0;
    }

    /// @notice Whether the mint window has opened (start time reached and
    ///         not paused). Bucket exhaustion is checked per mint.
    function mintOpen() public view returns (bool) {
        return !paused && block.timestamp >= startTime;
    }

    /// @notice QQAI left in the public bucket.
    function publicRemaining() public view returns (uint256) {
        return PUBLIC_CAP - publicMinted;
    }

    /// @notice The batch the NEXT paid mint lands in (1-based).
    ///         Batches keep opening until the paid bucket runs dry —
    ///         after the sale is finished this view names the batch
    ///         that would have opened next, but paidMint reverts.
    function currentBatch() public view returns (uint256) {
        return paidMintTotal / PAID_BATCH_SIZE + 1;
    }

    /// @notice Paid mints already sold inside the running batch.
    function paidInCurrentBatch() public view returns (uint256) {
        return paidMintTotal % PAID_BATCH_SIZE;
    }

    /// @notice Total paid mints at which the pool opens: the moment
    ///         batch POOL_OPEN_BATCH sells out.
    function poolOpenTriggerMints() public view returns (uint256) {
        return POOL_OPEN_BATCH * PAID_BATCH_SIZE;
    }

    /// @notice The §0ab.13 refund deadline: START_TIME + REFUND_DELAY
    ///         (7 days). If the pool has not opened by then, the
    ///         refund window opens.
    function refundDeadline() public view returns (uint256) {
        return startTime + REFUND_DELAY;
    }

    /// @notice Whether the §0ab.13 refund window is open: the pool
    ///         has not opened, the deadline has passed, and the
    ///         public bucket has not been recovered (a recovery
    ///         sweeps the refundable proceeds to TREASURY, after
    ///         which refunds can no longer be funded). The pool
    ///         opening closes the window permanently.
    function refundOpen() public view returns (bool) {
        return !poolOpen && !publicBucketRecovered && block.timestamp >= refundDeadline();
    }

    /// @notice BNB price of one paid mint in `batch` (1-based) on the
    ///         pre-pool ladder: the +5% step applied iteratively, one
    ///         floor per step (see the header for why this is not the
    ///         §0ab.3 closed form). Post-pool this stays readable as the
    ///         reference ladder price, but paidMint charges
    ///         currentMintPriceWei instead.
    function batchPriceWei(uint256 batch) public view returns (uint256) {
        require(batch != 0, "batch");
        uint256 price = PAID_BASE_PRICE_WEI;
        for (uint256 i = 1; i < batch; i++) {
            price = price * PRICE_STEP_NUM / PRICE_STEP_DEN;
        }
        return price;
    }

    /// @notice QQAI per paid mint in `batch` (1-based): the -5% ladder
    ///         applied iteratively, floored at PAID_AMOUNT_FLOOR. This
    ///         amount applies in BOTH phases — post-pool only the price
    ///         changes, not the per-mint amount.
    function batchPerMint(uint256 batch) public view returns (uint256) {
        require(batch != 0, "batch");
        uint256 amount = PAID_BASE_PER_MINT;
        for (uint256 i = 1; i < batch; i++) {
            amount = amount * AMOUNT_STEP_NUM / AMOUNT_STEP_DEN;
        }
        if (amount < PAID_AMOUNT_FLOOR) amount = PAID_AMOUNT_FLOOR;
        return amount;
    }

    /// @notice Ladder price of the running batch (the pre-pool charge;
    ///         post-pool reference only — see currentMintPriceWei).
    function currentPriceWei() public view returns (uint256) {
        return batchPriceWei(currentBatch());
    }

    /// @notice QQAI the next paid mint pays out (running batch).
    function currentPerMint() public view returns (uint256) {
        return batchPerMint(currentBatch());
    }

    /// @notice QQAI a paid mint in `batch` actually DELIVERS: the
    ///         ladder package plus the Agent ID bonus (§0ab.10) —
    ///         batchPerMint x (10000 + AGENT_ID_BONUS_BPS) / 10000,
    ///         integer floor. Applies in BOTH phases; the BNB price is
    ///         always computed on the base package, never on this
    ///         boosted amount.
    function deliverPerMint(uint256 batch) public view returns (uint256) {
        return batchPerMint(batch) * (10_000 + AGENT_ID_BONUS_BPS) / 10_000;
    }

    /// @notice QQAI the next paid mint delivers (running batch).
    function currentDeliverPerMint() public view returns (uint256) {
        return deliverPerMint(currentBatch());
    }

    /// @notice The pair's live reserves, ordered (QQAI, WBNB). Both zero
    ///         until the pool opens.
    function spotReserves() public view returns (uint256 reserveQQAI, uint256 reserveWbnb) {
        if (pair == address(0)) return (0, 0);
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        if (IPancakePair(pair).token0() == address(TOKEN)) return (uint256(r0), uint256(r1));
        return (uint256(r1), uint256(r0));
    }

    /// @notice The mint bonus (bps) the schedule prescribes for
    ///         `batch` (1-based, §0ab.9): BONUS_HIGH_BPS for the first
    ///         BONUS_TIER_BATCHES post-pool batches (production:
    ///         batches 5-8, +5%), BONUS_MID_BPS for the next group
    ///         (batches 9-12, +3%), BONUS_LOW_BPS for the next (batches
    ///         13-16, +1%), and 0 from the following batch on (batch
    ///         17+, mint price = spot exactly). The value for pre-pool
    ///         batches is the high rate, which is never applied (the
    ///         pre-pool price is the ladder's, not the spot's).
    function bonusBpsForBatch(uint256 batch) public pure returns (uint256) {
        require(batch != 0, "batch");
        if (batch <= POOL_OPEN_BATCH + BONUS_TIER_BATCHES) return BONUS_HIGH_BPS;
        if (batch <= POOL_OPEN_BATCH + 2 * BONUS_TIER_BATCHES) return BONUS_MID_BPS;
        if (batch <= POOL_OPEN_BATCH + 3 * BONUS_TIER_BATCHES) return BONUS_LOW_BPS;
        return 0;
    }

    /// @notice The mint bonus (bps) in force for the running batch.
    function currentBonusBps() public view returns (uint256) {
        return bonusBpsForBatch(currentBatch());
    }

    /// @notice The BNB price the next paidMint actually charges
    ///         (bnbGross). Pre-pool: the running batch's ladder price.
    ///         Post-pool (§0ab.10): the BASE package's spot value with
    ///         the running batch's fading price bonus applied —
    ///         amount x spot x 10000 / (10000 + bonusBps), integer
    ///         floor — so the buyer pays exactly the package's spot
    ///         value once the bonus has faded to 0 (batch 17+). The
    ///         gross is then split 20% TREASURY / 80% pool swap inside
    ///         the mint (see the BUY-THROUGH header). Falls back to
    ///         the ladder price if the pair somehow reads empty
    ///         reserves.
    function currentMintPriceWei() public view returns (uint256) {
        uint256 batch = currentBatch();
        if (!poolOpen) return batchPriceWei(batch);
        (uint256 reserveQQAI, uint256 reserveWbnb) = spotReserves();
        if (reserveQQAI == 0 || reserveWbnb == 0) return batchPriceWei(batch);
        return batchPerMint(batch) * reserveWbnb * 10_000 / (reserveQQAI * (10_000 + bonusBpsForBatch(batch)));
    }

    /// @notice QQAI left in the paid bucket: the bucket minus what
    ///         paid mints drew from it (full deliveries pre-pool,
    ///         top-ups post-pool) minus any dust already minted into
    ///         the liquidity reserve (lpTopUpMinted — that dust has
    ///         been issued and can never be drawn twice).
    function paidBucketRemaining() public view returns (uint256) {
        return PAID_BUCKET - paidMintedTokens - lpTopUpMinted;
    }

    /// @notice The sell tax (bps) the schedule prescribes for `batch`
    ///         (1-based): SELL_TAX_HIGH_BPS while the batch is one of
    ///         the first SELL_TAX_HIGH_BATCHES post-pool batches
    ///         (production: batches 5 and 6 — the value for pre-pool
    ///         batches is the same high rate, which setPair applies at
    ///         the opening), SELL_TAX_NORMAL_BPS from the next batch on
    ///         (production: batch 7), permanently (§0ab.6).
    function sellTaxBpsForBatch(uint256 batch) public pure returns (uint256) {
        require(batch != 0, "batch");
        return batch <= POOL_OPEN_BATCH + SELL_TAX_HIGH_BATCHES ? SELL_TAX_HIGH_BPS : SELL_TAX_NORMAL_BPS;
    }

    /// @notice The sell tax currently in force on the token (0 until
    ///         the pair is set at the pool opening).
    function currentSellTaxBps() public view returns (uint256) {
        return TOKEN.sellTaxBps();
    }

    /// @notice True once the paid sale is finished for good.
    ///         Pre-pool: the bucket can no longer cover the next
    ///         mint's full delivery (package + Agent ID bonus).
    ///         Post-pool (§0ab.10): the bucket is empty, or it can no
    ///         longer cover the next mint's TOP-UP at the live spot
    ///         price (deliver minus the swap quote for the running
    ///         batch) — the final mint may still be taken partially
    ///         (bucket remainder + swap output) until the bucket is
    ///         empty, and any remainder left untaken is the LP dust.
    function paidFinished() public view returns (bool) {
        uint256 remaining = paidBucketRemaining();
        if (remaining == 0) return true;
        if (!poolOpen) return remaining < currentDeliverPerMint();
        (uint256 reserveQQAI, uint256 reserveWbnb) = spotReserves();
        if (reserveQQAI == 0 || reserveWbnb == 0) return false;
        uint256 gross = currentMintPriceWei();
        uint256 swapBnb = gross - gross * DEV_SHARE_BPS / 10_000;
        uint256 quote = IPancakeRouter(ROUTER).getAmountOut(swapBnb, reserveWbnb, reserveQQAI);
        uint256 deliver = currentDeliverPerMint();
        return deliver > quote && remaining < deliver - quote;
    }

    /// @notice The paid sale's leftover dust ENTITLEMENT: the
    ///         paid-bucket remainder once the sale is finished (the
    ///         bucket running dry), else 0. This is the amount that
    ///         folds into the liquidity reserve (lpTopUpMinted records
    ///         how much of it has been minted).
    function lpDustAmount() public view returns (uint256) {
        if (publicBucketRecovered) return 0;
        return paidFinished() ? paidBucketRemaining() : 0;
    }

    /// @notice The liquidity reserve's total entitlement: the 225B base
    ///         plus the paid sale's dust once it is finished — or only
    ///         the base if the bucket was recovered first (the dust
    ///         already left through the recovery).
    function lpReserveAmount() public view returns (uint256) {
        return LP_ALLOCATION + lpDustAmount();
    }

    function _requireOpenAgent() internal view returns (uint256 id) {
        if (paused) revert IsPaused();
        if (block.timestamp < startTime) revert NotStarted();
        bool ok_;
        (id, ok_) = agentOf(msg.sender);
        if (!ok_) revert NotAgent();
    }

    /// @notice Free mint: FREE_PER_MINT QQAI to the caller for the
    ///         fixed entry gate fee of FREE_GATE_FEE_WEI (0.0001 BNB,
    ///         §0ab.11 — msg.value must equal it exactly; less or more
    ///         reverts FreeGateFee). At most FREE_MAX_PER_AGENT per
    ///         Agent ID, FREE_QUOTA_AGENTS unique Agent IDs overall,
    ///         and FREE_TOTAL_CAP free mints in total across everyone;
    ///         draws from the shared public bucket. The fee is
    ///         forwarded to TREASURY inside the mint; a failed send
    ///         accrues in freeGateFeePending (retried by
    ///         payFreeGateFees()) and never bricks the mint. Unchanged
    ///         by the pool: free minting works the same before and
    ///         after the pool opens.
    function freeMint() external payable {
        if (msg.value != FREE_GATE_FEE_WEI) revert FreeGateFee();
        uint256 id = _requireOpenAgent();
        if (freeMintTotal >= FREE_TOTAL_CAP) revert FreeTotalCapFull();
        uint256 count = freeMintCountOf[id];
        if (count >= FREE_MAX_PER_AGENT) revert FreeMaxed();
        if (count == 0) {
            if (freeAgentCount >= FREE_QUOTA_AGENTS) revert FreeQuotaFull();
            freeAgentCount++;
        }
        if (publicRemaining() < FREE_PER_MINT) revert BucketEmpty();
        freeMintCountOf[id] = count + 1;
        freeMintTotal++;
        publicMinted += FREE_PER_MINT;
        TOKEN.mint(msg.sender, FREE_PER_MINT);
        // Gate fee (§0ab.11): forward to TREASURY; absorb a failed
        // send into freeGateFeePending exactly like the dev share, so
        // the fee path can never brick a free mint.
        (bool feeSent,) = TREASURY.call{value: FREE_GATE_FEE_WEI}("");
        if (feeSent) {
            freeGateFeePaid += FREE_GATE_FEE_WEI;
            emit FreeGateFeeSent(TREASURY, FREE_GATE_FEE_WEI);
        } else {
            freeGateFeePending += FREE_GATE_FEE_WEI;
        }
        emit FreeMint(msg.sender, id, FREE_PER_MINT, count + 1, FREE_GATE_FEE_WEI);
    }

    /// @notice Paid mint: exactly currentMintPriceWei() of BNB
    ///         (bnbGross) for the running batch's package, at most
    ///         paidMaxPerAgent per Agent ID. The buyer always RECEIVES
    ///         the package plus the Agent ID bonus — amount x 1.05
    ///         (§0ab.10). PRE-POOL the delivery is minted straight
    ///         from the paid bucket and the proceeds accrue per batch,
    ///         settling 20/80 in the batch-filling mint (§0ab.7
    ///         amounts; §0ab.13 release model: the 20% dev share only
    ///         accrues in pendingDevShareBnb — nothing is released
    ///         pre-pool — and the 80% is held for the pool seeding;
    ///         the accumulated 20% is released in the
    ///         pool opening, split §0ab.15). POST-POOL the mint is a buy-through
    ///         (§0ab.10): 20% of bnbGross accrues as the dev share
    ///         (released once, split §0ab.15, when the running batch
    ///         fills) and 80% is swapped through
    ///         the pool by this contract, the buyer receiving the swap
    ///         output plus a bucket top-up up to amount x 1.05; the
    ///         final mint may be partial (bucket remainder + swap
    ///         output), after which paidMint reverts permanently
    ///         (PaidSoldOut). The mint that fills batch
    ///         POOL_OPEN_BATCH also attempts the pool opening (failure
    ///         is caught — openPool() stays available to everyone).
    function paidMint() external payable {
        uint256 batch = currentBatch();
        uint256 deliver = deliverPerMint(batch);
        uint256 price = currentMintPriceWei();
        if (poolOpen && price == 0) revert PoolPriceZero();
        if (msg.value != price) revert PaidValue();
        uint256 id = _requireOpenAgent();
        uint256 count = paidMintCountOf[id];
        if (count >= paidMaxPerAgent) revert PaidMaxed();
        if (!poolOpen) {
            if (paidBucketRemaining() < deliver) revert PaidSoldOut();
            if (publicRemaining() < deliver) revert BucketEmpty();
            paidMintCountOf[id] = count + 1;
            paidMintTotal++;
            paidMintedTokens += deliver;
            publicMinted += deliver;
            // Proceeds accrue against the running batch (§0ab.7);
            // nothing is forwarded per mint pre-pool. The mint that
            // fills the batch settles it below.
            batchAccruedBnb += msg.value;
            // Refund accounting (§0ab.13): record this payment and
            // the full delivery against the wallet — refund() settles
            // exactly these records if the window ever opens.
            paidBnbPaid[msg.sender] += msg.value;
            paidTokensReceived[msg.sender] += deliver;
            TOKEN.mint(msg.sender, deliver);
            emit PaidMint(msg.sender, id, deliver, count + 1, msg.value, batch);
        } else {
            _buyThroughMint(batch, deliver, id, count);
        }
        if (paidMintTotal % PAID_BATCH_SIZE == 0) {
            emit PaidBatchFilled(batch);
            _settleBatch();
        }
        if (!poolOpen && paidMintTotal >= poolOpenTriggerMints()) {
            try this.tryOpenPool() {} catch {}
        }
        // Graduated sell tax (§0ab.6): on the mint that fills a batch
        // and thereby opens the next one, align the token's sell tax
        // with the schedule for the batch that just opened — in
        // practice this fires exactly once, when batch
        // POOL_OPEN_BATCH + SELL_TAX_HIGH_BATCHES + 1 opens (production:
        // batch 7) and the rate steps 10% -> 2%. The self-call's
        // failure is caught, so a failed step can never brick the
        // mint; syncSellTax() is the permissionless repair path.
        if (poolOpen && paidMintTotal % PAID_BATCH_SIZE == 0) {
            try this.trySyncSellTax() {} catch {}
        }
    }

    /// @dev The post-pool buy-through mint (§0ab.10). One atomic
    ///      transaction: the dev share is calculated and accrued
    ///      (§0ab.13 — never transferred per mint), then the swap
    ///      executes — if the swap (or anything else) reverts, the
    ///      whole mint including the accrual rolls back, so no state
    ///      changes and no funds are ever left hanging. The swap's
    ///      min-out is the spot quote (router.getAmountOut over the
    ///      live reserves) minus SWAP_TOLERANCE_BPS; because the quote
    ///      and the swap read the same reserves inside the same
    ///      transaction, the executed output equals the quote. This
    ///      contract is the token's pool manager and therefore
    ///      tax-exempt, so the pair -> contract leg of the swap is NOT
    ///      skimmed by the buy tax: `received` is the full swap
    ///      output, measured exactly as the contract's balance delta.
    ///      The buyer is then topped up from the paid bucket to the
    ///      full delivery (package + Agent ID bonus); if the bucket
    ///      cannot cover the whole top-up, this mint is the final,
    ///      partial one (bucket remainder + swap output).
    function _buyThroughMint(uint256 batch, uint256 deliver, uint256 id, uint256 count) internal {
        (uint256 reserveQQAI, uint256 reserveWbnb) = spotReserves();
        if (reserveQQAI == 0 || reserveWbnb == 0) revert PoolUnavailable();
        uint256 remaining = paidBucketRemaining();
        if (remaining == 0) revert PaidSoldOut();
        uint256 dev = msg.value * DEV_SHARE_BPS / 10_000;
        uint256 swapBnb = msg.value - dev;
        uint256 quote = IPancakeRouter(ROUTER).getAmountOut(swapBnb, reserveWbnb, reserveQQAI);
        // Dev share (§0ab.13): calculated per mint, NEVER transferred
        // per mint — it accrues in pendingDevShareBnb, tracked for
        // the running batch in devShareBatchAccrued, and is released
        // once, split §0ab.15, in the mint that fills the batch
        // (see _settleBatch). The PaidSwap event still records this mint's
        // exact share.
        if (dev != 0) {
            pendingDevShareBnb += dev;
            devShareBatchAccrued += dev;
        }
        uint256 balBefore = TOKEN.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(TOKEN);
        uint256 minOut = quote * (10_000 - SWAP_TOLERANCE_BPS) / 10_000;
        IPancakeRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapBnb}(
            minOut, path, address(this), block.timestamp
        );
        uint256 received = TOKEN.balanceOf(address(this)) - balBefore;
        uint256 topUp = 0;
        uint256 delivered;
        if (received >= deliver) {
            // Unreachable by construction (the swap spends 80% of the
            // package's discounted spot value, so its output is below
            // the delivery) — kept as a guard: the buyer gets exactly
            // the delivery and any excess stays in this contract.
            delivered = deliver;
            require(TOKEN.transfer(msg.sender, deliver), "transfer");
        } else {
            topUp = deliver - received;
            if (topUp > remaining) topUp = remaining;
            delivered = received + topUp;
            if (topUp != 0) {
                paidMintedTokens += topUp;
                publicMinted += topUp;
                TOKEN.mint(msg.sender, topUp);
            }
            if (received != 0) require(TOKEN.transfer(msg.sender, received), "transfer");
        }
        paidMintCountOf[id] = count + 1;
        paidMintTotal++;
        emit PaidMint(msg.sender, id, delivered, count + 1, msg.value, batch);
        emit PaidSwap(batch, msg.value, dev, swapBnb, received, topUp);
    }

    /// @notice Self-call entry for the automatic sell-tax alignment
    ///         inside paidMint; its failure is caught there so a failed
    ///         step can never brick the mint that triggered it.
    function trySyncSellTax() external {
        if (msg.sender != address(this)) revert NotSelf();
        _syncSellTax();
    }

    /// @notice Permissionless repair path for the graduated sell tax:
    ///         anyone can call this once the pool is open to set the
    ///         token's sell tax to exactly the rate the schedule
    ///         prescribes for the running batch (e.g. if the automatic
    ///         step inside the batch-opening mint ever failed, or the
    ///         owner moved the rate manually). It can only ever set
    ///         the schedule's own value — never an arbitrary rate.
    function syncSellTax() external {
        if (!poolOpen) revert PoolUnavailable();
        _syncSellTax();
    }

    /// @dev Align the token's sell tax with the schedule for the
    ///      running batch; a no-op while the rate already matches. This
    ///      contract is the token's registered pool manager, which is
    ///      what authorises the setter call.
    function _syncSellTax() internal {
        uint256 target = sellTaxBpsForBatch(currentBatch());
        if (TOKEN.sellTaxBps() != target) {
            TOKEN.setSellTaxBps(target);
            emit SellTaxSynced(target);
        }
    }

    /// @dev Release `amount` of accrued dev share (§0ab.13 timing,
    ///      §0ab.15 split): the buy back & burn leg — 75% of the
    ///      amount, exactly 15% of the mint gross — goes in BNB to
    ///      BUYBACK_RECEIVER, and the team leg — the remaining 25%,
    ///      exactly 5% of the gross (it takes the rounding remainder,
    ///      so the two legs always sum to `amount`) — goes in BNB to
    ///      TREASURY. Never reverts: each leg's failed send is absorbed
    ///      into that leg's pending bucket (payBuybackShare() /
    ///      payDevShare() retry it), so a release can never brick the
    ///      mint or the pool opening that triggered it.
    function _releaseDevShare(uint256 amount) internal {
        if (amount == 0) return;
        uint256 buybackPart = amount * BUYBACK_SHARE_BPS / 10_000;
        _sendBuybackShare(buybackPart);
        _sendDevShare(amount - buybackPart);
    }

    /// @dev Send the TREASURY (team) leg of a dev-share release
    ///      (§0ab.15), or a refund's 5% treasury share via the same
    ///      accounting. Never reverts: a failed send is absorbed into
    ///      devSharePending (payDevShare() retries it).
    function _sendDevShare(uint256 amount) internal {
        if (amount == 0) return;
        (bool sent,) = TREASURY.call{value: amount}("");
        if (sent) {
            devSharePaid += amount;
            treasurySharePaid += amount;
            emit DevShareSent(TREASURY, amount);
        } else {
            devSharePending += amount;
        }
    }

    /// @dev Send the buy back & burn leg of a dev-share release to
    ///      BUYBACK_RECEIVER (§0ab.15). Never reverts: a failed send
    ///      is absorbed into buybackSharePending (payBuybackShare()
    ///      retries it).
    function _sendBuybackShare(uint256 amount) internal {
        if (amount == 0) return;
        (bool sent,) = BUYBACK_RECEIVER.call{value: amount}("");
        if (sent) {
            devSharePaid += amount;
            buybackSharePaid += amount;
            emit BuybackShareSent(BUYBACK_RECEIVER, amount);
        } else {
            buybackSharePending += amount;
        }
    }

    /// @dev Settle the batch that just filled (§0ab.7 amounts,
    ///      §0ab.13 release model). PRE-POOL the settlement is pure
    ///      accounting and NOTHING leaves the contract (full escrow
    ///      hold): the batch's accrued gross splits 20/80 — the dev
    ///      share accrues in pendingDevShareBnb (released once, in
    ///      the pool opening) and the rest becomes heldBnb (the pool
    ///      seed). POST-POOL there is no batch BNB accrual (the
    ///      buy-through mints spent their 80% in the swap); instead
    ///      this releases the running batch's per-mint dev accruals
    ///      (devShareBatchAccrued) — exactly one release
    ///      per batch completion, covering exactly that batch's
    ///      accumulation, split §0ab.15 at the release. Invariant: the
    ///      contract's BNB balance
    ///      always equals heldBnb + reserveBnb + batchAccruedBnb +
    ///      devSharePending + freeGateFeePending +
    ///      pendingDevShareBnb + liquidityReserveBnb +
    ///      buybackSharePending
    ///      (devShareBatchAccrued is a sub-account of
    ///      pendingDevShareBnb, never added on top).
    function _settleBatch() internal {
        uint256 accrued = batchAccruedBnb;
        if (accrued != 0) {
            batchAccruedBnb = 0;
            uint256 dev = accrued * DEV_SHARE_BPS / 10_000;
            uint256 rest = accrued - dev;
            if (poolOpen) {
                // Unreachable in the current flow (once the pool is
                // open, mints are buy-through and never accrue batch
                // BNB) — kept so the split stays total if the phase
                // flow ever changes: the 80% becomes reserveBnb and
                // the dev share releases immediately.
                reserveBnb += rest;
                _releaseDevShare(dev);
            } else {
                heldBnb += rest;
                pendingDevShareBnb += dev;
            }
            emit BatchSettled(currentBatch() - 1, accrued, dev, rest);
        }
        if (poolOpen && devShareBatchAccrued != 0) {
            uint256 release = devShareBatchAccrued;
            devShareBatchAccrued = 0;
            pendingDevShareBnb -= release;
            _releaseDevShare(release);
        }
    }

    /// @notice Refund a wallet's PRE-POOL paid mints (§0ab.13) — the
    ///         safety net if the pool has not opened within
    ///         REFUND_DELAY (7 days) of the start. All-or-nothing and
    ///         exactly once per wallet: the wallet's records are
    ///         zeroed, its full paid-mint delivery (package + Agent
    ///         ID bonus) is burned back into the paid bucket (the
    ///         bucket counters rewind by the same amount; the batch
    ///         counting — paidMintTotal and the per-agent mint
    ///         counts — does NOT rewind), and the recorded payment
    ///         splits 80% back to the wallet, 15% into the liquidity
    ///         reserve (liquidityReserveBnb — it joins the pool seed
    ///         if the pool ever opens) and 5% to TREASURY, sent
    ///         inside this call (a failed send accrues into
    ///         devSharePending like every other treasury-bound
    ///         share). The wallet must have approved this contract
    ///         to burnFrom its delivery; a wallet that no longer
    ///         holds the full delivery cannot refund (the burn
    ///         reverts, and with it the whole refund — records stay
    ///         intact). The refund is funded out of the pre-pool
    ///         proceeds buckets in aggregate — the unsettled batch
    ///         accrual first, then the settled seed hold, then the
    ///         accrued dev share — which always covers it in full:
    ///         pre-pool is a full escrow hold, so the sum of those
    ///         buckets never drops below the sum of outstanding
    ///         refund records. Not gated by the pause flag or the
    ///         Agent ID gate: it is an exit path, settled purely from
    ///         the caller's own records. Free mints carry no payment
    ///         and are never refundable; post-pool mints were never
    ///         recorded (and the window is shut by then anyway).
    function refund() external {
        if (!refundOpen()) revert RefundClosed();
        uint256 bnbPaid = paidBnbPaid[msg.sender];
        if (bnbPaid == 0) revert NothingToRefund();
        uint256 tokensDue = paidTokensReceived[msg.sender];
        // Zero the records first: exactly one refund per wallet.
        paidBnbPaid[msg.sender] = 0;
        paidTokensReceived[msg.sender] = 0;
        // The delivery returns to the paid bucket: the tokens are
        // burned below, so the bucket counters rewind by the same
        // amount (the entitlement can be sold again; the batch
        // counting does not rewind).
        paidMintedTokens -= tokensDue;
        publicMinted -= tokensDue;
        // Split (§0ab.13, owner decision 25 Nov 2026 03:23 WIB):
        // 80% back to the buyer, 15% to the liquidity reserve, 5%
        // to TREASURY. The treasury share takes the rounding
        // remainder so the three parts sum to exactly bnbPaid.
        uint256 toBuyer = bnbPaid * REFUND_BPS / 10_000;
        uint256 toLiquidity = bnbPaid * REFUND_LIQUIDITY_BPS / 10_000;
        uint256 toTreasury = bnbPaid - toBuyer - toLiquidity;
        _deductPrePoolBnb(bnbPaid);
        liquidityReserveBnb += toLiquidity;
        if (tokensDue != 0) TOKEN.burnFrom(msg.sender, tokensDue);
        (bool sent,) = msg.sender.call{value: toBuyer}("");
        if (!sent) revert TransferFailed();
        if (toTreasury != 0) {
            (bool tSent,) = TREASURY.call{value: toTreasury}("");
            if (tSent) {
                devSharePaid += toTreasury;
                treasurySharePaid += toTreasury;
                emit DevShareSent(TREASURY, toTreasury);
            } else {
                devSharePending += toTreasury;
            }
        }
        emit RefundPaid(msg.sender, bnbPaid, toBuyer, toLiquidity, toTreasury, tokensDue);
    }

    /// @dev Deduct `amount` of refunded payment from the pre-pool
    ///      proceeds buckets, in aggregate: the running batch's
    ///      unsettled accrual first, then the settled seed hold,
    ///      then the accrued dev share. While the refund window can
    ///      open, batchAccruedBnb + heldBnb + pendingDevShareBnb is
    ///      always >= the sum of outstanding paidBnbPaid records
    ///      (every pre-pool payment sits in exactly one of them and
    ///      refunds zero their record as they deduct), so the final
    ///      subtraction can never underflow.
    function _deductPrePoolBnb(uint256 amount) internal {
        uint256 fromAccrual = amount < batchAccruedBnb ? amount : batchAccruedBnb;
        batchAccruedBnb -= fromAccrual;
        amount -= fromAccrual;
        if (amount != 0) {
            uint256 fromHeld = amount < heldBnb ? amount : heldBnb;
            heldBnb -= fromHeld;
            amount -= fromHeld;
        }
        if (amount != 0) pendingDevShareBnb -= amount;
    }

    /// @notice Retry sending a dev share whose TREASURY send failed at
    ///         settlement (devSharePending). Permissionless; a no-op
    ///         while nothing is pending. Reverts (keeping the pending
    ///         amount intact) if the send fails again.
    function payDevShare() external {
        uint256 due = devSharePending;
        if (due == 0) return;
        devSharePending = 0;
        (bool sent,) = TREASURY.call{value: due}("");
        if (!sent) {
            devSharePending = due;
            revert TransferFailed();
        }
        devSharePaid += due;
        emit DevShareSent(TREASURY, due);
    }

    /// @notice Retry sending a buy back & burn share whose
    ///         BUYBACK_RECEIVER send failed at its release
    ///         (buybackSharePending, §0ab.15). Permissionless; a no-op
    ///         while nothing is pending. Reverts (keeping the pending
    ///         amount intact) if the send fails again.
    function payBuybackShare() external {
        uint256 due = buybackSharePending;
        if (due == 0) return;
        buybackSharePending = 0;
        (bool sent,) = BUYBACK_RECEIVER.call{value: due}("");
        if (!sent) {
            buybackSharePending = due;
            revert TransferFailed();
        }
        devSharePaid += due;
        buybackSharePaid += due;
        emit BuybackShareSent(BUYBACK_RECEIVER, due);
    }

    /// @notice Retry sending free-mint gate fees whose TREASURY send
    ///         failed at mint time (freeGateFeePending, §0ab.11).
    ///         Permissionless; a no-op while nothing is pending.
    ///         Reverts (keeping the pending amount intact) if the send
    ///         fails again.
    function payFreeGateFees() external {
        uint256 due = freeGateFeePending;
        if (due == 0) return;
        freeGateFeePending = 0;
        (bool sent,) = TREASURY.call{value: due}("");
        if (!sent) {
            freeGateFeePending = due;
            revert TransferFailed();
        }
        freeGateFeePaid += due;
        emit FreeGateFeeSent(TREASURY, due);
    }

    /// @notice Withdraw the BNB reserve bucket. Under §0ab.10 no new
    ///         post-pool BNB is held (the 80% goes into the buy-through
    ///         swap), so this only ever carries a balance if a batch
    ///         settled while the pool was open under the legacy flow.
    ///         Owner only.
    function withdrawReserveBnb(address to) external onlyOwner {
        require(to != address(0), "address");
        uint256 amount = reserveBnb;
        if (amount == 0) revert NothingToRecover();
        reserveBnb = 0;
        (bool sent,) = to.call{value: amount}("");
        if (!sent) revert TransferFailed();
        emit ReserveBnbWithdrawn(to, amount);
    }

    /// @notice Open the pool — permissionless fallback for the automatic
    ///         opening inside the batch-4-filling mint. Callable once
    ///         batch POOL_OPEN_BATCH has sold out (or the paid sale has
    ///         finished) and the bucket has not been recovered.
    function openPool() external {
        if (poolOpen) revert PoolAlreadyOpen();
        if (publicBucketRecovered) revert PoolUnavailable();
        if (paidMintTotal < poolOpenTriggerMints() && !paidFinished()) revert PoolNotReady();
        _openPool();
    }

    /// @notice Self-call entry for the automatic opening attempt inside
    ///         paidMint; its failure is caught there so a failed opening
    ///         can never brick the mint that triggered it.
    function tryOpenPool() external {
        if (msg.sender != address(this)) revert NotSelf();
        _openPool();
    }

    /// @dev The pool opening: mint any un-minted LP base shortfall to
    ///      this contract, seed ALL held BNB — the settled 80% holds
    ///      (heldBnb) PLUS any refund liquidity reserve
    ///      (liquidityReserveBnb, §0ab.13) — with QQAI from the
    ///      reserve at the batch-POOL_OPEN_BATCH per-token price (so
    ///      the opening spot equals that price, refund or not), send
    ///      the LP tokens to the burn address, flip the token's pair,
    ///      and — the split running exactly once — release the whole
    ///      pre-pool dev-share accumulation (pendingDevShareBnb) to
    ///      TREASURY. Any revert anywhere in here rolls the whole
    ///      opening back atomically; the dev release itself never
    ///      reverts (a failed send is absorbed into devSharePending).
    function _openPool() internal {
        uint256 bnbSeed = heldBnb + liquidityReserveBnb;
        if (bnbSeed == 0) revert PoolUnavailable();
        if (lpBaseMinted < LP_ALLOCATION) {
            uint256 shortfall = LP_ALLOCATION - lpBaseMinted;
            lpBaseMinted = LP_ALLOCATION;
            lpReserveReleased = true;
            TOKEN.mint(address(this), shortfall);
        }
        uint256 tokenSeed = bnbSeed * batchPerMint(POOL_OPEN_BATCH) / batchPriceWei(POOL_OPEN_BATCH);
        if (tokenSeed == 0 || TOKEN.balanceOf(address(this)) < tokenSeed) revert PoolSeedBalance();
        heldBnb = 0;
        liquidityReserveBnb = 0;
        require(TOKEN.approve(ROUTER, tokenSeed), "approve");
        // First liquidity on a fresh pair: the router uses the desired
        // amounts exactly, so no ETH refund path is exercised (this
        // contract's receive() stays closed) and the seeded ratio is
        // exactly the batch-POOL_OPEN_BATCH per-token price.
        (uint256 amountToken, uint256 amountBnb, uint256 liquidity) = IPancakeRouter(ROUTER).addLiquidityETH{
            value: bnbSeed
        }(address(TOKEN), tokenSeed, tokenSeed, bnbSeed, DEAD, block.timestamp);
        address pair_ = IPancakeFactory(IPancakeRouter(ROUTER).factory()).getPair(address(TOKEN), WBNB);
        require(pair_ != address(0), "pair");
        pair = pair_;
        poolOpen = true;
        lpSeededTokens = amountToken;
        // Flip trading on the token: from here on, transfers against
        // the pair carry the trade tax. This contract is the token's
        // registered pool manager, which is also what made the seeding
        // transfers above tax-exempt.
        TOKEN.setPair(pair_);
        emit PoolOpened(pair_, amountBnb, amountToken, liquidity);
        // The one-time split release (§0ab.13): the accumulated
        // pre-pool dev share is released now that the pool is open
        // (and the refund window is shut for good) — split §0ab.15:
        // 15% of gross to BUYBACK_RECEIVER, 5% to TREASURY. Absorbed
        // into the legs' pending buckets if a send fails — it can
        // never brick the opening.
        if (pendingDevShareBnb != 0) {
            uint256 release = pendingDevShareBnb;
            pendingDevShareBnb = 0;
            _releaseDevShare(release);
        }
    }

    /// @notice Mint the reserve & marketing allocation to TREASURY.
    ///         Owner only, exactly once.
    function releaseReserve() external onlyOwner {
        if (reserveReleased) revert AlreadyReleased();
        reserveReleased = true;
        TOKEN.mint(TREASURY, RESERVE_ALLOCATION);
        emit ReserveReleased(TREASURY, RESERVE_ALLOCATION);
    }

    /// @notice Mint whatever of the liquidity reserve is still
    ///         outstanding to this contract: the un-minted remainder of
    ///         the 225B base (the pool opening may already have minted
    ///         some or all of it) plus the paid sale's dust once it is
    ///         finished and not yet minted. Reverts when nothing is
    ///         outstanding. Owner only. The held reserve (minus what
    ///         the seeding put into the pair) is moved out with
    ///         transferLpReserve().
    function releaseLpReserve() external onlyOwner {
        uint256 baseOutstanding = LP_ALLOCATION - lpBaseMinted;
        uint256 dustEntitlement = lpDustAmount();
        uint256 dustOutstanding = dustEntitlement > lpTopUpMinted ? dustEntitlement - lpTopUpMinted : 0;
        uint256 outstanding = baseOutstanding + dustOutstanding;
        if (outstanding == 0) revert AlreadyReleased();
        lpBaseMinted = LP_ALLOCATION;
        lpReserveReleased = true;
        if (dustOutstanding != 0) lpTopUpMinted = dustEntitlement;
        TOKEN.mint(address(this), outstanding);
        emit LpReserveReleased(outstanding);
    }

    /// @notice Move held QQAI (the liquidity reserve) out of this
    ///         contract. Owner only.
    function transferLpReserve(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "address");
        require(TOKEN.transfer(to, amount), "transfer");
        emit LpReserveTransferred(to, amount);
    }

    /// @notice Owner escape hatch for the public bucket: mint the entire
    ///         un-minted remainder of the public bucket straight to `to`
    ///         and close the bucket for good (publicMinted is set to
    ///         PUBLIC_CAP, so freeMint/paidMint revert BucketEmpty from
    ///         then on); ALL spendable BNB held by this contract (the
    ///         pool seed hold, the post-pool reserve, the running
    ///         batch's unsettled accrual, any unreleased or unsent dev
    ///         share and any unsent free-mint gate fees) is swept to
    ///         TREASURY in the same call — the §0ab.13 refund
    ///         liquidity reserve is the one deliberate exception: it
    ///         is never swept. This guarantees neither the
    ///         un-distributed bucket nor any proceeds can ever be
    ///         stranded in this contract. Owner only, and
    ///         deliberately NOT gated by the pause flag or the start
    ///         time: the recovery path stays open exactly when minting
    ///         itself is stopped. If the LP reserve was already
    ///         released, the remainder excludes the dust that was
    ///         included in it (lpTopUpMinted); if recovery runs first,
    ///         releaseLpReserve() afterwards mints only what is still
    ///         outstanding.
    function recoverPublicBucket(address to) external onlyOwner {
        require(to != address(0), "address");
        // If the LP reserve already included the paid dust, that dust
        // has already been issued — exclude it here so the same tokens
        // are never minted twice.
        uint256 remaining = PUBLIC_CAP - publicMinted - lpTopUpMinted;
        if (remaining == 0) revert NothingToRecover();
        publicMinted = PUBLIC_CAP;
        publicBucketRecovered = true;
        // Sweep EVERY spendable BNB bucket: the pre-pool seed hold,
        // the post-pool reserve, the running batch's unsettled
        // accrual, any unreleased or unsent dev share (which counts
        // as paid once swept) and any unsent free-mint gate fees
        // (§0ab.11 — likewise counted as paid once swept) go to
        // TREASURY; the one exception is an already-split buyback leg
        // still pending (buybackSharePending, §0ab.15), which keeps
        // its own destination and is swept to BUYBACK_RECEIVER.
        // liquidityReserveBnb (§0ab.13) is deliberately NOT swept: it
        // is earmarked as liquidity and has no owner withdrawal path.
        uint256 sweep = heldBnb + reserveBnb + batchAccruedBnb + pendingDevShareBnb + devSharePending
            + freeGateFeePending + buybackSharePending;
        if (sweep != 0) {
            uint256 pending = pendingDevShareBnb + devSharePending;
            uint256 dsPending = devSharePending;
            uint256 gatePending = freeGateFeePending;
            uint256 bbPending = buybackSharePending;
            heldBnb = 0;
            reserveBnb = 0;
            batchAccruedBnb = 0;
            pendingDevShareBnb = 0;
            devShareBatchAccrued = 0;
            devSharePending = 0;
            freeGateFeePending = 0;
            buybackSharePending = 0;
            if (bbPending != 0) {
                (bool bbSent,) = BUYBACK_RECEIVER.call{value: bbPending}("");
                if (!bbSent) revert TransferFailed();
                devSharePaid += bbPending;
                buybackSharePaid += bbPending;
                emit BuybackShareSent(BUYBACK_RECEIVER, bbPending);
            }
            if (sweep - bbPending != 0) {
                (bool sent,) = TREASURY.call{value: sweep - bbPending}("");
                if (!sent) revert TransferFailed();
            }
            devSharePaid += pending;
            treasurySharePaid += dsPending;
            freeGateFeePaid += gatePending;
        }
        TOKEN.mint(to, remaining);
        emit PublicBucketRecovered(to, remaining);
    }

    // ---- Owner configuration (dev control, §0r) ----

    function setPaidMaxPerAgent(uint256 max_) external onlyOwner {
        require(max_ != 0, "max");
        paidMaxPerAgent = max_;
        emit PaidMaxPerAgentSet(max_);
    }

    function setStartTime(uint256 startTime_) external onlyOwner {
        startTime = startTime_;
        emit StartTimeSet(startTime_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Transfer contract ownership (dev control, §0r). There is
    ///         deliberately no renounce function.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @dev BNB only ever enters through paidMint() (accrued per
    ///      batch; settled 20/80 with the 20% released per §0ab.13 —
    ///      at the pool opening pre-pool, per batch completion
    ///      post-pool; seeded, reserved, refunded or swept out by the
    ///      paths above) and the freeMint() gate fee (§0ab.11:
    ///      forwarded to TREASURY inside the mint, or held as
    ///      freeGateFeePending); direct sends have no way in.
    receive() external payable {
        revert("no direct BNB");
    }
}
