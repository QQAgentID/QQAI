// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice QQAI — one-purpose deploy helper (BNB Chain).
///
///         WHY THIS EXISTS: the Binance Agentic Wallet `contract-call` flow
///         always sends to an explicit `--to` address, so it cannot broadcast
///         a bare CREATE transaction (a preview to the zero address parses as
///         a plain call, not a creation — verified 16 Nov 2026 on the Agent
///         Miner deploy). The QQAI suite is therefore deployed through this
///         helper:
///           1. This helper is deployed via the Arachnid CREATE2 factory
///              (0x4e59b44847b379578588920cA78FbF26c0B4956C, salt 0) with the
///              real deployer wallet (zech) passed as the OWNER constructor
///              argument — constructor msg.sender is irrelevant here.
///           2. Every suite contract is CREATE'd from this helper, so the
///              helper's address is the owner recorded inside them.
///           3. All owner-gated wiring (token setMinter / setPoolManager /
///              lockMinters, vesting goLive at sale open) is forwarded
///              through call() — owner only.
///
///         The helper can never receive or move funds: deploy() and call()
///         are non-payable and there is no withdrawal path.
contract QQAIDeployer {
    address public immutable OWNER;

    event Deployed(address indexed addr, uint256 initBytes);
    event Called(address indexed target);

    constructor(address owner_) {
        require(owner_ != address(0), "Deployer: zero owner");
        OWNER = owner_;
    }

    /// @notice CREATE a contract from its full init code (bytecode +
    ///         ABI-encoded constructor args). Owner only.
    function deploy(bytes memory initCode) external returns (address addr) {
        require(msg.sender == OWNER, "Deployer: not owner");
        assembly {
            addr := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(addr != address(0), "Deployer: create failed");
        emit Deployed(addr, initCode.length);
    }

    /// @notice Forward a value-0 call to a suite contract so the call lands
    ///         with msg.sender == this helper (the suite's owner).
    ///         Owner only.
    function call(address target, bytes memory data) external returns (bytes memory ret) {
        require(msg.sender == OWNER, "Deployer: not owner");
        require(target != address(0), "Deployer: zero target");
        (bool ok, bytes memory r) = target.call(data);
        require(ok, "Deployer: call failed");
        emit Called(target);
        return r;
    }
}
