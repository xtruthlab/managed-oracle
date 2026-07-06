// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ResolverStake} from "src/resolver-stake/ResolverStake.sol";

contract ResolverStakeTest is Test {
    ResolverStake internal rs;
    address internal alice;
    address internal bob;

    uint256 constant AMT = 1 ether;

    event Staked(address indexed resolver, uint256 amount);
    event Withdrawn(address indexed resolver, uint256 amount);

    function setUp() public {
        rs = new ResolverStake();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_stake_activatesAndHoldsExactly1() public {
        vm.expectEmit(true, false, false, true);
        emit Staked(alice, AMT);
        vm.prank(alice);
        rs.stake{value: AMT}();

        assertTrue(rs.isStaked(alice), "staked");
        assertEq(rs.stakerCount(), 1, "count");
        assertEq(address(rs).balance, AMT, "contract holds 1 OKB");
        assertEq(alice.balance, 9 ether, "alice paid 1 OKB");
    }

    function test_stake_wrongAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverStake.IncorrectStakeAmount.selector, 0.5 ether, AMT));
        rs.stake{value: 0.5 ether}();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverStake.IncorrectStakeAmount.selector, 2 ether, AMT));
        rs.stake{value: 2 ether}();
    }

    function test_stake_twice_reverts() public {
        vm.prank(alice);
        rs.stake{value: AMT}();
        vm.prank(alice);
        vm.expectRevert(ResolverStake.AlreadyStaked.selector);
        rs.stake{value: AMT}();
    }

    function test_withdraw_returnsFundAndDeactivates() public {
        vm.prank(alice);
        rs.stake{value: AMT}();

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, AMT);
        vm.prank(alice);
        rs.withdraw();

        assertFalse(rs.isStaked(alice), "not staked");
        assertEq(rs.stakerCount(), 0, "count");
        assertEq(address(rs).balance, 0, "drained");
        assertEq(alice.balance, 10 ether, "alice whole again");
    }

    function test_withdraw_notStaked_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ResolverStake.NotStaked.selector);
        rs.withdraw();
    }

    function test_restake_afterWithdraw_works() public {
        vm.startPrank(alice);
        rs.stake{value: AMT}();
        rs.withdraw();
        rs.stake{value: AMT}();
        vm.stopPrank();
        assertTrue(rs.isStaked(alice));
        assertEq(rs.stakerCount(), 1);
    }

    function test_multipleStakers_independent() public {
        vm.prank(alice);
        rs.stake{value: AMT}();
        vm.prank(bob);
        rs.stake{value: AMT}();
        assertEq(rs.stakerCount(), 2);
        assertEq(address(rs).balance, 2 * AMT);

        vm.prank(alice);
        rs.withdraw();
        assertEq(rs.stakerCount(), 1);
        assertTrue(rs.isStaked(bob));
        assertEq(alice.balance, 10 ether);
        assertEq(address(rs).balance, AMT);
    }

    function test_directSend_reverts_noReceive() public {
        vm.prank(alice);
        (bool ok,) = address(rs).call{value: AMT}("");
        assertFalse(ok, "plain transfer must revert (no receive/fallback)");
        assertEq(address(rs).balance, 0);
    }

    function test_reentrancy_cannotDoubleWithdraw() public {
        ReentrantStaker atk = new ReentrantStaker(rs);
        vm.deal(address(atk), 5 ether);
        atk.doStake();
        assertEq(address(rs).balance, AMT);

        atk.doWithdraw(); // its receive() re-enters withdraw(); guard + CEI must block the second

        assertTrue(atk.reenteredAttempted(), "reentry path exercised");
        assertEq(address(rs).balance, 0, "exactly one withdrawal happened");
        assertEq(address(atk).balance, 5 ether, "attacker got back exactly its 1 OKB, not more");
        assertFalse(rs.isStaked(address(atk)));
    }

    function test_withdraw_toRejectingReceiver_revertsAndKeepsState() public {
        NoReceiveStaker nr = new NoReceiveStaker(rs);
        vm.deal(address(nr), 5 ether);
        nr.doStake();
        vm.expectRevert(ResolverStake.TransferFailed.selector);
        nr.doWithdraw();
        // state rolled back — still staked, funds intact (recoverable if receiver could accept)
        assertTrue(rs.isStaked(address(nr)));
        assertEq(address(rs).balance, AMT);
    }
}

contract ReentrantStaker {
    ResolverStake public target;
    bool public reenteredAttempted;

    constructor(ResolverStake _t) {
        target = _t;
    }

    function doStake() external {
        target.stake{value: 1 ether}();
    }

    function doWithdraw() external {
        target.withdraw();
    }

    receive() external payable {
        if (!reenteredAttempted) {
            reenteredAttempted = true;
            // Must revert (ReentrancyGuard); swallow so the outer withdraw still completes.
            try target.withdraw() {} catch {}
        }
    }
}

contract NoReceiveStaker {
    ResolverStake public target;

    constructor(ResolverStake _t) {
        target = _t;
    }

    function doStake() external {
        target.stake{value: 1 ether}();
    }

    function doWithdraw() external {
        target.withdraw();
    }
    // no receive/fallback → cannot accept the withdrawal transfer
}
