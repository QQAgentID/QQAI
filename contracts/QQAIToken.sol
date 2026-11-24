// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPancakePair, IPancakeRouter} from "./External.sol";

/// @notice QQAI — capped, mint-on-demand ERC-20 for the QQAI Agentic ID ecosystem.
///
///         EMISSION MODEL (owner decision, 15 Nov 2026 — replaces the original
///         fixed supply minted in full by the constructor; modelled on a
///         capped mint-on-demand token). Nothing is minted at deployment.
///         New QQAI is born only when a registered minter calls `mint`, and
///         the hard cap MAX_SUPPLY is enforced on every mint (SupplyCap).
///
///         TOKEN-MINT MODEL (owner decision 25 Nov 2026, PARAMS §0ab —
///         supersedes every earlier sale/claim design, including the NFT
///         sale, the claim contract and the bonding curve): QQAI is sold by
///         direct minting through the QQAIMint contract — a free mint and a
///         paid mint, both gated by the Binance Agent ID registry, tokens
///         minted straight to the buyer's wallet. MAX SUPPLY = 1 trillion
///         (owner decision 25 Nov 2026, PARAMS §0ab; an 88-billion proposal
///         was withdrawn by the owner the same night). ALLOCATION SPLIT —
///         the four buckets sum exactly to the cap:
///           - 675B public mint bucket (67.5%) — minted by QQAIMint through
///             its free mint (16.5M per mint, max 2 per Agent ID, and a
///             hard global cap of 555 free mints in total, so at most
///             9.1575B) and its batched paid ladder mint (batches of
///             1,111 mints; pre-pool price +5% per batch from 0.003 BNB,
///             amount -5% per batch from 50M floored at 10M; EVERY paid
///             mint delivers amount x 1.05 — the +5% Agent ID bonus,
///             PARAMS §0ab.10) against a 665.8425B paid bucket. From
///             batch 5 the mint is a BUY-THROUGH (owner decision
///             25 Nov 2026, §0ab.10): the buyer pays the package's spot
///             value discounted by a fading price bonus (+5% batches
///             5-8, +3% batches 9-12, +1% batches 13-16, 0% from batch
///             17), 20% goes to TREASURY and 80% is swapped through
///             the pool by QQAIMint, which tops the buyer up from the
///             bucket to exactly amount x 1.05 — so the bucket drains
///             by top-ups only, at a price-dependent rate, until it
///             can no longer cover the next top-up; QQAIMint enforces
///             its own PUBLIC_CAP inside this bucket;
///           - 225B liquidity reserve (22.5%), plus the paid sale's
///             unsold dust once it finishes —
///             minted by QQAIMint to itself; part of it seeds the
///             PancakeSwap QQAI/WBNB pool that QQAIMint opens
///             AUTOMATICALLY when paid batch 4 sells out (PARAMS
///             §0ab.5), the rest stays held in QQAIMint until the
///             owner moves it with transferLpReserve;
///           - 50B team (5%) — NOT minted at setup: it vests to the TEAM
///             address through QQAIVesting (365-day cliff + 4-year linear
///             schedule from the go-live moment; QQAIVesting enforces its
///             own TEAM_CAP);
///           - 50B reserve & marketing (5%) — minted to TREASURY by
///             QQAIMint (releaseReserve), liquid, no vesting
///             (RESERVE_ALLOCATION below; held flexibly for marketing and
///             partnerships under the dev-control principle, PARAMS §0r).
///
///         TRADE TAX (user decision, 15 Nov 2026 18:18; PARAMS §0i;
///         sell side graduated by user decision 25 Nov 2026, §0ab.6;
///         settlement revised by user decision 25 Nov 2026, §0ab.15):
///         a tax is skimmed on transfers against the official PancakeSwap
///         pair only, in QQAI, inside the same transfer (the recipient
///         receives amount - tax). Since §0ab.15 the skimmed tax no
///         longer lands at TREASURY in QQAI: it ACCRUES in this contract
///         (taxPending) and is AUTOMATICALLY swapped to BNB through the
///         pair (swapExactTokensForETHSupportingFeeOnTransferTokens)
///         once the accrual reaches TAX_SWAP_THRESHOLD, with the BNB
///         sent straight to TREASURY — so no team wallet ever has to
///         sell QQAI by hand (no manual "dev sell"). The conversion is
///         best-effort by construction: it runs inside a self-call
///         wrapped in try/catch with an anti-recursion flag, and a
///         failed swap simply leaves the accrual in place for the next
///         taxed transfer (or a permissionless convertTax() call) — a
///         conversion can NEVER revert or block a user transfer. The
///         conversion router is wired once via setTaxRouter(); until
///         it is set, the tax takes the legacy §0ab.6 path straight to
///         TREASURY in QQAI.
///         BUYS (from == PAIR) pay a flat 2% (tradeTaxBps, initially
///         200). SELLS (to == PAIR) pay sellTaxBps, which follows a
///         graduated schedule: 0 while no pair is set, raised to 10%
///         (SELL_TAX_START_BPS) by setPair() the moment trading opens,
///         held at 10% for the first two post-pool mint batches
///         (production batches 5 and 6), then stepped straight back
///         down to a flat permanent 2% from batch 7 on by the pool
///         manager (QQAIMint) — no intermediate 8/6/4 steps (the
///         graduated ladder considered at 01:40 WIB was simplified by
///         the owner at 01:42 WIB: "2 batch aja abis itu ke semula").
///         Plain
///         wallet-to-wallet transfers are untaxed. Never taxed: mints and
///         burns (from/to == address(0) — claims and team vesting are
///         mints and are unaffected by construction),
///         transfers involving the QQAIPoolManager (its addLiquidity
///         seeding must move exact tranche amounts), transfers involving
///         TREASURY itself, and transfers involving the deployer (owner).
///         Before the pair is set, nothing is taxed. The pair is wired
///         once via setPair(), callable by the deployer or by the pool
///         manager (registered once via setPoolManager()); in production
///         the manager sets it when it pools the first milestone. Because
///         pair transfers are taxed, QQAI is a fee-on-transfer token for
///         the pair: PancakeSwap V2 swaps must use the
///         SupportingFeeOnTransferTokens paths (balance-delta accounting).
///
///         Deployment order: this token is deployed first, with no minters.
///         After QQAIMint and QQAIVesting are deployed, the owner registers
///         both as minters and calls `lockMinters()` to freeze the minter
///         set (the lock stays reversible by the owner, dev control §0r).
///         The owner also registers QQAIMint once via `setPoolManager()`:
///         QQAIMint flips the pair itself (setPair) at the automatic pool
///         opening when paid batch 4 sells out (PARAMS §0ab.5), and its
///         pool-manager status makes its seeding transfers tax-exempt.
///         The trade tax below only ever applies against the official
///         pair once it is set.
///
///         DEV CONTROL (user decision 24 Nov 2026 — nothing in the QQAI
///         system is permanently locked): ownership is transferable (there
///         is deliberately NO renounce function), the trade tax is
///         owner-adjustable within a sanity bound, and the minter lock is
///         reversible by the owner (`unlockMinters`). The owner therefore
///         always keeps full control of this token.
///
///         Burning follows ERC20Burnable semantics: any holder may burn their
///         own QQAI with `burn`, or burn from an account that approved them
///         with `burnFrom`.
contract QQAIToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 ether;
    /// @notice Reserve & marketing allocation (50 billion, 5% of the cap):
    ///         minted to TREASURY by QQAIMint.releaseReserve(), liquid, no
    ///         vesting (PARAMS §0ab). Accounting constant mirroring the
    ///         allocation enforced by QQAIMint.
    uint256 public constant RESERVE_ALLOCATION = 50_000_000_000 ether;
    /// @notice BUY-side trade tax against the official pair, in basis
    ///         points (flat 200 = 2%). Owner-adjustable (dev control,
    ///         24 Nov 2026) within the sanity bound in setTradeTaxBps
    ///         (at most 1000 bps = 10%).
    uint256 public tradeTaxBps = 200;
    /// @notice SELL-side trade tax against the official pair, in basis
    ///         points (graduated schedule, PARAMS §0ab.6): 0 while no
    ///         pair is set; setPair() raises it to SELL_TAX_START_BPS
    ///         when trading opens; the pool manager (QQAIMint) steps it
    ///         down to the permanent 200 (2%) when the third post-pool
    ///         batch opens (production: batch 7), after exactly two
    ///         post-pool batches at the high rate. Adjustable by the
    ///         owner or the pool manager via setSellTaxBps, within the
    ///         same 1000 bps sanity bound.
    uint256 public sellTaxBps;
    /// @notice Sell tax in force from the moment the pair is set (10%).
    uint256 public constant SELL_TAX_START_BPS = 1000;

    /// @notice Contract owner (dev control, 24 Nov 2026): transferable,
    ///         never renounced by design (no renounce function exists).
    address public owner;
    /// @notice Receives the trade tax — since §0ab.15 in BNB, after the
    ///         automatic conversion (in QQAI before the conversion
    ///         router is wired) — and is itself tax-exempt.
    address public immutable TREASURY;
    mapping(address => bool) public minters;
    bool public mintersLocked;
    /// @notice QQAIPoolManager address, set once by the owner (deploy
    ///         wiring); shares the setPair gate and is tax-exempt.
    address public poolManager;
    /// @notice The official PancakeSwap QQAI/USDT pair; zero until set.
    ///         Transfers against it are taxed (see header).
    address public PAIR;

    /// @notice Trade-tax conversion (§0ab.15): the PancakeSwap router
    ///         the accrued QQAI tax is swapped through, wired once via
    ///         setTaxRouter() (deploy-time wiring). Zero until set —
    ///         while zero, the tax takes the legacy path straight to
    ///         TREASURY in QQAI (see header).
    address public taxRouter;
    /// @notice WBNB address read from the conversion router at wiring
    ///         time (the swap path is [QQAI, taxWbnb]).
    address public taxWbnb;
    /// @notice QQAI trade tax accrued in this contract and not yet
    ///         converted to BNB (§0ab.15). Always equals this contract's
    ///         own QQAI balance: the contract holds nothing else.
    uint256 public taxPending;
    /// @notice Accrual level at which the automatic tax conversion
    ///         fires (§0ab.15): 100,000,000 QQAI — about 0.07% of the
    ///         opening pool's QQAI reserve (141.86B) and roughly
    ///         0.008 BNB at the opening price, i.e. orders of magnitude
    ///         above BSC swap gas (so a conversion is never
    ///         gas-negative) yet small enough that conversions stay
    ///         frequent and their price impact negligible.
    uint256 public constant TAX_SWAP_THRESHOLD = 100_000_000 ether;
    /// @notice Slippage tolerance for the conversion swap's min-out
    ///         (1% under the spot quote) — the same tolerance the mint
    ///         contract applies to its buy-through swap (§0ab.10). The
    ///         quote and the swap read the same reserves inside the
    ///         same transaction, so the executed output equals the
    ///         quote; the tolerance only absorbs pathological rounding.
    uint256 public constant TAX_SWAP_TOLERANCE_BPS = 100;
    /// @dev Anti-recursion flag for the tax conversion: while a
    ///      conversion runs, no nested conversion can start (the
    ///      conversion's own contract -> pair transfer is also
    ///      tax-exempt, see _taxExempt).
    bool private _inTaxSwap;

    error SupplyCap();
    error NotMinter();
    error NotOwner();
    error MintersLocked();
    error NotSelf();

    event MinterSet(address indexed account, bool enabled);
    event MintersLockedEvent();
    event MintersUnlockedEvent();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TradeTaxSet(uint256 bps);
    event SellTaxSet(uint256 bps);
    event PoolManagerSet(address indexed poolManager);
    event PairSet(address indexed pair);
    event TradeTax(address indexed from, address indexed to, uint256 tax);
    event TaxRouterSet(address indexed router, address indexed wbnb);
    /// @notice A §0ab.15 tax conversion executed: qqaiAmount of accrued
    ///         tax was swapped and bnbToTreasury of BNB landed at
    ///         TREASURY (measured as TREASURY's balance delta).
    event TaxConverted(uint256 qqaiAmount, uint256 bnbToTreasury);

    constructor(address treasury_) ERC20("QQAI", "QQAI") {
        require(treasury_ != address(0), "treasury");
        owner = msg.sender;
        TREASURY = treasury_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Register or unregister a minter. Owner only, and only until
    ///         `lockMinters()` freezes the set forever.
    function setMinter(address account, bool enabled) external onlyOwner {
        if (mintersLocked) revert MintersLocked();
        require(account != address(0), "address");
        minters[account] = enabled;
        emit MinterSet(account, enabled);
    }

    /// @notice Freeze the minter set. While locked, no minter can be added
    ///         or removed — but the lock is REVERSIBLE by the owner
    ///         (dev control, 24 Nov 2026: nothing is permanently locked).
    function lockMinters() external onlyOwner {
        if (mintersLocked) revert MintersLocked();
        mintersLocked = true;
        emit MintersLockedEvent();
    }

    /// @notice Re-open the minter set (owner only). The deploy sequence
    ///         still locks the set at setup; this exists so the dev is
    ///         never permanently locked out of his own token.
    function unlockMinters() external onlyOwner {
        require(mintersLocked, "not locked");
        mintersLocked = false;
        emit MintersUnlockedEvent();
    }

    /// @notice Transfer contract ownership (dev control, 24 Nov 2026).
    ///         There is deliberately no renounce function.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Set the BUY-side trade tax (bps). Sanity bound: at most
    ///         1000 bps (10%).
    function setTradeTaxBps(uint256 bps) external onlyOwner {
        require(bps <= 1_000, "tax bound");
        tradeTaxBps = bps;
        emit TradeTaxSet(bps);
    }

    /// @notice Set the SELL-side trade tax (bps). Callable by the owner
    ///         or by the registered pool manager — QQAIMint drives the
    ///         graduated schedule (§0ab.6) through this setter when the
    ///         third post-pool batch opens. Sanity bound: at most
    ///         1000 bps (10%).
    function setSellTaxBps(uint256 bps) external {
        require(msg.sender == owner || msg.sender == poolManager, "not authorized");
        require(bps <= 1_000, "tax bound");
        sellTaxBps = bps;
        emit SellTaxSet(bps);
    }

    /// @notice Mint new QQAI. Registered minters only; reverts with SupplyCap
    ///         when the mint would push the total supply past MAX_SUPPLY.
    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert SupplyCap();
        _mint(to, amount);
    }

    /// @notice Burn `amount` of the caller's own QQAI (ERC20Burnable semantics).
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn `amount` of `account`'s QQAI against the caller's allowance
    ///         (ERC20Burnable semantics).
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /// @notice Register the QQAIPoolManager address. Owner only, exactly
    ///         once (deploy-time wiring, PARAMS §10).
    function setPoolManager(address manager_) external onlyOwner {
        require(poolManager == address(0), "pool manager set");
        require(manager_ != address(0), "address");
        poolManager = manager_;
        emit PoolManagerSet(manager_);
    }

    /// @notice Set the official PancakeSwap pair. Owner (deployer) or the
    ///         pool manager, exactly once — in the token-mint model the
    ///         pool manager is QQAIMint, which calls this at the automatic
    ///         pool opening (paid batch 4 sell-out, PARAMS §0ab.5), right
    ///         after the router creates the pair. From this moment,
    ///         transfers against the pair carry the trade tax — and the
    ///         graduated sell tax starts at SELL_TAX_START_BPS (10%,
    ///         §0ab.6).
    function setPair(address pair_) external {
        require(msg.sender == owner || msg.sender == poolManager, "not authorized");
        require(PAIR == address(0), "pair set");
        require(pair_ != address(0), "address");
        PAIR = pair_;
        sellTaxBps = SELL_TAX_START_BPS;
        emit PairSet(pair_);
        emit SellTaxSet(sellTaxBps);
    }

    /// @notice Wire the trade-tax conversion router (§0ab.15). Owner or
    ///         the pool manager, exactly once (deploy-time wiring, like
    ///         setPoolManager/setPair). The WBNB side of the swap path
    ///         is read from the router itself, so the path can never
    ///         disagree with the router. From this moment, skimmed tax
    ///         accrues in this contract and auto-converts to BNB for
    ///         TREASURY (see the header); before it, the tax goes to
    ///         TREASURY in QQAI exactly as under §0ab.6.
    function setTaxRouter(address router_) external {
        require(msg.sender == owner || msg.sender == poolManager, "not authorized");
        require(taxRouter == address(0), "tax router set");
        require(router_ != address(0), "address");
        taxRouter = router_;
        taxWbnb = IPancakeRouter(router_).WETH();
        emit TaxRouterSet(router_, taxWbnb);
    }

    /// @notice Addresses whose transfers are never taxed: TREASURY itself,
    ///         the pool manager (exact tranche seeding), the deployer and
    ///         — since §0ab.15 — this contract itself, so the tax
    ///         conversion's own contract -> pair leg is never skimmed a
    ///         second time (no double tax).
    function _taxExempt(address a) internal view returns (bool) {
        return a == TREASURY || a == poolManager || a == owner || a == address(this);
    }

    /// @dev Central ERC20 transfer hook carrying the trade tax. Only a
    ///      transfer whose counterparty is the official pair (and neither
    ///      side is exempt, and it is neither a mint nor a burn) is taxed:
    ///      sells (to == PAIR) pay sellTaxBps, buys (from == PAIR) pay
    ///      tradeTaxBps; totalSupply is unchanged. The skimmed tax is
    ///      settled in the same transfer: while no conversion router is
    ///      wired it goes straight to TREASURY in QQAI (the §0ab.6
    ///      behaviour); once setTaxRouter() has run (§0ab.15) it accrues
    ///      in this contract instead and the automatic conversion is
    ///      attempted. Everything else takes the plain ERC20 path.
    function _update(address from, address to, uint256 value) internal override {
        if (
            value != 0 && PAIR != address(0) && from != address(0) && to != address(0)
                && (from == PAIR || to == PAIR) && !_taxExempt(from) && !_taxExempt(to)
        ) {
            uint256 tax = value * (to == PAIR ? sellTaxBps : tradeTaxBps) / 10_000;
            if (tax != 0) {
                super._update(from, to, value - tax);
                if (taxRouter == address(0)) {
                    super._update(from, TREASURY, tax);
                } else {
                    super._update(from, address(this), tax);
                    taxPending += tax;
                }
                emit TradeTax(from, to, tax);
                if (taxRouter != address(0)) _tryConvertTax();
                return;
            }
        }
        super._update(from, to, value);
    }

    /// @notice Flush the accrued trade tax (§0ab.15): swap whatever
    ///         taxPending holds to BNB for TREASURY, regardless of the
    ///         automatic threshold. Permissionless — a conversion can
    ///         only ever send BNB to TREASURY — and a no-op while
    ///         nothing is accrued, no router is wired or no pair is
    ///         set. Never reverts.
    function convertTax() external {
        _convertTax();
    }

    /// @dev Automatic trigger, called at the end of every taxed
    ///      transfer once a conversion router is wired: convert only
    ///      once the accrual reaches TAX_SWAP_THRESHOLD.
    function _tryConvertTax() internal {
        if (taxPending >= TAX_SWAP_THRESHOLD) _convertTax();
    }

    /// @dev Run one conversion attempt through a self-call whose
    ///      failure is caught, guarded by the anti-recursion flag: a
    ///      failed or impossible conversion (thin pool, router error,
    ///      the pair's swap lock while a buy is mid-flight) leaves
    ///      taxPending untouched and can never revert the transfer
    ///      that triggered it.
    function _convertTax() internal {
        if (_inTaxSwap || taxPending == 0 || taxRouter == address(0) || PAIR == address(0)) return;
        _inTaxSwap = true;
        try this.execTaxSwap() {} catch {}
        _inTaxSwap = false;
    }

    /// @notice Self-call only: swap the whole accrued tax balance to
    ///         BNB and send the BNB straight to TREASURY. The min-out
    ///         is the spot quote (router.getAmountOut over the pair's
    ///         live reserves) minus TAX_SWAP_TOLERANCE_BPS — the same
    ///         quote discipline as the mint contract's buy-through
    ///         (§0ab.10). This contract is tax-exempt, so the input
    ///         arrives at the pair in full and the executed output
    ///         equals the quote. ANY failure (quote, approval or swap)
    ///         restores taxPending in full and returns quietly: the
    ///         accrual is retried at the next taxed transfer or
    ///         convertTax() call, and is never lost.
    function execTaxSwap() external {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 amount = taxPending;
        if (amount == 0) return;
        taxPending = 0;
        uint256 bnbBefore = TREASURY.balance;
        bool swapped = false;
        try IPancakeRouter(taxRouter).getAmountOut(amount, _reserveQQAI(), _reserveWbnb()) returns (uint256 quote) {
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = taxWbnb;
            _approve(address(this), taxRouter, amount);
            try IPancakeRouter(taxRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount, quote * (10_000 - TAX_SWAP_TOLERANCE_BPS) / 10_000, path, TREASURY, block.timestamp
            ) {
                swapped = true;
            } catch {}
        } catch {}
        if (swapped) {
            emit TaxConverted(amount, TREASURY.balance - bnbBefore);
        } else {
            taxPending = amount;
        }
    }

    /// @dev The pair's live QQAI reserve (this token's side).
    function _reserveQQAI() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        return IPancakePair(PAIR).token0() == address(this) ? uint256(r0) : uint256(r1);
    }

    /// @dev The pair's live WBNB reserve.
    function _reserveWbnb() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        return IPancakePair(PAIR).token0() == address(this) ? uint256(r1) : uint256(r0);
    }
}
