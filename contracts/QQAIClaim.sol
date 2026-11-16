// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20QQAI, IPancakePair} from "./External.sol";
import {QQAINFT} from "./QQAINFT.sol";
import {QQAIToken} from "./QQAIToken.sol";

/// @notice QQAIClaim — the Two Doors claim plus the mining emission for QQAI Agentic ID
///         holders.
///
///         EMISSION MODEL (owner decision, 15 Nov 2026 — replaces the
///         fixed-supply design in which this contract was pre-funded with the
///         whole player allocation). QQAIToken is deployed separately and this
///         contract is registered as one of its minters: every QQAI paid out
///         here is minted on demand at the moment it is earned, bounded by
///         two sub-caps of the token's 111T MAX_SUPPLY:
///           - CLAIM_CAP 55.5T (50% of the cap) for KEEP / COLLAPSE claims;
///           - MINING_CAP 22.2T (20% of the cap) for the mining emission.
///         Entitlements that are never claimed are simply never minted —
///         there is no reserve to burn, and `finalizeClaimPeriod()` only
///         closes the claim window at CLAIM_END.
///
///         FINAL CLAIM SCHEME (owner decision, 15 Nov 2026; ladder model
///         from the same day's sale restructure): every NFT has an
///         entitlement
///
///             entitlement = UNIT_BASIS x tier weight x ladder multiplier
///
///         - Tier weight comes from QQAINFT.tierOf: Common x1, Rare x2, Epic x3,
///           Legendary x4.
///         - Ladder multiplier: fixed at mint by the NFT's ladder
///           k = floor(totalMinted before the mint / 11,111) — read from
///           QQAINFT.ladderOf — and worth 0.9^k (ladder 0 = x1.0, ladder 1 =
///           x0.9, ladder 2 = x0.81, ...). Free and paid mints alike.
///         Claims and mining are LOCKED until the token is live (QQAINFT
///         total minted >= 11,111; QQAINFT.liveAt), and mining accrues from
///         liveAt (an NFT minted after the live moment accrues only from
///         its own mint time).
///         - KEEP pays 35% of the entitlement; the NFT stays alive and keeps
///           mining. KEEP contributes nothing to the Collapse Pool.
///         - COLLAPSE pays out the full entitlement, split 90 / 10 (owner
///           experiment, 15 Nov 2026): 90% is minted to the claimant at once;
///           10% is reserved into the COLLAPSE POOL (below). The NFT is
///           transferred here and burned in the same transaction, which also
///           stops its mining and forfeits any unharvested mining accrual.
///
///         COLLAPSE POOL (experiment 1, 15 Nov 2026): the reserved 10% of
///         every COLLAPSE counts toward CLAIM_CAP from the moment of the
///         collapse (tracked in collapsePoolReserved) but is minted only at
///         distribution time. finalizeClaimPeriod() FREEZES the pool's
///         membership and weights (fix, user decision 15 Nov 2026 18:37):
///         it snapshots the pool total, the minted count (finalizedMinted)
///         and the live tier weight (finalizedLiveWeight), and the pool is
///         then shared pro-rata by tier weight ONLY among NFTs that
///         existed at that moment and are still alive (never collapsed —
///         KEEP-claimed and unclaimed alike). The sale keeps running after
///         CLAIM_END, but an NFT minted after the snapshot holds NO pool
///         share. Each eligible NFT's owner claims its share once via
///         claimCollapsePool. An eligible NFT burned after finalize leaves
///         its share unminted (stranded, NOT redistributed); if no NFT is
///         alive at finalize, the pool is simply never minted.
///
///         THERMOSTAT EMISSION (experiment 2, 15 Nov 2026): the mining rate
///         is multiplied by a thermostat factor read from the QQAI/USDT spot
///         price (PancakeSwap V2 reserves) against a one-time reference
///         price P0: >= 2x P0 pays x1.5, >= P0 pays x1.0, >= 0.5x P0 pays
///         x0.5, below that x0.25. The multiplier is snapshotted per NFT at
///         each checkpoint (accrual start and every harvest), so a price
///         move mid-period never reprices an ongoing period. With no pair
///         set (or no P0 recorded) the multiplier is x1.0.
///
///         UNIT_BASIS is 250,000,000 QQAI (set at the 111,111-NFT rescale,
///         15 Nov 2026). The absolute worst case — all 111,111 NFTs COLLAPSE
///         at the ladder multiplier locked in for each of them, computed
///         deterministically over the real per-id tier map — is
///         28,783,470,575,000 QQAI <= CLAIM_CAP, leaving 26,716,529,425,000 QQAI
///         of headroom (the ladder only ever discounts, so the cap can no
///         longer bind). Verified by simulation in test-evm/test.js
///         (section W).
///
///         TEAM VESTING (owner restructure, 15 Nov 2026; renamed from
///         "dev" to "team" by user decision 15 Nov 2026 18:09 — "ini versi
///         tim kita"): the 11.1T team allocation is NOT minted to anyone at
///         setup. It vests to the TEAM address through this contract:
///         nothing before the cliff (CLIFF_SECONDS after the token goes
///         live), then linearly with time since liveAt up to TEAM_CAP at
///         VESTING_SECONDS. `claimTeam()` (TEAM only) mints the
///         vested-but-unclaimed portion on demand.
///
///         MINING (new, 15 Nov 2026): every live NFT (minted, not collapsed)
///         accrues QQAI at MINING_RATE_PER_DAY x tier weight per day — Common
///         13,770/day, Rare 27,540/day, Epic 41,310/day, Legendary
///         55,080/day — starting at the token-live moment (QQAINFT.liveAt,
///         exposed here as miningStart once observed); an NFT minted after
///         that moment accrues from its own mint time instead. Accrual is
///         tracked per tokenId from a checkpoint timestamp:
///         it follows the NFT across transfers, and only the current owner
///         can harvest it with `harvestMining`, which mints the accrual and
///         resets the checkpoint. A KEEP-claimed NFT keeps mining. A COLLAPSE
///         clears the checkpoint: mining stops and unharvested accrual is
///         forfeited, so harvest before collapsing. At a full house the total
///         tier weight is 176,665 units, emitting 2,432,677,050 QQAI/day.
///         Mining keeps running after CLAIM_END until MINING_CAP is
///         exhausted.
///
///         The FIRST claim of each wallet (either door) is free: no USDT fee
///         is collected. Every later claim from the same wallet pays the
///         standard fee for the claimed NFT, scaled by its tier weight
///         (owner decision, 15 Nov 2026: fees are tier-scaled, not flat):
///         KEEP = KEEP_FEE x tier weight (Common 0.15, Rare 0.30, Epic 0.45,
///         Legendary 0.60 USDT), COLLAPSE = COLLAPSE_FEE x tier weight
///         (Common 0.30, Rare 0.60, Epic 0.90, Legendary 1.20 USDT) — read
///         them per NFT via keepFeeFor / collapseFeeFor. Paid claim fees
///         are split immediately: 80% to the liquidity receiver and 20% to
///         TREASURY. (Liquidity pooling is automated on-chain by
///         QQAIPoolManager, PARAMS §0i: the liquidity receiver IS the pool
///         manager, and the LP tokens each milestone tranche produces are
///         burned — sent to 0x000000000000000000000000000000000000dEaD —
///         by the manager in the same flow; they are never held by
///         TREASURY or by any person.)
///         There is no owner or withdrawal function for USDT, QQAI, or NFTs.
contract QQAIClaim is ReentrancyGuard {
    /// @notice Base entitlement unit: a Common NFT from ladder 0 has exactly
    ///         this entitlement (250,000,000 QQAI).
    uint256 public constant UNIT_BASIS = 250_000_000 ether;
    /// @notice Team allocation sub-cap (10% of QQAIToken.MAX_SUPPLY), minted
    ///         only through the vesting schedule in claimTeam().
    uint256 public constant TEAM_CAP = 11_100_000_000_000 ether;
    /// @notice Base COLLAPSE fee (USDT wei) per tier-weight unit: the fee
    ///         charged for one NFT is COLLAPSE_FEE x its tier weight.
    uint256 public constant COLLAPSE_FEE = 0.3 ether;
    /// @notice Base KEEP fee (USDT wei) per tier-weight unit: the fee
    ///         charged for one NFT is KEEP_FEE x its tier weight.
    uint256 public constant KEEP_FEE = 0.15 ether;
    /// @notice Sub-cap of QQAIToken.MAX_SUPPLY reserved for KEEP / COLLAPSE
    ///         claim mints: 55.5 trillion (50% of the 111T cap).
    uint256 public constant CLAIM_CAP = 55_500_000_000_000 ether;
    /// @notice Sub-cap of QQAIToken.MAX_SUPPLY reserved for mining mints:
    ///         22.2 trillion (20% of the 111T cap).
    uint256 public constant MINING_CAP = 22_200_000_000_000 ether;
    /// @notice Mining accrual per tier-weight unit per day: a tier weight w
    ///         NFT earns MINING_RATE_PER_DAY * w per 86,400 seconds.
    uint256 public constant MINING_RATE_PER_DAY = 13_770 ether;
    uint256 public constant SECONDS_PER_DAY = 86_400;

    QQAINFT public immutable NFT;
    IERC20QQAI public immutable USDT;
    QQAIToken public immutable TOKEN;
    address public immutable TREASURY;
    address public immutable LIQUIDITY_RECEIVER;
    uint256 public immutable CLAIM_END;
    /// @notice The only address that may claim the vesting team allocation.
    address public immutable TEAM;
    /// @notice Vesting gate: no team QQAI vests before liveAt + CLIFF_SECONDS.
    uint256 public immutable CLIFF_SECONDS;
    /// @notice Vesting horizon: the team allocation is fully vested at
    ///         liveAt + VESTING_SECONDS (linear in between, after the cliff).
    uint256 public immutable VESTING_SECONDS;
    /// @notice Total team QQAI already minted through claimTeam().
    uint256 public teamClaimed;

    mapping(uint256 => bool) public claimed;
    /// @notice True once this wallet has used its one free (fee-less) claim.
    mapping(address => bool) public firstClaimUsed;
    bool public claimFinalized;
    uint256 public keepClaims;
    uint256 public collapseClaims;
    /// @notice Total QQAI minted so far through KEEP / COLLAPSE claims.
    uint256 public totalClaimMinted;
    /// @notice Total QQAI minted so far through mining harvests.
    uint256 public totalMiningMinted;
    /// @notice When mining started: the first moment the pool was observed
    ///         open by a claim or harvest call. 0 until then.
    uint256 public miningStart;
    /// @notice Per-NFT mining checkpoint (last harvest / reset timestamp).
    ///         0 means "not started for this NFT" — accrual then counts from
    ///         miningStart. Cleared to 0 (accrual forfeited) on COLLAPSE.
    mapping(uint256 => uint256) public miningCheckpoint;

    /// @notice True once this NFT has been claimed through COLLAPSE (a KEEP
    ///         claim leaves it false). Drives Collapse Pool eligibility.
    mapping(uint256 => bool) public collapsed;
    /// @notice Total 10% COLLAPSE portions reserved into the Collapse Pool.
    ///         Counted in totalClaimMinted (under CLAIM_CAP) at collapse
    ///         time; the tokens are minted only at distribution.
    uint256 public collapsePoolReserved;
    /// @notice Total Collapse Pool QQAI already minted out via claimCollapsePool.
    uint256 public collapsePoolDistributed;
    mapping(uint256 => bool) public collapsePoolClaimed;
    /// @notice Finalize-time snapshots behind the pro-rata pool shares.
    ///         Membership is FROZEN at finalize (fix, user decision 15 Nov
    ///         2026 18:37): only NFTs with tokenId <= finalizedMinted can
    ///         ever hold a share, and shares divide by finalizedLiveWeight
    ///         — the live tier weight at the finalize moment — never by
    ///         the live weight afterwards. An eligible NFT burned after
    ///         finalize leaves its share unminted forever (stranded, NOT
    ///         redistributed to the other members).
    uint256 public collapsePoolAtFinalize;
    uint256 public finalizedMinted;
    uint256 public finalizedLiveWeight;

    /// @notice The deployer of this contract. Together with the pool
    ///         manager (below), the only addresses that may set the
    ///         thermostat pair (once) and record the reference price P0
    ///         (once).
    address public immutable DEPLOYER;
    /// @notice QQAIPoolManager address, set ONCE by the deployer via
    ///         setPoolManager() before the token goes live (it locks when
    ///         set, and setting is impossible after live). The manager
    ///         shares the setPair / recordReferencePrice gate so the first
    ///         pooled milestone wires the thermostat automatically.
    address public poolManager;
    /// @notice QQAI/USDT pair read by the mining thermostat; zero until set.
    IPancakePair public PAIR;
    /// @notice Reference spot price P0 (USDT per QQAI, scaled 1e18) for the
    ///         thermostat. Recorded once by recordReferencePrice(); 0 until.
    uint256 public referencePrice;
    /// @notice Thermostat multiplier (bps) snapshotted when mining started;
    ///         the fallback snapshot for NFTs that have not harvested yet.
    uint256 public miningStartMultBps;
    /// @notice Per-NFT thermostat multiplier snapshot (bps), refreshed at
    ///         every harvest. 0 = fall back to miningStartMultBps.
    mapping(uint256 => uint256) public miningMultBps;

    event KeepClaimed(address indexed claimant, uint256 indexed tokenId, uint256 amount, uint256 feeWei);
    event CollapseClaimed(
        address indexed claimant,
        uint256 indexed tokenId,
        uint256 liveSupplyBefore,
        uint256 directAmount,
        uint256 poolAmount,
        uint256 feeWei
    );
    event ClaimPeriodFinalized(address indexed caller);
    event MiningStarted(uint256 start);
    event MiningHarvested(address indexed owner, uint256 indexed tokenId, uint256 amount);
    event CollapsePoolClaimed(address indexed owner, uint256 indexed tokenId, uint256 amount);
    event PairSet(address indexed pair);
    event ReferencePriceRecorded(uint256 price);
    event TeamClaimed(address indexed team, uint256 amount);
    event PoolManagerSet(address indexed poolManager);

    constructor(
        QQAINFT nft_,
        IERC20QQAI usdt_,
        QQAIToken token_,
        address treasury_,
        address liquidityReceiver_,
        uint256 claimEnd_,
        address team_,
        uint256 cliffSeconds_,
        uint256 vestingSeconds_
    ) {
        require(address(nft_) != address(0) && address(usdt_) != address(0) && address(token_) != address(0), "address");
        require(treasury_ != address(0) && liquidityReceiver_ != address(0), "receiver");
        require(claimEnd_ > block.timestamp, "claim end");
        require(team_ != address(0), "team");
        require(vestingSeconds_ != 0 && cliffSeconds_ <= vestingSeconds_, "vesting");

        try usdt_.decimals() returns (uint8 d) {
            require(d == 18, "USDT decimals");
        } catch {
            revert("USDT decimals");
        }

        NFT = nft_;
        USDT = usdt_;
        TOKEN = token_;
        TREASURY = treasury_;
        LIQUIDITY_RECEIVER = liquidityReceiver_;
        CLAIM_END = claimEnd_;
        TEAM = team_;
        CLIFF_SECONDS = cliffSeconds_;
        VESTING_SECONDS = vestingSeconds_;
        DEPLOYER = msg.sender;
    }

    /// @dev This contract never needs BNB; claim fees are USDT only.
    receive() external payable {
        revert("no direct BNB");
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    function claimsOpen() public view returns (bool) {
        return block.timestamp < CLAIM_END && NFT.poolOpen();
    }

    /// @notice Tier multiplier for a tier code (QQAINFT.tierOf): Common 0 -> x1,
    ///         Rare 1 -> x2, Epic 2 -> x3, Legendary 3 -> x4.
    function tierMultiplier(uint8 tier) public pure returns (uint256) {
        return uint256(tier) + 1;
    }

    /// @notice The ladder a tokenId was minted into, as recorded by QQAINFT:
    ///         floor(totalMinted before the mint / 11,111). Ladder 0 is the
    ///         first 11,111 mints; the multiplier drops 10% per ladder.
    function ladderOf(uint256 tokenId) public view returns (uint256) {
        return NFT.ladderOf(tokenId);
    }

    /// @notice Ladder multiplier in basis points: 0.9^k computed iteratively
    ///         with a floor at every step (k=0 -> 10000, 1 -> 9000, 2 ->
    ///         8100, 3 -> 7290, 4 -> 6561, 5 -> 5904, ...). Ladders are
    ///         bounded by the finite NFT supply (k <= 10 in production).
    function ladderMultiplierBps(uint256 ladder) public pure returns (uint256) {
        uint256 bps = 10_000;
        for (uint256 i = 0; i < ladder; i++) {
            bps = bps * 9_000 / 10_000;
        }
        return bps;
    }

    /// @notice The claim multiplier (bps) locked in for one NFT at mint time.
    function claimMultiplierBps(uint256 tokenId) public view returns (uint256) {
        return ladderMultiplierBps(NFT.ladderOf(tokenId));
    }

    /// @notice The NFT's full entitlement: UNIT_BASIS x tier weight x ladder
    ///         multiplier. This is the COLLAPSE payout; KEEP pays 35% of it.
    function entitlementFor(uint256 tokenId) public view returns (uint256) {
        return UNIT_BASIS * tierMultiplier(NFT.tierOf(tokenId)) * claimMultiplierBps(tokenId) / 10_000;
    }

    /// @notice KEEP payout for a specific NFT: 35% of its entitlement.
    function keepAmountFor(uint256 tokenId) public view returns (uint256) {
        return entitlementFor(tokenId) * 3500 / 10_000;
    }

    /// @notice COLLAPSE payout for a specific NFT: 100% of its entitlement.
    ///         Independent of the live supply — the old band table is gone.
    function collapseAmountFor(uint256 tokenId) public view returns (uint256) {
        return entitlementFor(tokenId);
    }

    /// @notice KEEP fee (USDT wei) charged for claiming a specific NFT:
    ///         KEEP_FEE x the NFT's tier weight (Common 0.15, Rare 0.30,
    ///         Epic 0.45, Legendary 0.60 USDT). The first claim of each
    ///         wallet is still free (see _feeFor).
    function keepFeeFor(uint256 tokenId) public view returns (uint256) {
        return KEEP_FEE * tierMultiplier(NFT.tierOf(tokenId));
    }

    /// @notice COLLAPSE fee (USDT wei) charged for claiming a specific NFT:
    ///         COLLAPSE_FEE x the NFT's tier weight (Common 0.30, Rare
    ///         0.60, Epic 0.90, Legendary 1.20 USDT). The first claim of
    ///         each wallet is still free (see _feeFor).
    function collapseFeeFor(uint256 tokenId) public view returns (uint256) {
        return COLLAPSE_FEE * tierMultiplier(NFT.tierOf(tokenId));
    }

    function claimKeep(uint256 tokenId) external nonReentrant {
        _requireClaimable(tokenId);
        _ensureMiningStart();
        uint256 amount = keepAmountFor(tokenId);
        require(totalClaimMinted + amount <= CLAIM_CAP, "claim cap");
        claimed[tokenId] = true;
        keepClaims++;
        totalClaimMinted += amount;

        uint256 fee = _feeFor(keepFeeFor(tokenId));
        if (fee != 0) _collectFee(fee);
        TOKEN.mint(msg.sender, amount);
        emit KeepClaimed(msg.sender, tokenId, amount, fee);
    }

    function claimCollapse(uint256 tokenId) external nonReentrant {
        _requireClaimable(tokenId);
        _ensureMiningStart();
        uint256 liveBefore = NFT.liveSupply();
        uint256 amount = collapseAmountFor(tokenId);
        require(amount != 0, "no entitlement");
        require(totalClaimMinted + amount <= CLAIM_CAP, "claim cap");

        claimed[tokenId] = true;
        collapsed[tokenId] = true;
        collapseClaims++;
        totalClaimMinted += amount;
        // Collapse Pool split: 90% is minted to the claimant now; 10% is
        // reserved into the pool (already counted in totalClaimMinted above,
        // minted only when distributed after finalize).
        uint256 directAmount = amount * 90 / 100;
        uint256 poolAmount = amount - directAmount;
        collapsePoolReserved += poolAmount;
        // Collapse stops this NFT's mining and forfeits any accrual that was
        // not harvested first.
        miningCheckpoint[tokenId] = 0;
        miningMultBps[tokenId] = 0;

        uint256 fee = _feeFor(collapseFeeFor(tokenId));
        if (fee != 0) _collectFee(fee);

        // The claimant must have approved this contract for this NFT. Taking
        // ownership first is what authorizes this contract to call QQAINFT.burn.
        NFT.transferFrom(msg.sender, address(this), tokenId);
        NFT.burn(tokenId);

        TOKEN.mint(msg.sender, directAmount);
        emit CollapseClaimed(msg.sender, tokenId, liveBefore, directAmount, poolAmount, fee);
    }

    /// @notice Collapse Pool QQAI still reserved and not yet distributed
    ///         (before finalize: everything accumulated so far).
    function collapsePoolBalance() public view returns (uint256) {
        return collapsePoolReserved - collapsePoolDistributed;
    }

    /// @notice One eligible NFT's pro-rata share of the Collapse Pool by
    ///         tier weight, from the finalize-time snapshots. 0 before
    ///         finalize, for collapsed or burned NFTs, for NFTs minted
    ///         AFTER the finalize snapshot (frozen membership: tokenId
    ///         above finalizedMinted), and when no NFT was alive at
    ///         finalize (the pool then stays unminted forever).
    function collapsePoolShareOf(uint256 tokenId) public view returns (uint256) {
        if (!claimFinalized || finalizedLiveWeight == 0 || collapsed[tokenId]) return 0;
        if (tokenId > finalizedMinted) return 0;
        try NFT.ownerOf(tokenId) returns (address) {} catch {
            return 0;
        }
        return collapsePoolAtFinalize * tierMultiplier(NFT.tierOf(tokenId)) / finalizedLiveWeight;
    }

    /// @notice Claim one eligible NFT's Collapse Pool share: minted on
    ///         demand from the reserved pool, once per NFT, to its current
    ///         owner, only after the claim period has been finalized.
    ///         Membership is frozen at finalize: an NFT minted after the
    ///         finalize snapshot (tokenId above finalizedMinted) can never
    ///         claim. Total distributed across all claims can never exceed
    ///         collapsePoolReserved (guaranteed by the frozen denominator;
    ///         the require below is a hard backstop).
    function claimCollapsePool(uint256 tokenId) external nonReentrant {
        require(claimFinalized, "not finalized");
        require(tokenId <= finalizedMinted, "minted after finalize");
        require(!collapsePoolClaimed[tokenId], "pool claimed");
        require(NFT.ownerOf(tokenId) == msg.sender, "not NFT owner");
        uint256 share = collapsePoolShareOf(tokenId);
        require(collapsePoolDistributed + share <= collapsePoolReserved, "pool overdraw");
        collapsePoolClaimed[tokenId] = true;
        collapsePoolDistributed += share;
        if (share != 0) TOKEN.mint(msg.sender, share);
        emit CollapsePoolClaimed(msg.sender, tokenId, share);
    }

    /// @notice QQAI currently harvestable from one live NFT's mining accrual:
    ///         tier rate x elapsed since its checkpoint (or since mining
    ///         started), limited to the mining cap still unminted. Burned or
    ///         never-minted tokenIds read 0.
    function pendingMining(uint256 tokenId) public view returns (uint256) {
        // Effective mining start: the recorded start if a claim/harvest has
        // observed it, otherwise QQAINFT.liveAt directly (accrual is defined
        // from liveAt either way). 0 while the token is not live yet.
        uint256 start = miningStart != 0 ? miningStart : NFT.liveAt();
        if (start == 0) return 0;
        try NFT.ownerOf(tokenId) returns (address) {} catch {
            return 0;
        }
        uint256 base = miningCheckpoint[tokenId];
        if (base == 0) {
            base = start;
            // The sale keeps running after the token is live: an NFT minted
            // after liveAt only accrues from its own mint time.
            uint256 mt = NFT.mintTime(tokenId);
            if (mt > base) base = mt;
        }
        if (block.timestamp <= base) return 0;
        uint256 multBps = miningMultBps[tokenId];
        if (multBps == 0) multBps = miningStartMultBps;
        // Mining not yet observed by any claim/harvest (no start snapshot
        // recorded): price the running period at the current thermostat
        // reading — the same value _ensureMiningStart would snapshot.
        if (multBps == 0) multBps = currentMiningMultiplierBps();
        uint256 accrued = MINING_RATE_PER_DAY * tierMultiplier(NFT.tierOf(tokenId)) * (block.timestamp - base) * multBps
            / (SECONDS_PER_DAY * 10_000);
        uint256 remaining = MINING_CAP - totalMiningMinted;
        return accrued < remaining ? accrued : remaining;
    }

    /// @notice Harvest one NFT's mining accrual: mints it to the current NFT
    ///         owner (capped at the mining emission still unminted) and resets
    ///         the NFT's checkpoint to now. Anyone may own the NFT to call
    ///         this; only its owner receives the mint.
    function harvestMining(uint256 tokenId) external nonReentrant {
        _ensureMiningStart();
        require(miningStart != 0, "mining not started");
        require(NFT.ownerOf(tokenId) == msg.sender, "not NFT owner");
        // The accrual is priced with the NFT's snapshotted multiplier; the
        // snapshot is then refreshed to the current thermostat reading for
        // the next period.
        uint256 amount = pendingMining(tokenId);
        require(amount != 0, "nothing to harvest");
        miningCheckpoint[tokenId] = block.timestamp;
        miningMultBps[tokenId] = currentMiningMultiplierBps();
        totalMiningMinted += amount;
        TOKEN.mint(msg.sender, amount);
        emit MiningHarvested(msg.sender, tokenId, amount);
    }

    /// @notice Set the QQAIPoolManager address. Deployer only, exactly
    ///         once, and only before the token goes live — afterwards the
    ///         wiring is frozen forever. The manager needs this gate
    ///         membership to call setPair / recordReferencePrice when it
    ///         pools the first milestone tranche.
    function setPoolManager(address manager_) external {
        require(msg.sender == DEPLOYER, "not deployer");
        require(poolManager == address(0), "pool manager set");
        require(!NFT.poolOpen(), "token live");
        require(manager_ != address(0), "address");
        poolManager = manager_;
        emit PoolManagerSet(manager_);
    }

    /// @notice Set the QQAI/USDT pair read by the mining thermostat.
    ///         Deployer or the pool manager, exactly once — the pair is
    ///         locked in afterwards. (In production the pool manager calls
    ///         this when it pools the first milestone tranche.)
    function setPair(address pair_) external {
        require(msg.sender == DEPLOYER || msg.sender == poolManager, "not authorized");
        require(address(PAIR) == address(0), "pair set");
        require(pair_ != address(0), "address");
        PAIR = IPancakePair(pair_);
        emit PairSet(pair_);
    }

    /// @notice Spot price of QQAI in USDT (scaled 1e18; both tokens are 18
    ///         decimals) from the pair's reserves. 0 while no pair is set or
    ///         the QQAI reserve is empty.
    function spotPrice() public view returns (uint256) {
        if (address(PAIR) == address(0)) return 0;
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        uint256 qqReserve;
        uint256 usdtReserve;
        if (PAIR.token0() == address(TOKEN)) {
            qqReserve = uint256(r0);
            usdtReserve = uint256(r1);
        } else {
            qqReserve = uint256(r1);
            usdtReserve = uint256(r0);
        }
        if (qqReserve == 0) return 0;
        return usdtReserve * 1e18 / qqReserve;
    }

    /// @notice Record the thermostat reference price P0 from the current
    ///         spot price. Deployer or the pool manager only (audit fix,
    ///         15 Nov 2026 — the same gate as setPair: P0 anchors the mining
    ///         thermostat forever, so it must not be recordable by a
    ///         stranger at a thin or manipulated price moment; the pool
    ///         manager is admitted so the first pooled milestone records
    ///         P0 from the real initial pool in the same transaction),
    ///         exactly once, and only once the pair is set and the pool
    ///         has opened (claims/mining live).
    function recordReferencePrice() external {
        require(msg.sender == DEPLOYER || msg.sender == poolManager, "not authorized");
        require(address(PAIR) != address(0), "pair not set");
        require(referencePrice == 0, "recorded");
        require(NFT.poolOpen(), "pool not open");
        uint256 price = spotPrice();
        require(price != 0, "no price");
        referencePrice = price;
        emit ReferencePriceRecorded(price);
    }

    /// @notice Thermostat multiplier (bps) implied by the CURRENT spot
    ///         price: >= 2x P0 -> 15000, >= P0 -> 10000, >= 0.5x P0 -> 5000,
    ///         below that 2500. Reads 10000 (x1.0) while no pair is set or
    ///         no reference price has been recorded.
    function currentMiningMultiplierBps() public view returns (uint256) {
        if (address(PAIR) == address(0) || referencePrice == 0) return 10_000;
        uint256 price = spotPrice();
        if (price >= 2 * referencePrice) return 15_000;
        if (price >= referencePrice) return 10_000;
        if (2 * price >= referencePrice) return 5_000;
        return 2_500;
    }

    /// @notice Team QQAI vested so far: 0 before the token is live and
    ///         until liveAt + CLIFF_SECONDS; from the cliff on, TEAM_CAP x
    ///         elapsed / VESTING_SECONDS (elapsed measured from liveAt),
    ///         capped at TEAM_CAP once VESTING_SECONDS has passed.
    function vestedTeam() public view returns (uint256) {
        uint256 la = NFT.liveAt();
        if (la == 0) return 0;
        uint256 nowTs = block.timestamp;
        if (nowTs < la + CLIFF_SECONDS) return 0;
        uint256 elapsed = nowTs - la;
        if (elapsed >= VESTING_SECONDS) return TEAM_CAP;
        return TEAM_CAP * elapsed / VESTING_SECONDS;
    }

    /// @notice Mint the vested-but-unclaimed team allocation to TEAM. TEAM
    ///         only; the cumulative total minted this way can never exceed
    ///         TEAM_CAP, and QQAIToken's MAX_SUPPLY applies on top.
    function claimTeam() external nonReentrant {
        require(msg.sender == TEAM, "not team");
        uint256 vested = vestedTeam();
        require(vested > teamClaimed, "nothing vested");
        uint256 amount = vested - teamClaimed;
        teamClaimed = vested;
        TOKEN.mint(TEAM, amount);
        emit TeamClaimed(TEAM, amount);
    }

    /// @notice After CLAIM_END, close the claim window for good. Permissionless
    ///         and one-way. Under the emission model there is no reserve to
    ///         burn: unclaimed entitlements were never minted. Mining is not
    ///         affected and keeps running until MINING_CAP is exhausted.
    function finalizeClaimPeriod() external {
        require(block.timestamp >= CLAIM_END, "claim period open");
        require(!claimFinalized, "finalized");
        claimFinalized = true;
        // Collapse Pool distribution basis, frozen at this moment: the
        // pool total, the minted count (membership cutoff — the sale
        // keeps running after CLAIM_END, but later mints hold no share),
        // and the live tier-weight total (the pro-rata denominator).
        collapsePoolAtFinalize = collapsePoolReserved;
        finalizedMinted = NFT.minted();
        finalizedLiveWeight = NFT.liveTierWeight();
        emit ClaimPeriodFinalized(msg.sender);
    }

    function _requireClaimable(uint256 tokenId) internal view {
        require(block.timestamp < CLAIM_END, "claim ended");
        require(NFT.poolOpen(), "token not live");
        require(!claimed[tokenId], "already claimed");
        require(NFT.ownerOf(tokenId) == msg.sender, "not NFT owner");
    }

    /// @dev Records the mining start the first time the token is observed
    ///      live (by a claim or a harvest). The start is QQAINFT.liveAt — the
    ///      exact moment total minted reached the milestone — not the time
    ///      of this observing call, so accrual is identical no matter who
    ///      calls first or when.
    function _ensureMiningStart() internal {
        if (miningStart == 0) {
            uint256 la = NFT.liveAt();
            if (la != 0) {
                miningStart = la;
                miningStartMultBps = currentMiningMultiplierBps();
                emit MiningStarted(la);
            }
        }
    }

    /// @dev The first claim from a wallet is free; this consumes that allowance
    ///      and returns 0. Later claims from the same wallet pay the full fee.
    function _feeFor(uint256 standardFee) internal returns (uint256) {
        if (firstClaimUsed[msg.sender]) return standardFee;
        firstClaimUsed[msg.sender] = true;
        return 0;
    }

    function _collectFee(uint256 fee) internal {
        require(USDT.transferFrom(msg.sender, address(this), fee), "USDT fee");
        uint256 liquidityShare = fee * 80 / 100;
        uint256 treasuryShare = fee - liquidityShare;
        require(USDT.transfer(LIQUIDITY_RECEIVER, liquidityShare), "liquidity fee");
        require(USDT.transfer(TREASURY, treasuryShare), "treasury fee");
    }
}
