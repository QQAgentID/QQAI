// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeFactory, IPancakeRouter} from "./External.sol";
import {QQAINFT} from "./QQAINFT.sol";
import {QQAIClaim} from "./QQAIClaim.sol";
import {QQAIToken} from "./QQAIToken.sol";

/// @title QQAIPoolManager — automatic on-chain milestone liquidity (auto-pool)
/// @notice Purpose-locked pooling contract (user decision 15 Nov 2026,
///         PARAMS §0i). It has NO owner, NO admin, NO withdraw function,
///         NO arbitrary external-call surface and NO upgradeability. The
///         only state-changing functions are init() (one time, locks the
///         QQAINFT + QQAIClaim references forever) and the two
///         permissionless flows executeMilestone() / sweepRemainder().
///
///         Inflow (wired at deployment, PARAMS §10):
///           - the 22.2 trillion liquidity QQAI allocation is minted to
///             this contract at setup (before QQAIToken.lockMinters()),
///           - QQAINFT's LIQUIDITY_RECEIVER is this contract, so the 80%
///             escrow share of every releaseEscrow() lands here,
///           - QQAIClaim's fee LIQUIDITY_RECEIVER is this contract, so the
///             80% liquidity share of every claim fee lands here.
///         Every USDT this contract holds is therefore liquidity-destined
///         by construction, and QQAI can only ever leave through
///         addLiquidity (or the post-completion burn in sweepRemainder);
///         USDT can only ever leave through addLiquidity (or the
///         post-completion treasury sweep). Nothing else can move funds.
///
///         executeMilestone() pools ONE milestone tranche per call:
///         LIQ_CAP / 10 = 2.22 trillion QQAI (the final tranche takes the
///         entire remaining token balance) against the contract's ENTIRE
///         USDT balance, through the PancakeSwap V2 router, then burns
///         100% of the LP tokens this contract receives to the burn
///         address. A tranche can only run once that milestone is due
///         (total minted crossed it) AND its escrow was actually released
///         (the NFT's released-milestone count is ahead of this
///         contract's processed count), which blocks pooling fee dust
///         ahead of the real escrow release. On the first tranche the
///         manager also wires the thermostat and the trade tax:
///         claim.setPair(pair), token.setPair(pair) and
///         claim.recordReferencePrice() — the claim and token contracts
///         accept the manager as caller for exactly those one-shot
///         setters (registered beforehand via their setPoolManager).
contract QQAIPoolManager is ReentrancyGuard {
    /// @notice Total QQAI liquidity allocation routed through this contract.
    uint256 public constant LIQ_CAP = 22_200_000_000_000 ether;
    /// @notice QQAI per tranche (LIQ_CAP / 10); the final tranche takes the
    ///         entire remaining token balance instead.
    uint256 public constant TRANCHE_TOKENS = LIQ_CAP / 10;
    /// @notice Number of milestone tranches.
    uint256 public constant TOTAL_MILESTONES = 10;
    /// @notice LP tokens and swept residual QQAI are burned here.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// @notice Deployer of this contract; the only address that may call
    ///         init() (audit fix, 15 Nov 2026 — init is one-shot wiring, so
    ///         leaving it permissionless would let anyone front-run the
    ///         deployer's init with attacker-controlled fake NFT/Claim
    ///         contracts and permanently mis-wire the pooling).
    address public immutable DEPLOYER;

    QQAIToken public immutable TOKEN;
    IERC20 public immutable USDT;
    IPancakeRouter public immutable ROUTER;
    /// @notice Receives residual USDT in sweepRemainder() (the same QQAI
    ///         Treasury the NFT/Claim contracts use; see production config).
    address public immutable TREASURY;

    QQAINFT public NFT;
    QQAIClaim public CLAIM;
    bool public initialized;
    /// @notice Tranches pooled so far (0..TOTAL_MILESTONES).
    uint256 public milestonesProcessed;

    event Initialized(address indexed nft, address indexed claim);
    event MilestonePooled(uint256 indexed index, uint256 tokenUsed, uint256 usdtUsed, uint256 lpBurned);
    event RemainderSwept(uint256 usdtToTreasury, uint256 qqaiBurned);

    constructor(QQAIToken token_, IERC20 usdt_, IPancakeRouter router_, address treasury_) {
        require(
            address(token_) != address(0) && address(usdt_) != address(0) && address(router_) != address(0)
                && treasury_ != address(0),
            "address"
        );
        TOKEN = token_;
        USDT = usdt_;
        ROUTER = router_;
        TREASURY = treasury_;
        DEPLOYER = msg.sender;
    }

    /// @notice One-time wiring of the QQAINFT + QQAIClaim references; locks
    ///         forever once set. Called by the deployer in the deployment
    ///         sequence (PARAMS §10) before any funds are routed here.
    function init(address nft_, address claim_) external {
        require(msg.sender == DEPLOYER, "not deployer");
        require(!initialized, "initialized");
        require(nft_ != address(0) && claim_ != address(0), "address");
        NFT = QQAINFT(payable(nft_));
        CLAIM = QQAIClaim(payable(claim_));
        initialized = true;
        emit Initialized(nft_, claim_);
    }

    /// @notice Pool the next due milestone tranche and burn the LP tokens.
    ///         Permissionless: any caller can only trigger exactly this
    ///         intended pooling — funds move solely between this contract,
    ///         the pair and the burn address.
    function executeMilestone() external nonReentrant {
        require(initialized, "not initialized");
        uint256 due = NFT.minted() / NFT.MILESTONE();
        require(milestonesProcessed < due, "no milestone due");
        require(NFT.releasedMilestones() > milestonesProcessed, "escrow not released");

        uint256 usdtAmount = USDT.balanceOf(address(this));
        require(usdtAmount != 0, "no USDT");
        uint256 tokenBalance = TOKEN.balanceOf(address(this));
        uint256 tokenAmount;
        if (milestonesProcessed == TOTAL_MILESTONES - 1) {
            tokenAmount = tokenBalance;
        } else {
            // Audit fix (15 Nov 2026): a non-final tranche must move the
            // full TRANCHE_TOKENS. Silently pooling a short balance would
            // starve every later tranche (they would revert "no QQAI" with
            // the residual USDT locked); fail loudly on a setup shortfall
            // instead — the deploy sequence asserts the full LIQ_CAP.
            require(tokenBalance >= TRANCHE_TOKENS, "tranche balance");
            tokenAmount = TRANCHE_TOKENS;
        }
        require(tokenAmount != 0, "no QQAI");

        require(TOKEN.approve(address(ROUTER), tokenAmount), "approve QQAI");
        // BSC USDT keeps a residual router allowance when the router pulls
        // less than approved; reset it to zero before setting the new one.
        if (USDT.allowance(address(this), address(ROUTER)) != 0) {
            require(USDT.approve(address(ROUTER), 0), "approve reset");
        }
        require(USDT.approve(address(ROUTER), usdtAmount), "approve USDT");

        (uint256 amountA, uint256 amountB,) = ROUTER.addLiquidity(
            address(TOKEN), address(USDT), tokenAmount, usdtAmount, 0, 0, address(this), block.timestamp
        );

        address pair = IPancakeFactory(ROUTER.factory()).getPair(address(TOKEN), address(USDT));
        uint256 lp = IERC20(pair).balanceOf(address(this));
        if (lp != 0) require(IERC20(pair).transfer(BURN, lp), "LP burn");

        uint256 index = milestonesProcessed;
        if (index == 0) {
            // One-shot wiring, tolerant of a deployer who already set the
            // SAME values manually (audit fix, 15 Nov 2026): skip a setter
            // that is already done, but revert if a pre-set pair points
            // anywhere other than the pair this tranche just pooled into —
            // a wrong pre-set stays a hard failure, never a silent bypass.
            if (address(CLAIM.PAIR()) == address(0)) CLAIM.setPair(pair);
            else require(address(CLAIM.PAIR()) == pair, "claim pair mismatch");
            if (TOKEN.PAIR() == address(0)) TOKEN.setPair(pair);
            else require(TOKEN.PAIR() == pair, "token pair mismatch");
            if (CLAIM.referencePrice() == 0) CLAIM.recordReferencePrice();
        }
        milestonesProcessed = index + 1;
        emit MilestonePooled(index, amountA, amountB, lp);
    }

    /// @notice Post-completion cleanup, permissionless: once all ten
    ///         tranches are pooled, forward any residual USDT (claim-fee
    ///         accumulation past the final tranche, the final escrow
    ///         release of the last mint, rounding leftovers) to TREASURY
    ///         and burn any residual QQAI. Reverts before completion.
    function sweepRemainder() external nonReentrant {
        require(initialized, "not initialized");
        require(milestonesProcessed == TOTAL_MILESTONES, "tranches open");
        uint256 usdtAmount = USDT.balanceOf(address(this));
        uint256 tokenAmount = TOKEN.balanceOf(address(this));
        if (usdtAmount != 0) require(USDT.transfer(TREASURY, usdtAmount), "USDT sweep");
        if (tokenAmount != 0) require(TOKEN.transfer(BURN, tokenAmount), "QQAI burn");
        emit RemainderSwept(usdtAmount, tokenAmount);
    }
}
