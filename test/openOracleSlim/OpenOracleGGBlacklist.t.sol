// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CompatTypes} from "./CompatTypes.sol";
import "forge-std/Vm.sol";
import {OpenOracle as Slim} from "../../src/OpenOracleSlim.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// USDC-style ERC20 with mutable blacklist enforcement on transfer/transferFrom.
contract BlacklistableERC20 is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function blacklist(address a) external {
        blacklisted[a] = true;
    }

    function unblacklist(address a) external {
        blacklisted[a] = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[msg.sender], "blacklisted sender");
        require(!blacklisted[to], "blacklisted recipient");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[from], "blacklisted sender");
        require(!blacklisted[to], "blacklisted recipient");
        return super.transferFrom(from, to, amount);
    }
}

// Ported from BlacklistTrollingTest.t.sol. In the slim contract,
// dispute/settle payouts go to the internal `tokenHolder` mapping rather
// than being pushed externally, so a blacklist on the previous reporter or
// current reporter is irrelevant during the actual oracle flow.
// The blacklist becomes relevant only at withdraw time: `_withdraw` reverts
// outright on a blacklisted ERC20 transfer (no internal re-credit fallback).
contract OpenOracleGGBlacklistTest is Test {
    Slim internal oracle;
    BlacklistableERC20 internal token1;
    BlacklistableERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    uint96 constant SETTLER_REWARD = 0.001 ether;
    uint8 constant FLAG_TIME_TYPE = 1 << 0;

    function setUp() public {
        oracle = new Slim();
        token1 = new BlacklistableERC20("Token1", "TK1");
        token2 = new BlacklistableERC20("Token2", "TK2");

        token1.transfer(alice, 100 ether);
        token1.transfer(bob, 100 ether);
        token1.transfer(charlie, 100 ether);
        token2.transfer(alice, 100_000 ether);
        token2.transfer(bob, 100_000 ether);
        token2.transfer(charlie, 100_000 ether);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);

        _approve(alice);
        _approve(bob);
        _approve(charlie);
    }

    function _approve(address u) internal {
        vm.startPrank(u);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function _emptyTiming() internal pure returns (Slim.TimingBoundaries memory) {
        return
            Slim.TimingBoundaries({blockNumber: 0, blockNumberBound: 0, blockTimestamp: 0, blockTimestampBound: 0});
    }

    function _params() internal view returns (CompatTypes.CreateReportParams memory) {
        return CompatTypes.CreateReportParams({
            escalationHalt: 10e18,
            settlerReward: SETTLER_REWARD,
            token1Address: address(token1),
            settlementTime: uint48(300),
            disputeDelay: uint24(5),
            protocolFee: uint24(1000),
            token2Address: address(token2),
            callbackGasLimit: 0,
            feePercentage: uint24(3000),
            multiplier: uint16(110),
            callbackContract: address(0),
            protocolFeeRecipient: protocolFeeRecipient,
            flags: FLAG_TIME_TYPE
        });
    }

    // Captures everything bob needs to dispute/settle later.
    struct Ctx {
        uint256 reportId;
        Slim.OracleGame game;
        Slim.PreimageHelper helper;
    }

    // Bob calls report() — becomes both creator and reporter.
    function _bobReports(uint128 amount1, uint128 amount2) internal returns (Ctx memory ctx) {
        CompatTypes.CreateReportParams memory p = _params();
        uint256 createTs = block.timestamp;
        uint256 createBn = block.number;

        vm.prank(bob);
        ctx.reportId = CompatTypes.reportRaw(oracle, SETTLER_REWARD, p, amount1, amount2, bob, false, false, _emptyTiming());

        ctx.game.token1 = p.token1Address;
        ctx.game.token2 = p.token2Address;
        ctx.game.feePercentage = p.feePercentage;
        ctx.game.multiplier = p.multiplier;
        ctx.game.settlementTime = p.settlementTime;
        ctx.game.escalationHalt = p.escalationHalt;
        ctx.game.disputeDelay = p.disputeDelay;
        ctx.game.protocolFee = p.protocolFee;
        ctx.game.settlerReward = p.settlerReward;
        ctx.game.callbackContract = p.callbackContract;
        ctx.game.callbackGasLimit = p.callbackGasLimit;
        ctx.game.protocolFeeRecipient = p.protocolFeeRecipient;
        ctx.game.flags = p.flags;
        ctx.game.currentAmount1 = amount1;
        ctx.game.currentAmount2 = amount2;
        ctx.game.currentReporter = payable(bob);
        ctx.game.reportTimestamp = uint48(block.timestamp);
        ctx.game.lastReportOppoTime = uint48(block.number);

        ctx.helper = Slim.PreimageHelper({
            reportId: ctx.reportId,
            creator: bob,
            blockTimestamp: createTs,
            blockNumber: createBn
        });
    }

    // Alice disputes ctx.game; updates ctx.game in place.
    function _aliceDisputes(Ctx memory ctx, address tokenToSwap, uint128 newA1, uint128 newA2)
        internal
        returns (Ctx memory)
    {
        vm.prank(alice);
        oracle.dispute(
            ctx.reportId, tokenToSwap, newA1, newA2, alice, false, false, ctx.game, ctx.helper, _emptyTiming()
        );
        ctx.game.currentAmount1 = newA1;
        ctx.game.currentAmount2 = newA2;
        ctx.game.currentReporter = payable(alice);
        ctx.game.reportTimestamp = uint48(block.timestamp);
        ctx.game.lastReportOppoTime = uint48(block.number);
        return ctx;
    }

    // -------------------------------------------------------------------------
    // Dispute swaps token1; previous reporter (bob) blacklisted on token1
    // -------------------------------------------------------------------------
    function testDisputeToken1_PreviousReporterBlacklisted() public {
        Ctx memory ctx = _bobReports(1e18, 2000e18);

        vm.warp(block.timestamp + 6);

        // Blacklist bob on token1 prior to dispute. Dispute should still succeed,
        // since payout to bob is internal-balance only — no external push.
        token1.blacklist(bob);

        uint256 bobToken1ExtBefore = token1.balanceOf(bob);

        ctx = _aliceDisputes(ctx, address(token1), 1.1e18, 2100e18);

        // Bob's external balance unchanged (slim never pushes during dispute).
        assertEq(token1.balanceOf(bob), bobToken1ExtBefore, "bob external token1 unchanged");

        // Bob's internal balance: 1 (dust sentinel) + 2*oldAmount + fee.
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 expectedBob = 1 + 2e18 + fee;
        assertEq(oracle.tokenHolder(bob, address(token1)), expectedBob, "bob internal token1");

        // Bob tries to withdraw while still blacklisted. safeTransfer reverts; no
        // silent re-credit fallback — bob must wait until unblacklisted.
        vm.prank(bob);
        vm.expectRevert();
        oracle.withdraw(address(token1), type(uint256).max);

        // Settle and unblacklist; bob can now withdraw.
        vm.warp(block.timestamp + 300);
        vm.prank(charlie);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);

        token1.unblacklist(bob);

        uint256 bobBefore = token1.balanceOf(bob);
        vm.prank(bob);
        oracle.withdraw(address(token1), type(uint256).max);
        // Withdraw leaves 1 unit dust.
        assertEq(token1.balanceOf(bob), bobBefore + expectedBob - 1, "bob withdrew minus dust");
        assertEq(oracle.tokenHolder(bob, address(token1)), 1, "dust sentinel left");
    }

    // -------------------------------------------------------------------------
    // Dispute swaps token2; previous reporter (bob) blacklisted on token2
    // -------------------------------------------------------------------------
    function testDisputeToken2_PreviousReporterBlacklisted() public {
        Ctx memory ctx = _bobReports(1e18, 2000e18);

        vm.warp(block.timestamp + 6);

        token2.blacklist(bob);

        ctx = _aliceDisputes(ctx, address(token2), 1.1e18, 2100e18);

        uint256 fee = (2000e18 * 3000) / 1e7;
        uint256 expectedBobInternal = 1 + 2 * 2000e18 + fee;
        assertEq(oracle.tokenHolder(bob, address(token2)), expectedBobInternal, "bob internal token2");

        // Settle, unblacklist, withdraw.
        vm.warp(block.timestamp + 300);
        vm.prank(charlie);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);

        token2.unblacklist(bob);
        uint256 bobBefore = token2.balanceOf(bob);
        vm.prank(bob);
        oracle.withdraw(address(token2), type(uint256).max);
        assertEq(token2.balanceOf(bob), bobBefore + expectedBobInternal - 1, "bob withdrew minus dust");
    }

    // -------------------------------------------------------------------------
    // Settle: current reporter blacklisted on both tokens
    // -------------------------------------------------------------------------
    function testSettle_CurrentReporterBlacklistedBothTokens() public {
        Ctx memory ctx = _bobReports(1e18, 2000e18);

        vm.warp(block.timestamp + 301);

        token1.blacklist(bob);
        token2.blacklist(bob);

        uint256 charlieETHBefore = charlie.balance;

        vm.prank(charlie);
        oracle.settle(ctx.reportId, ctx.game, ctx.helper);

        // Charlie's settler reward is credited internally (slim doesn't push ETH on settle).
        assertEq(charlie.balance, charlieETHBefore, "charlie external ETH unchanged");
        assertEq(
            oracle.tokenHolder(charlie, address(0)),
            1 + SETTLER_REWARD,
            "charlie settler reward credited (sentinel + reward)"
        );

        // Bob's tokens are credited internally.
        assertEq(oracle.tokenHolder(bob, address(token1)), 1 + 1e18, "bob internal token1");
        assertEq(oracle.tokenHolder(bob, address(token2)), 1 + 2000e18, "bob internal token2");

        // Oracle still holds the underlying tokens.
        assertEq(token1.balanceOf(address(oracle)), 1e18, "oracle holds token1");
        assertEq(token2.balanceOf(address(oracle)), 2000e18, "oracle holds token2");

        // Bob can recover after unblacklist.
        token1.unblacklist(bob);
        token2.unblacklist(bob);

        uint256 b1 = token1.balanceOf(bob);
        uint256 b2 = token2.balanceOf(bob);
        vm.prank(bob);
        oracle.withdraw(address(token1), type(uint256).max);
        vm.prank(bob);
        oracle.withdraw(address(token2), type(uint256).max);
        assertEq(token1.balanceOf(bob), b1 + 1e18, "bob recovered token1 (sentinel left)");
        assertEq(token2.balanceOf(bob), b2 + 2000e18, "bob recovered token2 (sentinel left)");
    }
}
