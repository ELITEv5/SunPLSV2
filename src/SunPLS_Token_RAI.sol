// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║        SunPLS RAI — Token v1.0                                       ║
 * ║        Non-pegged, WPLS-backed floating stable (PulseChain RA I)     ║
 * ║                                                                      ║
 * ║   Identical architecture to SunPLS Token v2.0:                       ║
 * ║   ✓ ERC20Permit (EIP-2612) — single-tx agent flows                   ║
 * ║   ✓ Trust-minimized burn: vault pulls via transferFrom, then burns   ║
 * ║   ✓ One-time deployer-controlled vault latch                         ║
 * ║   ✓ 1,000,000,000 seed supply minted to deployer for LP seeding      ║
 * ║   ✓ mint() and burn() — vault only                                   ║
 * ║   ✓ No admin keys after setVault()                                   ║
 * ║                                                                      ║
 * ║   COMPILE: pragma ^0.8.20 + OZ v4.9.6 GitHub imports (NOT npm).      ║
 * ║   PulseChain supports Shanghai but NOT Cancun (no mcopy opcode).     ║
 * ║   OZ v5 uses mcopy — do not use it.                                  ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract SunPLSRAI is ERC20Permit {
    address private immutable deployer;

    address public vault;
    bool public vaultSet;

    // Stability pool is also authorized to burn — pool holds deposited SunPLS
    // and must burn it when absorbing liquidated debt.
    address public pool;
    bool public poolSet;

    uint256 public constant SEED_SUPPLY = 1_000_000_000 * 1e18;
    string public constant PROTOCOL_VERSION = "SunPLS_RAI_v1";

    modifier onlyVault() {
        require(vaultSet && msg.sender == vault, "Only vault");
        _;
    }

    modifier onlyVaultOrPool() {
        require(
            (vaultSet && msg.sender == vault) || (poolSet && msg.sender == pool),
            "Only vault or pool"
        );
        _;
    }

    event VaultSet(address indexed vault);
    event PoolSet(address indexed pool);

    constructor() ERC20("SunPLS RAI", "SunPLS") ERC20Permit("SunPLS RAI") {
        deployer = msg.sender;
        _mint(msg.sender, SEED_SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Vault latch
    // ─────────────────────────────────────────────────────────────────────

    function setVault(address _vault) external {
        require(msg.sender == deployer, "Only deployer");
        require(!vaultSet, "Already set");
        require(_vault != address(0), "Zero address");
        vault = _vault;
        vaultSet = true;
        emit VaultSet(_vault);
    }

    function setPool(address _pool) external {
        require(msg.sender == deployer, "Only deployer");
        require(!poolSet, "Already set");
        require(_pool != address(0), "Zero address");
        pool = _pool;
        poolSet = true;
        emit PoolSet(_pool);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mint / burn — vault only
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint SunPLS to a borrower. Called by vault on deposit + mint.
     */
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /**
     * @notice Burn SunPLS held by the caller (vault or pool).
     *         Caller must hold the tokens before calling burn().
     *         Vault: burns after pulling from user via transferFrom.
     *         Pool: burns depositor SunPLS during liquidation absorption.
     */
    function burn(uint256 amount) external onlyVaultOrPool {
        _burn(msg.sender, amount);
    }
}
