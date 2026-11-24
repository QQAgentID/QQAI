// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {QQAIToken} from "./QQAIToken.sol";

/// @notice QQAIVesting — the QQAI team allocation (owner decision
///         25 Nov 2026, PARAMS §0ab): TEAM_CAP = 50 billion QQAI (5% of
///         the 1T cap), minted on demand to the TEAM address through a
///         cliff + linear schedule — the same vesting pattern QQAIClaim
///         used for the old design's team allocation:
///           - nothing vests before go-live;
///           - nothing vests until liveAt + CLIFF_SECONDS (365 days);
///           - from the cliff on, vested = TEAM_CAP x elapsed /
///             VESTING_SECONDS (elapsed measured from liveAt), so 25% is
///             vested at the cliff and the full cap at liveAt + 4 years.
///         `claimTeam()` (TEAM only) mints the vested-but-unclaimed
///         amount; the cumulative total minted here can never exceed
///         TEAM_CAP, and QQAIToken's MAX_SUPPLY applies on top.
///
///         DEV CONTROL (§0r): the owner starts the schedule exactly once
///         with goLive() (called when the token sale opens) and can
///         transfer ownership; there is deliberately no renounce. This
///         contract must be registered as a minter on QQAIToken.
contract QQAIVesting {
    /// @notice Team allocation cap (50 billion, 5% of the 1T cap).
    uint256 public constant TEAM_CAP = 50_000_000_000 ether;

    QQAIToken public immutable TOKEN;
    /// @notice The only address that may claim the vesting team
    ///         allocation, and the address it is minted to.
    address public immutable TEAM;
    /// @notice Seconds after go-live before anything vests
    ///         (production: 31,536,000 = 365 days).
    uint256 public immutable CLIFF_SECONDS;
    /// @notice Seconds after go-live at which the cap is fully vested
    ///         (production: 126,144,000 = 4 years).
    uint256 public immutable VESTING_SECONDS;

    /// @notice Contract owner (dev control, §0r): transferable, never
    ///         renounced by design.
    address public owner;
    /// @notice Go-live timestamp; 0 until the owner calls goLive().
    uint256 public liveAt;
    /// @notice Cumulative QQAI minted to TEAM through claimTeam().
    uint256 public teamClaimed;

    error NotOwner();
    error NotTeam();
    error AlreadyLive();
    error NothingVested();

    event WentLive(uint256 liveAt);
    event TeamClaimed(address indexed team, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address token_, address team_, uint256 cliffSeconds_, uint256 vestingSeconds_) {
        require(token_ != address(0) && team_ != address(0), "address");
        require(vestingSeconds_ != 0 && cliffSeconds_ <= vestingSeconds_, "vesting");
        TOKEN = QQAIToken(token_);
        TEAM = team_;
        CLIFF_SECONDS = cliffSeconds_;
        VESTING_SECONDS = vestingSeconds_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Start the vesting schedule. Owner only, exactly once —
    ///         call when the token sale opens.
    function goLive() external onlyOwner {
        if (liveAt != 0) revert AlreadyLive();
        liveAt = block.timestamp;
        emit WentLive(liveAt);
    }

    /// @notice Team QQAI vested so far: 0 before go-live and until
    ///         liveAt + CLIFF_SECONDS; from the cliff on, TEAM_CAP x
    ///         elapsed / VESTING_SECONDS (elapsed measured from liveAt),
    ///         capped at TEAM_CAP once VESTING_SECONDS has passed.
    function vestedTeam() public view returns (uint256) {
        if (liveAt == 0) return 0;
        uint256 nowTs = block.timestamp;
        if (nowTs < liveAt + CLIFF_SECONDS) return 0;
        uint256 elapsed = nowTs - liveAt;
        if (elapsed >= VESTING_SECONDS) return TEAM_CAP;
        return TEAM_CAP * elapsed / VESTING_SECONDS;
    }

    /// @notice Mint the vested-but-unclaimed team allocation to TEAM.
    ///         TEAM only.
    function claimTeam() external {
        if (msg.sender != TEAM) revert NotTeam();
        uint256 vested = vestedTeam();
        if (vested <= teamClaimed) revert NothingVested();
        uint256 amount = vested - teamClaimed;
        teamClaimed = vested;
        TOKEN.mint(TEAM, amount);
        emit TeamClaimed(TEAM, amount);
    }

    /// @notice Transfer contract ownership (dev control, §0r). There is
    ///         deliberately no renounce function.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
