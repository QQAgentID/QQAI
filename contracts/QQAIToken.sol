// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice QQAI — capped, mint-on-demand ERC-20 for the QQAI Agentic ID ecosystem.
///
///         EMISSION MODEL (owner decision, 15 Nov 2026 — replaces the original
///         fixed 1T supply minted in full by the constructor; modelled on
///         Jager Agent's capped token). Nothing is minted at deployment. New
///         QQAI is born only when a registered minter calls `mint`, and the
///         hard cap MAX_SUPPLY = 111 trillion is enforced on every mint
///         (SupplyCap). The cap is split by design (enforced where noted):
///           - 55.5T (50%) player claims (KEEP / COLLAPSE) — minted by QQAIClaim,
///             which enforces its own CLAIM_CAP;
///           - 22.2T (20%) NFT mining emission — minted by QQAIClaim, which
///             enforces its own MINING_CAP;
///           - 22.2T (20%) liquidity — minted by the deployer to the
///             QQAIPoolManager contract during setup (auto-pool, PARAMS §0i);
///           - 11.1T (10%) team reserve — NOT minted at setup: it vests to
///             the TEAM address through QQAIClaim.claimTeam() (cliff +
///             linear schedule from the token-live moment; QQAIClaim enforces
///             its TEAM_CAP).
///
///         TRADE TAX (user decision, 15 Nov 2026 18:18; PARAMS §0i): a 2%
///         tax (TRADE_TAX_BPS = 200, an immutable constant — there is no
///         setter, so the tax can never be raised) is skimmed on transfers
///         against the official PancakeSwap pair only: sells (to == PAIR)
///         and buys (from == PAIR) pay 2% of the transferred amount, in
///         QQAI, straight to TREASURY inside the same transfer (the
///         recipient receives amount - tax; no auto-swap). Plain
///         wallet-to-wallet transfers are untaxed. Never taxed: mints and
///         burns (from/to == address(0) — claims, mining, team vesting and
///         pool shares are mints and are unaffected by construction),
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
///         Deployment order (breaks the token <-> claim circular dependency):
///         this token is deployed first, with no minters. After QQAIClaim is
///         deployed, the owner registers QQAIClaim and the deployer address as
///         minters, the deployer mints the liquidity allocation, and
///         the owner calls `lockMinters()` to freeze the minter set forever.
///         After the lock nobody can add or remove a minter, and the owner
///         has no remaining power over the token.
///
///         Burning follows ERC20Burnable semantics: any holder may burn their
///         own QQAI with `burn`, or burn from an account that approved them
///         with `burnFrom`.
contract QQAIToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 111_000_000_000_000 ether;
    /// @notice Trade tax on buys and sells against the official pair, in
    ///         basis points (200 = 2% per side). Immutable by construction:
    ///         a compile-time constant with no setter — it can never change.
    uint256 public constant TRADE_TAX_BPS = 200;

    address public immutable owner;
    /// @notice Receives the trade tax (in QQAI) and is itself tax-exempt.
    address public immutable TREASURY;
    mapping(address => bool) public minters;
    bool public mintersLocked;
    /// @notice QQAIPoolManager address, set once by the owner (deploy
    ///         wiring); shares the setPair gate and is tax-exempt.
    address public poolManager;
    /// @notice The official PancakeSwap QQAI/USDT pair; zero until set.
    ///         Transfers against it are taxed (see header).
    address public PAIR;

    error SupplyCap();
    error NotMinter();
    error NotOwner();
    error MintersLocked();

    event MinterSet(address indexed account, bool enabled);
    event MintersLockedEvent();
    event PoolManagerSet(address indexed poolManager);
    event PairSet(address indexed pair);
    event TradeTax(address indexed from, address indexed to, uint256 tax);

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

    /// @notice Freeze the minter set forever. Irreversible; after this call
    ///         no minter can be added or removed by anyone.
    function lockMinters() external onlyOwner {
        if (mintersLocked) revert MintersLocked();
        mintersLocked = true;
        emit MintersLockedEvent();
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
    ///         pool manager, exactly once — in production the manager calls
    ///         this when it pools the first milestone tranche, right after
    ///         the router creates the pair. From this moment, transfers
    ///         against the pair carry the trade tax.
    function setPair(address pair_) external {
        require(msg.sender == owner || msg.sender == poolManager, "not authorized");
        require(PAIR == address(0), "pair set");
        require(pair_ != address(0), "address");
        PAIR = pair_;
        emit PairSet(pair_);
    }

    /// @notice Addresses whose transfers are never taxed: TREASURY itself,
    ///         the pool manager (exact tranche seeding) and the deployer.
    function _taxExempt(address a) internal view returns (bool) {
        return a == TREASURY || a == poolManager || a == owner;
    }

    /// @dev Central ERC20 transfer hook carrying the trade tax. Only a
    ///      transfer whose counterparty is the official pair (and neither
    ///      side is exempt, and it is neither a mint nor a burn) is taxed:
    ///      TRADE_TAX_BPS of the amount is redirected to TREASURY in the
    ///      same transfer; totalSupply is unchanged. Everything else takes
    ///      the plain ERC20 path.
    function _update(address from, address to, uint256 value) internal override {
        if (
            value != 0 && PAIR != address(0) && from != address(0) && to != address(0)
                && (from == PAIR || to == PAIR) && !_taxExempt(from) && !_taxExempt(to)
        ) {
            uint256 tax = value * TRADE_TAX_BPS / 10_000;
            if (tax != 0) {
                super._update(from, to, value - tax);
                super._update(from, TREASURY, tax);
                emit TradeTax(from, to, tax);
                return;
            }
        }
        super._update(from, to, value);
    }
}
