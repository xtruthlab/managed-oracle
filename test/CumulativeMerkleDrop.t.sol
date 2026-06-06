// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {CumulativeMerkleDrop} from "../reference/CumulativeMerkleDrop.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockXTR is ERC20 {
    constructor() ERC20("Xtruth Token", "XTR") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract CumulativeMerkleDropTest is Test {
    MockXTR xtr;
    CumulativeMerkleDrop drop;

    address owner = address(0xABCD);
    address A = address(0xA);
    address B = address(0xB);

    uint256 amtA = 100 ether;
    uint256 amtB = 50 ether;

    bytes32 leafA;
    bytes32 leafB;
    bytes32 root;

    function setUp() public {
        xtr = new MockXTR();
        drop = new CumulativeMerkleDrop(address(xtr), owner);
        xtr.mint(address(drop), 1000 ether); // fund

        // 用和合约一致的方案手搓 2 叶子树:单次哈希叶子 + 排序配对
        leafA = keccak256(abi.encodePacked(A, amtA));
        leafB = keccak256(abi.encodePacked(B, amtB));
        root = leafA < leafB
            ? keccak256(abi.encodePacked(leafA, leafB))
            : keccak256(abi.encodePacked(leafB, leafA));

        vm.prank(owner);
        drop.setMerkleRoot(root);
    }

    function _proofFor(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function test_claim_validProof() public {
        drop.claim(A, amtA, root, _proofFor(leafB)); // A 的兄弟是 leafB
        assertEq(xtr.balanceOf(A), amtA);
        assertEq(drop.cumulativeClaimed(A), amtA);
    }

    function test_claim_cumulative_secondRoundOnlyDelta() public {
        drop.claim(A, amtA, root, _proofFor(leafB)); // 先领 100

        // 第二轮:A 累计涨到 180,重建 root
        uint256 amtA2 = 180 ether;
        bytes32 leafA2 = keccak256(abi.encodePacked(A, amtA2));
        bytes32 root2 = leafA2 < leafB
            ? keccak256(abi.encodePacked(leafA2, leafB))
            : keccak256(abi.encodePacked(leafB, leafA2));
        vm.prank(owner);
        drop.setMerkleRoot(root2);

        drop.claim(A, amtA2, root2, _proofFor(leafB));
        assertEq(xtr.balanceOf(A), amtA2); // 共 180(只补了 80)
    }

    function test_revert_nothingToClaim_secondTimeSameRoot() public {
        drop.claim(A, amtA, root, _proofFor(leafB));
        vm.expectRevert(CumulativeMerkleDrop.NothingToClaim.selector);
        drop.claim(A, amtA, root, _proofFor(leafB));
    }

    function test_revert_badProof() public {
        bytes32[] memory bad = _proofFor(keccak256("garbage"));
        vm.expectRevert(CumulativeMerkleDrop.InvalidProof.selector);
        drop.claim(A, amtA, root, bad);
    }

    function test_revert_staleRoot() public {
        vm.prank(owner);
        drop.setMerkleRoot(keccak256("newroot"));
        vm.expectRevert(CumulativeMerkleDrop.MerkleRootWasUpdated.selector);
        drop.claim(A, amtA, root, _proofFor(leafB)); // 用旧 root
    }

    function test_onlyOwner_setRoot() public {
        vm.prank(A);
        vm.expectRevert();
        drop.setMerkleRoot(keccak256("x"));
    }
}
