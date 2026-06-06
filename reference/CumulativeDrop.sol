// SPDX-License-Identifier: MIT
//
// 基于 1inch CumulativeMerkleDrop(MIT)改写:把「Merkle 验证」换成「治理直接赋值 cumulativeOwed」。
// —— 质押者少时用这版:最简单、最透明(应得金额直接上链可读),无需 proof。
// 累计式记账(存累计、发差额、>= 守卫、CEI、unchecked)与 1inch 完全一致,只是金额来源
// 从「merkle 叶子」换成「链上 cumulativeOwed 映射」。
//
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CumulativeDrop
 * @notice 累计式直接赋值分发器:链下算好「每地址累计应得」,治理直接写进合约,用户自取差额。
 * @dev 资金需预先转入本合约;发放靠 `transfer`(非 mint)。漏领可累计补领。
 */
contract CumulativeDrop is Ownable {
    using SafeERC20 for IERC20;

    /// @notice 被分发的 ERC20 代币(XTR)。不可变。
    address public immutable token;

    /// @notice 每个地址的「累计应得」(取代 merkleRoot;由治理直接写)。
    mapping(address => uint256) public cumulativeOwed;
    /// @notice 每个地址的「累计已领」。
    mapping(address => uint256) public cumulativeClaimed;

    event OwedUpdated(address indexed account, uint256 cumulativeOwed);
    event Claimed(address indexed account, uint256 amount);

    error LengthMismatch();
    error NothingToClaim();

    /**
     * @param token_ 被分发的 ERC20 代币地址。
     * @param owner_ 合约 owner(可写应得)—— 建议设为多签 / Timelock。
     */
    constructor(address token_, address owner_) Ownable(owner_) {
        token = token_;
    }

    /**
     * @notice 批量「覆盖写」累计应得(取代 setMerkleRoot;每期链下算好后调用)。
     * @dev 覆盖式:传入的就是「截至目前的累计应得」。无需与已领比较 —— claim 时的 `>=` 守卫
     *      会自然处理「写得比已领还低」的情况(那时无差额可领、直接 revert,不会下溢)。
     *      列表过大时分多笔调用,以免超出区块 gas 上限。
     */
    function setCumulativeOwed(address[] calldata accounts, uint256[] calldata amounts) external onlyOwner {
        if (accounts.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            cumulativeOwed[accounts[i]] = amounts[i];
            emit OwedUpdated(accounts[i], amounts[i]);
        }
    }

    /**
     * @notice 为某账户领取代币(任何人可代触发,币只发给 account)。
     * @dev 只发「累计应得 − 累计已领」的差额。
     */
    function claim(address account) external {
        uint256 owed = cumulativeOwed[account];
        uint256 preclaimed = cumulativeClaimed[account];
        // solhint-disable-next-line gas-strict-inequalities
        if (preclaimed >= owed) revert NothingToClaim(); // 没差额(含「应得≤已领」)→ 拒绝,且防下溢
        cumulativeClaimed[account] = owed;               // 先记账,后转账(防重入)

        unchecked {
            uint256 amount = owed - preclaimed;
            IERC20(token).safeTransfer(account, amount);
            emit Claimed(account, amount);
        }
    }
}
