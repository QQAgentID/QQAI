// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAgentRegistry, IERC20QQAI} from "./External.sol";

/// @notice QQAI Agentic ID — Agent ID gated ERC-721 sale with a free quota, a FLAT
///         1.1 USDT paid price, a single sale escrow released 80/20 at every
///         11,111-mint milestone, and referral mint tickets.
///
///         FINAL SALE MODEL (owner restructure, 15 Nov 2026 — replaces the
///         22-batch / conditional-price-ladder / expiry-refund design):
///         - The paid price is a flat 1.1 USDT for every mint. There are no
///           batches and no price ladder: the sale opens at `startUnix` and
///           runs until all 111,111 NFTs are minted. One safety net exists
///           (audit fix, 15 Nov 2026): if the token has NOT gone live within
///           1 day of the start (`REFUND_AFTER`; user decision 15 Nov
///           2026 17:46 — supersedes the audit fix's 365 days), the sale is
///           failed — minting and escrow releases close permanently, and the
///           current owner of any PAID NFT can reclaim 90% of the 1.1 USDT
///           price (0.99 USDT; the remaining 0.11 USDT goes to TREASURY) via
///           `refundUnreached()`. Free NFTs are not refundable.
///         - 100% of paid USDT is held by this contract as ONE escrow bucket.
///           `releaseEscrow()` is permissionless and releases the ENTIRE
///           escrow balance — 80% to LIQUIDITY_RECEIVER, 20% to TREASURY — each
///           time the total minted crosses another MILESTONE (11,111) step,
///           plus one final release once the supply is fully minted. The
///           first release is therefore the token-live milestone itself.
///         - The token goes LIVE the moment total minted reaches MILESTONE:
///           `liveAt` records that timestamp. Claims and mining in QQAIClaim
///           are locked until then and use `liveAt` as their start. The sale
///           keeps running after the token is live.
///         - Every NFT's claim multiplier is fixed at mint by its LADDER:
///           ladder k = floor(totalMinted before the mint / MILESTONE), and
///           the multiplier is 0.9^k (ladder 0 = x1.0). Token ids are
///           sequential, so the ladder of tokenId t is exactly
///           floor((t - 1) / MILESTONE); it is also snapshotted into the
///           paid-mint record at mint time.
///
///         The free-mint BNB fee is forwarded to TREASURY in the same
///         transaction and never enters the escrow. There is no owner,
///         pause, upgrade, or administrative withdrawal: USDT held by this
///         contract is exactly the recorded escrow balance, and the only
///         ways it ever leaves are `releaseEscrow()` under the rules above
///         and, in the failed-sale state, `refundUnreached()`.
contract QQAINFT is ERC721, ReentrancyGuard {
    struct Config {
        string name;
        string symbol;
        string baseURI;
        address registry;
        address treasury;
        address liquidityReceiver;
        address usdt;
        uint256 freeFee;
        uint256 freeSupply;
        uint256 paidCap;
        uint256 freePerAgent;
        uint256 basePerAgent;
        uint256 startUnix;
        uint256 milestone;
        uint256 refundAfterUnix;
    }

    struct PaidInfo {
        uint256 ladder;
        uint256 priceWei;
        address buyer;
    }

    uint256 public constant FREE_FEE_PRODUCTION = 0.0001 ether;
    /// @notice Flat paid price: 1.1 USDT (18 decimals) for every paid mint.
    uint256 public constant PRICE = 1_100_000_000_000_000_000;
    /// @notice Per-transaction paid-mint quantity cap (audit round 4,
    ///         15 Nov 2026): referral tickets make the effective per-agent
    ///         mint cap unbounded, so without a per-call cap a single
    ///         mint(qty) could exceed the block gas limit and revert.
    ///         100 mints per call stays far inside one BSC block; larger
    ///         amounts simply split across calls. No economic parameter
    ///         changes — the per-agent cap logic is untouched.
    uint256 public constant MAX_QTY_PER_TX = 100;

    IAgentRegistry public immutable REGISTRY;
    IERC20QQAI public immutable USDT;
    address public immutable TREASURY;
    address public immutable LIQUIDITY_RECEIVER;
    uint256 public immutable FREE_FEE;
    uint256 public immutable FREE_SUPPLY;
    uint256 public immutable PAID_CAP;
    uint256 public immutable TOTAL_SUPPLY;
    uint256 public immutable FREE_PER_AGENT;
    uint256 public immutable BASE_PER_AGENT;
    uint256 public immutable START;
    /// @notice Milestone step (production 11,111): the ladder divisor, the
    ///         token-live threshold, and the escrow-release step are all this
    ///         one number.
    uint256 public immutable MILESTONE;
    /// @notice Failed-sale safety-net deadline (audit fix, 15 Nov 2026;
    ///         window set to 1 day by user decision 15 Nov 2026 17:46):
    ///         production refundAfterUnix = 1796256000 = START + 1 day.
    ///         If the token is not live by then, the sale is failed — see
    ///         saleFailed() / refundUnreached().
    uint256 public immutable REFUND_AFTER;
    address public immutable DEPLOYER;
    /// @notice QQAITierData (SSTORE2 bitmap) addresses, set once by the
    ///         deployer right after deployment (constructor argument
    ///         decoding of the full Config plus two more addresses exceeds
    ///         the stack limit), then locked forever.
    address public tierDataA;
    address public tierDataB;
    bool public tierDataLocked;
    string private BASE_URI;

    /// @notice Total NFTs ever minted; token ids are sequential from 1 and never reused.
    uint256 public minted;
    /// @notice NFTs currently in existence (mints minus actual burns).
    uint256 public liveSupply;
    /// @notice Sum of tier weights (Common 1 / Rare 2 / Epic 3 / Legendary 4)
    ///         over all currently live NFTs, maintained incrementally in
    ///         _update so it covers every mint and burn path. QQAIClaim reads
    ///         it at finalize time as the Collapse Pool pro-rata denominator.
    uint256 public liveTierWeight;
    uint256 public freeSold;
    uint256 public paidSold;

    /// @notice Timestamp of the mint that first pushed total minted to
    ///         MILESTONE — the moment the token went live. 0 until then.
    uint256 public liveAt;
    /// @notice USDT (wei) currently held as sale escrow.
    uint256 public escrowBalance;
    /// @notice How many milestone steps have already been released via
    ///         releaseEscrow() (the crossed count at the last release).
    uint256 public escrowMilestonesReleased;
    /// @notice True once the final (full-sellout) escrow release has run.
    bool public escrowFinalReleased;

    mapping(uint256 => uint256) public mintedByAgent;
    mapping(uint256 => uint256) public freeByAgent;
    mapping(uint256 => uint256) public referralTickets;
    mapping(uint256 => bytes32) public tokenSeed;
    /// @notice Block timestamp at which each tokenId was minted. QQAIClaim
    ///         uses it so an NFT minted after the token went live only
    ///         accrues mining from its own mint time.
    mapping(uint256 => uint256) public mintTime;
    mapping(uint256 => PaidInfo) private paidInfo;

    event FreeMinted(address indexed buyer, uint256 indexed agentId, uint256 tokenId);
    event TierDataSet(address indexed chunkA, address indexed chunkB);
    event PaidMinted(
        address indexed buyer,
        uint256 indexed agentId,
        uint256 qty,
        uint256 firstTokenId,
        uint256 firstLadder,
        uint256 costWei,
        address referrer
    );
    event ReferralTicketsGranted(address indexed referrer, uint256 indexed referrerAgentId, uint256 added, uint256 totalTickets);
    event TokenLive(uint256 liveAt);
    event EscrowReleased(address indexed caller, uint256 amountWei, uint256 liquidityWei, uint256 treasuryWei, uint256 milestonesReleased);
    event RefundUnreached(address indexed owner, uint256 indexed tokenId, uint256 amountWei);

    constructor(Config memory c) ERC721(c.name, c.symbol) {
        require(
            c.registry != address(0) && c.treasury != address(0) && c.liquidityReceiver != address(0) && c.usdt != address(0),
            "address"
        );
        require(bytes(c.baseURI).length != 0, "baseURI");
        require(c.freeSupply != 0 && c.paidCap != 0, "supply");
        require(c.milestone != 0, "milestone");
        require(c.freePerAgent == 1, "free per agent");
        // Audit round 4 (15 Nov 2026): the production free fee is a
        // contract invariant, not a config choice — a mis-typed
        // production-config can no longer deploy silently with a wrong fee.
        require(c.freeFee == FREE_FEE_PRODUCTION, "free fee");
        require(c.basePerAgent != 0 && c.basePerAgent <= 1_000, "base per agent");
        require(c.startUnix > block.timestamp, "start in past");
        require(c.refundAfterUnix > c.startUnix, "refund deadline");

        try IERC20QQAI(c.usdt).decimals() returns (uint8 d) {
            require(d == 18, "USDT decimals");
        } catch {
            revert("USDT decimals");
        }

        REGISTRY = IAgentRegistry(c.registry);
        USDT = IERC20QQAI(c.usdt);
        TREASURY = c.treasury;
        LIQUIDITY_RECEIVER = c.liquidityReceiver;
        FREE_FEE = c.freeFee;
        FREE_SUPPLY = c.freeSupply;
        PAID_CAP = c.paidCap;
        TOTAL_SUPPLY = c.freeSupply + c.paidCap;
        FREE_PER_AGENT = c.freePerAgent;
        BASE_PER_AGENT = c.basePerAgent;
        START = c.startUnix;
        MILESTONE = c.milestone;
        REFUND_AFTER = c.refundAfterUnix;
        DEPLOYER = msg.sender;
        BASE_URI = c.baseURI;
    }

    /// @notice One-time setup: register the two QQAITierData contracts holding
    ///         the tier bitmap chunks. Deployer only, locks forever.
    ///         Audit round 2 (15 Nov 2026): both addresses must hold EXACTLY
    ///         TIER_CHUNK_BYTES of code. EXTCODECOPY from a codeless or
    ///         short address silently reads zeros, which would make every
    ///         tier read as Common and corrupt liveTierWeight and every
    ///         claim amount — a mis-wired chunk must fail loudly here
    ///         instead of at the first mint.
    function setTierData(address a, address b) external {
        require(msg.sender == DEPLOYER && !tierDataLocked, "tier data locked");
        require(a != address(0) && b != address(0), "tier data zero");
        require(a.code.length == TIER_CHUNK_BYTES && b.code.length == TIER_CHUNK_BYTES, "tier data size");
        tierDataA = a;
        tierDataB = b;
        tierDataLocked = true;
        emit TierDataSet(a, b);
    }

    /// @dev BNB only ever flows through mintFree(); anything sent directly would have no way out.
    receive() external payable {
        revert("no direct BNB");
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    /// @dev Agent ID check: handle non-empty and the handle's token owned by `a`.
    function agentOf(address a) public view returns (uint256 id, bool ok) {
        try REGISTRY.handleOf(a) returns (string memory handle) {
            if (bytes(handle).length == 0) return (0, false);
            id = uint256(keccak256(bytes(handle)));
            try REGISTRY.ownerOf(id) returns (address holder) {
                ok = holder == a;
            } catch {
                ok = false;
            }
        } catch {
            ok = false;
        }
        if (!ok) id = 0;
    }

    function computeSeed(uint256 tokenId) public pure returns (bytes32) {
        return sha256(abi.encodePacked("QQ-", Strings.toString(tokenId)));
    }

    /// @notice Canonical rarity tier of a tokenId: 0 = Common, 1 = Rare,
    ///         2 = Epic, 3 = Legendary. The assignment was fixed before
    ///         launch by a salted hash ranking (quotas 66,667 / 27,778 /
    ///         12,222 / 4,444); a sha256 commitment to the salt is
    ///         published in the project metadata and the salt is revealed
    ///         when the token goes live so anyone can verify the
    ///         assignment was never changed. (computeSeed above is only
    ///         the per-token artwork seed, not the tier assignment.) The
    ///         bitmap below is the canonical map — the exact same map
    ///         the site metadata worker embeds as TIERMAP. Packed 2 bits
    ///         per tokenId (tokenId 1 in the
    ///         lowest bits of byte 0) = 27,778 bytes, which exceeds the
    ///         contract size limit inside this contract, so the bitmap lives
    ///         in two QQAITierData (SSTORE2-style) contracts whose runtime code
    ///         IS the bitmap: chunk A = bytes [0, 13,889), chunk B = bytes
    ///         [13,889, 27,778). Regenerate/verify with
    ///         contracts/gen-tiermap-v2.js (output: contracts/tierdata.json).
    uint256 internal constant TIER_CHUNK_BYTES = 13_889;

    function tierOf(uint256 tokenId) public view returns (uint8) {
        require(tokenId != 0 && tokenId <= 111_111, "tokenId range");
        uint256 i = tokenId - 1;
        uint256 byteIndex = i >> 2;
        require(tierDataLocked, "tier data unset");
        address src = byteIndex < TIER_CHUNK_BYTES ? tierDataA : tierDataB;
        uint256 offset = byteIndex < TIER_CHUNK_BYTES ? byteIndex : byteIndex - TIER_CHUNK_BYTES;
        bytes memory one = new bytes(1);
        assembly ("memory-safe") {
            extcodecopy(src, add(one, 32), offset, 1)
        }
        uint256 b = uint8(one[0]);
        return uint8((b >> ((i & 3) * 2)) & 3);
    }

    /// @notice The ladder a tokenId was minted into: floor(totalMinted before
    ///         its mint / MILESTONE). Token ids are sequential from 1, so the
    ///         total minted before tokenId t is exactly t - 1. The claim
    ///         multiplier for ladder k is 0.9^k (see QQAIClaim).
    function ladderOf(uint256 tokenId) public view returns (uint256) {
        require(tokenId != 0 && tokenId <= TOTAL_SUPPLY, "tokenId range");
        return (tokenId - 1) / MILESTONE;
    }

    /// @notice The ladder the NEXT mint will land in.
    function currentLadder() public view returns (uint256) {
        return minted / MILESTONE;
    }

    /// @notice True once the token is live (total minted reached MILESTONE).
    function tokenLive() public view returns (bool) {
        return liveAt != 0;
    }

    /// @notice The claim/mining gate: open once the token is live. Kept under
    ///         this name for QQAIClaim and the site; it no longer has anything
    ///         to do with a sale end or a full sellout.
    function poolOpen() public view returns (bool) {
        return liveAt != 0;
    }

    /// @notice Failed-sale state (audit fix, 15 Nov 2026): the refund
    ///         deadline has passed and the token never went live (total
    ///         minted never reached MILESTONE, so liveAt was never set). In
    ///         this state minting and escrow releases are closed forever
    ///         and paid minters can reclaim their 1.1 USDT via
    ///         refundUnreached().
    function saleFailed() public view returns (bool) {
        return liveAt == 0 && block.timestamp > REFUND_AFTER;
    }

    /// @notice True while paid minters can reclaim via refundUnreached()
    ///         (exactly the failed-sale state).
    function refundOpen() public view returns (bool) {
        return saleFailed();
    }

    /// @notice How many milestone steps have already been released through
    ///         releaseEscrow() (view alias of escrowMilestonesReleased,
    ///         read by QQAIPoolManager to gate its pooling tranches).
    function releasedMilestones() external view returns (uint256) {
        return escrowMilestonesReleased;
    }

    function effectiveCapOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        return BASE_PER_AGENT + referralTickets[id];
    }

    function quotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        uint256 cap = BASE_PER_AGENT + referralTickets[id];
        uint256 used = mintedByAgent[id];
        return cap > used ? cap - used : 0;
    }

    function freeQuotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        if (freeByAgent[id] >= FREE_PER_AGENT) return 0;
        if (quotaOf(a) == 0) return 0;
        // Per-agent semantics (audit fix, 15 Nov 2026): this view answers
        // "how many free mints does THIS agent have left" — the site shows
        // it as the connected agent's personal "free left" — not the
        // global remainder (which is FREE_SUPPLY - freeSold via status()).
        uint256 mine = FREE_PER_AGENT - freeByAgent[id];
        uint256 globalLeft = FREE_SUPPLY - freeSold;
        return mine < globalLeft ? mine : globalLeft;
    }

    function freeOpen() public view returns (bool) {
        return block.timestamp >= START && freeSold < FREE_SUPPLY && minted < TOTAL_SUPPLY;
    }

    function paidOpen() public view returns (bool) {
        return block.timestamp >= START && paidSold < PAID_CAP && minted < TOTAL_SUPPLY;
    }

    /// @notice 0 = before start, 1 = sale open (token not live yet), 2 = token live.
    function phase() public view returns (uint256) {
        if (liveAt != 0) return 2;
        if (block.timestamp < START) return 0;
        return 1;
    }

    function status()
        external
        view
        returns (
            uint256 phase_,
            uint256 freeSold_,
            uint256 paidSold_,
            uint256 minted_,
            uint256 liveSupply_,
            uint256 currentLadder_,
            uint256 milestone_,
            uint256 liveAt_,
            uint256 start_,
            uint256 escrowBalance_,
            uint256 escrowMilestonesReleased_,
            uint256 priceWei_
        )
    {
        return (
            phase(),
            freeSold,
            paidSold,
            minted,
            liveSupply,
            currentLadder(),
            MILESTONE,
            liveAt,
            START,
            escrowBalance,
            escrowMilestonesReleased,
            PRICE
        );
    }

    function paidInfoOf(uint256 tokenId)
        external
        view
        returns (uint256 ladder, uint256 priceWei, address buyer)
    {
        PaidInfo storage info = paidInfo[tokenId];
        return (info.ladder, info.priceWei, info.buyer);
    }

    /// @notice Claim the free NFT for your Agent ID, paying only the fixed BNB service
    ///         fee, which is forwarded to TREASURY in this transaction.
    function mintFree() external payable nonReentrant returns (uint256 id) {
        (uint256 agentId, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(!saleFailed(), "sale failed");
        require(freeOpen(), "free closed");
        require(msg.value == FREE_FEE, "fee");
        require(freeByAgent[agentId] < FREE_PER_AGENT, "free quota");
        require(mintedByAgent[agentId] < BASE_PER_AGENT + referralTickets[agentId], "mint cap");

        freeByAgent[agentId]++;
        mintedByAgent[agentId]++;
        freeSold++;
        id = ++minted;
        tokenSeed[id] = computeSeed(id);
        mintTime[id] = block.timestamp;
        _mint(msg.sender, id);
        _afterMint();

        (bool sent,) = TREASURY.call{value: msg.value}("");
        require(sent, "treasury send");
        emit FreeMinted(msg.sender, agentId, id);
    }

    /// @notice Mint `qty` NFTs at the flat 1.1 USDT price. The full payment is
    ///         held as sale escrow (see releaseEscrow). `referrer` may be
    ///         address(0); a non-zero referrer must own a different Agent ID
    ///         and earns one mint ticket per paid NFT, with NO cap on
    ///         accumulated tickets (owner decision, 15 Nov 2026): an Agent
    ///         ID's effective mint cap is BASE_PER_AGENT + its total referral
    ///         tickets. Tickets can only be earned through real paid mints,
    ///         so the tickets in existence are bounded by the finite paid
    ///         supply — no overflow surface; the per-call work is bounded
    ///         by MAX_QTY_PER_TX (audit round 4).
    function mint(uint256 qty, address referrer) external nonReentrant returns (uint256 firstId) {
        (uint256 agentId, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(!saleFailed(), "sale failed");
        require(block.timestamp >= START, "sale closed");
        require(qty != 0, "qty");
        require(qty <= MAX_QTY_PER_TX, "qty cap");
        require(paidSold + qty <= PAID_CAP && minted + qty <= TOTAL_SUPPLY, "sold out");
        require(mintedByAgent[agentId] + qty <= BASE_PER_AGENT + referralTickets[agentId], "mint cap");

        uint256 referrerAgentId;
        if (referrer != address(0)) {
            require(referrer != msg.sender, "self referral");
            bool referrerOk;
            (referrerAgentId, referrerOk) = agentOf(referrer);
            require(referrerOk, "referrer Agent ID");
            require(referrerAgentId != agentId, "same Agent ID");
        }

        uint256 cost = PRICE * qty;
        uint256 firstLadder = minted / MILESTONE;

        // Payment is pulled BEFORE any state changes or mints (CEI;
        // audit hardening, 15 Nov 2026). If the transfer fails the whole
        // call reverts with no NFTs minted and no referral tickets granted.
        _safeTransferFromUSDT(msg.sender, address(this), cost);

        paidSold += qty;
        mintedByAgent[agentId] += qty;
        escrowBalance += cost;

        firstId = minted + 1;
        for (uint256 i = 0; i < qty; i++) {
            uint256 id = ++minted;
            tokenSeed[id] = computeSeed(id);
            mintTime[id] = block.timestamp;
            // Snapshot of the ladder this tokenId was minted into; identical
            // to ladderOf(id) = (id - 1) / MILESTONE by construction.
            paidInfo[id] = PaidInfo({ladder: (id - 1) / MILESTONE, priceWei: PRICE, buyer: msg.sender});
            _mint(msg.sender, id);
        }
        _afterMint();

        uint256 ticketsAdded;
        if (referrer != address(0)) {
            ticketsAdded = qty;
            referralTickets[referrerAgentId] += qty;
        }

        if (ticketsAdded != 0) {
            emit ReferralTicketsGranted(referrer, referrerAgentId, ticketsAdded, referralTickets[referrerAgentId]);
        }
        emit PaidMinted(msg.sender, agentId, qty, firstId, firstLadder, cost, referrer);
    }

    /// @notice Release the ENTIRE current sale escrow: 80% to the liquidity
    ///         receiver, 20% to TREASURY. Permissionless. Callable once the
    ///         total minted has crossed at least one more MILESTONE step
    ///         than has already been released (the first release is the
    ///         token-live milestone itself), or once the supply is fully
    ///         minted (final release of whatever remains). In the
    ///         failed-sale state this reverts and the escrow instead backs
    ///         refundUnreached() claims; those are the only two ways USDT
    ///         ever leaves this contract.
    function releaseEscrow() external nonReentrant {
        require(!saleFailed(), "sale failed");
        uint256 crossed = minted / MILESTONE;
        bool milestoneDue = crossed > escrowMilestonesReleased;
        bool finalDue = minted == TOTAL_SUPPLY && !escrowFinalReleased;
        require(milestoneDue || finalDue, "escrow locked");

        uint256 amount = escrowBalance;
        escrowBalance = 0;
        if (milestoneDue) escrowMilestonesReleased = crossed;
        if (minted == TOTAL_SUPPLY) escrowFinalReleased = true;

        uint256 liquidityShare = amount * 80 / 100;
        uint256 treasuryShare = amount - liquidityShare;
        if (liquidityShare != 0) _safeTransferUSDT(LIQUIDITY_RECEIVER, liquidityShare);
        if (treasuryShare != 0) _safeTransferUSDT(TREASURY, treasuryShare);
        emit EscrowReleased(msg.sender, amount, liquidityShare, treasuryShare, escrowMilestonesReleased);
    }

    /// @notice Failed-sale safety net (audit fix, 15 Nov 2026; refund
    ///         split FINAL at 90/10 by user decision 15 Nov 2026 17:50,
    ///         superseding the brief 80/20 of 17:47): once the sale has
    ///         failed (see saleFailed()), the CURRENT owner of a PAID NFT
    ///         burns it and reclaims 90% of PRICE (0.99 USDT of the
    ///         1.1 USDT price) from the escrow; the remaining 10%
    ///         (0.11 USDT) is transferred to TREASURY in the same call. The
    ///         escrow is reduced by the full PRICE. Free NFTs have no paid
    ///         record and revert. The burn makes a second refund of the
    ///         same NFT impossible. Before the deadline, or once the token
    ///         is live, this always reverts.
    function refundUnreached(uint256 tokenId) external nonReentrant {
        require(saleFailed(), "refund closed");
        require(ownerOf(tokenId) == msg.sender, "not owner");
        require(paidInfo[tokenId].priceWei != 0, "not paid");
        escrowBalance -= PRICE;
        _burn(tokenId);
        uint256 refund = PRICE * 90 / 100;
        uint256 treasuryShare = PRICE - refund;
        _safeTransferUSDT(msg.sender, refund);
        _safeTransferUSDT(TREASURY, treasuryShare);
        emit RefundUnreached(msg.sender, tokenId, PRICE);
    }

    /// @notice Burn one of your own NFTs. QQAIClaim uses this after taking ownership of
    ///         an NFT for a COLLAPSE claim; ordinary holders may also burn directly.
    ///         Audit round 4 (15 Nov 2026): a PAID NFT cannot be voluntarily
    ///         burned before the token is live — its 1.1 USDT sits in escrow
    ///         and, if the sale then fails, refundUnreached() is the only
    ///         exit; a burned NFT has no owner left to call it, so the funds
    ///         would be locked forever. Free NFTs carry no escrow and stay
    ///         burnable at any time; after TokenLive a paid burn can only
    ///         ever harm the burner (refunds are closed by then).
    ///         QQAIClaim's COLLAPSE path runs post-live and is unaffected;
    ///         refundUnreached uses the internal _burn.
    function burn(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "not owner");
        require(paidInfo[tokenId].priceWei == 0 || liveAt != 0, "paid burn locked pre-live");
        _burn(tokenId);
    }

    /// @dev Records the token-live moment the first time total minted reaches
    ///      MILESTONE. Called at the end of every mint path.
    function _afterMint() internal {
        if (liveAt == 0 && minted >= MILESTONE) {
            liveAt = block.timestamp;
            emit TokenLive(liveAt);
        }
    }

    function _safeTransferUSDT(address to, uint256 amount) internal {
        require(USDT.transfer(to, amount), "USDT transfer");
    }

    function _safeTransferFromUSDT(address from, address to, uint256 amount) internal {
        require(USDT.transferFrom(from, to, amount), "USDT transferFrom");
    }

    /// @dev Tracks actual ERC-721 supply for the COLLAPSE claim table, plus
    ///      the live tier-weight total used by QQAIClaim's Collapse Pool.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        address previous = super._update(to, tokenId, auth);
        if (from == address(0) && to != address(0)) {
            liveSupply++;
            liveTierWeight += uint256(tierOf(tokenId)) + 1;
        } else if (from != address(0) && to == address(0)) {
            liveSupply--;
            liveTierWeight -= uint256(tierOf(tokenId)) + 1;
        }
        return previous;
    }

    function _baseURI() internal view override returns (string memory) {
        return BASE_URI;
    }
}
