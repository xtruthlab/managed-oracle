// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingRewardsVault} from "../src/staking-rewards/StakingRewardsVault.sol";

/**
 * @title Deployment script for StakingRewardsVault
 * @notice Deploys the non-inflationary XTR staking-rewards distributor.
 *
 * The signing key is supplied on the CLI (`--private-key` / `--account` /
 * `--ledger`), NOT read in-script — so no key ever lives in the repo.
 *
 * Required environment variables (all three are explicit on purpose — this
 * contract custodies funds, so the admin/distributor must be chosen, never
 * silently defaulted):
 *   REWARD_TOKEN      XTR token address
 *                       mainnet 196  : 0x1819672530c65e1eF3a3f62fA8e6722655225a78
 *                       testnet 1952 : 0x44B706e1d8b6883677c7c92DC386d96c9B5650F3
 *   VAULT_ADMIN       DEFAULT_ADMIN_ROLE holder (pause / rescueExcess / role
 *                     admin). Should be a multisig/Timelock in production; the
 *                     deployer EOA is acceptable while still in setup.
 *   VAULT_DISTRIBUTOR DISTRIBUTOR_ROLE holder (writes monthly cumulative
 *                     `owed`). Can equal VAULT_ADMIN, or a dedicated off-chain
 *                     submitter bot.
 *
 * Run (example — mainnet):
 *   cd managed-oracle
 *   export REWARD_TOKEN=0x1819672530c65e1eF3a3f62fA8e6722655225a78
 *   export VAULT_ADMIN=0x1F53Be6BDe296C20393d71Eb20233Faae3480B80
 *   export VAULT_DISTRIBUTOR=0x1F53Be6BDe296C20393d71Eb20233Faae3480B80
 *   forge script script/DeployStakingRewardsVault.s.sol \
 *     --rpc-url https://rpc.xlayer.tech --private-key 0x<MAINNET_KEY> --broadcast
 */
contract DeployStakingRewardsVault is Script {
    function run() external {
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        address admin = vm.envAddress("VAULT_ADMIN");
        address distributor = vm.envAddress("VAULT_DISTRIBUTOR");

        require(rewardToken != address(0), "REWARD_TOKEN unset");
        require(admin != address(0), "VAULT_ADMIN unset");
        require(distributor != address(0), "VAULT_DISTRIBUTOR unset");

        vm.startBroadcast();
        StakingRewardsVault vault = new StakingRewardsVault(IERC20(rewardToken), admin, distributor);
        vm.stopBroadcast();

        console.log("StakingRewardsVault deployed at:", address(vault));
        console.log("  rewardToken :", rewardToken);
        console.log("  admin       :", admin);
        console.log("  distributor :", distributor);
    }
}
