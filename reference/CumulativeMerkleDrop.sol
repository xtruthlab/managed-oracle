// SPDX-License-Identifier: MIT
//
// Fork 自 1inch/merkle-distribution(MIT 许可):
//   https://github.com/1inch/merkle-distribution/blob/master/contracts/CumulativeMerkleDrop.sol
// 本 fork 的改动:
//   1. 依赖从 @1inch/solidity-utils 换成 OpenZeppelin(本仓库已有);
//   2. 内联事件 / 错误(去掉对 ICumulativeMerkleDrop 接口文件的依赖),使其自包含、可直接编译;
//   3. 构造函数把 owner 作为参数传入(便于直接设为多签),而非上游的 msg.sender;
//   4. 修正上游事件名拼写 MerkelRootUpdated → MerkleRootUpdated;
//   5. 注释全部中文化。
// 领取记账(累计式 + 发差额)与上游完全一致。
//
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CumulativeMerkleDrop
 * @notice 用 Merkle 树 + 累计金额分发代币的合约(质押者规模变大后,作为 StakingRewardsVault 的替代)。
 * @dev 每个叶子记录某地址的「累计应得」。每期治理把链下算好的新 root 写上链;用户带 proof 领取,
 *      合约只发 `累计应得 − 已领`(差额)。漏领可用最新 proof 一次补齐;新 root 取代旧 root。
 *
 *      ⚠ 叶子哈希约定:leaf = keccak256(abi.encodePacked(account, cumulativeAmount))(单次哈希),
 *      且配对时按数值「排序后」哈希(见 _verifyAsm)。链下生成 root / proof 必须用「相同方案」
 *      —— 即 1inch 的 merkle 库或等价实现;注意这与 OZ StandardMerkleTree 默认的「双重哈希叶子」
 *      不兼容,别混用。
 */
contract CumulativeMerkleDrop is Ownable {
    using SafeERC20 for IERC20;

    /// @notice 被分发的 ERC20 代币(XTR)。不可变。
    address public immutable token;

    /// @notice 当前分发的 Merkle root。
    bytes32 public merkleRoot;

    /// @notice 每个地址的「累计已领」量。
    mapping(address => uint256) public cumulativeClaimed;

    event MerkleRootUpdated(bytes32 oldMerkleRoot, bytes32 newMerkleRoot);
    event Claimed(address indexed account, uint256 amount);

    error MerkleRootWasUpdated();
    error InvalidProof();
    error NothingToClaim();

    /**
     * @param token_ 被分发的 ERC20 代币地址。
     * @param owner_ 合约 owner(可设 root)—— 建议设为多签 / Timelock。
     */
    constructor(address token_, address owner_) Ownable(owner_) {
        token = token_;
    }

    /**
     * @notice 更新分发用的 Merkle root(仅 owner)。
     * @param merkleRoot_ 新的 Merkle root。
     */
    function setMerkleRoot(bytes32 merkleRoot_) external onlyOwner {
        emit MerkleRootUpdated(merkleRoot, merkleRoot_);
        merkleRoot = merkleRoot_;
    }

    /**
     * @notice 用 Merkle proof 为某账户领取代币。
     * @dev cumulativeAmount 是该账户「跨所有分发」的累计应得;合约只发它与已领的差额。
     * @param account            领取的账户(币也发给它,任何人可代为触发)。
     * @param cumulativeAmount   该账户的累计应得总额。
     * @param expectedMerkleRoot proof 对应的 root(防 root 被更新后误领旧值)。
     * @param merkleProof        证明该 (account, cumulativeAmount) 在树里的 proof。
     */
    function claim(
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external {
        // root 若已被更新,拒绝(避免按过期 proof 领取)。
        if (merkleRoot != expectedMerkleRoot) revert MerkleRootWasUpdated();

        // 校验 merkle proof。
        bytes32 leaf = keccak256(abi.encodePacked(account, cumulativeAmount));
        if (!_verifyAsm(merkleProof, expectedMerkleRoot, leaf)) revert InvalidProof();

        // 记账:累计已领不能 ≥ 本次累计应得(否则没得领;也防下溢)。
        uint256 preclaimed = cumulativeClaimed[account];
        // solhint-disable-next-line gas-strict-inequalities
        if (preclaimed >= cumulativeAmount) revert NothingToClaim();
        cumulativeClaimed[account] = cumulativeAmount; // 先记账,后转账

        // 发差额(上面已判 preclaimed < cumulativeAmount,故不会下溢,用 unchecked 省 gas)。
        unchecked {
            uint256 amount = cumulativeAmount - preclaimed;
            IERC20(token).safeTransfer(account, amount);
            emit Claimed(account, amount);
        }
    }

    /**
     * @notice 用内联汇编校验 Merkle proof(省 gas)。
     * @dev 配对时按数值排序后哈希,需与链下生成 proof 的方案一致。
     * @param proof 待校验的 proof。
     * @param root  对照的 Merkle root。
     * @param leaf  待校验的叶子。
     * @return valid proof 是否有效。
     */
    function _verifyAsm(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool valid) {
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            let ptr := proof.offset

            for { let end := add(ptr, mul(0x20, proof.length)) } lt(ptr, end) { ptr := add(ptr, 0x20) } {
                let node := calldataload(ptr)

                switch lt(leaf, node)
                case 1 {
                    mstore(0x00, leaf)
                    mstore(0x20, node)
                }
                default {
                    mstore(0x00, node)
                    mstore(0x20, leaf)
                }

                leaf := keccak256(0x00, 0x40)
            }

            valid := eq(root, leaf)
        }
    }
}
