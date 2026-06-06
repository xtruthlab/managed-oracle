// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {StakingRewardsVault} from "../src/staking-rewards/StakingRewardsVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockXTR is ERC20 {
    constructor() ERC20("Xtruth Token", "XTR") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract StakingRewardsVaultTest is Test {
    MockXTR xtr;
    StakingRewardsVault vault;

    address admin = address(0xA11CE);
    address distributor = address(0xD15);
    address A = address(0xA);
    address B = address(0xB);
    address treasury = address(0x7);

    function setUp() public {
        xtr = new MockXTR();
        vault = new StakingRewardsVault(IERC20(address(xtr)), admin, distributor);
    }

    // ---- helpers ----
    function _fund(uint256 amt) internal {
        xtr.mint(address(vault), amt); // 链下每月把当期额度打进来
    }

    function _setOwed(address who, uint256 amt) internal {
        address[] memory a = new address[](1);
        uint256[] memory v = new uint256[](1);
        a[0] = who; v[0] = amt;
        vm.prank(distributor);
        vault.setOwed(a, v);
    }

    // ---- core flow ----
    function test_setOwed_then_claim_paysDelta() public {
        _fund(1000 ether);
        _setOwed(A, 1000 ether);

        assertEq(vault.claimable(A), 1000 ether);
        vm.prank(A);
        uint256 got = vault.claim();
        assertEq(got, 1000 ether);
        assertEq(xtr.balanceOf(A), 1000 ether);
        assertEq(vault.claimed(A), 1000 ether);
        assertEq(vault.claimable(A), 0);
    }

    function test_cumulative_secondMonth_onlyDelta() public {
        _fund(1000 ether);
        _setOwed(A, 1000 ether);
        vm.prank(A); vault.claim();              // claims 1000

        _fund(1500 ether);                        // fund next tranche
        _setOwed(A, 2500 ether);                  // cumulative now 2500
        vm.prank(A);
        uint256 got = vault.claim();
        assertEq(got, 1500 ether);                // only the delta
        assertEq(xtr.balanceOf(A), 2500 ether);
    }

    function test_missedMonths_claimAllAtOnce() public {
        _fund(3000 ether);
        _setOwed(A, 3000 ether);                  // accumulated over months, never claimed
        vm.prank(A);
        assertEq(vault.claim(), 3000 ether);
    }

    // ---- safety guards ----
    function test_revert_allocateBeyondFunding() public {
        _fund(500 ether);                         // only 500 funded
        vm.expectRevert();                        // allocating 1000 must revert (outstanding > balance)
        _setOwed(A, 1000 ether);
    }

    function test_revert_owedBelowClaimed() public {
        _fund(1000 ether);
        _setOwed(A, 1000 ether);
        vm.prank(A); vault.claim();               // claimed 1000
        vm.expectRevert();                        // cannot set owed below claimed
        _setOwed(A, 500 ether);
    }

    function test_revert_claimNothing() public {
        vm.prank(B);
        vm.expectRevert(StakingRewardsVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_onlyDistributor_canSetOwed() public {
        address[] memory a = new address[](1);
        uint256[] memory v = new uint256[](1);
        a[0] = A; v[0] = 1 ether;
        vm.prank(A);
        vm.expectRevert();
        vault.setOwed(a, v);
    }

    function test_pause_blocksClaim() public {
        _fund(1000 ether);
        _setOwed(A, 1000 ether);
        vm.prank(admin); vault.pause();
        vm.prank(A);
        vm.expectRevert();
        vault.claim();
    }

    // ---- admin / sweeps ----
    function test_rescueExcess_onlyAboveOutstanding() public {
        _fund(1000 ether);
        _setOwed(A, 1000 ether);                  // outstanding == balance => no excess
        vm.prank(admin);
        vm.expectRevert(StakingRewardsVault.NoExcess.selector);
        vault.rescueExcess(treasury);

        _fund(10 ether);                          // over-fund by 10
        vm.prank(admin);
        vault.rescueExcess(treasury);
        assertEq(xtr.balanceOf(treasury), 10 ether);
    }

}
