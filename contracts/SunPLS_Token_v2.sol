// SPDX-License-Identifier: CC-BY-NC-SA-4.0
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║                   SunPLS Token v2.0 — ELITE TEAM6                    ║
 * ║                   Autonomous Stable Asset                            ║
 * ║                                                                      ║
 * ║   CHANGES FROM v1.3:                                                 ║
 * ║                                                                      ║
 * ║   ✓ ERC20Permit (EIP-2612)                                           ║
 * ║     Enables single-transaction agent flows: repay, liquidate,        ║
 * ║     and redeem without a prior approve() transaction.                ║
 * ║     Agents sign a permit offline and submit one tx.                  ║
 * ║                                                                      ║
 * ║   ✓ Trust-minimized vault burn                                       ║
 * ║     v1.3: vault called burn(address from, amount) — burned directly  ║
 * ║            from user address via internal _burn.                     ║
 * ║     v2.0: vault calls transferFrom(user → vault) then burn(amount)   ║
 * ║            — vault burns only tokens it holds. The vault cannot      ║
 * ║            silently drain user balances without a visible transfer.  ║
 * ║     This model integrates naturally with permit: user approves once  ║
 * ║     (or signs a permit), vault pulls then burns.                     ║
 * ║                                                                      ║
 * ║   UNCHANGED:                                                         ║
 * ║   ✓ One-time deployer-controlled vault latch                         ║
 * ║   ✓ No admin keys after setVault()                                   ║
 * ║   ✓ 1,000,000,000 SUNPLS minted once at construction for LP seed     ║
 * ║   ✓ mint(address to, uint256 amount) — vault only                    ║
 * ║                                                                      ║
 * ║   DEPLOY SEQUENCE (same as v1, new token address):                   ║
 * ║   Step 1: Deploy SunPLS_Token_v2 (1B minted to deployer)             ║
 * ║   Step 2: Create PulseX SunPLS/WPLS pair + seed 1:1 with WPLS        ║
 * ║   Step 3: Deploy SunPLS_Oracle (UNCHANGED from v1)                   ║
 * ║   Step 4: Deploy SunPLS_Controller v4.3 (UNCHANGED from v1)          ║
 * ║   Step 5: Deploy SunPLS_Vault_v2 (weth, token, oracle, controller,   ║
 * ║             debtCeiling)                                             ║
 * ║   Step 6: token.setVault(vault)      ← latches forever               ║
 * ║   Step 7: controller.setVault(vault) ← latches forever               ║
 * ║                                                                      ║
 * ║   Dev:     ELITE TEAM6                                               ║
 * ║   Website: https://www.sundaitoken.com                               ║
 * ║   License: CC-BY-NC-SA-4.0 | Immutable After Launch                  ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract SunPLS is ERC20Permit {

    address private immutable deployer;

    address public vault;
    bool    public vaultSet;

    uint256 public constant SEED_SUPPLY      = 1_000_000_000 * 1e18;
    string  public constant PROTOCOL_VERSION = "SunPLS_v2";

    modifier onlyVault() {
        require(vaultSet && msg.sender == vault, "Only vault");
        _;
    }

    event VaultSet(address indexed vault);
    event Minted(address indexed to,   uint256 amount);
    event Burned(address indexed from, uint256 amount);

    constructor()
        ERC20("SunPLS", "SUNPLS")
        ERC20Permit("SunPLS")
    {
        deployer = msg.sender;
        _mint(msg.sender, SEED_SUPPLY);
    }

    /// @notice One-time vault latch. Only deployer. Immutable after.
    function setVault(address _vault) external {
        require(msg.sender == deployer, "Only deployer");
        require(!vaultSet,              "Vault already set");
        require(_vault != address(0),   "Zero vault address");
        vault    = _vault;
        vaultSet = true;
        emit VaultSet(_vault);
    }

    /// @notice Mint to any address. Vault only.
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /// @notice Burn tokens from vault's own balance.
    ///         Vault must transferFrom user → vault before calling this.
    ///         The vault cannot silently drain user balances — burn path
    ///         requires a visible ERC20 transfer first.
    function burn(uint256 amount) external onlyVault {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    function decimals() public pure override returns (uint8) { return 18; }
}
