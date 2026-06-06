// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title StakingRewardsVault
 * @notice XTR 的「非通胀」质押激励分发金库(直接存表版)。
 *
 * 设计(见 moov2-staking-rewards.html):
 *  - 本金库由一笔奖励储备支撑,奖励通过从合约余额 `transfer` 发放 —— 本合约绝不增发(mint)——
 *    因此发放本身不会稀释供应。(预期会把 VotingV2/Staker 的原生 emission 设为 0,由本金库替代它。)
 *  - 「线性释放进度」由链下处理:每月把当期应释放的额度打入本合约即可,本合约不内置时间/线性逻辑,
 *    只认「合约里实际有多少钱」。
 *  - 链下按月算出每地址的「累计应得」,治理通过 {setOwed} 覆盖写上链(不用 Merkle,人少时最简单、
 *    最透明)。用户用 {claim} 自取 `owed - claimed`(未领差额),漏领可累计补领。
 *
 * 保留的两道闸(相对裸版的增强):
 *  - 暂停:出事时 {pause} 冻结 {setOwed}/{claim}。
 *  - 资金闸:每次 {setOwed} 后,「已分配未领总额」不得超过合约当前余额 —— 即「先注资、再分配」,
 *    合约永远不会承诺它发不出来的钱,也防止先领者把别人的份额领空。
 *  - 分权:DISTRIBUTOR 写表(可给链下机器人)、ADMIN 管理(暂停 / 回收)分离。
 *
 * 注:claim 采用「先记账后转账」(CEI),且奖励代币在构造时固定为普通 ERC20(XTR,无回调钩子),
 *     故无重入面,未额外引入 ReentrancyGuard。
 */
contract StakingRewardsVault is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /// @notice 允许写入每月累计 `owed` 的角色(运维多签 / 提交者)。
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    /// @notice 奖励代币(XTR)。不可变。
    IERC20 public immutable rewardToken;

    /// @notice 每个地址的累计应得(由治理 / distributor 写入)。
    mapping(address => uint256) public owed;
    /// @notice 每个地址已领取的累计量。
    mapping(address => uint256) public claimed;
    /// @notice 所有 `owed` 之和(已分配)。
    uint256 public totalOwed;
    /// @notice 所有 `claimed` 之和。
    uint256 public totalClaimed;

    event OwedUpdated(address indexed account, uint256 oldOwed, uint256 newOwed);
    event Claimed(address indexed account, uint256 amount);
    event ExcessRescued(address indexed to, uint256 amount);

    error LengthMismatch();
    error OwedBelowClaimed(address account);
    error ExceedsFunding(uint256 outstanding, uint256 balance);
    error NothingToClaim();
    error NoExcess();
    error ZeroAddress();

    /**
     * @param _rewardToken XTR 代币地址。
     * @param _admin       DEFAULT_ADMIN_ROLE 持有者 —— 必须是多签 / Timelock。
     * @param _distributor 初始 DISTRIBUTOR_ROLE 持有者(可与 _admin 相同)。
     */
    constructor(IERC20 _rewardToken, address _admin, address _distributor) {
        if (address(_rewardToken) == address(0) || _admin == address(0) || _distributor == address(0)) {
            revert ZeroAddress();
        }
        rewardToken = _rewardToken;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DISTRIBUTOR_ROLE, _distributor);
    }

    /*//////////////////////////////////////////////////////////////
                                  视图
    //////////////////////////////////////////////////////////////*/

    /// @notice `account` 当前可领取的未领额度。
    function claimable(address account) external view returns (uint256) {
        return owed[account] - claimed[account];
    }

    /// @notice 已分配给用户、但尚未被领走的代币总额(合约对用户的负债)。
    function outstanding() public view returns (uint256) {
        return totalOwed - totalClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                            DISTRIBUTOR 操作
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice 批量「覆盖写」一组地址的累计 owed(每期链下算好后调用)。
     * @dev 累计值可上调也可下修,但永远不得低于该地址已领取的量。
     *      整批写完后,「已分配未领总额」不得超过合约当前余额 —— 即必须「先注资、再分配」。
     *      列表过大时分多笔调用,以免超出区块 gas 上限。
     */
    function setOwed(address[] calldata accounts, uint256[] calldata cumulativeAmounts)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        whenNotPaused
    {
        if (accounts.length != cumulativeAmounts.length) revert LengthMismatch();

        uint256 running = totalOwed;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 newOwed = cumulativeAmounts[i];
            if (newOwed < claimed[account]) revert OwedBelowClaimed(account);

            uint256 oldOwed = owed[account];
            if (newOwed == oldOwed) continue;

            running = running - oldOwed + newOwed;
            owed[account] = newOwed;
            emit OwedUpdated(account, oldOwed, newOwed);
        }

        // 资金闸:已分配未领总额不得超过当前实际到账余额。
        uint256 newOutstanding = running - totalClaimed;
        uint256 balance = rewardToken.balanceOf(address(this));
        if (newOutstanding > balance) revert ExceedsFunding(newOutstanding, balance);

        totalOwed = running;
    }

    /*//////////////////////////////////////////////////////////////
                                  领取
    //////////////////////////////////////////////////////////////*/

    /// @notice 领取调用者当前所有可领的奖励。
    function claim() external whenNotPaused returns (uint256 amount) {
        amount = owed[msg.sender] - claimed[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] += amount; // 先改状态,后做外部调用(CEI)
        totalClaimed += amount;

        rewardToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              管理 / 安全
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice 取走「高于当前未领总额」的盈余奖励代币(例如某月多打入的部分)。
     * @dev 永远不会动支撑未领分配的资金:可取额 = 余额 − outstanding。
     */
    function rescueExcess(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 owedToUsers = outstanding();
        uint256 bal = rewardToken.balanceOf(address(this));
        if (bal <= owedToUsers) revert NoExcess();
        uint256 excess = bal - owedToUsers;
        rewardToken.safeTransfer(to, excess);
        emit ExcessRescued(to, excess);
    }
}
