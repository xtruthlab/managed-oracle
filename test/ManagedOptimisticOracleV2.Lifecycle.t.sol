// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ManagedOptimisticOracleV2} from "src/optimistic-oracle-v2/implementation/ManagedOptimisticOracleV2.sol";
import {ManagedOptimisticOracleV2Interface} from
    "src/optimistic-oracle-v2/interfaces/ManagedOptimisticOracleV2Interface.sol";
import {OptimisticOracleV2Interface} from "src/optimistic-oracle-v2/interfaces/OptimisticOracleV2Interface.sol";

import {OracleInterfaces} from "@uma/contracts/data-verification-mechanism/implementation/Constants.sol";
import {OracleAncillaryInterface} from
    "@uma/contracts/data-verification-mechanism/interfaces/OracleAncillaryInterface.sol";
import {FinderInterface} from "@uma/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

import {AddressWhitelist} from "src/common/implementation/AddressWhitelist.sol";
import {DisabledAddressWhitelist} from "src/common/implementation/DisabledAddressWhitelist.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Reuse the unit-test mocks (top-level contracts in the sibling test file).
import {MockStore, MockIdentifierWhitelist, MockFinder} from "./ManagedOptimisticOracleV2.t.sol";

/**
 * @dev Minimal DVM mock implementing OracleAncillaryInterface. `disputePriceFor` calls `requestPrice`, and settle/state
 * read `hasPrice` / `getPrice`. The test pushes a resolved price via `pushPrice` to simulate DVM resolution.
 */
contract MockOracle is OracleAncillaryInterface {
    mapping(bytes32 => int256) internal prices;
    mapping(bytes32 => bool) internal resolved;
    mapping(bytes32 => bool) public requested;

    function _key(bytes32 id, uint256 time, bytes memory anc) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, time, anc));
    }

    function requestPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData) public override {
        requested[_key(identifier, time, ancillaryData)] = true;
    }

    function hasPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData)
        public
        view
        override
        returns (bool)
    {
        return resolved[_key(identifier, time, ancillaryData)];
    }

    function getPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData)
        public
        view
        override
        returns (int256)
    {
        bytes32 k = _key(identifier, time, ancillaryData);
        require(resolved[k], "no price");
        return prices[k];
    }

    // Test helper: simulate the DVM resolving a disputed request.
    function pushPrice(bytes32 identifier, uint256 time, bytes memory ancillaryData, int256 price) external {
        bytes32 k = _key(identifier, time, ancillaryData);
        prices[k] = price;
        resolved[k] = true;
    }
}

/**
 * @title Full request -> propose -> (dispute -> DVM) -> settle lifecycle tests for ManagedOptimisticOracleV2.
 * @notice Complements ManagedOptimisticOracleV2.t.sol (which covers the management layer in isolation) by exercising the
 * end-to-end OO lifecycle: settlement payouts, dispute resolution both ways, state machine transitions, whitelist gating
 * of the real propose/dispute calls, and that manager bond/liveness/whitelist overrides actually take effect on-chain.
 */
