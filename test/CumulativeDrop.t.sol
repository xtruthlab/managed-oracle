// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {CumulativeDrop} from "../reference/CumulativeDrop.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockXTR is ERC20 {
    constructor() ERC20("Xtruth Token", "XTR") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract CumulativeDropTest is Test {
    MockXTR xtr;
    CumulativeDrop drop;
    address owner = address(0xABCD);
    address A = address(0xA);

    function setUp() public {
        xtr = new MockXTR();
        drop = new CumulativeDrop(address(xtr), owner);
        xtr.mint(address(drop), 1000 ether);
    }

    function _set(address who, uint256 amt) internal {
        address[] memory a = new address[](1);
        uint256[] memory v = new uint256[](1);
        a[0] = who; v[0] = amt;
        vm.prank(owner);
        drop.setCumulativeOwed(a, v);
    }

    function test_claim_paysDelta() public {
        _set(A, 100 ether);
        drop.claim(A);
        assertEq(xtr.balanceOf(A), 100 ether);
    }

    function test_cumulative_onlyDelta() public {
        _set(A, 100 ether);
        drop.claim(A);
        _set(A, 250 ether);
        drop.claim(A);
        assertEq(xtr.balanceOf(A), 250 ether); // 共 250(只补 150)
    }

    function test_missed_claimAllAtOnce() public {
        _set(A, 300 ether); // 多期累计、从未领
        drop.claim(A);
        assertEq(xtr.balanceOf(A), 300 ether);
    }

    function test_revert_nothingToClaim() public {
        _set(A, 100 ether);
        drop.claim(A);
        vm.expectRevert(CumulativeDrop.NothingToClaim.selector);
        drop.claim(A); // 再领无差额
    }

    function test_owedBelowClaimed_noUnderflow() public {
        _set(A, 100 ether);
        drop.claim(A);            // 已领 100
        _set(A, 40 ether);        // 误写成低于已领
        vm.expectRevert(CumulativeDrop.NothingToClaim.selector);
        drop.claim(A);            // 不下溢,直接 revert
    }

    function test_onlyOwner_setOwed() public {
        address[] memory a = new address[](1);
        uint256[] memory v = new uint256[](1);
        a[0] = A; v[0] = 1 ether;
        vm.prank(A);
        vm.expectRevert();
        drop.setCumulativeOwed(a, v);
    }
}
