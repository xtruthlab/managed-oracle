// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ResolverStake
 * @notice xtruth resolver 的「会员入场押金」合约。审核通过的 resolver 质押正好 1 OKB(X Layer
 * 原生币)激活身份,并可**随时全额提取**。提取会触发 {Withdrawn} 事件 —— 运维据此决定是否把该
 * 地址从 MOOv2 proposer 白名单移除(也可以忽略)。
 *
 * 定位:这是「押金 / 诚意门槛」,**不是「可罚没 bond」**。因此:
 *  - 无 owner / admin、无 slash、无锁定 / 冷却 —— 任何人(含部署者)都拿不走 resolver 的押金,
 *    resolver 也随时可全额退出。合约对每个地址只托管它自己那 1 OKB。
 *  - 「答错要罚」的经济惩罚由 resolver 在 MOOv2 里每次 propose 的保证金承担,和这 1 OKB 无关。
 *  - 对坏行为的约束靠链下运营闭环(提取 → 通知 → 白名单移除),不在链上做。
 *
 * 安全:
 *  - 提取采用「先记账后转账」(CEI:先置零 + emit,再原生转账),并叠加 {ReentrancyGuard} 双保险。
 *  - 无 receive / fallback —— 任何非 {stake} 的裸转入都会 revert,合约余额恒等于 `stakerCount * 1 OKB`。
 */
contract ResolverStake is ReentrancyGuard {
    /// @notice 固定质押额:1 OKB(原生币,18 位小数)。
    uint256 public constant STAKE_AMOUNT = 1 ether;

    /// @notice 地址 => 是否已质押(激活中)。
    mapping(address => bool) public isStaked;

    /// @notice 当前质押人数(= 合约余额 / STAKE_AMOUNT)。
    uint256 public stakerCount;

    /// @notice 质押额必须正好为 STAKE_AMOUNT。
    error IncorrectStakeAmount(uint256 sent, uint256 required);
    /// @notice 同一地址不可重复质押。
    error AlreadyStaked();
    /// @notice 未质押无法提取。
    error NotStaked();
    /// @notice 原生币转账失败。
    error TransferFailed();

    /// @notice 某地址质押 STAKE_AMOUNT 激活为 resolver。
    event Staked(address indexed resolver, uint256 amount);
    /// @notice 某地址提取押金 —— 运维据此考虑是否将其移出 MOOv2 白名单。
    event Withdrawn(address indexed resolver, uint256 amount);

    /**
     * @notice 质押正好 1 OKB,激活为 resolver。
     * @dev 一地址一份;若已质押,需先 {withdraw} 再重新质押。
     */
    function stake() external payable {
        require(msg.value == STAKE_AMOUNT, IncorrectStakeAmount(msg.value, STAKE_AMOUNT));
        require(!isStaked[msg.sender], AlreadyStaked());
        isStaked[msg.sender] = true;
        stakerCount += 1;
        emit Staked(msg.sender, STAKE_AMOUNT);
    }

    /**
     * @notice 随时全额提取你的 1 OKB 押金。触发 {Withdrawn} 供运维审阅白名单移除(可忽略)。
     * @dev CEI + nonReentrant:先把状态置零并 emit,再原生转账。
     */
    function withdraw() external nonReentrant {
        require(isStaked[msg.sender], NotStaked());
        isStaked[msg.sender] = false;
        stakerCount -= 1;
        emit Withdrawn(msg.sender, STAKE_AMOUNT);
        (bool ok,) = payable(msg.sender).call{value: STAKE_AMOUNT}("");
        require(ok, TransferFailed());
    }
}