contract ManagedOptimisticOracleV2LifecycleTest is Test {
    // Actors
    address internal configAdmin = makeAddr("configAdmin");
    address internal upgradeAdmin = makeAddr("upgradeAdmin");
    address internal requestManager = makeAddr("requestManager");
    address internal requester = makeAddr("requester");
    address internal proposer = makeAddr("proposer");
    address internal disputer = makeAddr("disputer");
    address internal outsider = makeAddr("outsider");

    // Core
    ManagedOptimisticOracleV2 internal moo;
    MockFinder internal finder;
    AddressWhitelist internal collateralWhitelist;
    AddressWhitelist internal defaultProposerWhitelist;
    AddressWhitelist internal requesterWhitelist;
    DisabledAddressWhitelist internal disabledWhitelist;
    MockIdentifierWhitelist internal idWhitelist;
    MockStore internal store;
    MockOracle internal oracle;
    ERC20Mock internal currency;

    // Params (mirror the deploy / unit-test config)
    uint256 internal constant DEFAULT_LIVENESS = 2 days;
    uint256 internal constant MIN_LIVENESS = 1 hours;
    uint256 internal constant FINAL_FEE = 10 ether;
    uint128 internal constant MIN_BOND = 1 ether;
    uint128 internal constant MAX_BOND = 1_000 ether;
    // Amount minted to a proposer/disputer before they act (each starts at 0 balance).
    uint256 internal constant PURSE = 10_000 ether;

    bytes32 internal constant IDENTIFIER = keccak256("PRICE_ID");
    bytes internal constant ANCILLARY = bytes(":memo: lifecycle");

    function setUp() public {
        finder = new MockFinder();
        collateralWhitelist = new AddressWhitelist();
        defaultProposerWhitelist = new AddressWhitelist();
        requesterWhitelist = new AddressWhitelist();
        disabledWhitelist = new DisabledAddressWhitelist();
        idWhitelist = new MockIdentifierWhitelist();
        store = new MockStore();
        oracle = new MockOracle();
        currency = new ERC20Mock();

        collateralWhitelist.addToWhitelist(address(currency));
        idWhitelist.addSupportedIdentifier(IDENTIFIER);

        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(collateralWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(idWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(oracle));

        store.setFinalFee(address(currency), FINAL_FEE);

        defaultProposerWhitelist.addToWhitelist(proposer);
        requesterWhitelist.addToWhitelist(requester);

        ManagedOptimisticOracleV2 impl = new ManagedOptimisticOracleV2();
        ManagedOptimisticOracleV2.CurrencyBondRange[] memory ranges =
            new ManagedOptimisticOracleV2.CurrencyBondRange[](1);
        ranges[0] = ManagedOptimisticOracleV2.CurrencyBondRange({
            currency: IERC20(address(currency)),
            range: ManagedOptimisticOracleV2.BondRange({minimumBond: MIN_BOND, maximumBond: MAX_BOND})
        });

        bytes memory initData = abi.encodeWithSelector(
            ManagedOptimisticOracleV2.initialize.selector,
            DEFAULT_LIVENESS,
            address(finder),
            address(defaultProposerWhitelist),
            address(requesterWhitelist),
            ranges,
            MIN_LIVENESS,
            configAdmin,
            upgradeAdmin
        );
        moo = ManagedOptimisticOracleV2(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(configAdmin);
        moo.addRequestManager(requestManager);
    }

    // ----------------------------- helpers -----------------------------

    function _fund(address who, uint256 amount) internal {
        currency.mint(who, amount);
        vm.prank(who);
        currency.approve(address(moo), type(uint256).max);
    }

    function _request(uint256 timestamp, uint256 reward) internal returns (uint256 totalBond) {
        _fund(requester, reward);
        vm.prank(requester);
        return moo.requestPrice(IDENTIFIER, timestamp, ANCILLARY, IERC20(address(currency)), reward);
    }

    // proposer == msg.sender so bond paid by, and payout returns to, the same address (clean accounting).
    function _proposeSelf(address who, uint256 timestamp, int256 price) internal returns (uint256) {
        _fund(who, PURSE);
        vm.prank(who);
        return moo.proposePrice(requester, IDENTIFIER, timestamp, ANCILLARY, price);
    }

    function _dispute(address who, uint256 timestamp) internal returns (uint256) {
        _fund(who, PURSE);
        vm.prank(who);
        return moo.disputePrice(requester, IDENTIFIER, timestamp, ANCILLARY);
    }

    function _state(uint256 timestamp) internal view returns (OptimisticOracleV2Interface.State) {
        return moo.getState(requester, IDENTIFIER, timestamp, ANCILLARY);
    }

    // Push a DVM resolution for a disputed request (non-event-based => dvm timestamp == request timestamp).
    function _resolveDvm(uint256 timestamp, int256 price) internal {
        bytes memory stamped = moo.stampAncillaryData(ANCILLARY, requester);
        oracle.pushPrice(IDENTIFIER, timestamp, stamped, price);
    }

    // ----------------------------- settlement (no dispute) -----------------------------

    function testExpirySettlementPaysProposerBondPlusReward() external {
        uint256 t = block.timestamp;
        uint256 reward = 50 ether;
        assertEq(_request(t, reward), 20 ether); // bond(=finalFee 10) + finalFee 10

        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Requested));

        _proposeSelf(proposer, t, 1234); // funds proposer with PURSE, then pays totalBond 20
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Proposed));
        assertEq(currency.balanceOf(proposer), PURSE - 20 ether);

        // Cannot settle before liveness expires.
        vm.expectRevert(OptimisticOracleV2Interface.RequestNotSettleable.selector);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);

        vm.warp(t + DEFAULT_LIVENESS);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Expired));

        uint256 payout = moo.settle(requester, IDENTIFIER, t, ANCILLARY);
        // Expiry payout = bond(10) + finalFee(10) + reward(50).
        assertEq(payout, 70 ether);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Settled));
        // Net for proposer = -20 (bond+fee) +70 (payout) = +50 reward.
        assertEq(currency.balanceOf(proposer), PURSE + 50 ether);

        OptimisticOracleV2Interface.Request memory r = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(r.resolvedPrice, 1234);
        assertTrue(r.settled);
    }

    // ----------------------------- dispute -> DVM resolution -----------------------------

    function testDisputeProposerWins() external {
        uint256 t = block.timestamp;
        _request(t, 0);
        _proposeSelf(proposer, t, 100);

        uint256 pBefore = currency.balanceOf(proposer); // already paid 20 bond
        _dispute(disputer, t);
        uint256 dBefore = currency.balanceOf(disputer); // already paid 20 bond
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Disputed));

        // DVM agrees with proposer (price == proposed) => proposer wins.
        _resolveDvm(t, 100);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Resolved));

        uint256 payout = moo.settle(requester, IDENTIFIER, t, ANCILLARY);
        // Resolved payout = bond(10) + unburnedBond(10-5) + finalFee(10) = 25.
        assertEq(payout, 25 ether);
        assertEq(currency.balanceOf(proposer), pBefore + 25 ether); // proposer collects
        assertEq(currency.balanceOf(disputer), dBefore); // disputer gets nothing back
        assertEq(
            moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).resolvedPrice, 100
        );
    }

    function testDisputeDisputerWins() external {
        uint256 t = block.timestamp;
        _request(t, 0);
        _proposeSelf(proposer, t, 100);
        _dispute(disputer, t);

        uint256 pBefore = currency.balanceOf(proposer);
        uint256 dBefore = currency.balanceOf(disputer);

        // DVM disagrees with proposer (price != proposed) => disputer wins.
        _resolveDvm(t, 999);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Resolved));

        uint256 payout = moo.settle(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(payout, 25 ether);
        assertEq(currency.balanceOf(disputer), dBefore + 25 ether); // disputer collects
        assertEq(currency.balanceOf(proposer), pBefore); // proposer loses bond
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).resolvedPrice, 999);
    }

    function testAnyoneCanDispute() external {
        // Disputing has no whitelist: a completely un-whitelisted address can dispute.
        uint256 t = block.timestamp;
        _request(t, 0);
        _proposeSelf(proposer, t, 7);
        assertFalse(requesterWhitelist.isOnWhitelist(outsider));
        assertFalse(defaultProposerWhitelist.isOnWhitelist(outsider));
        _dispute(outsider, t);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Disputed));
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).disputer, outsider);
    }

    function testCannotDisputeAfterExpiry() external {
        uint256 t = block.timestamp;
        _request(t, 0);
        _proposeSelf(proposer, t, 7);
        vm.warp(t + DEFAULT_LIVENESS); // now Expired, not Proposed
        _fund(disputer, 10_000 ether);
        vm.expectRevert(OptimisticOracleV2Interface.RequestStateNotProposed.selector);
        vm.prank(disputer);
        moo.disputePrice(requester, IDENTIFIER, t, ANCILLARY);
    }

    function testCannotDisputeBeforeProposal() external {
        uint256 t = block.timestamp;
        _request(t, 0); // only Requested
        _fund(disputer, 10_000 ether);
        vm.expectRevert(OptimisticOracleV2Interface.RequestStateNotProposed.selector);
        vm.prank(disputer);
        moo.disputePrice(requester, IDENTIFIER, t, ANCILLARY);
    }

    // ----------------------------- proposer whitelist gating of the real propose path -----------------------------

    function testProposePriceSelfRoutesThroughWhitelist() external {
        uint256 t = block.timestamp;
        _request(t, 0);
        // Un-whitelisted self-proposer is rejected (proposer == msg.sender == outsider).
        _fund(outsider, 10_000 ether);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ProposerNotWhitelisted.selector);
        vm.prank(outsider);
        moo.proposePrice(requester, IDENTIFIER, t, ANCILLARY, 1);

        // Whitelisted self-proposer succeeds.
        _proposeSelf(proposer, t, 1);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Proposed));
    }

    function testCustomEnabledWhitelistOverridesDefault() external {
        uint256 t = block.timestamp;
        // A request-specific whitelist that allows only `outsider` (who is NOT in the default whitelist).
        AddressWhitelist custom = new AddressWhitelist();
        custom.addToWhitelist(outsider);
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(custom));

        _request(t, 0);

        // The default proposer is now blocked for this request.
        _fund(proposer, 10_000 ether);
        vm.expectRevert(ManagedOptimisticOracleV2Interface.ProposerNotWhitelisted.selector);
        vm.prank(proposer);
        moo.proposePrice(requester, IDENTIFIER, t, ANCILLARY, 1);

        // The custom-whitelisted proposer can propose.
        _proposeSelf(outsider, t, 1);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Proposed));
    }

    function testDisabledWhitelistAllowsAnyProposerThenSettles() external {
        uint256 t = block.timestamp;
        vm.prank(requestManager);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(disabledWhitelist));
        _request(t, 0);

        // Open proposing: an arbitrary address proposes and the request settles on expiry.
        _proposeSelf(outsider, t, 55);
        vm.warp(t + DEFAULT_LIVENESS);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).resolvedPrice, 55);
    }

    // ----------------------------- manager overrides take effect end-to-end -----------------------------

    function testCustomLivenessShortensSettlementWindow() external {
        uint256 t = block.timestamp;
        vm.prank(requestManager);
        moo.requestManagerSetCustomLiveness(requester, IDENTIFIER, ANCILLARY, 3 hours);
        _request(t, 0);
        _proposeSelf(proposer, t, 1);

        // Custom liveness => expiration is t + 3h, far earlier than the 2-day default.
        OptimisticOracleV2Interface.Request memory r = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(r.expirationTime, t + 3 hours);

        vm.warp(t + 3 hours - 1);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Proposed));
        vm.expectRevert(OptimisticOracleV2Interface.RequestNotSettleable.selector);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);

        vm.warp(t + 3 hours);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Expired));
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);
    }

    function testCustomBondPulledAndReturned() external {
        uint256 t = block.timestamp;
        vm.prank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 5 ether);
        _request(t, 0);

        uint256 totalBond = _proposeSelf(proposer, t, 1); // funds proposer with PURSE first
        // totalBond = customBond(5) + finalFee(10).
        assertEq(totalBond, 15 ether);
        assertEq(currency.balanceOf(proposer), PURSE - 15 ether);

        vm.warp(t + DEFAULT_LIVENESS);
        uint256 payout = moo.settle(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(payout, 15 ether); // bond(5) + finalFee(10) + reward(0)
        assertEq(currency.balanceOf(proposer), PURSE); // fully made whole
    }

    function testManagerBondOverridesRequesterSetBond() external {
        uint256 t = block.timestamp;
        _request(t, 0);

        // Requester sets their own bond (base OOv2 setter, not range-checked)...
        vm.prank(requester);
        moo.setBond(IDENTIFIER, t, ANCILLARY, 3 ether);
        // ...but the manager override wins at propose time.
        vm.prank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 7 ether);

        uint256 totalBond = _proposeSelf(proposer, t, 1);
        assertEq(totalBond, 17 ether); // 7 (manager) + 10 finalFee, NOT 3 (requester)
        assertEq(moo.getRequest(requester, IDENTIFIER, t, ANCILLARY).requestSettings.bond, 7 ether);
    }

    function testRequesterSetBondUsedWhenNoManagerOverride() external {
        uint256 t = block.timestamp;
        _request(t, 0);
        vm.prank(requester);
        moo.setBond(IDENTIFIER, t, ANCILLARY, 4 ether);
        uint256 totalBond = _proposeSelf(proposer, t, 1);
        assertEq(totalBond, 14 ether); // 4 + 10, requester's value honored
    }

    function testBondRangeBoundariesAccepted() external {
        // Exactly min and exactly max are valid manager bond settings.
        vm.startPrank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), MIN_BOND);
        assertEq(
            moo.getRequest(requester, IDENTIFIER, block.timestamp, ANCILLARY).requestSettings.bond, 0
        ); // not yet applied (only at propose)
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), MAX_BOND);
        vm.stopPrank();
        // Stored custom bond reflects the last accepted value (max).
        (uint256 amount,) = moo.customBonds(moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY), IERC20(address(currency)));
        assertEq(amount, MAX_BOND);
    }

    // ----------------------------- advance configuration (managedRequestId omits timestamp) -----------------------------

    function testManagerConfigSetBeforeRequestApplies() external {
        // Configure bond, liveness and a custom whitelist BEFORE the request exists.
        AddressWhitelist custom = new AddressWhitelist();
        custom.addToWhitelist(outsider);
        vm.startPrank(requestManager);
        moo.requestManagerSetBond(requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 8 ether);
        moo.requestManagerSetCustomLiveness(requester, IDENTIFIER, ANCILLARY, 5 hours);
        moo.requestManagerSetProposerWhitelist(requester, IDENTIFIER, ANCILLARY, address(custom));
        vm.stopPrank();

        // Now the request is made at some later timestamp; the config still applies (id omits timestamp).
        uint256 t = block.timestamp + 123;
        vm.warp(t);
        _request(t, 0);

        uint256 totalBond = _proposeSelf(outsider, t, 1); // outsider allowed by the pre-set custom whitelist
        assertEq(totalBond, 18 ether); // bond 8 + finalFee 10
        OptimisticOracleV2Interface.Request memory r = moo.getRequest(requester, IDENTIFIER, t, ANCILLARY);
        assertEq(r.expirationTime, t + 5 hours);
        assertEq(r.requestSettings.bond, 8 ether);
    }

    // ----------------------------- events -----------------------------

    function testSettleEmitsEvent() external {
        uint256 t = block.timestamp;
        _request(t, 0);
        _proposeSelf(proposer, t, 321);
        vm.warp(t + DEFAULT_LIVENESS);
        vm.expectEmit(true, true, true, true);
        emit OptimisticOracleV2Interface.Settle(requester, proposer, address(0), IDENTIFIER, t, ANCILLARY, 321, 20 ether);
        moo.settle(requester, IDENTIFIER, t, ANCILLARY);
    }

    function testSettleAndGetPriceSettlesAndReturns() external {
        uint256 t = block.timestamp;
        // settleAndGetPrice uses msg.sender as the requester, so it must be called by the (whitelisted) requester.
        _request(t, 0);
        _proposeSelf(proposer, t, 777);
        vm.warp(t + DEFAULT_LIVENESS);
        vm.prank(requester);
        int256 price = moo.settleAndGetPrice(IDENTIFIER, t, ANCILLARY);
        assertEq(price, 777);
        assertEq(uint256(_state(t)), uint256(OptimisticOracleV2Interface.State.Settled));
    }

    // ----------------------------- multicall (batched management) -----------------------------

    function testMulticallBatchesManagerConfig() external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            ManagedOptimisticOracleV2.requestManagerSetBond,
            (requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 6 ether)
        );
        calls[1] = abi.encodeCall(
            ManagedOptimisticOracleV2.requestManagerSetCustomLiveness, (requester, IDENTIFIER, ANCILLARY, 4 hours)
        );

        // delegatecall preserves msg.sender, so a single prank covers both inner manager calls.
        vm.prank(requestManager);
        moo.multicall(calls);

        bytes32 id = moo.getManagedRequestId(requester, IDENTIFIER, ANCILLARY);
        (uint256 amount,) = moo.customBonds(id, IERC20(address(currency)));
        (uint256 liveness,) = moo.customLivenessValues(id);
        assertEq(amount, 6 ether);
        assertEq(liveness, 4 hours);
    }

    function testMulticallBubblesRevert() external {
        bytes[] memory calls = new bytes[](1);
        // Bond above the allowed max -> inner call reverts -> the whole multicall reverts.
        calls[0] = abi.encodeCall(
            ManagedOptimisticOracleV2.requestManagerSetBond,
            (requester, IDENTIFIER, ANCILLARY, IERC20(address(currency)), 5_000 ether)
        );
        vm.prank(requestManager);
        vm.expectRevert();
        moo.multicall(calls);
    }
}
