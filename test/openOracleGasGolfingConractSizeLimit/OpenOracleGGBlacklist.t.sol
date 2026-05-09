// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {OpenOracle as OpenOracleGG} from "../../src/OpenOracleGasGolfing_ContractSizeLimit.sol";
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

// Ported from BlacklistTrollingTest.t.sol. In the gas-golfing contract,
// dispute/settle payouts already go to the internal `tokenHolder` mapping
// rather than being pushed externally, so a blacklist on the previous
// reporter or current reporter is irrelevant during the actual oracle flow.
// The blacklist becomes relevant only at withdraw time (`getHeldTokens`),
// where `_transferTokens` falls back to re-crediting the internal balance
// if the external push reverts.
contract OpenOracleGGBlacklistTest is Test {
    OpenOracleGG internal oracle;
    BlacklistableERC20 internal token1;
    BlacklistableERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    uint256 constant ORACLE_FEE = 0.01 ether;
    uint96 constant SETTLER_REWARD = 0.001 ether;

    uint256 internal constant ORACLE_GAME_SLOT = 1;

    function setUp() public {
        oracle = new OpenOracleGG();
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

    function _stateHash(uint256 reportId) internal view returns (bytes32) {
        return vm.load(address(oracle), keccak256(abi.encode(reportId, ORACLE_GAME_SLOT)));
    }

    function _emptyTiming() internal pure returns (OpenOracleGG.TimingBoundaries memory) {
        return OpenOracleGG.TimingBoundaries({
            blockNumber: 0,
            blockNumberBound: 0,
            blockTimestamp: 0,
            blockTimestampBound: 0
        });
    }

    function _oracleCaller() internal returns (address) {
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.Prank || mode == VmSafe.CallerMode.RecurrentPrank) return sender;
        return address(this);
    }

    function _submitInitialReport(
        uint256 reportId,
        uint128 amount1,
        uint128 amount2,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries memory timing
    ) internal {
        oracle.submitInitialReport(
            reportId,
            amount1,
            amount2,
            stateHash,
            _oracleCaller(),
            tryInternalBalance1,
            tryInternalBalance2,
            timing
        );
    }

    function _disputeAndSwap(
        uint256 reportId,
        address tokenToSwap,
        uint128 newAmount1,
        uint128 newAmount2,
        uint128 amt2Expected,
        bytes32 stateHash,
        bool tryInternalBalance1,
        bool tryInternalBalance2,
        OpenOracleGG.TimingBoundaries memory timing
    ) internal {
        oracle.disputeAndSwap(
            reportId,
            tokenToSwap,
            newAmount1,
            newAmount2,
            _oracleCaller(),
            amt2Expected,
            stateHash,
            tryInternalBalance1,
            tryInternalBalance2,
            timing
        );
    }

    function _params() internal view returns (OpenOracleGG.CreateReportParams memory) {
        return OpenOracleGG.CreateReportParams({
            exactToken1Report: 1e18,
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
            timeType: true,
            trackDisputes: false,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: protocolFeeRecipient
        });
    }

    // -------------------------------------------------------------------------
    // Dispute swaps token1; previous reporter (bob) blacklisted on token1
    // -------------------------------------------------------------------------
    // In the gas-golfing version, the dispute credits bob's token1 winnings
    // to `tokenHolder[bob][token1]` regardless of blacklist state. Bob can
    // only externalize them when unblacklisted; if he tries while blacklisted,
    // `getHeldTokens` re-credits his internal balance via the `_transferTokens`
    // fallback.
    function testDisputeToken1_PreviousReporterBlacklisted() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_params(), true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        // Blacklist bob on token1 prior to dispute. Dispute should still succeed,
        // since payout to bob is internal-balance only — no external push.
        token1.blacklist(bob);

        uint256 bobToken1ExtBefore = token1.balanceOf(bob);

        vm.prank(alice);
        _disputeAndSwap(
            reportId, address(token1), 1.1e18, 2100e18, 2000e18, sh, false, false, _emptyTiming()
        );

        // Bob's external balance unchanged (gas-golfing never pushes during dispute).
        assertEq(token1.balanceOf(bob), bobToken1ExtBefore, "bob external token1 unchanged");

        // Bob's internal balance: 1 (dust sentinel) + 2*oldAmount + fee.
        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 expectedBob = 1 + 2e18 + fee;
        assertEq(oracle.tokenHolder(bob, address(token1)), expectedBob, "bob internal token1");

        // Bob tries to withdraw while still blacklisted. Underlying transfer fails,
        // and `_transferTokens` falls back to re-crediting bob's internal balance.
        // Net result: bob still has the same internal balance.
        vm.prank(bob);
        oracle.getHeldTokens(address(token1));
        assertEq(token1.balanceOf(bob), bobToken1ExtBefore, "still no external delivery");
        assertEq(oracle.tokenHolder(bob, address(token1)), expectedBob, "internal balance preserved");

        // Settle and unblacklist; bob can now withdraw.
        vm.warp(block.timestamp + 300);
        vm.prank(charlie);
        oracle.settle(reportId);

        token1.unblacklist(bob);

        uint256 bobBefore = token1.balanceOf(bob);
        vm.prank(bob);
        oracle.getHeldTokens(address(token1));
        // Withdraw leaves 1 unit dust.
        assertEq(token1.balanceOf(bob), bobBefore + expectedBob - 1, "bob withdrew minus dust");
        assertEq(oracle.tokenHolder(bob, address(token1)), 1, "dust sentinel left");
    }

    // -------------------------------------------------------------------------
    // Dispute swaps token2; previous reporter (bob) blacklisted on token2
    // -------------------------------------------------------------------------
    function testDisputeToken2_PreviousReporterBlacklisted() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_params(), true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 6);

        token2.blacklist(bob);

        // Dispute swaps token2: alice posts newAmount2 + oldAmount2 + fee + protocolFee of token2.
        vm.prank(alice);
        _disputeAndSwap(
            reportId, address(token2), 1.1e18, 2100e18, 2000e18, sh, false, false, _emptyTiming()
        );

        uint256 fee = (2000e18 * 3000) / 1e7;
        uint256 expectedBobInternal = 1 + 2 * 2000e18 + fee;
        assertEq(oracle.tokenHolder(bob, address(token2)), expectedBobInternal, "bob internal token2");

        // Settle, unblacklist, withdraw.
        vm.warp(block.timestamp + 300);
        vm.prank(charlie);
        oracle.settle(reportId);

        token2.unblacklist(bob);
        uint256 bobBefore = token2.balanceOf(bob);
        vm.prank(bob);
        oracle.getHeldTokens(address(token2));
        assertEq(token2.balanceOf(bob), bobBefore + expectedBobInternal - 1, "bob withdrew minus dust");
    }

    // -------------------------------------------------------------------------
    // Settle: current reporter blacklisted on both tokens
    // -------------------------------------------------------------------------
    // Settle never pushes tokens in gas-golfing, so blacklist on bob is irrelevant
    // for the settle transaction itself. The funds become recoverable later.
    function testSettle_CurrentReporterBlacklistedBothTokens() public {
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(_params(), true);
        bytes32 sh = _stateHash(reportId);

        vm.prank(bob);
        _submitInitialReport(reportId, 1e18, 2000e18, sh, false, false, _emptyTiming());

        vm.warp(block.timestamp + 301);

        token1.blacklist(bob);
        token2.blacklist(bob);

        uint256 charlieETHBefore = charlie.balance;

        vm.prank(charlie);
        oracle.settle(reportId);

        // Charlie's settler reward is credited internally (gas-golfing also doesn't
        // push ETH on settle).
        assertEq(charlie.balance, charlieETHBefore, "charlie external ETH unchanged");
        assertEq(oracle.ethHolder(charlie), 1 + SETTLER_REWARD, "charlie settler reward credited (sentinel + reward)");

        // Bob's tokens are credited internally.
        assertEq(oracle.tokenHolder(bob, address(token1)), 1 + 1e18, "bob internal token1");
        assertEq(oracle.tokenHolder(bob, address(token2)), 1 + 2000e18, "bob internal token2");

        // Oracle still holds the underlying tokens (no extra dust unit under
        // virtual sentinel — tokenHolder shows 1+amt but the 1 is virtual).
        assertEq(token1.balanceOf(address(oracle)), 1e18, "oracle holds token1");
        assertEq(token2.balanceOf(address(oracle)), 2000e18, "oracle holds token2");

        // Bob can recover after unblacklist.
        token1.unblacklist(bob);
        token2.unblacklist(bob);

        uint256 b1 = token1.balanceOf(bob);
        uint256 b2 = token2.balanceOf(bob);
        vm.prank(bob);
        oracle.getHeldTokens(address(token1));
        vm.prank(bob);
        oracle.getHeldTokens(address(token2));
        assertEq(token1.balanceOf(bob), b1 + 1e18, "bob recovered token1 (sentinel left)");
        assertEq(token2.balanceOf(bob), b2 + 2000e18, "bob recovered token2 (sentinel left)");
    }
}
