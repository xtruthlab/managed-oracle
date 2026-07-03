// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ResolverStake} from "../src/resolver-stake/ResolverStake.sol";

/**
 * @title Deployment script for ResolverStake
 * @notice Deploys the resolver membership-deposit contract (1 OKB, withdrawable
 * any time). No constructor args — the contract is owner-less by design (no
 * slash, no admin), so nothing needs to be configured or defaulted.
 *
 * The signing key is supplied on the CLI (`--private-key` / `--account` /
 * `--ledger`), NOT read in-script — so no key ever lives in the repo.
 *
 * Run (example — testnet):
 *   cd managed-oracle
 *   forge script script/DeployResolverStake.s.sol \
 *     --rpc-url https://testrpc.xlayer.tech/terigon --private-key 0x<KEY> --broadcast
 */
contract DeployResolverStake is Script {
    function run() external {
        vm.startBroadcast();
        ResolverStake resolverStake = new ResolverStake();
        vm.stopBroadcast();

        console.log("ResolverStake deployed at:", address(resolverStake));
        console.log("  STAKE_AMOUNT (wei)     :", resolverStake.STAKE_AMOUNT());
    }
}
